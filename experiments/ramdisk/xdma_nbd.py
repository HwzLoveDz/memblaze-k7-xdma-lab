# SPDX-License-Identifier: MIT
"""nbdkit Python API v2 plugin for the validated Memblaze 4 GiB DDR image."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import nbdkit
from xdma_backend import CAPACITY, CHUNK, SECTOR, XdmaBackend

API_VERSION = 2
device = 0


def config(key, value):
    global device
    if key != "device":
        raise ValueError("only device=<XDMA index> is supported")
    device = int(value)
    if not 0 <= device <= 15:
        raise ValueError("invalid device index")


def thread_model():
    return nbdkit.THREAD_MODEL_SERIALIZE_ALL_REQUESTS


def open(readonly):
    return XdmaBackend(device=device, readonly=readonly)


def close(h):
    nbdkit.debug(f"FPGA_DDR_READ_BYTES={h.read_bytes} FPGA_DDR_WRITE_BYTES={h.write_bytes}")
    h.close()


def get_size(h):
    return h.size


def block_size(h):
    return (SECTOR, 4096, CHUNK)


def can_write(h):
    return h.write_fd is not None


def can_multi_conn(h):
    return False


def is_rotational(h):
    return False


def can_flush(h):
    return True


def can_fua(h):
    return nbdkit.FUA_NONE


def can_trim(h):
    return False


def can_fast_zero(h):
    return False


def pread(h, buf, offset, flags):
    h.read_into(buf, offset)


def pwrite(h, buf, offset, flags):
    h.write(buf, offset)


def flush(h, flags):
    h.flush()


def zero(h, count, offset, flags):
    if flags & nbdkit.FLAG_FAST_ZERO:
        import errno
        nbdkit.set_error(errno.EOPNOTSUPP)
        raise RuntimeError("fast zero is unsupported")
    h.zero(count, offset)
