// Creates a disposable Flutter consumer to verify automatic native bundling.
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && (args.length != 1 || args.single != 'ohos')) {
    throw ArgumentError(
      'Usage: dart run tool/create_flutter_smoke.dart [ohos]',
    );
  }
  final platforms = args.isEmpty ? 'android,ios,macos,windows,linux' : 'ohos';
  final root = Directory.current.absolute.path;
  final app = Directory('build/flutter_smoke').absolute;
  final create = await Process.run('flutter', [
    'create',
    '--no-pub',
    '--platforms=$platforms',
    '--project-name=ech_http_smoke',
    app.path,
  ], runInShell: Platform.isWindows);
  if (create.exitCode != 0) {
    throw StateError('${create.stdout}\n${create.stderr}');
  }
  final packagePath = root.replaceAll('\\', '/').replaceAll("'", "''");
  await File('${app.path}/pubspec.yaml').writeAsString('''
name: ech_http_smoke
publish_to: none
environment:
  sdk: '>=3.10.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
  ech_http:
    path: '$packagePath'
  http: ^1.6.0
dev_dependencies:
  flutter_lints: ^6.0.0
''');
  await File('${app.path}/lib/main.dart').writeAsString('''
import 'package:flutter/material.dart';
import 'package:ech_http/ech_http.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(MaterialApp(home: Scaffold(body: Center(child: FutureBuilder<String>(
    future: smoke(),
    builder: (context, snapshot) => Padding(
      padding: const EdgeInsets.all(24),
      child: SelectableText(snapshot.data ?? snapshot.error?.toString() ?? 'Testing ECH...'),
    ),
  )))));
}

Future<String> smoke() async {
  final target = Uri.https('crypto.cloudflare.com', '/cdn-cgi/trace');
  final bootstrap = EchClient();
  final client = EchClient(resolver: DohEchResolver(
    client: bootstrap,
    endpoint: Uri.https('cloudflare-dns.com', '/dns-query'),
    hosts: {target.host},
  ));
  try {
    final response = await client.send(http.Request('GET', target));
    final body = await response.stream.bytesToString();
    final result = '\${EchClient.backendVersion}\\n'
      'HTTP \${response.statusCode}\\nECH accepted: \${response.echAccepted}\\n\\n\$body';
    debugPrint('ECH_HTTP_SMOKE: \$result');
    return result;
  } finally {
    client.close();
    bootstrap.close();
  }
}
''');
  // The generated counter-widget test no longer describes this consumer.
  final counterTest = File('${app.path}/test/widget_test.dart');
  if (await counterTest.exists()) await counterTest.delete();
  if (platforms == 'ohos') {
    final module = File('${app.path}/ohos/entry/src/main/module.json5');
    final source = await module.readAsString();
    if (!source.contains('"tablet"')) {
      await module.writeAsString(
        source.replaceFirst('"phone"', '"phone", "tablet"'),
      );
    }
  }
  stdout.writeln(
    'Created ${app.path}. Run flutter pub get and flutter build <target> there.',
  );
}
