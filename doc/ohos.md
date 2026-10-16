# OpenHarmony / HarmonyOS native support

[English](ohos.md) | [简体中文](ohos.zh-CN.md)

Build and bundle `ech_http` through Flutter-OH Native Assets on `arm64`
(phones and tablets) and `x64`. The existing `EchClient`, ECH, certificate
validation, proxy, gzip, and streaming APIs remain available. See the
verification scope below for the checks performed on each architecture.

## Requirements

- Dart >=3.10, Python >=3.12, Git, CMake >=3.22, Ninja, and Go (for BoringSSL).
- An OpenHarmony native SDK containing `build/cmake/ohos.toolchain.cmake`.
  `OHOS_NDK_HOME` may point to the native directory or its parent.
  The HarmonyOS command-line tools layout
  `HOS_SDK_HOME/default/openharmony/native` is also supported.
- Flutter-OH with OHOS Native Assets support for application builds.
  Verified with CPF-Flutter `oh-3.41.9-release`, commit
  `62357a93d653bf844f730bb1f4b7cc9e2139d14e`.
  Earlier toolchains with only FFI plugin packaging are insufficient.

The compatible `code_assets` and `hooks` version ranges accommodate Flutter-OH
3.41's `meta 1.17.0` pin. The verified consumer resolves `code_assets 1.2.1`
and `hooks 2.0.2`, without overriding Flutter's `meta` dependency.

The verified Flutter-OH toolchain passes `target_os=linux` to third-party hooks
alongside its `native/llvm/bin/clang`. The hook identifies OHOS from that
compiler's SDK and uses the OHOS toolchain and sysroot, rather than Linux
prebuilt dependencies. Explicit `target_os=ohos` inputs are also recognized.
Installing an OHOS SDK alone does not redirect ordinary Linux builds.

## Application setup

Reference an `ech_http` version containing OHOS support from the Flutter-OH
application's `pubspec.yaml`. For development and verification, use a local
dependency:

```yaml
dependencies:
  ech_http:
    path: /absolute/path/to/ech_http
```

Run `flutter pub get` and `flutter build hap` with Flutter-OH.
The hook normally locates the SDK from Flutter's compiler path. If that path
is unavailable, configure the target explicitly in the **application's**
`pubspec.yaml`:

```yaml
hooks:
  user_defines:
    ech_http:
      target: ohos
      ohos_sdk: /absolute/path/to/openharmony/native
      # Optional: share downloaded pinned sources between builds.
      source_cache: /absolute/path/to/ech-http-sources
```

The first build downloads and compiles the BoringSSL, curl, and zlib versions
pinned in `lib/src/build_support/dependencies.json`. curl and zlib archives
are checked against SHA-256 digests; BoringSSL is checked against its Git
revision. Later builds reuse Ninja outputs incrementally. No additional
prebuilt dependency repository is required.

OHOS links the C++ runtime statically and hides static library symbols. The
HAP does not need an extra `libc++_shared.so`, and the TLS library's symbols
are not exported to other native plugins.

## Standalone builds

Check cross-compilation and Native Assets output without creating an app:

```sh
export OHOS_NDK_HOME=/absolute/path/to/openharmony/native
dart pub get
dart run tool/check_native_build.dart ohos arm64
```

The check uses Flutter-OH's Linux compatibility input and OHOS compiler.
The manifest at `.dart_tool/verify/ohos-arm64-device/output.json` identifies
the OHOS library as `package:ech_http/ech_http_bindings`.
Repeat with `ohos x64` to verify the other supported architecture.

To build the library and native request smoke executable directly:

```sh
python3 tool/build_ohos.py \
  --native-sdk "$OHOS_NDK_HOME" \
  --dart-sdk /absolute/path/to/dart-sdk \
  --arch arm64
```

Outputs are in `build/ohos/arm64/bridge/out/`. `--arch x64` uses
`build/ohos/x64/`. Flutter-OH builds run the same dependency build steps.

The native smoke executable accepts four arguments:

```sh
./ech_http_smoke URL HTTP_PROXY_OR_EMPTY ECH_CONFIG_LIST_OR_EMPTY TARGET_IP_OR_EMPTY
```

With a nonempty ECH configuration, success requires HTTP 200 and accepted ECH.
Commercial HarmonyOS devices may reject unsigned ELF executables. Use an
official debug signature or a normally signed test HAP; executable file
permissions do not replace code signing.

## Flutter device smoke app

```sh
dart run tool/create_flutter_smoke.dart ohos
cd build/flutter_smoke
flutter pub get
flutter build hap --debug --no-codesign
```

The app's bundle name is `com.example.ech_http_smoke`, with phone and tablet
support. It discovers Cloudflare's ECH configuration over DoH, sends an HTTPS
request, and displays the status, `ECH accepted`, and backend version. Sign
with the normal Huawei debug signing workflow before installing on a device.
Success requires HTTP 200 and `ECH accepted: true`.

The unsigned HAP is at
`build/flutter_smoke/build/ohos/hap/entry-default-unsigned.hap`, relative to
the repository root. The verified Flutter-OH macOS Release AOT compiler is
Intel-only, so Release builds on Apple Silicon require Rosetta. Debug smoke
builds do not use that AOT compiler.

## Verification scope

Local verification on 2026-10-17 used a macOS arm64 host, Dart 3.13.5,
and OpenHarmony native SDK 6.0.0.47 (API 20). The Flutter HAP used
Flutter-OH 3.41.9+ohos-1.0.2, its bundled Dart 3.11.5, and HarmonyOS SDK
26.0.0.105. The connected MatePad mini runs HarmonyOS API 26.

| Check | Result |
| --- | --- |
| arm64 native library and smoke executable | Cross-compilation passed |
| x64 native library and smoke executable | Cross-compilation passed; no x64 device attached |
| Flutter-OH compatibility input | Build hook produced the Native Assets manifest |
| ELF dynamic dependencies | Only `libc.so`; no additional TLS, zlib, or C++ shared library |
| macOS offline unit and native regression tests | Passed; public-network tests are opt-in |
| Flutter-OH consumer dependency resolution | Passed with Flutter's `meta 1.17.0` pin |
| Flutter smoke app analysis | Passed |
| Debug HAP packaging | Passed with arm64 `libech_http.so` and Native Assets mapping |
| Local Release HAP build | Native library and Dart compilation passed; AOT requires Rosetta, absent on the verified host |
| Bare ELF execution on MatePad mini | Rejected with `Permission denied` before request code ran |
| Signed Debug HAP on MatePad mini | Native library loaded and FFI symbols resolved |
| Device HTTPS / ECH request | HTTP 200, accepted ECH, `sni=encrypted`, and `tls=TLSv1.3` |

The signed HAP's device log contains:

```text
ECH_HTTP_SMOKE: libcurl/8.22.0 BoringSSL zlib/1.3.2
HTTP 200
ECH accepted: true
tls=TLSv1.3
sni=encrypted
```

The local capture is stored in `build/ohos-runtime-smoke.log` (a generated
file, not part of the package). Device verification covers Native Assets
integration and public HTTPS/ECH. gzip, proxies, cancellation, and isolate
shutdown have desktop regression coverage but have not each been repeated
on an OHOS device. x64 has build coverage only. Release HAP and remote CI
verification were not part of the initial local device run.

## Caching and Dart SDK changes

Build directories are separate for each architecture. The source builder
records each dependency and standalone bridge configuration's source path, configure
arguments, dependency pins, native SDK metadata, and toolchain digest.
Unchanged inputs preserve incremental outputs. Changed inputs discard the
generated directory and repeat configuration probes and compilation. This
also migrates older build directories without a configuration record.
Downloaded sources are stored separately and survive this invalidation.
The build hook also resets bridge CMake metadata when the package source moves.

When switching between standard Dart and Flutter-OH's bundled Dart,
regenerate the application's `.dart_tool` and run `flutter pub get`.
Otherwise a cached `hook.dill` may produce
`Invalid kernel binary format version`. CI keeps package tools on their
original Dart SDK and gives the Flutter-OH consumer its own `.dart_tool`.

Run the cache regression checks without networking or an OHOS SDK:

```sh
python3 tool/test_build_ohos.py
```

The OHOS CI job checks SDK detection, cache invalidation, arm64/x64 hook
outputs, and an unsigned Release HAP built with the pinned Flutter-OH
toolchain. Remote packaging checks do not replace signed device execution.
