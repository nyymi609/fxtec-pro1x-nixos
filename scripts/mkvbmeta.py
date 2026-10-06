#!/usr/bin/env python3
"""Write a 4096-byte AVB vbmeta image with verification disabled (flags=2).

Equivalent to: avbtool make_vbmeta_image --flags 2 --padding_size 4096
(no keys, algorithm NONE, no descriptors), so the repo needs no avbtool.

AvbVBMetaImageHeader is 256 bytes, big-endian.
"""
import struct
import sys

FLAGS_VERIFICATION_DISABLED = 2

HEADER = (
    ">4s"   # magic "AVB0"
    "II"    # required libavb version major, minor
    "Q"     # authentication data block size
    "Q"     # auxiliary data block size
    "I"     # algorithm type (0 = NONE)
    "QQ"    # hash offset, size
    "QQ"    # signature offset, size
    "QQ"    # public key offset, size
    "QQ"    # public key metadata offset, size
    "QQ"    # descriptors offset, size
    "Q"     # rollback index
    "I"     # flags
    "I"     # rollback index location
    "48s"   # release string
    "80x"   # reserved
)

assert struct.calcsize(HEADER) == 256


def main(out: str) -> None:
    header = struct.pack(
        HEADER,
        b"AVB0",
        1, 0,
        0,
        0,
        0,
        0, 0,
        0, 0,
        0, 0,
        0, 0,
        0, 0,
        0,
        FLAGS_VERIFICATION_DISABLED,
        0,
        b"pro1x-nixos".ljust(48, b"\0"),
    )
    with open(out, "wb") as f:
        f.write(header.ljust(4096, b"\0"))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: mkvbmeta.py OUTPUT")
    main(sys.argv[1])
