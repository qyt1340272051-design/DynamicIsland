"""Exercise the published path in a standalone SDK copy, not shell mocks."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

SDK = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SDK / 'tools'))
import check_docs


class DocumentationTests(unittest.TestCase):
    def copy_sdk(self, directory):
        sdk = Path(directory) / 'SDK'
        sdk.mkdir()
        for name in ('tools', 'types', 'examples', 'docs'):
            shutil.copytree(SDK / name, sdk / name, ignore=shutil.ignore_patterns('__pycache__'))
        for name in ('schema',):
            shutil.copytree(SDK / name, sdk / name)
        shutil.copy(SDK / 'VERSIONING.md', sdk / 'VERSIONING.md')
        return sdk

    def test_all_handbook_sources_are_exact_valid_examples_and_links_resolve(self):
        result = check_docs.check(SDK)
        self.assertEqual(result['examples'], 9)
        self.assertEqual(result['documents'], 15)

    def test_quick_start_builds_the_actual_template_from_a_standalone_sdk(self):
        with tempfile.TemporaryDirectory(prefix='sdk-documentation-') as directory:
            sdk = self.copy_sdk(directory)
            # Exercise the command actually copied from the handbook. On macOS
            # use an interactive zsh without user startup files: pasting the
            # old full Bash block here expanded its shebang as shell history.
            check_docs.check(sdk)
            environment = dict(os.environ, TMPDIR=directory, HISTFILE=os.devnull)
            command = (sdk / 'docs/quick-start-command.sh').read_text()
            shell = ['zsh', '-f', '-i'] if shutil.which('zsh') else ['bash', '--noprofile', '--norc', '-i']
            result = subprocess.run(shell, input=command + '\nexit\n', cwd=sdk, env=environment,
                                    check=True, capture_output=True, text=True, timeout=30)
            package_lines = [line for line in result.stdout.splitlines() if line.startswith('Plugin package: ')]
            self.assertEqual(len(package_lines), 1)
            package = Path(package_lines[0].removeprefix('Plugin package: '))
            self.assertTrue(package.is_relative_to(Path(directory)))
            with zipfile.ZipFile(package) as archive:
                self.assertEqual(set(archive.namelist()), {'manifest.json', 'index.js', 'README.md'})
                for name in archive.namelist():
                    self.assertEqual(archive.read(name), (SDK / 'examples/hello-world' / name).read_bytes())
            self.assertEqual(package.read_bytes(), (SDK / 'tests/fixtures/hello-world.dip').read_bytes())

    def test_changed_source_cannot_leave_a_stale_code_block_green(self):
        with tempfile.TemporaryDirectory() as directory:
            sdk = self.copy_sdk(directory)
            source = sdk / 'docs/snippets/activity.js'
            source.write_text(source.read_text() + '// changed\n')
            with self.assertRaisesRegex(ValueError, 'example drift'):
                check_docs.check(sdk)

    def test_untracked_code_and_broken_links_fail_documentation_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            sdk = self.copy_sdk(directory)
            page = sdk / 'docs/quick-start.md'
            original = page.read_text()
            page.write_text(original + '\n```js\nunknownAPI();\n```\n')
            with self.assertRaisesRegex(ValueError, 'needs sdk-source'):
                check_docs.check(sdk)
            page.write_text(original + '\n[Missing topic](missing.md)\n')
            with self.assertRaisesRegex(ValueError, 'broken link'):
                check_docs.check(sdk)


if __name__ == '__main__':
    unittest.main()
