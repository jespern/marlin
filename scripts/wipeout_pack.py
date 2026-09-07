#!/usr/bin/env python3
"""Pack the wipEout graphics assets into one xz-compressed bundle.

    scripts/wipeout_pack.py <data-root> assets/wo.pak

<data-root> is the directory that holds `wipeout/` (the layout the reference
build uses). Only what the port loads goes in: common models, textures and
the fourteen track directories. Music, sound and the intro video stay out.

Container (little endian), then the whole thing xz-compressed:

    "WPK1"            magic
    u32 count
    count × { u16 path_len, path bytes, u32 offset, u32 size }
    file data         offsets are relative to the end of the table
"""
import lzma
import os
import struct
import sys

DIRS = ["common", "textures"] + ["track%02d" % i for i in range(1, 15)]


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    root, out = sys.argv[1], sys.argv[2]
    files = []
    for d in DIRS:
        full = os.path.join(root, "wipeout", d)
        for name in sorted(os.listdir(full)):
            path = os.path.join(full, name)
            if os.path.isfile(path):
                files.append(("wipeout/%s/%s" % (d, name), path))

    table = bytearray()
    data = bytearray()
    for rel, path in files:
        with open(path, "rb") as f:
            blob = f.read()
        encoded = rel.encode("ascii")
        table += struct.pack("<H", len(encoded)) + encoded
        table += struct.pack("<II", len(data), len(blob))
        data += blob

    raw = b"WPK1" + struct.pack("<I", len(files)) + bytes(table) + bytes(data)
    packed = lzma.compress(
        raw,
        format=lzma.FORMAT_XZ,
        check=lzma.CHECK_CRC32,
        preset=9 | lzma.PRESET_EXTREME,
    )
    with open(out, "wb") as f:
        f.write(packed)
    print("%d files, %.1f MB raw, %.1f MB packed -> %s" % (
        len(files), len(raw) / 1048576, len(packed) / 1048576, out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
