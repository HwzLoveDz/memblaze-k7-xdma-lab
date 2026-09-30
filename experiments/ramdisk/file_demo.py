# SPDX-License-Identifier: MIT
"""Create and verify a 64 MiB file through the mounted FPGA filesystem."""
import hashlib
import json
import os
from pathlib import Path
import sys
import time
from xdma_backend import AlignedDMA, CHUNK


def main(directory):
    path = Path(directory) / "DMA_demo_64MiB.bin"
    size = 64 * CHUNK
    wfd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_DIRECT, 0o600)
    rfd = None
    try:
        rfd = os.open(path, os.O_RDONLY | os.O_DIRECT)
        backend = AlignedDMA(rfd, wfd, size)
    except BaseException:
        os.close(wfd)
        if rfd is not None:
            os.close(rfd)
        raise
    expected, actual = hashlib.sha256(), hashlib.sha256()
    block = bytearray(CHUNK)
    try:
        start = time.monotonic()
        seed = os.urandom(CHUNK)
        for index in range(size // CHUNK):
            block[:] = seed
            block[:8] = index.to_bytes(8, "little")
            expected.update(block)
            backend.write(block, index * CHUNK)
        os.fsync(wfd)
        write_seconds = time.monotonic() - start
        start = time.monotonic()
        for index in range(size // CHUNK):
            backend.read_into(block, index * CHUNK)
            actual.update(block)
        read_seconds = time.monotonic() - start
        if actual.digest() != expected.digest():
            raise RuntimeError("RAM disk file SHA256 mismatch")
        print(json.dumps({"FILE_DATA_COMPARE": "PASS", "bytes": size,
                          "sha256": actual.hexdigest(), "path": str(path),
                          "direct_io": True,
                          "write_MiB_s": round(64 / write_seconds, 2),
                          "read_MiB_s": round(64 / read_seconds, 2)}, ensure_ascii=False))
    finally:
        backend.close()


if __name__ == "__main__":
    main(sys.argv[1])
