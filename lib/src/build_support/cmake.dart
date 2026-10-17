import 'dart:io';

import 'package:path/path.dart' as p;

/// CMake caches absolute source paths. Hooks can reuse their output directory
/// when a dependency moves from a local checkout to a versioned pub cache.
Future<void> prepareCmakeDirectory(String source, String build) async {
  final cache = File(p.join(build, 'CMakeCache.txt'));
  if (!await cache.exists()) return;
  const prefix = 'CMAKE_HOME_DIRECTORY:INTERNAL=';
  final homes = (await cache.readAsLines()).where(
    (line) => line.startsWith(prefix),
  );
  if (homes.isEmpty ||
      p.equals(
        p.normalize(homes.single.substring(prefix.length)),
        p.normalize(p.absolute(source)),
      )) {
    return;
  }
  await cache.delete();
  final files = Directory(p.join(build, 'CMakeFiles'));
  if (await files.exists()) await files.delete(recursive: true);
}
