#!/usr/bin/env python3
"""Create a portable ZIP32 .dip archive; the Host still validates on import."""
import argparse
import os
from pathlib import Path
import stat
import unicodedata
import zipfile


def inspect_source(source: Path):
    """Check portable archive file/path limits without evaluating JavaScript."""
    if source.is_symlink() or not source.is_dir():
        raise ValueError('source must be a real directory')
    source = source.resolve()
    manifest = source / 'manifest.json'
    if not manifest.is_file() or manifest.is_symlink():
        raise ValueError('root manifest.json is required')
    entries, aliases = [], {}
    total, files = 0, 0
    def unreadable(error):
        raise error
    for current, directories, names in os.walk(source, followlinks=False, onerror=unreadable):
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
                entries.append((path, relative + '/', True, info))
            elif stat.S_ISREG(info.st_mode) and info.st_nlink == 1:
                if info.st_size > 8 * 1024 * 1024:
                    raise ValueError('file exceeds 8 MiB')
                total += info.st_size
                files += 1
                entries.append((path, relative, False, info))
            else:
                raise ValueError('symlinks, hardlinks and special files are not supported')
            if len(entries) > 512 or files > 256 or total > 32 * 1024 * 1024:
                raise ValueError('package exceeds the Host resource limits')
    if len(entries) > 512 or files > 256 or total > 32 * 1024 * 1024:
        raise ValueError('package exceeds the Host resource limits')
    return source, entries, files, total


def _identity(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def _read_file(root_descriptor, relative, expected):
    """Read the inspected file through directory handles, never new symlinks."""
    directory = os.dup(root_descriptor)
    try:
        parts = relative.split('/')
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=directory)
            os.close(directory)
            directory = child
        descriptor = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                             dir_fd=directory)
        with os.fdopen(descriptor, 'rb') as stream:
            opened = os.fstat(stream.fileno())
            if (not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1
                    or _identity(opened) != _identity(expected)):
                raise ValueError('source changed while packaging')
            data = stream.read(8 * 1024 * 1024 + 1)
            after = os.fstat(stream.fileno())
            if (len(data) != opened.st_size or after.st_nlink != 1
                    or _identity(after) != _identity(opened)):
                raise ValueError('source changed while packaging')
            return data
    finally:
        os.close(directory)


def package(source: Path, destination: Path) -> None:
    if source.is_symlink() or not source.is_dir():
        raise ValueError('source must be a real directory')
    source = source.resolve()
    destination = destination.absolute()
    resolved_destination = destination.parent.resolve() / destination.name
    if destination.suffix.lower() != '.dip' or resolved_destination.is_relative_to(source):
        raise ValueError('output must be a .dip outside the source directory')
    source, entries, _, _ = inspect_source(source)
    root_descriptor = os.open(source, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        # Exclusive creation prevents accidentally replacing an earlier package.
        with destination.open('xb') as output:
            with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED,
                                 compresslevel=6, allowZip64=False) as archive:
                for _path, relative, directory, info in sorted(entries, key=lambda item: item[1]):
                    entry = zipfile.ZipInfo(relative, date_time=(1980, 1, 1, 0, 0, 0))
                    entry.create_system = 3
                    entry.compress_type = zipfile.ZIP_STORED if directory else zipfile.ZIP_DEFLATED
                    entry.external_attr = ((stat.S_IFDIR | 0o700) if directory else
                                           (stat.S_IFREG | 0o600)) << 16
                    if directory:
                        entry.external_attr |= 0x10
                    archive.writestr(entry, b'' if directory else _read_file(root_descriptor, relative, info))
        if destination.stat().st_size > 40 * 1024 * 1024:
            raise ValueError('archive exceeds 40 MiB')
    except FileExistsError:
        raise
    except Exception:
        destination.unlink(missing_ok=True)
        raise
    finally:
        os.close(root_descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, help='expanded plugin directory')
    parser.add_argument('output', type=Path, help='new .dip output path')
    arguments = parser.parse_args()
    try:
        package(arguments.source, arguments.output)
    except (OSError, ValueError, zipfile.BadZipFile, zipfile.LargeZipFile) as error:
        parser.exit(1, f'Package creation failed: {error}\n')
    print(f'Created {arguments.output}. Import it in Dynamic Island to validate.')


if __name__ == '__main__':
    main()
