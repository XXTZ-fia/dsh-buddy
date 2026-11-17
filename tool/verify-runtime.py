"""Fail packaging when the bundled Android runtime is missing or corrupt."""
import hashlib
import json
from pathlib import Path
import sys
import lzma


def verify(base):
    base = Path(base)
    manifest = json.loads((base / 'assets/runtime/manifest.json').read_text())
    if manifest['abi'] != 'arm64-v8a':
        raise ValueError('Expected arm64-v8a runtime')
    rootfs = base / 'assets/runtime' / manifest['rootfs']
    if rootfs.stat().st_size != manifest['rootfsBytes']:
        raise ValueError('Rootfs size mismatch')
    with rootfs.open('rb') as stream:
        if hashlib.file_digest(stream, 'sha256').hexdigest() != manifest['rootfsSha256']:
            raise ValueError('Rootfs checksum mismatch')
    for name in ('proot', 'proot-loader', 'talloc', 'android-shmem'):
        lib = base / 'jniLibs/arm64-v8a' / f'lib{name}.so'
        with lib.open('rb') as stream:
            header = stream.read(20)
        if header[:4] != b'\x7fELF' or int.from_bytes(header[18:20], 'little') != 183:
            raise ValueError(f'Not an AArch64 ELF: {lib}')
        with lib.open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != manifest['jniLibs'][lib.name]['sha256']:
                raise ValueError(f'Native library checksum mismatch: {lib}')
    if '--deep' in sys.argv:
        with lzma.open(rootfs, 'rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != manifest['tarSha256']:
                raise ValueError('Decompressed archive checksum mismatch')
    print(f"Runtime verified: {manifest['runtimeVersion']}")


if __name__ == '__main__':
    verify(sys.argv[1])
