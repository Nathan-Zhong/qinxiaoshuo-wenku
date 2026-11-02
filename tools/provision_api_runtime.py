#!/usr/bin/env python3
"""Install an owner-supplied private API archive for an official APK build."""
from __future__ import annotations

import argparse
from pathlib import Path
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parent.parent
REQUIRED = {'armeabi-v7a', 'arm64-v8a', 'x86_64'}
ELF_ABIS = {'armeabi-v7a': (1, 40), 'arm64-v8a': (2, 183),
            'x86': (1, 3), 'x86_64': (2, 62)}
MAX_ENTRY = 16 * 1024 * 1024
MAX_ARCHIVE = 32 * 1024 * 1024


def install(archive: Path, root: Path = ROOT):
    if archive.stat().st_size > MAX_ARCHIVE:
        raise ValueError('Private API archive is too large')
    payloads = {}
    with ZipFile(archive) as source:
        entries = source.infolist()
        if len(entries) > 12:
            raise ValueError('Private API archive has unexpected entries')
        for entry in entries:
            if entry.is_dir():
                continue
            parts = entry.filename.split('/')
            if len(parts) != 2 or parts[0] not in ELF_ABIS or parts[1] != 'libcpp.so':
                raise ValueError('Private API archive has an unexpected path')
            abi = parts[0]
            if abi in payloads or not 64 <= entry.file_size <= MAX_ENTRY:
                raise ValueError('Private API archive has a duplicate or invalid library')
            if entry.flag_bits & 1 or (entry.external_attr >> 16) & 0o170000 == 0o120000:
                raise ValueError('Private API archive must contain regular unencrypted files')
            data = source.read(entry)
            elf_class, machine = ELF_ABIS[abi]
            if (data[:4] != b'\x7fELF' or data[4] != elf_class or data[5] != 1
                    or int.from_bytes(data[18:20], 'little') != machine):
                raise ValueError('Private API library does not match its Android architecture')
            payloads[abi] = data
    if not REQUIRED.issubset(payloads):
        raise ValueError('Private API archive must include all three release architectures')
    destination = root / 'android/app/src/main/jniLibs'
    targets = {abi: destination / abi / 'libcpp.so' for abi in payloads}
    if any(target.exists() or target.is_symlink() for target in targets.values()):
        raise ValueError('Refusing to replace an existing local API runtime')
    created = []
    try:
        for abi, target in targets.items():
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open('xb') as output:
                created.append(target)
                output.write(payloads[abi])
    except Exception:
        for target in created:
            target.unlink(missing_ok=True)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    args = parser.parse_args()
    install(args.archive)
    print('Private API runtime provisioned without modifying its bytes.')


if __name__ == '__main__':
    main()
