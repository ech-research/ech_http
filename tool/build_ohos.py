#!/usr/bin/env python3
"""Cross-compile ech_http with pinned BoringSSL, curl and zlib for OpenHarmony.

Requires Python 3.12+, Git, CMake, Ninja, and an OpenHarmony native SDK.
No Android binaries or host TLS libraries are used. Downloads are cached.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
ARCHITECTURES = {'arm64': 'arm64-v8a', 'x64': 'x86_64'}


def run(args):
    print('+', ' '.join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), check=True)


def configure(cmake, source, build, arguments, identity=None):
    # Configure probes and object files must not survive a dependency or SDK
    # change. Downloads live outside these generated build directories.
    fingerprint = json.dumps({
        'schema': 1,
        'source': str(source.resolve()),
        'arguments': list(map(str, arguments)),
        'identity': identity,
    }, sort_keys=True)
    stamp = build / '.ech-http-config.json'
    if build.exists() and (not stamp.is_file() or stamp.read_text() != fingerprint):
        shutil.rmtree(build)
    run([cmake, '-S', source, '-B', build, *arguments])
    stamp.write_text(fingerprint)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def native_sdk(path):
    root = Path(path).expanduser().resolve()
    for candidate in [root, root / 'native', root / 'openharmony/native',
                      root / 'default/openharmony/native']:
        if (candidate / 'build/cmake/ohos.toolchain.cmake').is_file():
            return candidate
    raise ValueError(f'OpenHarmony native SDK not found under {root}')


def download_source(pin, cache, name):
    archive = cache / Path(pin['url']).name
    if not archive.is_file() or digest(archive) != pin['sha256']:
        partial = archive.with_suffix(archive.suffix + '.part')
        try:
            with urllib.request.urlopen(pin['url'], timeout=60) as source, partial.open('wb') as output:
                shutil.copyfileobj(source, output)
            if digest(partial) != pin['sha256']:
                raise RuntimeError(f'{name} source SHA-256 mismatch')
            partial.replace(archive)
        finally:
            partial.unlink(missing_ok=True)
    directory = cache / f"{name}-{pin['version']}"
    if not directory.is_dir():
        with tarfile.open(archive) as tar:
            tar.extractall(cache, filter='data')
    return directory


def sources(manifest, cache):
    cache.mkdir(parents=True, exist_ok=True)
    revision = manifest['boringssl']['revision']
    boring = cache / f'boringssl-{revision}'
    if not (boring / '.git').is_dir():
        run(['git', 'init', boring])
        run(['git', '-C', boring, 'remote', 'add', 'origin', manifest['boringssl']['repository']])
    if not (boring / 'CMakeLists.txt').is_file():
        run(['git', '-C', boring, 'fetch', '--depth=1', 'origin', revision])
        run(['git', '-C', boring, 'checkout', '--detach', revision])
    actual = subprocess.check_output(['git', '-C', str(boring), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != revision:
        raise RuntimeError('BoringSSL source revision mismatch')
    return boring, download_source(manifest['curl'], cache, 'curl'), download_source(manifest['zlib'], cache, 'zlib')


def main():
    if sys.version_info < (3, 12):
        raise SystemExit('OpenHarmony source builds require Python >=3.12')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native-sdk', default=os.environ.get('OHOS_NDK_HOME') or os.environ.get('HOS_SDK_HOME'))
    parser.add_argument('--dart-sdk', type=Path)
    parser.add_argument('--arch', choices=ARCHITECTURES, default='arm64')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--source-cache', type=Path, default=ROOT / 'build/ohos/sources')
    parser.add_argument('--deps-only', action='store_true')
    options = parser.parse_args()
    if not options.native_sdk:
        parser.error('Set OHOS_NDK_HOME or pass --native-sdk pointing to an OpenHarmony SDK')
    if not options.deps_only and (options.dart_sdk is None or not (options.dart_sdk / 'include/dart_native_api.h').is_file()):
        parser.error('--dart-sdk must point to a Dart SDK containing include/dart_native_api.h')
    sdk = native_sdk(options.native_sdk)
    work = (options.output or ROOT / 'build/ohos' / options.arch).resolve()
    work.mkdir(parents=True, exist_ok=True)
    suffix = '.exe' if os.name == 'nt' else ''
    cmake = shutil.which('cmake') or str(sdk / f'build-tools/cmake/bin/cmake{suffix}')
    ninja = shutil.which('ninja') or str(sdk / f'build-tools/cmake/bin/ninja{suffix}')
    if not Path(cmake).is_file() or not Path(ninja).is_file():
        parser.error('Install CMake >=3.22 and Ninja, or add the native SDK build-tools/cmake/bin to PATH')
    common = ['-G', 'Ninja', f'-DCMAKE_MAKE_PROGRAM={ninja}', '-DCMAKE_BUILD_TYPE=Release',
              f'-DCMAKE_TOOLCHAIN_FILE={sdk}/build/cmake/ohos.toolchain.cmake',
              f'-DOHOS_ARCH={ARCHITECTURES[options.arch]}', '-DOHOS_PLATFORM=OHOS',
              '-DOHOS_STL=c++_static', '-DCMAKE_POSITION_INDEPENDENT_CODE=ON',
              '-DCMAKE_C_VISIBILITY_PRESET=hidden', '-DCMAKE_CXX_VISIBILITY_PRESET=hidden',
              # The SDK adds --gcc-toolchain even for libc++; BoringSSL's
              # -Werror must not reject this SDK-supplied, unused argument.
              '-DCMAKE_C_FLAGS=-Wno-unused-command-line-argument',
              '-DCMAKE_CXX_FLAGS=-Wno-unused-command-line-argument']
    manifest = json.loads((ROOT / 'lib/src/build_support/dependencies.json').read_text())
    sdk_metadata = json.loads((sdk / 'oh-uni-package.json').read_text())
    identity = {
        'dependencies': {name: manifest[name] for name in ('boringssl', 'curl', 'zlib')},
        'native_sdk': sdk_metadata,
        'toolchain_sha256': digest(sdk / 'build/cmake/ohos.toolchain.cmake'),
    }
    boring, curl, zlib = sources(manifest, options.source_cache.resolve())
    parallel = str(min(os.cpu_count() or 2, 8))
    boring_build = work / 'boringssl'
    configure(cmake, boring, boring_build, [*common, '-DBUILD_SHARED_LIBS=OFF',
         '-DBUILD_TESTING=OFF', '-DOPENSSL_NO_ASM=ON', '-DOPENSSL_SMALL=ON'], identity)
    run([cmake, '--build', boring_build, '--target', 'ssl', 'crypto', '--parallel', parallel])
    zlib_build = work / 'zlib'
    configure(cmake, zlib, zlib_build, [*common, '-DZLIB_BUILD_SHARED=OFF',
         '-DZLIB_BUILD_STATIC=ON', '-DZLIB_BUILD_TESTING=OFF'], identity)
    run([cmake, '--build', zlib_build, '--target', 'zlibstatic', '--parallel', parallel])
    includes = work / 'zlib-include'
    includes.mkdir(exist_ok=True)
    shutil.copyfile(zlib / 'zlib.h', includes / 'zlib.h')
    shutil.copyfile(zlib_build / 'zconf.h', includes / 'zconf.h')
    curl_build = work / 'curl'
    configure(cmake, ROOT / 'tool/ohos', curl_build, [*common,
         f'-DEH_CURL_SOURCE={curl}', f'-DEH_BORINGSSL_SOURCE={boring}',
         f'-DEH_BORINGSSL_BUILD={boring_build}', f'-DZLIB_LIBRARY={zlib_build}/libz.a',
         f'-DZLIB_INCLUDE_DIR={includes}'], identity)
    run([cmake, '--build', curl_build, '--parallel', parallel])
    if 'HAVE_SSL_SET1_ECH_CONFIG_LIST:INTERNAL=1' not in (curl_build / 'CMakeCache.txt').read_text():
        raise RuntimeError('libcurl was built without BoringSSL ECH support')
    if '#define HAVE_LIBZ 1' not in (curl_build / 'curl/lib/curl_config.h').read_text():
        raise RuntimeError('libcurl was built without zlib support')
    stage = work / 'sdk'
    (stage / 'lib').mkdir(parents=True, exist_ok=True)
    shutil.copytree(boring / 'include/openssl', stage / 'include/openssl', dirs_exist_ok=True)
    shutil.copytree(curl / 'include/curl', stage / 'include/curl', dirs_exist_ok=True)
    shutil.copytree(includes, stage / 'include', dirs_exist_ok=True)
    for source, name in [(curl_build / 'curl/lib/libcurl.a', 'curl'),
                         (boring_build / 'libssl.a', 'ssl'), (boring_build / 'libcrypto.a', 'crypto'),
                         (zlib_build / 'libz.a', 'zlib')]:
        shutil.copyfile(source, stage / f'lib/lib{name}.a')
    (stage / 'cmake').mkdir(exist_ok=True)
    shutil.copyfile(ROOT / 'tool/ohos/EchHttpDeps.cmake', stage / 'cmake/EchHttpDeps.cmake')
    (stage / 'metadata.json').write_text(json.dumps({
        'schema': 1, 'target': f'ohos-{options.arch}',
        'curl': manifest['curl'], 'boringssl': manifest['boringssl'], 'zlib': manifest['zlib'],
        'native_sdk': sdk_metadata,
    }, indent=2) + '\n')
    if options.deps_only:
        return
    bridge = work / 'bridge'
    configure(cmake, ROOT / 'src', bridge, [*common,
         f'-DEH_DEPS_ROOT={stage}', f'-DEH_DART_INCLUDE={options.dart_sdk.resolve()}/include',
         '-DEH_BUILD_SMOKE=ON'], identity)
    run([cmake, '--build', bridge, '--parallel', parallel])
    print(f'OpenHarmony library: {bridge}/out/libech_http.so', flush=True)


if __name__ == '__main__':
    main()
