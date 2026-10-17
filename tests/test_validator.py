"""Offline authoring-tool regressions; no App, network or JS execution."""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

SDK = Path(__file__).resolve().parents[1]
FIXTURES = SDK / 'tests' / 'fixtures'
TOOLS = SDK / 'tools'
sys.path.insert(0, str(TOOLS))
import di_plugin as tool
import package_plugin as archive_tool


class ValidatorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='di-sdk-test-')
        self.root = Path(self.temporary.name)
        self.manifest = json.loads((FIXTURES / 'valid-manifest.json').read_text())

    def tearDown(self):
        self.temporary.cleanup()

    def rejected(self, function, value, code=None):
        with self.assertRaises(tool.ValidationError) as caught:
            function(value)
        if code:
            self.assertEqual(caught.exception.code, code)

    def invoke(self, *arguments, script=None):
        completed = subprocess.run([sys.executable, str(script or TOOLS / 'di_plugin.py'),
                                    *map(str, arguments)], text=True, capture_output=True,
                                   cwd=self.root, timeout=15)
        self.assertEqual(completed.stderr, '')
        output = json.loads(completed.stdout)
        self.assertEqual(output['ok'], completed.returncode == 0)
        return completed, output

    def source(self):
        source = self.root / 'source'
        source.mkdir()
        (source / 'manifest.json').write_text(json.dumps(self.manifest))
        (source / 'index.js').write_text('throw new Error("DO_NOT_PRINT_OR_EXECUTE_ENTRY");\n')
        return source

    def test_valid_fixtures_and_all_eight_node_kinds(self):
        tool.validate_manifest(tool.read_json(FIXTURES / 'valid-manifest.json'))
        summary = tool.validate_node(tool.read_json(FIXTURES / 'valid-node.json'))
        self.assertEqual(summary, {'nodes': 10, 'depth': 4})

    def test_shared_host_contract_cases_match_all_expected_results(self):
        cases = json.loads((FIXTURES / 'host-contract-cases.json').read_text())
        self.assertEqual(len(cases['manifests']), 12)
        self.assertEqual(len(cases['nodes']), 18)
        for group, validator in (('manifests', tool.validate_manifest),
                                 ('nodes', tool.validate_node)):
            for case in cases[group]:
                with self.subTest(group=group, case=case['name']):
                    source = (case['source'] if group == 'manifests' else
                              json.dumps(case['node'], ensure_ascii=False, allow_nan=False))
                    try:
                        validator(tool.decode_json(source.encode('utf-8')))
                        accepted = True
                    except tool.ValidationError:
                        accepted = False
                    self.assertEqual(accepted, case['accept'])

    def test_both_official_manifests_use_the_closed_host_vocabulary(self):
        repo = SDK.parent
        for name in ('pomodoro', 'github'):
            file = repo / 'docs' / 'plugin-system' / 'examples' / name / 'manifest.json'
            if not file.exists():
                self.skipTest('Repository official examples are outside the portable SDK.')
            tool.validate_manifest(tool.read_json(file))

    def test_manifest_schema_copy_is_exact_and_enums_match_cli(self):
        schema = json.loads((SDK / 'schema' / 'plugin-manifest-v1.schema.json').read_text())
        canonical = SDK.parent / 'docs/plugin-system/schema/plugin-manifest-v1.schema.json'
        if canonical.exists():
            self.assertEqual(schema, json.loads(canonical.read_text()))
        self.assertEqual(set(schema['$defs']['permission']['enum']), set(tool.PERMISSIONS))
        self.assertEqual(set(schema['$defs']['capability']['enum']), set(tool.CAPABILITIES))
        self.assertEqual(schema['properties']['permissions']['maxItems'], 8)
        self.assertEqual(schema['properties']['capabilities']['maxItems'], 10)

    def test_manifest_required_unknown_proto_and_null_fields(self):
        for missing in self.manifest:
            value = copy.deepcopy(self.manifest)
            del value[missing]
            self.rejected(tool.validate_manifest, value)
        for field in ('__proto__', 'constructor', 'prototype', 'apiVersion'):
            value = dict(self.manifest, **{field: {}})
            self.rejected(tool.validate_manifest, value)
        for field in list(self.manifest) + ['developer']:
            value = dict(self.manifest, **{field: None})
            self.rejected(tool.validate_manifest, value)

    def test_manifest_exact_types_and_closed_arrays(self):
        for change in ({'schemaVersion': True}, {'schemaVersion': '1'}, {'schemaVersion': 2},
                       {'id': []}, {'engine': 'native'}, {'permissions': ['network', 'network']},
                       {'permissions': ['unknown']}, {'capabilities': ['network']},
                       {'capabilities': [None]}, {'permissions': 'network'}):
            self.rejected(tool.validate_manifest, dict(self.manifest, **change))
        tool.validate_manifest(dict(self.manifest, schemaVersion=1.0))
        tool.validate_manifest(dict(self.manifest, permissions=sorted(tool.PERMISSIONS),
                                    capabilities=sorted(tool.CAPABILITIES)))

    def test_manifest_ids_entry_paths_and_byte_limits(self):
        for value in ('com.example', 'Com.example.demo', 'com.1example.demo',
                      'com.example.demo-', 'com..demo', 'com.' + 'a' * 64 + '.demo',
                      'com.' + 'a' * 63 + '.' + 'b' * 63 + '.' + 'c' * 63 + '.' + 'd' * 63):
            self.rejected(tool.validate_manifest, dict(self.manifest, id=value))
        for value in ('../index.js', '/index.js', 'a//index.js', './index.js',
                      'a/../index.js', 'a\\index.js', 'C:index.js', '.js', 'index.JS',
                      'a/' + 'x' * 240 + '.js'):
            self.rejected(tool.validate_manifest, dict(self.manifest, entry=value))
        tool.validate_manifest(dict(self.manifest, entry='dist/.entry.js'))

    def test_manifest_names_count_scalars_and_reject_hidden_controls(self):
        tool.validate_manifest(dict(self.manifest, name='😀' * 80))
        for value in ('', '😀' * 81, ' leading', 'trailing\u3000', '\u00a0name',
                      'hidden\u200bname', 'line\nname', 'bad\u202ename'):
            self.rejected(tool.validate_manifest, dict(self.manifest, name=value))

    def test_semver_handles_big_components_without_integer_coercion(self):
        for value in ('0.0.0', '1.2.3-alpha.0+build.01', '9' * 100 + '.0.0'):
            tool.validate_manifest(dict(self.manifest, version=value))
        for value in ('01.0.0', '1.0', 'v1.0.0', '1.0.0-01', '1.0.0+',
                      '1.0.0-a..b', '1.0.0+α', '1' * 129 + '.0.0'):
            self.rejected(tool.validate_manifest, dict(self.manifest, version=value))

    def test_json_invalid_encodings_bom_nul_and_unpaired_surrogates(self):
        for value in (b'\xff', b'\xef\xbb\xbf{}', b'{"x":"\x00"}', b'"\\ud800"',
                      b'{"x":"\\udfff"}', b'{broken', b'{} trailing'):
            self.rejected(tool.decode_json, value, 'invalidJSON')

    def test_duplicate_keys_are_rejected_including_escapes_and_nested_nodes(self):
        for value in (b'{"id":1,"id":2}', b'{"type":"text","content":"x","\\u0063ontent":"y"}',
                      b'{"label":{"type":"text","type":"icon"}}'):
            self.rejected(tool.decode_json, value, 'duplicateField')

    def test_nonfinite_and_overflow_json_numbers(self):
        for value in (b'NaN', b'Infinity', b'-Infinity', b'1e9999', b'-1e9999'):
            self.rejected(tool.decode_json, value, 'invalidJSON')
        self.rejected(tool.decode_json, b' ' * 65_537, 'quotaExceeded')

    def test_nodes_reject_unknown_null_types_and_proto_properties(self):
        for value in (None, [], {'type': None}, {'type': 'image', 'source': {}},
                      {'type': 'zStack', 'children': []}, {'type': 'text', 'content': None},
                      {'type': 'text', 'content': 'x', 'color': None},
                      {'type': 'text', 'content': 'x', '__proto__': {}},
                      {'type': 'button', 'actionID': 'a', 'label': None},
                      {'type': 'hStack', 'children': None}):
            self.rejected(tool.validate_node, value)

    def test_node_text_limits_use_utf8_not_character_count(self):
        tool.validate_node({'type': 'text', 'content': '😀' * 64})
        self.rejected(tool.validate_node, {'type': 'text', 'content': '😀' * 65}, 'quotaExceeded')
        self.rejected(tool.validate_node, {'type': 'button', 'actionID': 'x',
                                          'label': {'type': 'spacer'},
                                          'accessibilityLabel': '中' * 86}, 'quotaExceeded')

    def test_node_identifiers_colors_and_progress_values(self):
        for value in ({'type': 'icon', 'symbolName': '../icon'},
                      {'type': 'icon', 'symbolName': 'x' * 129},
                      {'type': 'button', 'actionID': 'x' * 81, 'label': {'type': 'spacer'}},
                      {'type': 'progress', 'value': True}, {'type': 'progress', 'value': -0.1},
                      {'type': 'progress', 'value': 1.1}, {'type': 'progress', 'value': float('nan')},
                      {'type': 'progress', 'value': 0.5, 'color': '#fff'},
                      {'type': 'progress', 'value': 0.5, 'style': 'circular'}):
            self.rejected(tool.validate_node, value)
        for color in tool.COLORS:
            tool.validate_node({'type': 'progress', 'value': 1, 'style': 'battery', 'color': color})

    def test_countdown_requires_lowercase_canonical_uuid_and_no_state_fields(self):
        value = {'type': 'countdown', 'id': 'focus',
                 'generation': '12345678-1234-1234-1234-123456789abc'}
        tool.validate_node(value)
        for change in ({'generation': value['generation'].upper()}, {'generation': None},
                       {'generation': 'not-a-uuid'}, {'id': ''}, {'remainingMs': 15},
                       {'deadline': 1}, {'style': 'ring'}):
            self.rejected(tool.validate_node, dict(value, **change))

    def test_depth_children_and_aggregate_node_boundaries(self):
        node = {'type': 'text', 'content': 'leaf'}
        for _ in range(7):
            node = {'type': 'vStack', 'children': [node]}
        self.assertEqual(tool.validate_node(node)['depth'], 8)
        self.rejected(tool.validate_node, {'type': 'button', 'actionID': 'x', 'label': node}, 'quotaExceeded')
        self.rejected(tool.validate_node, {'type': 'hStack', 'children': [{'type': 'spacer'}] * 17}, 'quotaExceeded')
        # Root + seven full rows (7*17) + one row of seven leaves = 128.
        rows = [{'type': 'hStack', 'children': [{'type': 'spacer'}] * 16} for _ in range(7)]
        rows.append({'type': 'hStack', 'children': [{'type': 'spacer'}] * 7})
        self.assertEqual(tool.validate_node({'type': 'vStack', 'children': rows})['nodes'], 128)
        rows[-1]['children'].append({'type': 'spacer'})
        self.rejected(tool.validate_node, {'type': 'vStack', 'children': rows}, 'quotaExceeded')

    def test_json_file_read_rejects_links_and_oversize(self):
        file = self.root / 'node.json'
        file.write_text('{"type":"spacer"}')
        link = self.root / 'link.json'
        link.symlink_to(file)
        self.rejected(tool.read_json, link, 'unsafeFile')
        hardlink = self.root / 'hard.json'
        os.link(file, hardlink)
        self.rejected(tool.read_json, file, 'unsafeFile')
        hardlink.unlink()
        file.write_bytes(b' ' * 65_537)
        self.rejected(tool.read_json, file, 'quotaExceeded')

    def test_source_validation_does_not_execute_entry(self):
        source = self.source()
        summary = tool.validate_directory(source)
        self.assertEqual(summary['files'], 2)
        completed, output = self.invoke('validate', source)
        self.assertTrue(output['ok'])
        self.assertNotIn('DO_NOT_PRINT_OR_EXECUTE_ENTRY', completed.stdout)

    def test_source_rejects_root_and_nested_symlinks_and_hardlinks(self):
        source = self.source()
        link = self.root / 'linked-source'
        link.symlink_to(source, target_is_directory=True)
        self.rejected(tool.validate_directory, link, 'invalidPackage')
        (source / 'alias.js').symlink_to(source / 'index.js')
        self.rejected(tool.validate_directory, source, 'invalidPackage')
        (source / 'alias.js').unlink()
        os.link(source / 'index.js', source / 'hard.js')
        self.rejected(tool.validate_directory, source, 'invalidPackage')

    def test_source_rejects_unsafe_paths_missing_entry_and_special_files(self):
        source = self.source()
        (source / 'bad\\name.js').write_text('x')
        self.rejected(tool.validate_directory, source, 'invalidPackage')
        (source / 'bad\\name.js').unlink()
        (source / 'index.js').unlink()
        self.rejected(tool.validate_directory, source, 'invalidPackage')
        os.mkfifo(source / 'index.js')
        self.rejected(tool.validate_directory, source, 'invalidPackage')

    def test_source_rejects_file_count_size_and_depth_excess(self):
        source = self.source()
        for index in range(255):
            (source / ('extra' + str(index))).touch()
        self.rejected(tool.validate_directory, source, 'invalidPackage')
        for file in source.glob('extra*'):
            file.unlink()
        with (source / 'large').open('wb') as stream:
            stream.truncate(8 * 1024 * 1024 + 1)
        self.rejected(tool.validate_directory, source, 'invalidPackage')
        (source / 'large').unlink()
        nested = source
        for _ in range(17):
            nested = nested / 'a'
            nested.mkdir()
        self.rejected(tool.validate_directory, source, 'invalidPackage')

    def test_source_aggregate_bytes_and_path_entries_are_bounded(self):
        source = self.source()
        for index in range(5):
            with (source / ('large' + str(index))).open('wb') as stream:
                stream.truncate(8 * 1024 * 1024)
        self.rejected(tool.validate_directory, source, 'invalidPackage')
        for file in source.glob('large*'):
            file.unlink()
        for index in range(511):
            (source / ('dir' + str(index))).mkdir()
        self.rejected(tool.validate_directory, source, 'invalidPackage')

    def test_source_relative_path_bytes_are_bounded(self):
        source = self.source()
        # dir_fd creates a genuine overlong relative tree without macOS's
        # absolute-path syscall ceiling preventing fixture setup first.
        descriptor = os.open(source, os.O_RDONLY | os.O_DIRECTORY)
        try:
            for _ in range(15):
                name = 'a' * 70
                os.mkdir(name, dir_fd=descriptor)
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY, dir_fd=descriptor)
                os.close(descriptor)
                descriptor = child
            file_descriptor = os.open('x', os.O_CREAT | os.O_WRONLY, 0o600, dir_fd=descriptor)
            os.close(file_descriptor)
        finally:
            os.close(descriptor)
        self.rejected(tool.validate_directory, source, 'invalidPackage')

    def test_package_is_deterministic_and_refuses_overwrite_or_inside_output(self):
        source = self.source()
        first, second = self.root / 'first.dip', self.root / 'second.dip'
        self.invoke('package', source, first)
        self.invoke('package', source, second)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        original = first.read_bytes()
        _, output = self.invoke('package', source, first)
        self.assertFalse(output['ok'])
        self.assertEqual(first.read_bytes(), original)
        _, output = self.invoke('package', source, source / 'inside.dip')
        self.assertFalse(output['ok'])
        self.assertFalse((source / 'inside.dip').exists())
        with zipfile.ZipFile(first) as archive:
            self.assertEqual(sorted(archive.namelist()), ['index.js', 'manifest.json'])
            self.assertTrue(all(info.date_time == (1980, 1, 1, 0, 0, 0) for info in archive.infolist()))

    def test_package_resolves_output_parent_before_containment_check(self):
        source = self.source()
        alias = self.root / 'alias'
        alias.symlink_to(source, target_is_directory=True)
        _, output = self.invoke('package', source, alias / 'inside.dip')
        self.assertFalse(output['ok'])
        self.assertFalse((source / 'inside.dip').exists())

    def test_package_validates_manifest_before_creating_archive(self):
        source = self.source()
        (source / 'manifest.json').write_text('{"secret_body_do_not_echo":true}')
        target = self.root / 'invalid.dip'
        completed, output = self.invoke('package', source, target)
        self.assertFalse(output['ok'])
        self.assertFalse(target.exists())
        self.assertNotIn('secret_body_do_not_echo', completed.stdout)

    def test_archive_refuses_file_symlink_swap_after_inspection(self):
        source = self.source()
        outside = self.root / 'outside-secret.js'
        outside.write_text('PRIVATE_OUTSIDE_SOURCE')
        target = self.root / 'swapped.dip'
        original = archive_tool.inspect_source
        def swap(path):
            result = original(path)
            (source / 'index.js').unlink()
            (source / 'index.js').symlink_to(outside)
            return result
        with mock.patch.object(archive_tool, 'inspect_source', side_effect=swap):
            with self.assertRaises((ValueError, OSError)):
                archive_tool.package(source, target)
        self.assertFalse(target.exists())

    def test_archive_refuses_parent_directory_symlink_swap_after_inspection(self):
        source = self.source()
        (source / 'dist').mkdir()
        (source / 'dist' / 'extra.js').write_text('original')
        outside = self.root / 'outside'
        outside.mkdir()
        (outside / 'extra.js').write_text('PRIVATE_OUTSIDE_SOURCE')
        target = self.root / 'parent-swapped.dip'
        original = archive_tool.inspect_source
        def swap(path):
            result = original(path)
            shutil.rmtree(source / 'dist')
            (source / 'dist').symlink_to(outside, target_is_directory=True)
            return result
        with mock.patch.object(archive_tool, 'inspect_source', side_effect=swap):
            with self.assertRaises((ValueError, OSError)):
                archive_tool.package(source, target)
        self.assertFalse(target.exists())

    def test_portable_tools_work_without_repository_files(self):
        portable = self.root / 'portable-tools'
        shutil.copytree(TOOLS, portable, ignore=shutil.ignore_patterns('__pycache__'))
        source = self.source()
        _, output = self.invoke('package', source, self.root / 'portable.dip',
                                script=portable / 'di_plugin.py')
        self.assertTrue(output['ok'])

    def test_repository_wrapper_preserves_legacy_cli_and_archive_bytes(self):
        wrapper = SDK.parent / 'Scripts' / 'package-plugin.py'
        if not wrapper.exists():
            self.skipTest('Repository compatibility wrapper is outside the portable SDK.')
        source = self.source()
        # The legacy command intentionally remains archive-only. The new SDK
        # package command performs the separate authoring preflight first.
        (source / 'manifest.json').write_text('{}')
        wrapped = self.root / 'wrapped.dip'
        expected = self.root / 'expected.dip'
        completed = subprocess.run([sys.executable, str(wrapper), str(source), str(wrapped)],
                                   capture_output=True, text=True, timeout=15)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout,
                         'Created ' + str(wrapped) + '. Import it in Dynamic Island to validate.\n')
        archive_tool.package(source, expected)
        self.assertEqual(wrapped.read_bytes(), expected.read_bytes())

    def test_cli_errors_are_short_fixed_json_without_input_echo(self):
        file = self.root / 'bad.json'
        file.write_text('{"SECRET_SCRIPT_OR_STORAGE_BODY": broken')
        for arguments in (('validate-node', file), ('unknown-SECRET-argument',),
                          ('validate-manifest',), ('validate-node', self.root / 'missing')):
            completed, output = self.invoke(*arguments)
            self.assertFalse(output['ok'])
            self.assertLess(len(completed.stdout), 240)
            self.assertNotIn('SECRET', completed.stdout)
            self.assertNotIn(str(self.root), completed.stdout)

    def test_hello_world_package_matches_committed_cross_language_fixture(self):
        source = SDK / 'examples' / 'hello-world'
        expected = FIXTURES / 'hello-world.dip'
        self.assertTrue(source.is_dir(), 'Canonical Hello source must be included.')
        self.assertTrue(expected.is_file(), 'Cross-language archive fixture must be included.')
        actual = self.root / 'hello-world.dip'
        self.invoke('package', source, actual)
        self.assertEqual(actual.read_bytes(), expected.read_bytes())


if __name__ == '__main__':
    unittest.main()
