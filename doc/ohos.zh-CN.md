# OpenHarmony / HarmonyOS 原生适配

[English](ohos.md) | [简体中文](ohos.zh-CN.md)

支持通过 Flutter-OH 的 Native Assets 构建和打包 `ech_http`。
保留现有 `EchClient`、ECH、证书校验、代理、gzip 和流式响应 API。
支持 `arm64`（手机、平板）和 `x64`；各架构的验证结果见下文。

## 构建要求

- Dart >=3.10、Python >=3.12、Git、CMake >=3.22、Ninja、Go（编译 BoringSSL 所需）。
- OpenHarmony native SDK，包含 `build/cmake/ohos.toolchain.cmake`。
  可将 `OHOS_NDK_HOME` 指向 `native` 本身或其父目录；也支持 HarmonyOS
  命令行工具的 `HOS_SDK_HOME/default/openharmony/native` 布局。
- 应用构建需要已支持 OHOS Native Assets 的 Flutter-OH。
  本次核对的 CPF-Flutter `oh-3.41.9-release` 提交
  `62357a93d653bf844f730bb1f4b7cc9e2139d14e` 已包含该功能。
  仅有旧版 FFI 插件打包支持的 Flutter-OH 不满足要求。

包允许使用 `code_assets` / `hooks` 的兼容版本范围，解决 Flutter-OH
3.41 固定 `meta 1.17.0` 与 `hooks 2.2` 的依赖冲突。实际测试应用解析为
`code_assets 1.2.1`、`hooks 2.0.2`，无需覆盖 Flutter SDK 的 `meta` 版本。

Flutter-OH 当前向第三方 hook 传递 `target_os=linux`，同时提供 OHOS 的
`native/llvm/bin/clang`。构建钩子根据编译器所属 SDK 识别鸿蒙目标，使用
OHOS toolchain、sysroot 和架构编译，**不会使用 Linux 预编译依赖**。
将来直接传递 `target_os=ohos` 的工具链也可以识别。

## 应用接入

在 Flutter-OH 应用的 `pubspec.yaml` 中引用包含 OHOS 支持的 `ech_http`。
开发与验证时可使用本地依赖：

```yaml
dependencies:
  ech_http:
    path: /absolute/path/to/ech_http
```

使用 Flutter-OH 运行 `flutter pub get` 和 `flutter build hap`。
正常情况下自动从 Flutter 提供的编译器路径定位 native SDK。
若工具链没有提供该路径，可在**应用**的 `pubspec.yaml` 中明确配置：

```yaml
hooks:
  user_defines:
    ech_http:
      target: ohos
      ohos_sdk: /absolute/path/to/openharmony/native
      # 可选：跨构建复用已下载的固定版本源码。
      source_cache: /absolute/path/to/ech-http-sources
```

首次构建会从包内 `dependencies.json` 指定的版本下载和编译 BoringSSL、
curl、zlib。curl/zlib 校验 SHA-256，BoringSSL 校验 Git 提交。
随后 Ninja 增量复用编译结果。无需另外创建或发布预编译依赖仓库。
OHOS 使用静态 C++ 运行库，并隐藏其符号；HAP 不必额外打包
`libc++_shared.so`，也不会把 TLS 库的符号暴露给其他播放器插件。

## 独立编译与检查

不必先创建 Flutter 应用即可检查交叉编译和 Native Assets 输出：

```sh
export OHOS_NDK_HOME=/absolute/path/to/openharmony/native
dart pub get
dart run tool/check_native_build.dart ohos arm64
```

该检查使用与 Flutter-OH 一致的 Linux 兼容输入和 OHOS 编译器。
清单位于 `.dart_tool/verify/ohos-arm64-device/output.json`，包含
`package:ech_http/ech_http_bindings` 对应的鸿蒙 `.so`。

也可单独生成库与原生请求测试程序：

```sh
python3 tool/build_ohos.py \
  --native-sdk "$OHOS_NDK_HOME" \
  --dart-sdk /absolute/path/to/dart-sdk \
  --arch arm64
```

产物位于 `build/ohos/arm64/bridge/out/`。`--arch x64` 使用独立的
`build/ohos/x64/` 目录。已有 Flutter-OH 的构建会自动运行相同的依赖编译步骤。

原生测试程序参数与现有工具一致：

```sh
./ech_http_smoke URL HTTP代理或空字符串 ECHConfigList或空字符串 目标IP或空字符串
```

ECH 配置非空时，测试要求响应为 HTTP 200 且报告 ECH 被服务器接受。
HarmonyOS 商用设备可能拒绝直接执行未签名 ELF；这种情况下应使用官方
调试签名，或将库放入正常签名的测试 HAP。普通文件执行权限并不能替代代码签名。

## Flutter 真机测试包

使用 Flutter-OH 创建独立的 ECH 测试应用：

```sh
dart run tool/create_flutter_smoke.dart ohos
cd build/flutter_smoke
flutter pub get
flutter build hap --debug --no-codesign
```

应用包名为 `com.example.ech_http_smoke`，支持手机、平板。
启动后通过 DoH 获取 Cloudflare ECH 配置，发起 HTTPS 请求，并显示
HTTP 状态、`ECH accepted` 和后端版本。使用正常的华为调试签名后安装。
成功标准是 HTTP 200、`ECH accepted: true`，不能只根据页面打开判断成功。

包路径为 `build/flutter_smoke/build/ohos/hap/entry-default-unsigned.hap`
（相对于本仓库根目录）。当前 Flutter-OH 的 macOS Release AOT 编译器
为 Intel 架构；Apple Silicon 上的 Release 构建需要 Rosetta。
Debug 测试包不依赖这个 AOT 编译器。

## 验证范围

2026-10-17 本地检查使用 macOS arm64 构建机、Dart 3.13.5、OpenHarmony
native SDK 6.0.0.47（API 20）。Flutter HAP 使用 Flutter-OH
3.41.9+ohos-1.0.2、其内置 Dart 3.11.5 和 HarmonyOS SDK 26.0.0.105。
连接的 MatePad mini 为 HarmonyOS API 26。

| 检查 | 结果 |
| --- | --- |
| arm64 原生库及测试程序交叉编译 | 通过 |
| x64 原生库及测试程序交叉编译 | 通过；未连接 x64 设备 |
| Flutter-OH 兼容输入的构建钩子 | 通过，生成 `package:ech_http/ech_http_bindings` 清单 |
| ELF 动态依赖检查 | 仅依赖 `libc.so`，没有额外的 TLS、zlib、C++ 动态库 |
| macOS Dart 单元和原生回归测试 | 通过；网络 live 测试需单独启用 |
| Flutter-OH 3.41.9+ohos-1.0.2 应用依赖解析 | 通过，兼容 Flutter 固定的 `meta 1.17.0` |
| Flutter 测试应用静态分析 | 通过 |
| Debug HAP 构建及库打包 | 通过，包内包含 arm64 `libech_http.so` 与 Native Assets 映射 |
| 本机 Release HAP 构建 | 原生库与 Dart 编译通过；AOT 编译器需要本机尚未安装的 Rosetta |
| MatePad mini 上执行裸 ELF | 系统返回 `Permission denied`，未执行到请求代码 |
| 已签名 Flutter Debug HAP 真机运行 | 通过，Native Assets 中的 arm64 库正常加载并解析 FFI 符号 |
| MatePad mini HTTPS / ECH 请求 | 通过，DoH 获取 ECH 配置后返回 HTTP 200、`ECH accepted: true`，服务端返回 `sni=encrypted`、`tls=TLSv1.3` |

真机日志中的关键结果如下（来自正常签名安装的 Flutter HAP）：

```text
ECH_HTTP_SMOKE: libcurl/8.22.0 BoringSSL zlib/1.3.2
HTTP 200
ECH accepted: true
tls=TLSv1.3
sni=encrypted
```

本地验证记录保存在 `build/ohos-runtime-smoke.log`。本次已验证 Flutter
Native Assets 集成和公网 HTTPS/ECH；gzip、代理、取消请求、isolate 退出
等行为已覆盖桌面回归测试，尚未在鸿蒙真机上逐项复测。
x64 仅完成交叉编译和构建钩子检查。初次本地真机验证未包含 Release HAP
与远程 CI；后续远程验证结果见下文记录。

## 缓存与工具链切换

构建目录按架构区分。源码构建脚本为每个依赖和独立编译的桥接层记录源码绝对路径、
配置参数、BoringSSL/curl/zlib 版本与摘要、SDK 元数据及 toolchain 摘要。
这些输入不变时复用 Ninja 增量产物；输入改变时清理对应的生成目录，
重新运行配置探测和编译，避免依赖升级后出现源码目录冲突或使用旧探测结果。
迁移没有配置记录的旧构建目录时也会重新生成。
已下载的源码独立保存，不受 CMake 构建目录清理影响。
构建钩子的桥接层也会在包源码路径变更时重置 CMake 元数据。

切换标准 Dart 与 Flutter-OH 内置 Dart 时，应重新生成应用的 `.dart_tool`
并运行 `flutter pub get`，避免旧 SDK 编译的 `hook.dill` 导致
`Invalid kernel binary format version`。CI 中包级检查始终使用原 Dart SDK，
Flutter-OH 测试应用使用自身独立的 `.dart_tool` 和内置 Dart。

运行无需网络或 OHOS SDK 的缓存回归检查：

```sh
python3 tool/test_build_ohos.py
```

CI 的 OHOS 作业检查 SDK 识别、缓存失效、arm64/x64 构建钩子输出，
以及固定 Flutter-OH 工具链的未签名 Release HAP 打包。远程构建不能
替代签名 HAP 的真机运行检查。
