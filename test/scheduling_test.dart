import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ech_http/ech_http.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  EchClient client({
    required Uri proxy,
    int concurrency = 64,
    int perHost = 6,
    EchResolver? resolver,
  }) {
    final c = EchClient(
      proxy: proxy,
      maxConcurrentRequests: concurrency,
      maxConcurrentRequestsPerHost: perHost,
      resolver: resolver,
    );
    addTearDown(c.close);
    return c;
  }

  Completer<void> gate() {
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    return release;
  }

  // Proxy synthetic HTTP hostnames locally, without external DNS or traffic.
  Future<Uri> serve(FutureOr<void> Function(HttpRequest) handler) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      try {
        await handler(request);
      } on SocketException {
        // Deliberate cancellation.
      } on HttpException {
        // Deliberate cancellation.
      }
    });
    return Uri.http('127.0.0.1:${server.port}', '/');
  }

  test(
    'defaults bound concurrency to 64 globally and 6 per URL host',
    () async {
      final release = gate();
      final full = Completer<void>();
      final activeByHost = <String, int>{};
      final maximumByHost = <String, int>{};
      var active = 0, maximum = 0, starts = 0;
      final proxy = await serve((r) async {
        final host = r.uri.host;
        starts++;
        active++;
        if (active > maximum) maximum = active;
        final count = (activeByHost[host] ?? 0) + 1;
        activeByHost[host] = count;
        if (count > (maximumByHost[host] ?? 0)) maximumByHost[host] = count;
        if (active == 64 && !full.isCompleted) full.complete();
        await release.future;
        active--;
        activeByHost[host] = activeByHost[host]! - 1;
        r.response.write('ok');
        await r.response.close();
      });
      final c = EchClient(proxy: proxy);
      addTearDown(c.close);
      final responses = Future.wait([
        for (var host = 0; host < 12; host++)
          for (var request = 0; request < 7; request++)
            c.get(Uri.http('host-$host.example', '/$request')),
      ]);
      await full.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(starts, 64);
      expect(activeByHost.values, everyElement(lessThanOrEqualTo(6)));
      release.complete();
      expect(await responses, hasLength(84));
      expect(maximum, 64);
      expect(maximumByHost.values, everyElement(lessThanOrEqualTo(6)));
      expect(maximumByHost['host-0.example'], 6);
    },
  );

  test(
    'a saturated host does not block later requests to another host',
    () async {
      final release = gate();
      final full = Completer<void>();
      var slowStarts = 0;
      final proxy = await serve((r) async {
        if (r.uri.host == 'slow.example') {
          if (++slowStarts == 6) full.complete();
          await release.future;
        }
        r.response.write('ok');
        await r.response.close();
      });
      final c = client(proxy: proxy);
      final slow = Future.wait(
        List.generate(8, (i) => c.get(Uri.http('slow.example', '/$i'))),
      );
      await full.future.timeout(const Duration(seconds: 3));
      final fast = await c
          .get(Uri.http('fast.example'))
          .timeout(const Duration(seconds: 2));
      expect(fast.body, 'ok');
      expect(slowStarts, 6);
      expect(release.isCompleted, isFalse);
      release.complete();
      expect(await slow, hasLength(8));
    },
  );

  test('hostname limits span ports and ignore hostname case', () async {
    final release = gate();
    final entered = Completer<void>();
    final paths = <String>[];
    final proxy = await serve((r) async {
      paths.add(r.uri.path);
      if (r.uri.path == '/first') {
        entered.complete();
        await release.future;
      }
      r.response.write('ok');
      await r.response.close();
    });
    final c = client(proxy: proxy, concurrency: 2, perHost: 1);
    final first = c.get(Uri.http('SAME.example:80', '/first'));
    await entered.future;
    final second = c.get(Uri.http('same.example:8080', '/second'));
    expect(
      (await c
              .get(Uri.http('other.example', '/other'))
              .timeout(const Duration(seconds: 2)))
          .body,
      'ok',
    );
    expect(paths, ['/first', '/other']);
    release.complete();
    await Future.wait([first, second]);
    expect(paths, ['/first', '/other', '/second']);
  });

  test('host queues remain FIFO after cancelling a queued request', () async {
    final release = gate();
    final entered = Completer<void>();
    final paths = <String>[];
    final proxy = await serve((r) async {
      if (r.uri.host == 'same.example') paths.add(r.uri.path);
      if (r.uri.path == '/first') {
        entered.complete();
        await release.future;
      }
      r.response.write('ok');
      await r.response.close();
    });
    final c = client(proxy: proxy, perHost: 1);
    final first = c.get(Uri.http('same.example', '/first'));
    await entered.future;
    final abort = Completer<void>();
    final cancelled = expectLater(
      c.send(
        http.AbortableRequest(
          'GET',
          Uri.http('same.example', '/cancelled'),
          abortTrigger: abort.future,
        ),
      ),
      throwsA(isA<http.RequestAbortedException>()),
    );
    final next = Future.wait([
      c.get(Uri.http('same.example', '/one')),
      c.get(Uri.http('same.example', '/two')),
    ]);
    await c.get(Uri.http('other.example')).timeout(const Duration(seconds: 2));
    abort.complete();
    await cancelled.timeout(const Duration(seconds: 1));
    release.complete();
    await first;
    await next;
    expect(paths, ['/first', '/one', '/two']);
  });

  test(
    'redirects release the source slot and wait for destination capacity',
    () async {
      final release = gate();
      final entered = Completer<void>();
      final redirectSeen = Completer<void>();
      var targetStarts = 0;
      final proxy = await serve((r) async {
        if (r.uri.host == 'target.example') targetStarts++;
        if (r.uri.path == '/held') {
          entered.complete();
          await release.future;
        }
        if (r.uri.path == '/redirect') {
          r.response.statusCode = 302;
          r.response.headers.set('location', 'http://target.example/final');
          redirectSeen.complete();
        } else {
          r.response.write('ok');
        }
        await r.response.close();
      });
      final c = client(proxy: proxy, concurrency: 2, perHost: 1);
      final held = c.get(Uri.http('target.example', '/held'));
      await entered.future;
      var finished = false;
      final redirected = c.get(Uri.http('source.example', '/redirect')).then((
        r,
      ) {
        finished = true;
        return r;
      });
      await redirectSeen.future;
      expect(
        (await c
                .get(Uri.http('source.example', '/check'))
                .timeout(const Duration(seconds: 2)))
            .body,
        'ok',
      );
      expect(finished, isFalse);
      expect(targetStarts, 1);
      release.complete();
      await held;
      expect((await redirected).body, 'ok');
      expect(targetStarts, 2);
    },
  );

  test('failed construction and failover release host capacity', () async {
    var starts = 0;
    final proxy = await serve((r) async {
      starts++;
      r.response.write('ok');
      await r.response.close();
    });
    final c = client(
      proxy: proxy,
      perHost: 1,
      resolver: StaticEchResolver({
        'same.example': EchRoute(
          // Unsupported ECH fails before opening a connection on either IP.
          configList: base64.encode([0, 4, 0, 1, 0, 0]),
          addresses: ['127.0.0.1', '127.0.0.2'],
        ),
      }),
    );
    await expectLater(
      c.get(Uri.https('same.example')).timeout(const Duration(seconds: 2)),
      throwsA(
        isA<EchException>().having((e) => e.nativeCode, 'ECH required', 101),
      ),
    );
    final invalid = http.Request('GET', Uri.http('same.example'))
      ..headers['x-test'] = 'bad\r\nvalue';
    await expectLater(c.send(invalid), throwsArgumentError);
    expect(
      (await c
              .get(Uri.http('same.example'))
              .timeout(const Duration(seconds: 2)))
          .body,
      'ok',
    );
    expect(starts, 1);
  });

  test('closing rejects requests waiting for host capacity', () async {
    final release = gate();
    final entered = Completer<void>();
    var starts = 0;
    final proxy = await serve((r) async {
      if (++starts == 1) entered.complete();
      await release.future;
      await r.response.close();
    });
    final c = client(proxy: proxy, perHost: 1);
    final waiting = List.generate(
      3,
      (_) => expectLater(
        c.get(Uri.http('same.example')),
        throwsA(isA<http.ClientException>()),
      ),
    );
    await entered.future;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    c.close();
    await Future.wait(waiting).timeout(const Duration(seconds: 1));
    expect(starts, 1);
  });

  test('global and per-host limits must both be positive', () {
    for (final value in [0, -1]) {
      expect(
        () => EchClient(maxConcurrentRequests: value),
        throwsArgumentError,
      );
      expect(
        () => EchClient(maxConcurrentRequestsPerHost: value),
        throwsArgumentError,
      );
    }
  });
}
