import importlib.util
from pathlib import Path
import tempfile
import unittest
import warnings
from zipfile import ZipFile

spec = importlib.util.spec_from_file_location('provision', Path(__file__).with_name('provision_api_runtime.py'))
provision = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provision)


def library(abi):
    data = bytearray(64)
    data[:4] = b'\x7fELF'
    data[4], machine = provision.ELF_ABIS[abi]
    data[5] = 1
    data[18:20] = machine.to_bytes(2, 'little')
    return bytes(data) + b'original-private-runtime'


class ProvisionApiRuntimeTest(unittest.TestCase):
    def archive(self, root, entries):
        archive = root / 'input.zip'
        with warnings.catch_warnings(), ZipFile(archive, 'w') as output:
            warnings.simplefilter('ignore', UserWarning)
            for name, data in entries:
                output.writestr(name, data)
        return archive

    def entries(self):
        return [(f'{abi}/libcpp.so', library(abi)) for abi in provision.ELF_ABIS]

    def test_preserves_original_bytes_and_never_overwrites_existing_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.archive(root, self.entries())
            provision.install(archive, root)
            for abi in provision.ELF_ABIS:
                self.assertEqual((root / f'android/app/src/main/jniLibs/{abi}/libcpp.so').read_bytes(), library(abi))
            with self.assertRaises(ValueError):
                provision.install(archive, root)

    def test_rejects_unexpected_paths_missing_abis_duplicates_and_wrong_architecture(self):
        valid = self.entries()
        invalid = [valid + [('../libcpp.so', library('x86'))], valid[:1],
                   valid + [valid[0]], [('arm64-v8a/libcpp.so', library('x86'))] + valid[:1]]
        for entries in invalid:
            with self.subTest(entries=[name for name, _ in entries]), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                with self.assertRaises(ValueError):
                    provision.install(self.archive(root, entries), root)
                self.assertFalse(any(root.rglob('libcpp.so')))

    def test_source_preview_check_rejects_runtime_but_official_verification_accepts_it(self):
        spec = importlib.util.spec_from_file_location('verify', Path(__file__).with_name('verify_apk_runtime.py'))
        verify = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(verify)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            provision.install(self.archive(root, self.entries()), root)
            apk = root / 'official.apk'
            with ZipFile(apk, 'w') as output:
                output.writestr('lib/arm64-v8a/libcpp.so', library('arm64-v8a'))
            verify.verify(apk, 'arm64-v8a', root)
            with self.assertRaises(ValueError):
                verify.verify_source_preview(apk)


if __name__ == '__main__':
    unittest.main()
