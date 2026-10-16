import 'dart:io';

import 'package:ech_http/src/build_support/cmake.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late String source;
  late String build;
  late File cache;
  late File metadata;
  late File artifact;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ech-cmake-');
    source = p.join(root.path, 'checkout', 'src');
    build = p.join(root.path, 'build');
    await Directory(p.join(build, 'CMakeFiles')).create(recursive: true);
    cache = File(p.join(build, 'CMakeCache.txt'));
    metadata = File(p.join(build, 'CMakeFiles', 'stamp'));
    artifact = File(p.join(build, 'libech_http.so'));
    await metadata.writeAsString('generated');
    await artifact.writeAsString('compiled library');
  });
  tearDown(() => root.delete(recursive: true));

  test('keeps an incremental build at the same source location', () async {
    await cache.writeAsString('CMAKE_HOME_DIRECTORY:INTERNAL=$source\n');
    await prepareCmakeDirectory(source, build);
    expect(await cache.exists(), isTrue);
    expect(await metadata.exists(), isTrue);
  });

  test('local-to-Git dependency changes discard only CMake metadata', () async {
    await cache.writeAsString('CMAKE_HOME_DIRECTORY:INTERNAL=$source\n');
    await prepareCmakeDirectory(p.join(root.path, 'pub-cache', 'src'), build);
    expect(await cache.exists(), isFalse);
    expect(await metadata.exists(), isFalse);
    expect(await artifact.readAsString(), 'compiled library');
  });

  test('accepts a build directory without a cache', () async {
    await prepareCmakeDirectory(source, build);
    expect(await artifact.exists(), isTrue);
  });
}
