# OpenHarmony / HarmonyOS native support

[English](ohos.md) | [简体中文](ohos.zh-CN.md)

Build and bundle `ech_http` through Flutter-OH Native Assets on `arm64`
(phones and tablets) and `x64`. The existing `EchClient`, ECH, certificate
validation, proxy, gzip, and streaming APIs remain available. See the
verification scope below for the checks performed on each architecture.

## Requirements

- Dart >=3.10, CMake >=3.22, and Ninja. `ech_http` consumers do not need Python
  or Go to build the precompiled dependencies.
- An OpenHarmony / HarmonyOS native SDK containing `build/cmake/ohos.toolchain.cmake`.
  The precompiled SDK and verified consumer use version 26.0.0.105 / API 26;
  compatibility with lower API levels has not been verified.
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
      # Optional: share verified precompiled SDKs between builds.
      binary_cache: /absolute/path/to/ech-http-sdks
```

The first build downloads the precompiled SDK pinned by version and SHA-256
in `lib/src/build_support/dependencies.json`. After validating metadata and
per-file hashes, the hook compiles only `src/ech_http.cpp`. Consumers no longer
download or compile BoringSSL, curl, or zlib sources. Later builds reuse the
verified SDK cache, with the same integrity and repair checks as other platforms.

The independent [libechhttp_ohos_build](https://github.com/tignioj/libechhttp_ohos_build)
repository builds and publishes these SDKs, starting with
[v0.1.0](https://github.com/tignioj/libechhttp_ohos_build/releases/tag/v0.1.0).
Each archive includes matching headers, four static libraries, CMake targets,
licenses, per-file hashes, and build provenance. Maintainers update reviewed
pins with `python3 tool/update_prebuilt.py ohos=v0.1.0`; application hooks never
invoke that Python tool.

OHOS links the C++ runtime statically and hides static library symbols. The HAP
does not need an extra `libc++_shared.so`, and TLS symbols are not exported to
other native plugins.

## Standalone builds

Check SDK download, bridge cross-compilation, and Native Assets output without
creating an application:

```sh
export OHOS_NDK_HOME=/absolute/path/to/openharmony/native
dart pub get
dart run tool/check_native_build.dart ohos arm64
dart run tool/check_native_build.dart ohos x64
```

The checks use Flutter-OH's Linux compatibility input and OHOS compiler, and
download the corresponding precompiled SDK. Manifests are written to
`.dart_tool/verify/ohos-arm64-device/output.json` and
`.dart_tool/verify/ohos-x64-device/output.json`, with the library identified as
`package:ech_http/ech_http_bindings`.

Maintainers rebuilding dependencies use the independent SDK repository's build
and publication workflow. Neither this package nor consumers contain an entry
point to compile those dependency sources.

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

### Precompiled SDK device rerun (2026-10-17)

A signed Debug HAP using the published precompiled SDK was reinstalled and
launched on MatePad mini (MLR-AL10, API 26). The tested `ech_http` implementation
was commit `0a94849d7e1efba33abafd3a2529cf8dca4a2268`, with the `v0.1.0` arm64 SDK
built from `6ebb0d4b4617115f4a2cc7f1b324d861e222c9a2`. The SDK archive SHA-256 was
`986aaea773733301b66a1f94a1986f71b1a31f54e89c4909fcc2fd4b0ea982fc`.

The app was rebuilt with Flutter-OH 3.41.9+ohos-1.0.2, Dart 3.11.5, and HarmonyOS
SDK 26.0.0.105 after clearing its `.dart_tool` and Flutter build outputs. Local
checks verified the downloaded archive digest, precompiled static-library link
paths, HAP arm64 library, and Native Assets mapping. The packaged library exactly
matched the newly built bridge after `llvm-strip`; its sole ELF dynamic dependency
was `libc.so`. The HAP was signed with the existing local debug identity, passed
signature verification, and was successfully installed over the test app.

At 14:05:48 (Asia/Shanghai), the device returned the unique marker for this run.
Native Assets loading and FFI calls succeeded, including the backend version.
After discovering ECH configuration over DoH, the request to
`https://crypto.cloudflare.com/cdn-cgi/trace` returned:

```text
ECH_HTTP_PREBUILT_V0_1_0_0a94849: libcurl/8.22.0 BoringSSL zlib/1.3.2
HTTP 200
ECH accepted: true
tls=TLSv1.3
sni=encrypted
```

The raw local capture is `build/prebuilt-ohos-runtime-smoke.log`; provenance and
assertion results are in `build/prebuilt-device-result.json`. These generated
files are not published with the package. This rerun covers arm64 signed Debug
HAP loading and live HTTPS/ECH. It does not cover signed Release HAP execution,
compatibility below API 26, x64 devices, or individual OHOS device regression
checks for proxies, gzip, cancellation, and isolate shutdown. Desktop coverage
for these features does not establish OHOS device verification.

### Initial source-build record

The initial source-build verification on 2026-10-17 used a macOS arm64 host, Dart 3.13.5,
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
| Initial source-build signed Debug HAP on MatePad mini | Native library loaded and FFI symbols resolved |
| Initial source-build device HTTPS / ECH request | HTTP 200, accepted ECH, `sni=encrypted`, and `tls=TLSv1.3` |

The earlier source-build signed HAP's device log contains:

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
verification were not part of the initial local device run. The separate
precompiled SDK device rerun is recorded above.

The dependency repository's [initial SDK CI](https://github.com/tignioj/libechhttp_ohos_build/actions/runs/39006660450)
verified arm64/x64 dependency and packaged consumer links, ELF architecture,
dynamic dependencies, archive and file digests, and source provenance.
It does not execute target device code.

One local macOS arm64 check on the same date downloaded this Release into an
empty SDK cache and built the bridge in 6.7 seconds for arm64 and 7.0 seconds
for x64. These observations include downloading and building, depend on the
network and build host, and are not a timing guarantee for other environments.

## Caching and Dart SDK changes

OHOS shares `preparePrebuilt` with the other platforms. The target and archive
SHA-256 identify the cache directory. ZIP digests, SDK metadata, and per-file
hashes are checked; modified extracted files are repaired from the verified
archive. New archive pins use a new cache directory. `binary_cache` paths are
relative to the consuming `pubspec.yaml`; a complete cache works offline.
The hook resets bridge CMake metadata when the package source moves.

When switching between standard Dart and Flutter-OH's bundled Dart,
regenerate the application's `.dart_tool` and run `flutter pub get`.
Otherwise a cached `hook.dill` may produce
`Invalid kernel binary format version`. CI keeps package tools on their
original Dart SDK and gives the Flutter-OH consumer its own `.dart_tool`.

```sh
dart test test/ohos_build_test.dart test/prebuilt_test.dart
```

Independent SDK CI builds and link-checks both architectures, validates ELF
properties, and verifies complete archives. Package CI downloads published
SDKs, builds only the bridge, and checks arm64/x64 hook outputs plus unsigned
Release HAP contents and Native Assets mapping with pinned Flutter-OH.
Neither pipeline replaces signed device execution. x64 still has no device
coverage. Proxy, gzip, cancellation, and isolate shutdown have desktop tests
but have not each been repeated on an OHOS device. The precompiled SDK device
rerun above is manual verification, separate from automated CI.
