import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:path/path.dart' as p;

/// Hosted code_assets does not know OHOS yet. Flutter-OH currently sends
/// target_os=linux with its OHOS compiler. Detect the SDK, not the build host.
final class OhosBuildConfig {
  OhosBuildConfig._(this.nativeSdk, this.architecture);

  final String nativeSdk;
  final Architecture architecture;

  String get abi => switch (architecture) {
    Architecture.arm64 => 'arm64-v8a',
    Architecture.x64 => 'x86_64',
    _ => throw UnsupportedError('ech_http OHOS supports arm64 and x64'),
  };

  List<String> get cmakeArguments => [
    '-DCMAKE_TOOLCHAIN_FILE=${p.join(nativeSdk, 'build', 'cmake', 'ohos.toolchain.cmake')}',
    '-DOHOS_ARCH=$abi',
    '-DOHOS_PLATFORM=OHOS',
    '-DOHOS_STL=c++_static',
  ];

  static OhosBuildConfig? detect({
    required OS targetOS,
    required Architecture architecture,
    Uri? compiler,
    String? sdkPath,
    bool explicitlyOhos = false,
    Map<String, String>? environment,
  }) {
    if (explicitlyOhos && targetOS != OS.linux && targetOS.name != 'ohos') {
      throw UnsupportedError(
        'An explicit OHOS target requires Flutter-OH, not $targetOS. '
        'Apply the OHOS user_defines only to OHOS builds.',
      );
    }
    final compilerSdk = compiler == null
        ? null
        : _findNativeSdk(
            p.dirname(p.dirname(p.dirname(compiler.toFilePath()))),
          );
    final ohos =
        explicitlyOhos ||
        targetOS.name == 'ohos' ||
        (targetOS == OS.linux && compilerSdk != null);
    if (!ohos) return null;
    if (architecture != Architecture.arm64 &&
        architecture != Architecture.x64) {
      throw UnsupportedError('ech_http OHOS supports arm64 and x64');
    }
    final env = environment ?? Platform.environment;
    final candidates = [
      ?sdkPath,
      ?compilerSdk,
      if (env['OHOS_NDK_HOME'] != null) env['OHOS_NDK_HOME']!,
      if (env['HOS_SDK_HOME'] != null) env['HOS_SDK_HOME']!,
    ];
    for (final candidate in candidates) {
      final sdk = _findNativeSdk(candidate);
      if (sdk != null) return OhosBuildConfig._(sdk, architecture);
    }
    throw StateError(
      'OpenHarmony native SDK not found. Set OHOS_NDK_HOME or '
      'hooks.user_defines.ech_http.ohos_sdk to the native SDK directory.',
    );
  }

  static String? _findNativeSdk(String root) {
    for (final candidate in [
      root,
      p.join(root, 'native'),
      p.join(root, 'openharmony', 'native'),
      p.join(root, 'default', 'openharmony', 'native'),
    ]) {
      if (File(
        p.join(candidate, 'build', 'cmake', 'ohos.toolchain.cmake'),
      ).existsSync()) {
        return p.normalize(p.absolute(candidate));
      }
    }
    return null;
  }
}
