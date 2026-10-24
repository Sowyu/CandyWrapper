#!/usr/bin/python3
"""Create exact-size, valid PNGs using random pixels and a private ancillary padding chunk."""
from pathlib import Path
import os
import struct
import sys
import zlib

folder = Path(sys.argv[1]).resolve()
assert folder.is_relative_to(Path.home() / 'CandyWrapper-research/sandbox')
folder.mkdir(parents=True, exist_ok=True)


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)


for size in [1, 5, 20]:
    raw = b''.join(b'\0' + os.urandom(512) for _ in range(512))
    header = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 512, 512, 8, 0, 0, 0, 0))
    header += chunk(b'IDAT', zlib.compress(raw, 1))
    tail = chunk(b'IEND', b'')
    image = header + chunk(b'cwSp', os.urandom(size * 1048576 - len(header) - len(tail) - 12)) + tail
    assert len(image) == size * 1048576
    (folder / ('image-%d.png' % size)).write_bytes(image)
    print('%d MiB PNG' % size)
