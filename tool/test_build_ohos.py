"""Offline regression tests for the OHOS CMake cache lifecycle."""
from pathlib import Path
import shutil
import subprocess
from tempfile import TemporaryDirectory
import unittest

from build_ohos import configure


@unittest.skipUnless(shutil.which('cmake'), 'CMake is required')
class ConfigureTest(unittest.TestCase):
    def setUp(self):
        self.temporary = TemporaryDirectory(prefix='ech-ohos-cache-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / 'source-v1'
        self.source.mkdir()
        (self.source / 'CMakeLists.txt').write_text(
            'cmake_minimum_required(VERSION 3.22)\n'
            'project(cache_test NONE)\n'
            'set(CACHED_RESULT "${PIN}" CACHE STRING "configure probe")\n'
        )
        self.build = self.root / 'build'
        self.download = self.root / 'sources' / 'archive.tar'
        self.download.parent.mkdir()
        self.download.write_text('cached download')

    def check_configure(self, source=None, pin='one', identity=None):
        configure('cmake', source or self.source, self.build,
                  [f'-DPIN={pin}'], identity)
        self.assertEqual(self.download.read_text(), 'cached download')

    def test_unchanged_configuration_preserves_incremental_outputs(self):
        self.check_configure()
        artifact = self.build / 'incremental-output'
        artifact.write_text('keep')
        self.check_configure()
        self.assertEqual(artifact.read_text(), 'keep')

    def test_dependency_source_can_move_to_a_new_revision(self):
        self.check_configure()
        source = self.root / 'source-v2'
        shutil.copytree(self.source, source)
        self.check_configure(source=source)
        self.assertIn(f'CMAKE_HOME_DIRECTORY:INTERNAL={source}',
                      (self.build / 'CMakeCache.txt').read_text())

    def test_changed_arguments_repeat_cached_configure_probes(self):
        self.check_configure()
        self.check_configure(pin='two')
        self.assertIn('CACHED_RESULT:STRING=two',
                      (self.build / 'CMakeCache.txt').read_text())

    def test_dependency_and_sdk_updates_discard_generated_outputs(self):
        for identity in ({'dependency': 'v1', 'sdk': 'v1'},
                         {'dependency': 'v2', 'sdk': 'v1'},
                         {'dependency': 'v2', 'sdk': 'v2'}):
            with self.subTest(identity=identity):
                self.check_configure(identity=identity)
                artifact = self.build / 'obsolete-output'
                self.assertFalse(artifact.exists())
                artifact.write_text('remove on change')

    def test_migrates_a_build_without_a_fingerprint(self):
        subprocess.run(['cmake', '-S', str(self.source), '-B', str(self.build),
                        '-DPIN=legacy'], check=True, capture_output=True)
        self.check_configure()
        self.assertIn('CACHED_RESULT:STRING=one',
                      (self.build / 'CMakeCache.txt').read_text())


if __name__ == '__main__':
    unittest.main()
