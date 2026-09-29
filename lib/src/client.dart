import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:io' show HttpClientResponseCompressionState;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:http/http.dart' as http;

import 'native.dart' as native;
import 'types.dart';

/// A streaming package:http client with an in-process TLS/HTTP backend.
/// Non-null resolver results require verified ECH without plaintext fallback.
/// Uploads are buffered up to [maxRequestBytes]. Call [close] when finished.
final class EchClient extends http.BaseClient implements Finalizable {
  EchClient({
    this.resolver,
    this.proxy,
    this.timeout = const Duration(seconds: 30),
    this.connectTimeout = const Duration(seconds: 10),
    this.maxResponseBytes = 32 * 1024 * 1024,
    this.maxRequestBytes = 8 * 1024 * 1024,
    this.maxConcurrentRequests = 64,
    this.maxConcurrentRequestsPerHost = 6,
    this.autoUncompress = true,
    this.trustedRootsPem,
  }) {
    if (timeout.inMilliseconds <= 0 ||
        timeout.inMilliseconds > 0x7fffffff ||
        connectTimeout.inMilliseconds <= 0 ||
        connectTimeout.inMilliseconds > 0x7fffffff) {
      throw ArgumentError(
        'Timeouts must be positive and fit a signed 32-bit millisecond count',
      );
    }
    if (maxResponseBytes <= 0 ||
        maxRequestBytes <= 0 ||
        maxConcurrentRequests <= 0 ||
        maxConcurrentRequestsPerHost <= 0) {
      throw ArgumentError('Limits must be positive');
    }
    if (proxy != null &&
        (proxy!.scheme != 'http' ||
            proxy!.host.isEmpty ||
            proxy!.fragment.isNotEmpty ||
            proxy!.query.isNotEmpty ||
            (proxy!.path.isNotEmpty && proxy!.path != '/'))) {
      throw ArgumentError.value(proxy, 'proxy', 'Expected an HTTP proxy URL');
    }
    _client = native.clientCreate();
    if (_client == nullptr) {
      throw StateError('Unable to initialize the native HTTP backend');
    }
    _scheduler = _RequestScheduler(
      maxConcurrentRequests,
      maxConcurrentRequestsPerHost,
    );
    _finalizer.attach(this, _client.cast(), detach: this);
  }

  final EchResolver? resolver;
  final Uri? proxy;
  final Duration timeout;
  final Duration connectTimeout;

  /// Maximum delivered body bytes, after gzip decoding when enabled.
  final int maxResponseBytes;
  final int maxRequestBytes;

  /// Maximum in-flight native requests across all hosts for this client.
  final int maxConcurrentRequests;

  /// Per-client limit by URL hostname, ignoring case, scheme, port and proxy.
  /// Saturated hosts do not block requests to other hosts.
  final int maxConcurrentRequestsPerHost;

  /// Decodes gzip while preserving wire headers and Content-Length.
  /// Disabling this does not disable gzip negotiation.
  final bool autoUncompress;

  /// Replaces the bundled Mozilla CA roots for this client, e.g. for private PKI.
  final String? trustedRootsPem;
  static final _finalizer = NativeFinalizer(
    Native.addressOf<
          NativeFunction<Void Function(Pointer<native.NativeClient>)>
        >(native.clientDestroy)
        .cast(),
  );
  late Pointer<native.NativeClient> _client;
  late final _RequestScheduler _scheduler;
  final Set<_Transfer> _transfers = {};
  final Set<_Operation> _operations = {};
  bool _closed = false;

  static String get backendVersion => native.nativeVersion().toDartString();

  @override
  Future<EchResponse> send(http.BaseRequest request) async {
    if (_closed) throw http.ClientException('Client is closed', request.url);
    _validateUrl(request.url);
    final operation = _Operation();
    _operations.add(operation);
    if (request is http.Abortable) {
      unawaited(
        request.abortTrigger?.then(
          (_) => operation.cancel(http.RequestAbortedException(request.url)),
          onError: (Object _, StackTrace _) =>
              operation.cancel(http.RequestAbortedException(request.url)),
        ),
      );
    }
    try {
      return await _send(request, operation);
    } finally {
      _operations.remove(operation);
    }
  }

  Future<EchResponse> _send(
    http.BaseRequest request,
    _Operation operation,
  ) async {
    final body = BytesBuilder(copy: false);
    final upload = StreamIterator(request.finalize());
    try {
      while (await operation.race(upload.moveNext())) {
        final chunk = upload.current;
        if (body.length + chunk.length > maxRequestBytes) {
          throw http.ClientException(
            'Upload exceeds maxRequestBytes',
            request.url,
          );
        }
        body.add(chunk);
      }
    } finally {
      unawaited(upload.cancel());
    }
    var bytes = body.takeBytes();
    var uri = request.url;
    var method = request.method;
    var headers = Map<String, String>.of(request.headers);
    if (!headers.keys.any((key) => key.toLowerCase() == 'accept-encoding')) {
      headers['accept-encoding'] = 'gzip';
    }
    for (var redirects = 0; ; redirects++) {
      operation.check();
      final route = uri.scheme == 'https' && resolver != null
          ? await operation.race(resolver!.resolve(uri))
          : null;
      final response = await _sendWithRoute(
        request,
        uri,
        method,
        headers,
        bytes,
        route,
        operation,
      );
      final location = response.headers['location'];
      if (!request.followRedirects ||
          !response.isRedirect ||
          location == null) {
        return response;
      }
      await response.stream.drain<void>();
      if (redirects >= request.maxRedirects) {
        throw http.ClientException('Too many redirects', uri);
      }
      final next = uri.resolve(location);
      _validateUrl(next);
      if (uri.scheme == 'https' && next.scheme != 'https') {
        throw http.ClientException('HTTPS downgrade redirect refused', next);
      }
      if (uri.origin != next.origin) {
        headers.removeWhere(
          (key, _) => {
            'authorization',
            'cookie',
            'proxy-authorization',
            'host',
          }.contains(key.toLowerCase()),
        );
      }
      if ((response.statusCode == 303 && method != 'HEAD') ||
          ((response.statusCode == 301 || response.statusCode == 302) &&
              method == 'POST')) {
        method = 'GET';
        bytes = Uint8List(0);
        headers.removeWhere(
          (key, _) => {
            'content-length',
            'content-type',
            'transfer-encoding',
          }.contains(key.toLowerCase()),
        );
      }
      uri = next;
    }
  }

  Future<EchResponse> _sendWithRoute(
    http.BaseRequest original,
    Uri uri,
    String method,
    Map<String, String> headers,
    Uint8List body,
    EchRoute? route,
    _Operation operation,
  ) async {
    final addresses = route == null || route.addresses.isEmpty
        ? ['']
        : route.addresses;
    for (var index = 0; ; index++) {
      final slot = await _scheduler.acquire(uri, operation);
      try {
        operation.check();
        final transfer = _Transfer(
          this,
          slot,
          original,
          uri,
          method,
          headers,
          body,
          route,
          addresses[index],
        );
        _transfers.add(transfer);
        unawaited(operation.stopped.then(transfer.cancel));
        return await transfer.response.future;
      } catch (error) {
        slot.release();
        // Only replay GET/HEAD, and only before receiving response headers.
        if (error is! EchException ||
            (method != 'GET' && method != 'HEAD') ||
            index == addresses.length - 1) {
          rethrow;
        }
      }
    }
  }

  void _finished(_Transfer transfer) {
    _transfers.remove(transfer);
    transfer.slot.release();
  }

  static void _validateUrl(Uri uri) {
    if (!{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw ArgumentError.value(
        uri,
        'url',
        'Expected an HTTP(S) URL without embedded credentials',
      );
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _scheduler.close();
    for (final operation in _operations) {
      operation.cancel(http.ClientException('Client is closed'));
    }
    for (final transfer in _transfers.toList()) {
      transfer.cancel(http.ClientException('Client is closed', transfer.uri));
    }
    _finalizer.detach(this);
    native.clientDestroy(_client);
    _client = nullptr;
  }
}

final class _RequestScheduler {
  _RequestScheduler(this.maxConcurrent, this.maxPerHost);

  final int maxConcurrent;
  final int maxPerHost;
  final Set<_RequestSlot> _waiting = {};
  final Map<String, int> _activePerHost = {};
  int _active = 0;
  bool _closed = false;

  Future<_RequestSlot> acquire(Uri uri, _Operation operation) async {
    operation.check();
    final slot = _RequestSlot(this, uri.host.toLowerCase());
    _waiting.add(slot);
    _dispatch();
    try {
      await operation.race(slot.ready.future);
      return slot;
    } catch (_) {
      _waiting.remove(slot);
      slot.release();
      rethrow;
    }
  }

  void _dispatch() {
    if (_closed || _waiting.isEmpty || _active >= maxConcurrent) return;
    final admitted = <_RequestSlot>[];
    for (final slot in _waiting) {
      if (_active >= maxConcurrent) break;
      final hostActive = _activePerHost[slot.host] ?? 0;
      if (hostActive >= maxPerHost) continue;
      _active++;
      _activePerHost[slot.host] = hostActive + 1;
      slot.granted = true;
      admitted.add(slot);
    }
    for (final slot in admitted) {
      _waiting.remove(slot);
      slot.ready.complete();
    }
  }

  void _release(String host) {
    _active--;
    final remaining = _activePerHost[host]! - 1;
    if (remaining == 0) {
      _activePerHost.remove(host);
    } else {
      _activePerHost[host] = remaining;
    }
    _dispatch();
  }

  void close() {
    _closed = true;
    // Operations own cancellation; closing only stops admission.
    _waiting.clear();
  }
}

final class _RequestSlot {
  _RequestSlot(this._scheduler, this.host);

  final _RequestScheduler _scheduler;
  final String host;
  final Completer<void> ready = Completer();
  bool granted = false;

  void release() {
    if (!granted) return;
    granted = false;
    _scheduler._release(host);
  }
}

final class _Operation {
  final _stopped = Completer<Object>();
  Object? _reason;
  Future<Object> get stopped => _stopped.future;
  void cancel(Object reason) {
    if (_reason != null) return;
    _reason = reason;
    _stopped.complete(reason);
  }

  void check() {
    if (_reason case final reason?) throw reason;
  }

  Future<T> race<T>(Future<T> future) {
    return Future.any([future, stopped.then<T>((reason) => throw reason)]).then(
      (value) {
        check();
        return value;
      },
    );
  }
}

final class _Transfer implements Finalizable {
  _Transfer(
    this.client,
    this.slot,
    this.original,
    this.uri,
    String method,
    Map<String, String> headers,
    Uint8List bytes,
    EchRoute? route,
    String address,
  ) {
    if (!RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(method)) {
      throw ArgumentError.value(method, 'method');
    }
    for (final entry in headers.entries) {
      if (!RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(entry.key) ||
          entry.value.contains(RegExp(r'[\r\n\x00]'))) {
        throw ArgumentError('Invalid HTTP header');
      }
    }
    events = ReceivePort('ech_http response');
    subscription = events.listen(_onEvent);
    body = StreamController<List<int>>(onCancel: () => _finish(null));
    try {
      pointer = using((arena) {
        final opts = arena<native.NativeOptions>();
        opts.ref
          ..url = uri.toString().toNativeUtf8(allocator: arena)
          ..method = method.toNativeUtf8(allocator: arena)
          ..headers = headers.entries
              .where(
                (e) => !{
                  'content-length',
                  'transfer-encoding',
                }.contains(e.key.toLowerCase()),
              )
              .map(
                (e) => e.value.isEmpty ? '${e.key};' : '${e.key}: ${e.value}',
              )
              .join('\r\n')
              .toNativeUtf8(allocator: arena)
          ..proxy = (client.proxy?.toString() ?? '').toNativeUtf8(
            allocator: arena,
          )
          ..echConfig = (route?.configList ?? '').toNativeUtf8(allocator: arena)
          ..connectIp = address.toNativeUtf8(allocator: arena)
          ..caPem = (client.trustedRootsPem ?? '').toNativeUtf8(
            allocator: arena,
          )
          ..bodyLength = bytes.length
          ..timeoutMs = client.timeout.inMilliseconds
          ..connectTimeoutMs = client.connectTimeout.inMilliseconds
          ..maxResponseBytes = client.maxResponseBytes
          ..autoUncompress = client.autoUncompress;
        if (bytes.isNotEmpty) {
          opts.ref.body = arena<Uint8>(bytes.length);
          opts.ref.body.asTypedList(bytes.length).setAll(0, bytes);
        }
        return native.requestStart(
          client._client,
          opts,
          NativeApi.postCObject,
          events.sendPort.nativePort,
        );
      });
      if (pointer == nullptr) {
        throw StateError('Unable to start native request');
      }
      _finalizer.attach(this, pointer.cast(), detach: this);
    } catch (_) {
      events.close();
      unawaited(subscription.cancel());
      unawaited(body.close());
      if (pointer != nullptr) native.requestDestroy(pointer);
      rethrow;
    }
  }

  final EchClient client;
  final _RequestSlot slot;
  final http.BaseRequest original;
  final Uri uri;
  final Completer<EchResponse> response = Completer();
  static final _finalizer = NativeFinalizer(
    Native.addressOf<
          NativeFunction<Void Function(Pointer<native.NativeRequest>)>
        >(native.requestDestroy)
        .cast(),
  );
  Pointer<native.NativeRequest> pointer = nullptr;
  late final StreamController<List<int>> body;
  late final ReceivePort events;
  late final StreamSubscription<Object?> subscription;
  bool done = false;

  void cancel(Object reason) => _finish(reason);

  List<int> _acknowledgeBody(List<int> data) {
    // Bound unread bodies without pausing completion or error events.
    if (!done) native.requestAcknowledge(pointer, data.length);
    return data;
  }

  void _onEvent(Object? message) {
    if (done) return;
    final event = message as List<Object?>;
    final type = event[0] as int;
    final code = event[1] as int;
    final data = event[4] as Uint8List;
    if (type == 1) {
      final lines = latin1.decode(data).split('\r\n');
      final headers = <String, String>{};
      for (final line in lines.skip(1)) {
        final colon = line.indexOf(':');
        if (colon <= 0) continue;
        final key = line.substring(0, colon).trim().toLowerCase();
        final text = line.substring(colon + 1).trim();
        headers.update(
          key,
          (previous) => '$previous, $text',
          ifAbsent: () => text,
        );
      }
      response.complete(
        EchResponse(
          body.stream.map(_acknowledgeBody),
          code,
          echAccepted: event[2] != 0,
          echRetries: event[3] as int,
          compressionState: headers['content-encoding'] == 'gzip'
              ? (client.autoUncompress
                    ? HttpClientResponseCompressionState.decompressed
                    : HttpClientResponseCompressionState.compressed)
              : HttpClientResponseCompressionState.notCompressed,
          contentLength: int.tryParse(headers['content-length'] ?? ''),
          request: original,
          headers: headers,
          isRedirect: const {301, 302, 303, 307, 308}.contains(code),
          reasonPhrase: lines.first.split(' ').skip(2).join(' '),
        ),
      );
    } else if (type == 2) {
      body.add(data);
    } else if (type == 3 || type == 4) {
      _finish(
        type == 4
            ? EchException(
                utf8.decode(data, allowMalformed: true),
                uri: uri,
                nativeCode: code,
              )
            : null,
      );
    }
  }

  void _finish(Object? error) {
    if (done) return;
    done = true;
    events.close();
    unawaited(subscription.cancel());
    _finalizer.detach(this);
    native.requestDestroy(pointer);
    pointer = nullptr;
    client._finished(this);
    if (!response.isCompleted) {
      response.completeError(
        error ?? EchException('Response ended without headers', uri: uri),
      );
    } else if (error != null) {
      body.addError(error);
    }
    unawaited(body.close());
  }
}
