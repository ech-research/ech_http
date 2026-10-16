// Exercise the same hook for an explicit target, without a Flutter project.
import 'dart:convert';
import 'dart:io';

import '../hook/build.dart' as hook;
import 'package:code_assets/code_assets.dart';
import 'package:ech_http/src/build_support/ohos.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2 || args.length > 4) {
    throw ArgumentError(
      'Usage: dart run tool/check_native_build.dart <os> <arch> [device|simulator] [binary-cache]',
    );
  }
  final os = args[0], arch = args[1];
  final ohos = os == 'ohos'
      ? OhosBuildConfig.detect(
          targetOS: OS.fromString('ohos'),
          architecture: Architecture.fromString(arch),
        )
      : null;
  final simulator = args.length > 2 && args[2] == 'simulator';
  final root = Directory.current.absolute.uri;
  final directory = Directory.fromUri(
    root.resolve(
      '.dart_tool/verify/$os-$arch-${simulator ? 'simulator' : 'device'}/',
    ),
  );
  await directory.create(recursive: true);
  final config = <String, Object>{
    'link_mode_preference': 'dynamic',
    // Exercise the actual compatibility input supplied by Flutter-OH.
    'target_os': ohos == null ? os : 'linux',
    'target_architecture': arch,
    if (ohos != null)
      'c_compiler': {
        'cc':
            '${ohos.nativeSdk}/llvm/bin/clang${Platform.isWindows ? '.exe' : ''}',
        'ar':
            '${ohos.nativeSdk}/llvm/bin/llvm-ar${Platform.isWindows ? '.exe' : ''}',
        'ld':
            '${ohos.nativeSdk}/llvm/bin/ld.lld${Platform.isWindows ? '.exe' : ''}',
      },
    if (os == 'android') 'android': {'target_ndk_api': 21},
    if (os == 'ios')
      'ios': {
        'target_sdk': simulator ? 'iphonesimulator' : 'iphoneos',
        'target_version': 13,
      },
    if (os == 'macos') 'macos': {'target_version': arch == 'arm64' ? 11 : 10},
  };
  final input = File.fromUri(directory.uri.resolve('input.json'));
  final output = File.fromUri(directory.uri.resolve('output.json'));
  final data = <String, Object>{
    'assets': <String, Object>{},
    'config': {
      'build_asset_types': ['code_assets/code'],
      'extensions': {'code_assets': config},
      'linking_enabled': false,
    },
    'out_dir_shared': root.resolve('.dart_tool/verify/shared/').toFilePath(),
    'out_file': output.path,
    'package_name': 'ech_http',
    'package_root': root.toFilePath(),
    if (args.length == 4)
      'user_defines': {
        'workspace_pubspec': {
          'base_path': root.resolve('pubspec.yaml').toFilePath(),
          'defines': {'binary_cache': Directory(args[3]).absolute.path},
        },
      },
  };
  await input.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  await hook.main(['--config', input.path]);
  if (!await output.exists()) {
    throw StateError('Hook did not write its asset manifest');
  }
  stdout.writeln('Native hook succeeded: $os/$arch. Manifest: ${output.path}');
}
