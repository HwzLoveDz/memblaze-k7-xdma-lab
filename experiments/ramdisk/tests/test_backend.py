# SPDX-License-Identifier: MIT
"""Exercise the production DMA transfer logic against sparse files on Linux."""
import ctypes
import errno
import mmap
import os
from pathlib import Path
import random
import sys
import tempfile
import threading
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import xdma_backend as backend


class BackendTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xdma-backend-test-")
        self.path = Path(self.temp.name) / "sparse-ddr.bin"
        with self.path.open("wb") as output:
            output.truncate(backend.CAPACITY)
        self.instances = []

    def tearDown(self):
        try:
            for instance in self.instances:
                instance.close()
        finally:
            self.temp.cleanup()

    def make_backend(self, readonly=False, chunk=backend.CHUNK):
        read_fd = os.open(self.path, os.O_RDONLY | os.O_CLOEXEC)
        write_fd = None if readonly else os.open(
            self.path, os.O_WRONLY | os.O_CLOEXEC)
        instance = backend.AlignedDMA(read_fd, write_fd, chunk=chunk)
        self.instances.append(instance)
        return instance

    def read(self, instance, size, offset):
        result = bytearray(size)
        instance.read_into(result, offset)
        return bytes(result)

    def test_alignment_chunking_and_last_sector(self):
        instance = self.make_backend(chunk=4096)
        self.assertEqual(instance.address % mmap.PAGESIZE, 0)
        payload = bytes(range(256)) * 38  # 9728 bytes: crosses bounce chunks.
        positions = (0, 512, 2**31 - 4096, 2**31,
                     backend.CAPACITY - len(payload))
        for offset in positions:
            with self.subTest(offset=offset):
                instance.write(payload, offset)
                self.assertEqual(self.read(instance, len(payload), offset), payload)
        self.assertEqual(instance.write_bytes, len(payload) * len(positions))
        self.assertEqual(instance.read_bytes, instance.write_bytes)

    def test_random_sector_requests(self):
        instance = self.make_backend(chunk=4096)
        generator = random.Random(325)
        for index in range(80):
            count = generator.randrange(1, 20) * backend.SECTOR
            offset = generator.randrange(
                (backend.CAPACITY - count) // backend.SECTOR + 1) * backend.SECTOR
            payload = generator.randbytes(count)
            with self.subTest(index=index, offset=offset, count=count):
                instance.write(payload, offset)
                self.assertEqual(self.read(instance, count, offset), payload)

    def test_zero_writes_whole_region_and_preserves_neighbors(self):
        instance = self.make_backend(chunk=4096)
        offset = 2**31 - 512
        payload = b"\xa5" * (3 * 4096)
        instance.write(payload, offset)
        instance.zero(8192, offset + 512)
        expected = payload[:512] + bytes(8192) + payload[8704:]
        self.assertEqual(self.read(instance, len(payload), offset), expected)
        instance.zero(512, backend.CAPACITY - 512)
        self.assertEqual(self.read(instance, 512, backend.CAPACITY - 512), bytes(512))

    def test_range_and_alignment_fail_before_io(self):
        instance = self.make_backend()
        invalid = ((512, -512), (512, backend.CAPACITY),
                   (1024, backend.CAPACITY - 512), (-512, 0),
                   (1, 0), (512, 1), (0, backend.CAPACITY + 512))
        with mock.patch.object(backend.libc, "pread") as syscall:
            for count, offset in invalid:
                with self.subTest(count=count, offset=offset):
                    with self.assertRaises(OSError) as result:
                        instance.check_range(count, offset)
                    self.assertEqual(result.exception.errno, errno.EINVAL)
            syscall.assert_not_called()
        self.assertEqual(self.read(instance, 0, backend.CAPACITY), b"")
        instance.write(b"", backend.CAPACITY)

    def test_readonly_write_and_zero_fail(self):
        instance = self.make_backend(readonly=True)
        for operation in (lambda: instance.write(bytes(512), 0),
                          lambda: instance.zero(512, 0)):
            with self.assertRaises(OSError) as result:
                operation()
            self.assertEqual(result.exception.errno, errno.EROFS)

    def test_short_reads_and_writes_advance_pointer_and_offset(self):
        instance = self.make_backend(chunk=4096)
        payload = bytes(range(256)) * 16
        for operation in ("pwrite", "pread"):
            actual = getattr(backend.libc, operation)
            calls = []

            def short(fd, pointer, count, offset):
                calls.append((pointer, count, offset))
                # Odd-size short results exercise low-bit correspondence.
                return actual(fd, pointer, min(count, 137), offset)

            with mock.patch.object(backend.libc, operation, short):
                if operation == "pwrite":
                    instance.write(payload, 2**31)
                else:
                    self.assertEqual(self.read(instance, len(payload), 2**31), payload)
            self.assertGreater(len(calls), 1)
            for pointer, count, offset in calls:
                done = offset - 2**31
                self.assertEqual(pointer, instance.address + done)
                self.assertEqual(count, len(payload) - done)

    def test_eintr_is_retried_without_advancing(self):
        instance = self.make_backend()
        payload = b"\x5a" * 512
        instance.write(payload, 512)
        for operation in ("pread", "pwrite"):
            actual = getattr(backend.libc, operation)
            calls = []

            def interrupted(fd, pointer, count, offset):
                calls.append((pointer, count, offset))
                if len(calls) == 1:
                    ctypes.set_errno(errno.EINTR)
                    return -1
                return actual(fd, pointer, count, offset)

            with mock.patch.object(backend.libc, operation, interrupted):
                if operation == "pread":
                    self.assertEqual(self.read(instance, 512, 512), payload)
                else:
                    instance.write(payload, 512)
            self.assertEqual(len(calls), 2)
            self.assertEqual(calls[0], calls[1])

    def test_zero_return_and_impossible_count_fail(self):
        instance = self.make_backend()
        for operation in ("pread", "pwrite"):
            for returned in (0, 513):
                with self.subTest(operation=operation, returned=returned):
                    with mock.patch.object(backend.libc, operation,
                                           return_value=returned):
                        with self.assertRaises(OSError) as result:
                            if operation == "pread":
                                self.read(instance, 512, 0)
                            else:
                                instance.write(bytes(512), 0)
                    self.assertEqual(result.exception.errno, errno.EIO)

    def test_syscall_error_is_propagated(self):
        instance = self.make_backend()

        def failed(*args):
            ctypes.set_errno(errno.EBADF)
            return -1

        for operation in ("pread", "pwrite"):
            with mock.patch.object(backend.libc, operation, failed):
                with self.assertRaises(OSError) as result:
                    if operation == "pread":
                        self.read(instance, 512, 0)
                    else:
                        instance.write(bytes(512), 0)
                self.assertEqual(result.exception.errno, errno.EBADF)

    def test_concurrent_callers_do_not_share_corrupted_bounce_buffer(self):
        instance = self.make_backend(chunk=4096)
        errors = []
        barrier = threading.Barrier(4)

        def worker(index):
            try:
                barrier.wait(timeout=5)
                offset = (index + 1) * 1024**2
                payload = bytes([index + 1]) * 8192
                for _ in range(20):
                    instance.write(payload, offset)
                    if self.read(instance, len(payload), offset) != payload:
                        raise AssertionError("shared bounce buffer data corruption")
                instance.flush()
            except BaseException as error:
                errors.append(error)

        threads = [threading.Thread(target=worker, args=(index,))
                   for index in range(4)]
        try:
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(timeout=10)
            self.assertFalse(any(thread.is_alive() for thread in threads))
            self.assertEqual(errors, [])
        finally:
            for thread in threads:
                thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
