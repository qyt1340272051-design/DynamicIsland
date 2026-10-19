#!/usr/bin/env python3
"""SDK 1.0.0 release-candidate offline preflight, narrower than Host admission.

Python 3.9+ standard library only. No JavaScript is executed. Manifest validation
mirrors the Host's closed V1 vocabulary; declarations do not promise accepted
SDK APIs. Nodes cover only the eight kinds used by the official examples.
The Host independently checks permissions, instances, quotas and countdowns.

Copied schemas are editor aids. CLI checks also enforce UTF-8 bytes, duplicate
keys, finite numbers and aggregate tree limits. Schema copies and these checks
can drift: Host parity tests remain required.
"""
import argparse
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import uuid
import zipfile

from package_plugin import inspect_source, package


SDK_VERSION = '1.0.0'
MAX_JSON_BYTES = 65_536
PERMISSIONS = frozenset((
    'network', 'storage.local', 'links.open', 'notifications.publish',
    'clipboard.read', 'clipboard.write', 'calendar.read', 'files.userSelected',
))
CAPABILITIES = frozenset((
    'activity.publish', 'activity.update', 'activity.end', 'ui.islandNode',
    'actions.handle', 'storage.local', 'scheduler', 'countdown', 'links.open',
    'presentation.request',
))
COLORS = frozenset(('primary', 'secondary', 'accent', 'success', 'warning', 'danger'))
NODE_KINDS = frozenset(('text', 'icon', 'hStack', 'vStack', 'spacer',
                        'progress', 'countdown', 'button'))
MANIFEST_FIELDS = frozenset((
    'schemaVersion', 'id', 'name', 'version', 'engine', 'entry',
    'minimumHostVersion', 'permissions', 'capabilities',
))
SEMVER = re.compile(
    r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
    r'(?:-(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
    r'(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?'
    r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?'
)
IDENTIFIER = re.compile(r'[A-Za-z0-9._-]+')
SYMBOL = re.compile(r'[A-Za-z0-9._:-]+')
LABEL = re.compile(r'[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?')
ENTRY_COMPONENT = re.compile(r'[A-Za-z0-9._-]+')
MESSAGES = {
    'invalidJSON': 'Invalid or unsupported JSON.',
    'duplicateField': 'Duplicate JSON field.',
    'invalidManifest': 'Invalid Manifest V1 data.',
    'invalidNode': 'Invalid authoring-subset node.',
    'quotaExceeded': 'An authoring limit was exceeded.',
    'unsafeFile': 'Input must be a regular file with one link.',
    'invalidPackage': 'Invalid package directory or archive output.',
    'ioError': 'File operation failed.',
    'usage': 'Invalid command arguments.',
}


class ValidationError(ValueError):
    def __init__(self, code, path='$'):
        self.code = code
        self.path = path
        super().__init__(MESSAGES[code])


def fail(code, path='$'):
    raise ValidationError(code, path)


def utf8_size(value, code, path):
    try:
        return len(value.encode('utf-8', errors='strict'))
    except (AttributeError, UnicodeError):
        fail(code, path)


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail('duplicateField')
        result[key] = value
    return result


def _finite_float(value):
    number = float(value)
    if not math.isfinite(number):
        fail('invalidJSON')
    return number


def _constant(_value):
    fail('invalidJSON')


def decode_json(data):
    if len(data) > MAX_JSON_BYTES:
        fail('quotaExceeded')
    if data.startswith(b'\xef\xbb\xbf') or b'\x00' in data:
        fail('invalidJSON')
    try:
        value = json.loads(data.decode('utf-8', errors='strict'),
                           object_pairs_hook=_pairs, parse_float=_finite_float,
                           parse_constant=_constant)
        _check_unicode(value)
        return value
    except ValidationError:
        raise
    except (ValueError, UnicodeError, RecursionError, OverflowError):
        fail('invalidJSON')


def _check_unicode(value):
    # Escaped lone surrogates are not valid Swift Unicode scalar data.
    if isinstance(value, str):
        utf8_size(value, 'invalidJSON', '$')
    elif isinstance(value, list):
        for item in value:
            _check_unicode(item)
    elif isinstance(value, dict):
        for key, item in value.items():
            utf8_size(key, 'invalidJSON', '$')
            _check_unicode(item)


def read_json(path):
    try:
        before = path.lstat()
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            fail('unsafeFile')
        if before.st_size > MAX_JSON_BYTES:
            fail('quotaExceeded')
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, 'rb') as stream:
            opened = os.fstat(stream.fileno())
            if (not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1
                    or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)):
                fail('unsafeFile')
            data = stream.read(MAX_JSON_BYTES + 1)
            after = os.fstat(stream.fileno())
            if (after.st_size, after.st_mtime_ns, after.st_ctime_ns) != (
                    opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns):
                fail('unsafeFile')
        return decode_json(data)
    except ValidationError:
        raise
    except OSError:
        fail('ioError')


def fields(value, required, optional, code, path):
    if type(value) is not dict:
        fail(code, path)
    keys = set(value)
    if not set(required).issubset(keys) or not keys.issubset(set(required) | set(optional)):
        fail(code, path)


def string(value, code, path, maximum_bytes=None, nonempty=False):
    if type(value) is not str or (nonempty and not value):
        fail(code, path)
    size = utf8_size(value, code, path)
    if maximum_bytes is not None and size > maximum_bytes:
        fail('quotaExceeded', path)
    return value


def _name(value, path):
    string(value, 'invalidManifest', path, nonempty=True)
    if len(value) > 80:
        fail('invalidManifest', path)
    def boundary(char):
        n = ord(char)
        return n in (0x20, 0xA0, 0x1680, 0x202F, 0x205F, 0x3000) or 0x2000 <= n <= 0x200A
    if boundary(value[0]) or boundary(value[-1]):
        fail('invalidManifest', path)
    for char in value:
        n = ord(char)
        if (0 <= n <= 0x1F or 0x7F <= n <= 0x9F
                or n in (0xAD, 0x61C, 0x180E, 0xFEFF)
                or 0x200B <= n <= 0x200F or 0x2028 <= n <= 0x202E
                or 0x2060 <= n <= 0x206F or 0xFFF9 <= n <= 0xFFFB):
            fail('invalidManifest', path)


def _version(value, path):
    string(value, 'invalidManifest', path, maximum_bytes=128, nonempty=True)
    if SEMVER.fullmatch(value) is None:
        fail('invalidManifest', path)


def _closed_array(value, allowed, path):
    if type(value) is not list or len(value) > len(allowed):
        fail('invalidManifest', path)
    seen = set()
    for item in value:
        if type(item) is not str or item not in allowed or item in seen:
            fail('invalidManifest', path)
        seen.add(item)


def validate_manifest(value):
    fields(value, MANIFEST_FIELDS, ('developer',), 'invalidManifest', '$')
    version = value['schemaVersion']
    if type(version) not in (int, float) or version != 1:
        fail('invalidManifest', '$.schemaVersion')
    plugin_id = string(value['id'], 'invalidManifest', '$.id', 255, True)
    parts = plugin_id.split('.')
    if len(parts) < 3 or any(LABEL.fullmatch(part) is None for part in parts):
        fail('invalidManifest', '$.id')
    _name(value['name'], '$.name')
    if 'developer' in value:
        _name(value['developer'], '$.developer')
    for key in ('version', 'minimumHostVersion'):
        _version(value[key], '$.' + key)
    if type(value['engine']) is not str or value['engine'] not in ('javascriptcore', 'superisland'):
        fail('invalidManifest', '$.engine')
    entry = string(value['entry'], 'invalidManifest', '$.entry', 240, True)
    entry_parts = entry.split('/')
    if (not entry.endswith('.js') or len(entry_parts[-1]) <= 3
            or any(part in ('.', '..') or ENTRY_COMPONENT.fullmatch(part) is None for part in entry_parts)):
        fail('invalidManifest', '$.entry')
    _closed_array(value['permissions'], PERMISSIONS, '$.permissions')
    _closed_array(value['capabilities'], CAPABILITIES, '$.capabilities')
    return value


def _identifier(value, path, limit=128, symbol=False):
    string(value, 'invalidNode', path, limit, True)
    if (SYMBOL if symbol else IDENTIFIER).fullmatch(value) is None:
        fail('invalidNode', path)


def _token(value, allowed, path):
    if type(value) is not str or value not in allowed:
        fail('invalidNode', path)


def validate_node(value):
    count = 0
    deepest = 0
    def visit(node, depth, path):
        nonlocal count, deepest
        count += 1
        deepest = max(deepest, depth)
        if depth > 8 or count > 128:
            fail('quotaExceeded', path)
        if type(node) is not dict or type(node.get('type')) is not str:
            fail('invalidNode', path)
        kind = node['type']
        shapes = {
            'text': (('type', 'content'), ('color',)),
            'icon': (('type', 'symbolName'), ()),
            'hStack': (('type', 'children'), ()),
            'vStack': (('type', 'children'), ()),
            'spacer': (('type',), ()),
            'progress': (('type', 'value'), ('style', 'color')),
            'countdown': (('type', 'id', 'generation'), ('style', 'color')),
            'button': (('type', 'actionID', 'label'), ('accessibilityLabel',)),
        }
        if kind not in shapes:
            fail('invalidNode', path)
        fields(node, *shapes[kind], 'invalidNode', path)
        if 'color' in node:
            _token(node['color'], COLORS, path + '.color')
        if kind == 'text':
            string(node['content'], 'invalidNode', path + '.content', 256)
        elif kind == 'icon':
            _identifier(node['symbolName'], path + '.symbolName', symbol=True)
        elif kind in ('hStack', 'vStack'):
            children = node['children']
            if type(children) is not list:
                fail('invalidNode', path + '.children')
            if len(children) > 16:
                fail('quotaExceeded', path + '.children')
            for index, child in enumerate(children):
                visit(child, depth + 1, path + '.children[' + str(index) + ']')
        elif kind == 'progress':
            number = node['value']
            if type(number) not in (int, float) or not 0 <= number <= 1:
                fail('invalidNode', path + '.value')
            if 'style' in node:
                _token(node['style'], ('linear', 'battery'), path + '.style')
        elif kind == 'countdown':
            _identifier(node['id'], path + '.id', 80)
            generation = string(node['generation'], 'invalidNode', path + '.generation', 36)
            try:
                if len(generation) != 36 or str(uuid.UUID(generation)) != generation:
                    fail('invalidNode', path + '.generation')
            except (ValueError, AttributeError):
                fail('invalidNode', path + '.generation')
            if 'style' in node:
                _token(node['style'], ('time', 'progress'), path + '.style')
        elif kind == 'button':
            _identifier(node['actionID'], path + '.actionID', 80)
            if 'accessibilityLabel' in node:
                string(node['accessibilityLabel'], 'invalidNode', path + '.accessibilityLabel', 256)
            visit(node['label'], depth + 1, path + '.label')
    visit(value, 1, '$')
    return {'nodes': count, 'depth': deepest}


def validate_directory(source):
    try:
        root, _entries, file_count, total = inspect_source(source)
        manifest = validate_manifest(read_json(root / 'manifest.json'))
        entry = root.joinpath(*manifest['entry'].split('/'))
        entry_info = entry.lstat()
        if not stat.S_ISREG(entry_info.st_mode) or entry_info.st_nlink != 1:
            fail('unsafeFile')
        # The declared entry is never interpreted or executed by this tool.
        return {'files': file_count, 'bytes': total}
    except ValidationError:
        raise
    except (ValueError, OSError):
        fail('invalidPackage')


class Parser(argparse.ArgumentParser):
    def error(self, message):
        fail('usage')


def main(argv=None):
    command = 'unknown'
    try:
        parser = Parser(description=__doc__)
        commands = parser.add_subparsers(dest='command', required=True, parser_class=Parser)
        for name in ('validate-manifest', 'validate-node'):
            commands.add_parser(name).add_argument('file', type=Path)
        commands.add_parser('validate').add_argument('directory', type=Path)
        package_parser = commands.add_parser('package')
        package_parser.add_argument('source', type=Path)
        package_parser.add_argument('output', type=Path)
        args = parser.parse_args(argv)
        command = args.command
        summary = {}
        if command == 'validate-manifest':
            validate_manifest(read_json(args.file))
        elif command == 'validate-node':
            summary = validate_node(read_json(args.file))
        elif command == 'validate':
            summary = validate_directory(args.directory)
        elif command == 'package':
            summary = validate_directory(args.source)
            try:
                package(args.source, args.output)
            except (OSError, ValueError, zipfile.BadZipFile, zipfile.LargeZipFile):
                fail('invalidPackage')
        print(json.dumps({'ok': True, 'command': command, 'scope': 'authoring-preflight', 'sdkVersion': SDK_VERSION,
                          'summary': summary}, sort_keys=True))
        return 0
    except ValidationError as error:
        print(json.dumps({'ok': False, 'command': command, 'code': error.code,
                          'message': MESSAGES[error.code], 'path': error.path}, sort_keys=True))
        return 1


if __name__ == '__main__':
    sys.exit(main())
