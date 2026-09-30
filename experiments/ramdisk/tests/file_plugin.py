# SPDX-License-Identifier: MIT
"""Test-only nbdkit entry point; production plugin never accepts a file backend."""
import os
from pathlib import Path
import stat
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import xdma_backend
import xdma_nbd as production

test_file = None


class FileBackend(xdma_backend.AlignedDMA):
    def __init__(self, device=0, readonly=False, size=xdma_backend.CAPACITY):
        if test_file is None:
            raise ValueError("file=<test sparse image> is required")
        info = os.stat(test_file)
        if not stat.S_ISREG(info.st_mode) or info.st_size != size:
            raise ValueError("test image must be a regular exact-capacity file")
        read_fd = write_fd = None
        try:
            read_fd = os.open(test_file, os.O_RDONLY | os.O_CLOEXEC)
            if not readonly:
                write_fd = os.open(test_file, os.O_WRONLY | os.O_CLOEXEC)
            super().__init__(read_fd, write_fd, size)
        except BaseException:
            for fd in {read_fd, write_fd} - {None}:
                os.close(fd)
            raise


production.XdmaBackend = FileBackend
API_VERSION = production.API_VERSION
for callback in ("thread_model", "open", "close", "get_size", "block_size",
                 "can_write", "can_multi_conn", "is_rotational", "can_flush",
                 "can_fua", "can_trim", "can_fast_zero", "pread", "pwrite",
                 "flush", "zero"):
    globals()[callback] = getattr(production, callback)


def config(key, value):
    global test_file
    if key == "file":
        test_file = os.path.realpath(value)
    else:
        production.config(key, value)
