#!/usr/bin/env python3
"""Create a portable ZIP32 .dip archive; the Host still validates on import."""
import argparse
import os
from pathlib import Path
import stat
import unicodedata
import zipfile


def package(source: Path, destination: Path) -> None:
    if source.is_symlink() or not source.is_dir():
        raise ValueError('source must be a real directory')
    source = source.resolve()
    destination = destination.absolute()
    if destination.suffix.lower() != '.dip' or destination.is_relative_to(source):
        raise ValueError('output must be a .dip outside the source directory')
    manifest = source / 'manifest.json'
    if not manifest.is_file() or manifest.is_symlink():
        raise ValueError('root manifest.json is required')
    entries, aliases = [], {}
    total, files = 0, 0
    for current, directories, names in os.walk(source, followlinks=False):
        for name in sorted(directories + names):
            path = Path(current) / name
            info = path.lstat()
            relative = path.relative_to(source).as_posix()
            parts = relative.split('/')
            if (len(parts) > 16 or len(relative.encode('utf-8')) > 1024
                    or any(part in ('', '.', '..') or '\\' in part or ':' in part
                           or any(unicodedata.category(char).startswith('C') for char in part)
                           for part in parts)):
                raise ValueError('unsupported package path')
            key = '/'.join(unicodedata.normalize('NFC', part).casefold() for part in parts)
            if key in aliases and aliases[key] != relative:
                raise ValueError('case or Unicode path collision')
            aliases[key] = relative
            if stat.S_ISDIR(info.st_mode):
                entries.append((path, relative + '/', True))
            elif stat.S_ISREG(info.st_mode) and info.st_nlink == 1:
                if info.st_size > 8 * 1024 * 1024:
                    raise ValueError('file exceeds 8 MiB')
                total += info.st_size
                files += 1
                entries.append((path, relative, False))
            else:
                raise ValueError('symlinks, hardlinks and special files are not supported')
    if len(entries) > 512 or files > 256 or total > 32 * 1024 * 1024:
        raise ValueError('package exceeds the Host resource limits')
    try:
        # Exclusive creation prevents accidentally replacing an earlier package.
        with destination.open('xb') as output:
            with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED,
                                 compresslevel=6, allowZip64=False) as archive:
                for path, relative, directory in sorted(entries, key=lambda item: item[1]):
                    entry = zipfile.ZipInfo(relative, date_time=(1980, 1, 1, 0, 0, 0))
                    entry.create_system = 3
                    entry.compress_type = zipfile.ZIP_STORED if directory else zipfile.ZIP_DEFLATED
                    entry.external_attr = ((stat.S_IFDIR | 0o700) if directory else
                                           (stat.S_IFREG | 0o600)) << 16
                    if directory:
                        entry.external_attr |= 0x10
                    archive.writestr(entry, b'' if directory else path.read_bytes())
        if destination.stat().st_size > 40 * 1024 * 1024:
            raise ValueError('archive exceeds 40 MiB')
    except FileExistsError:
        raise
    except Exception:
        destination.unlink(missing_ok=True)
        raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, help='expanded plugin directory')
    parser.add_argument('output', type=Path, help='new .dip output path')
    arguments = parser.parse_args()
    try:
        package(arguments.source, arguments.output)
    except (OSError, ValueError, zipfile.BadZipFile, zipfile.LargeZipFile) as error:
        parser.exit(1, f'Package creation failed: {error}\n')
    print(f'Created {arguments.output}. Import it in Dynamic Island to validate.')
