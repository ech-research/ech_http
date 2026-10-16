import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:ech_http/src/build_support/ohos.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory native;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ech-ohos-sdk-');
    native = Directory(p.join(root.path, 'default', 'openharmony', 'native'));
    final toolchain = File(
      p.join(native.path, 'build', 'cmake', 'ohos.toolchain.cmake'),
    );
    await toolchain.parent.create(recursive: true);
    await toolchain.writeAsString('# SDK fixture');
  });
  tearDown(() async => root.delete(recursive: true));

  test(
    'recognizes Flutter-OH linux compatibility input by its compiler SDK',
    () {
      final config = OhosBuildConfig.detect(
        targetOS: OS.linux,
        architecture: Architecture.arm64,
        compiler: File(p.join(native.path, 'llvm', 'bin', 'clang')).uri,
        environment: {},
      )!;
      expect(config.nativeSdk, native.path);
      expect(config.abi, 'arm64-v8a');
      expect(config.cmakeArguments, contains('-DOHOS_STL=c++_static'));
      expect(config.cmakeArguments, contains('-DOHOS_ARCH=arm64-v8a'));
    },
  );

  test('normal Linux builds stay Linux when an OHOS SDK is installed', () {
    expect(
      OhosBuildConfig.detect(
        targetOS: OS.linux,
        architecture: Architecture.arm64,
        compiler: File('/usr/bin/clang').uri,
        environment: {'OHOS_NDK_HOME': native.path},
      ),
      isNull,
    );
  });

  test('accepts an explicit OHOS target and HOS_SDK_HOME layout', () {
    final config = OhosBuildConfig.detect(
      targetOS: OS.fromString('ohos'),
      architecture: Architecture.x64,
      environment: {'HOS_SDK_HOME': root.path},
    )!;
    expect(config.nativeSdk, native.path);
    expect(config.abi, 'x86_64');
  });

  test(
    'supports explicit source-build configuration with a native SDK path',
    () {
      final config = OhosBuildConfig.detect(
        targetOS: OS.linux,
        architecture: Architecture.arm64,
        explicitlyOhos: true,
        sdkPath: native.path,
        environment: {},
      )!;
      expect(config.nativeSdk, native.path);
    },
  );

  test('missing SDK fails with actionable configuration guidance', () {
    expect(
      () => OhosBuildConfig.detect(
        targetOS: OS.fromString('ohos'),
        architecture: Architecture.arm64,
        environment: {},
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('OHOS_NDK_HOME'),
        ),
      ),
    );
  });

  test('unsupported OHOS architecture fails before compiling dependencies', () {
    expect(
      () => OhosBuildConfig.detect(
        targetOS: OS.fromString('ohos'),
        architecture: Architecture.arm,
        sdkPath: native.path,
      ),
      throwsUnsupportedError,
    );
  });

  test('explicit OHOS override cannot mislabel a macOS asset', () {
    expect(
      () => OhosBuildConfig.detect(
        targetOS: OS.macOS,
        architecture: Architecture.arm64,
        explicitlyOhos: true,
        sdkPath: native.path,
      ),
      throwsUnsupportedError,
    );
  });
}
