#!/usr/bin/env python3
"""Verify that an APK redistributes the original API binary without stripping."""
from __future__ import annotations
import argparse
from pathlib import Path
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parent.parent


def verify(apk: Path, abi: str, root: Path = ROOT):
    original = root / 'android/app/src/main/jniLibs' / abi / 'libcpp.so'
    with ZipFile(apk) as archive:
        names = [n for n in archive.namelist() if n.startswith('lib/') and n.endswith('/libcpp.so')]
        expected = f'lib/{abi}/libcpp.so'
        if names != [expected]:
            raise ValueError(f'Expected only the {abi} API runtime in this one-ABI APK')
        if archive.read(expected) != original.read_bytes():
            raise ValueError(f'{abi}: packaged API runtime differs from the original; check native symbol stripping')


def verify_source_preview(apk: Path):
    with ZipFile(apk) as archive:
        if any(Path(name).name.lower() == 'libcpp.so' for name in archive.namelist()):
            raise ValueError('Public source previews must not contain the private API runtime')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--abi', choices=['armeabi-v7a','arm64-v8a','x86_64'])
    mode.add_argument('--source-preview', action='store_true')
    args = parser.parse_args()
    if args.source_preview:
        verify_source_preview(args.apk)
        print('Public source preview contains no private API runtime; Wenku network API is unavailable.')
    else:
        verify(args.apk, args.abi)
        print(f'{args.abi}: embedded API runtime is byte-for-byte unchanged.')


if __name__ == '__main__':
    main()
