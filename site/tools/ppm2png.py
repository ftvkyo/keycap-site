# SPDX-License-Identifier: GPL-3.0-or-later
"""Convert a binary PPM, as keycap-server writes it, to a PNG.

usage: python3 tools/ppm2png.py SOURCE.ppm TARGET.png [RRGGBB]

Pixels of the colour RRGGBB, the preview's background, are transparent.
The same pixels give the same bytes: no timestamps, fixed compression.
"""

import re
import struct
import sys
import zlib
from pathlib import Path

source, target = Path(sys.argv[1]), Path(sys.argv[2])
transparent = bytes.fromhex(sys.argv[3]) if len(sys.argv) > 3 else None

data = source.read_bytes()
header = re.match(rb"P6\s+(\d+)\s+(\d+)\s+255\s", data)
width, height = int(header[1]), int(header[2])
rest = data[header.end() :]
row = width * 3
raw = b"".join(b"\0" + rest[y * row : (y + 1) * row] for y in range(height))


def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))


target.write_bytes(
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    + (chunk(b"tRNS", struct.pack(">HHH", *transparent)) if transparent else b"")
    + chunk(b"IDAT", zlib.compress(raw, 9))
    + chunk(b"IEND", b"")
)
