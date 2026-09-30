# SPDX-License-Identifier: MIT
"""Synchronous, aligned I/O to the already configured FPGA DDR.

This module has no nbdkit dependency so its transfer logic can be tested alone.
Only XdmaBackend opens hardware; AlignedDMA also works with test-file descriptors.
"""
import array
import ctypes
import errno
import fcntl
import mmap
import os
from pathlib import Path
import stat
import threading

CAPACITY = 4 * 1024**3
SECTOR = 512
CHUNK = 1024**2
ADDRMODE_GET = 0x80047105
ALIGN_GET = 0x80047106

libc = ctypes.CDLL(None, use_errno=True)
for name in ("pread", "pwrite"):
    func = getattr(libc, name)
    func.argtypes = (ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t,
                     ctypes.c_longlong)
    func.restype = ctypes.c_ssize_t


class AlignedDMA:
    def __init__(self, read_fd, write_fd, size=CAPACITY, chunk=CHUNK):
        if not (0 < size <= CAPACITY and size % SECTOR == 0):
            raise ValueError("capacity must be a sector multiple, at most 4 GiB")
        if not (0 < chunk <= 8 * CHUNK and chunk % SECTOR == 0):
            raise ValueError("invalid transfer chunk")
        self.read_fd, self.write_fd = read_fd, write_fd
        self.size, self.chunk = size, chunk
        self.buffer = mmap.mmap(-1, chunk)
        self.address = ctypes.addressof(ctypes.c_char.from_buffer(self.buffer))
        if self.address % mmap.PAGESIZE:
            self.buffer.close()
            raise RuntimeError("DMA bounce buffer is not page aligned")
        self.lock = threading.RLock()
        self.read_bytes = self.write_bytes = 0

    def check_range(self, count, offset):
        if (count < 0 or offset < 0 or offset > self.size
                or count > self.size - offset):
            raise OSError(errno.EINVAL, "request outside FPGA DDR")
        if count % SECTOR or offset % SECTOR:
            raise OSError(errno.EINVAL, "request must be 512-byte aligned")

    def _transfer(self, name, fd, count, offset):
        done = 0
        while done < count:
            transferred = getattr(libc, name)(
                fd, self.address + done, count - done, offset + done)
            if transferred < 0:
                code = ctypes.get_errno()
                if code == errno.EINTR:
                    continue
                raise OSError(code, f"XDMA {name} at 0x{offset + done:x}")
            if transferred == 0 or transferred > count - done:
                raise OSError(errno.EIO, f"incomplete XDMA {name}")
            done += transferred

    def read_into(self, output, offset):
        view = memoryview(output).cast("B")
        self.check_range(len(view), offset)
        with self.lock:
            for start in range(0, len(view), self.chunk):
                count = min(self.chunk, len(view) - start)
                self._transfer("pread", self.read_fd, count, offset + start)
                view[start:start + count] = self.buffer[:count]
                self.read_bytes += count

    def write(self, source, offset):
        view = memoryview(source).cast("B")
        self.check_range(len(view), offset)
        if self.write_fd is None:
            raise OSError(errno.EROFS, "read-only connection")
        with self.lock:
            for start in range(0, len(view), self.chunk):
                count = min(self.chunk, len(view) - start)
                self.buffer[:count] = view[start:start + count]
                self._transfer("pwrite", self.write_fd, count, offset + start)
                self.write_bytes += count

    def zero(self, count, offset):
        self.check_range(count, offset)
        zeros = bytes(min(count, self.chunk))
        with self.lock:
            for start in range(0, count, self.chunk):
                self.write(zeros[:min(self.chunk, count - start)], offset + start)

    def flush(self):
        # There is no host write cache. Each pwrite waits for DMA completion.
        # This barrier says nothing about survival of FPGA power loss.
        with self.lock:
            pass

    def close(self):
        with self.lock:
            self.buffer.close()
            for fd in {self.read_fd, self.write_fd} - {None}:
                os.close(fd)


def _ioctl_int(fd, request):
    result = array.array("i", [0])
    fcntl.ioctl(fd, request, result, True)
    return result[0]


class XdmaBackend(AlignedDMA):
    def __init__(self, device=0, readonly=False, size=CAPACITY):
        if not isinstance(device, int) or not 0 <= device <= 15:
            raise ValueError("invalid XDMA device index")
        nodes = [f"xdma{device}_c2h_0", f"xdma{device}_h2c_0"]
        parents = []
        for node in nodes:
            info = os.stat(f"/dev/{node}")
            if not stat.S_ISCHR(info.st_mode):
                raise RuntimeError(f"/dev/{node} is not an XDMA character device")
            parent_link = Path(f"/sys/class/xdma/{node}/device")
            if not parent_link.is_symlink():
                raise RuntimeError(f"missing XDMA PCI parent for {node}")
            parent = parent_link.resolve(strict=True)
            if ((parent / "vendor").read_text().strip() != "0x10ee"
                    or (parent / "device").read_text().strip() != "0x7024"
                    or (parent / "subsystem_vendor").read_text().strip() != "0x10ee"
                    or (parent / "subsystem_device").read_text().strip() != "0x0007"
                    or (parent / "driver").resolve().name != "xdma"):
                raise RuntimeError(f"unexpected FPGA identity or driver for {node}")
            parents.append(parent)
        if parents[0] != parents[1]:
            raise RuntimeError("H2C and C2H belong to different PCI devices")
        read_fd = write_fd = None
        try:
            read_fd = os.open(f"/dev/{nodes[0]}", os.O_RDONLY | os.O_CLOEXEC)
            if not readonly:
                write_fd = os.open(f"/dev/{nodes[1]}", os.O_WRONLY | os.O_CLOEXEC)
            for fd in (read_fd, write_fd):
                if fd is None:
                    continue
                alignment = _ioctl_int(fd, ALIGN_GET)
                if (_ioctl_int(fd, ADDRMODE_GET) != 0
                        or not 0 < alignment <= SECTOR
                        or alignment & (alignment - 1)):
                    raise RuntimeError("XDMA must use incremental AXI-MM with alignment <=512")
            super().__init__(read_fd, write_fd, size)
        except BaseException:
            for fd in {read_fd, write_fd} - {None}:
                os.close(fd)
            raise
        self.bdf = parents[0].name


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--zero", action="store_true")
    args = parser.parse_args()
    backend = XdmaBackend()
    try:
        print(f"FPGA_DDR_BDF={backend.bdf}", flush=True)
        if args.zero:
            backend.zero(CAPACITY, 0)
            print(f"FPGA_DDR_ZERO_BYTES={backend.write_bytes}", flush=True)
    finally:
        backend.close()
