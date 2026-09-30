# SPDX-License-Identifier: MIT
"""Real nbdkit/libnbd negotiation and I/O; no kernel NBD or hardware required."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

try:
    import nbd
except ImportError:
    nbd = None

CAPACITY = 4 * 1024**3
PLUGIN = Path(__file__).with_name("file_plugin.py")


@unittest.skipUnless(nbd is not None and shutil.which("nbdkit"),
                     "requires nbdkit Python plugin and python3-libnbd")
class NbdIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xdma-nbd-test-")
        self.root = Path(self.temp.name)
        self.image = self.root / "sparse-ddr.bin"
        with self.image.open("wb") as output:
            output.truncate(CAPACITY)
        self.processes = []
        self.handles = []
        self.logs = []
        self.addCleanup(self.cleanup)

    def cleanup(self):
        for handle in self.handles:
            try:
                handle.shutdown()
            except Exception:
                pass
        for process in self.processes:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
            self.assertIsNotNone(process.poll(), "orphan nbdkit process")
        for log in self.logs:
            log.close()
        self.temp.cleanup()
        self.assertFalse(self.root.exists(), "test socket/image were not removed")

    def connect(self, readonly=False):
        socket_path = self.root / f"socket-{len(self.processes)}"
        log_path = self.root / f"server-{len(self.processes)}.log"
        log = log_path.open("wb")
        self.logs.append(log)
        command = ["nbdkit", "--foreground", "--verbose", "--unix",
                   str(socket_path)]
        if readonly:
            command.append("--readonly")
        command.extend(["python", str(PLUGIN), f"file={self.image}"])
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        self.processes.append(process)
        deadline = time.monotonic() + 10
        while not socket_path.exists():
            if process.poll() is not None or time.monotonic() >= deadline:
                log.flush()
                self.fail("nbdkit did not start: " + log_path.read_text())
            time.sleep(0.05)
        handle = nbd.NBD()
        handle.set_request_block_size(True)
        self.handles.append(handle)
        handle.connect_unix(str(socket_path))
        return handle

    def test_negotiated_capabilities_and_callbacks(self):
        handle = self.connect()
        self.assertEqual(handle.get_size(), CAPACITY)
        self.assertEqual(handle.get_block_size(nbd.SIZE_MINIMUM), 512)
        self.assertEqual(handle.get_block_size(nbd.SIZE_PREFERRED), 4096)
        self.assertEqual(handle.get_block_size(nbd.SIZE_MAXIMUM), 1024**2)
        self.assertFalse(handle.is_read_only())
        self.assertFalse(handle.is_rotational())
        self.assertTrue(handle.can_flush())
        self.assertFalse(handle.can_fua())
        self.assertFalse(handle.can_trim())
        self.assertFalse(handle.can_multi_conn())
        self.assertTrue(handle.can_zero())
        payload = bytes(range(256)) * 16
        for offset in (0, 2**31 - 512, 2**31, CAPACITY - len(payload)):
            with self.subTest(offset=offset):
                handle.pwrite(payload, offset)
                handle.flush()
                self.assertEqual(handle.pread(len(payload), offset), payload)
        handle.zero(4096, 2**31)
        handle.flush()
        self.assertEqual(handle.pread(4096, 2**31), bytes(4096))
        # Verify the backing file itself, beyond protocol-level round trips.
        with self.image.open("rb") as image:
            image.seek(CAPACITY - len(payload))
            self.assertEqual(image.read(len(payload)), payload)
        for offset in (1, CAPACITY):
            with self.subTest(invalid_offset=offset):
                with self.assertRaises(nbd.Error):
                    handle.pread(512, offset)
        with self.assertRaises(nbd.Error):
            handle.pwrite(bytes(512), CAPACITY)
        with self.assertRaises(nbd.Error):
            handle.zero(1024, CAPACITY - 512)

    def test_readonly_connection_refuses_write(self):
        handle = self.connect(readonly=True)
        self.assertTrue(handle.is_read_only())
        self.assertEqual(handle.pread(512, CAPACITY - 512), bytes(512))
        with self.assertRaises(nbd.Error):
            handle.pwrite(bytes(512), 0)


if __name__ == "__main__":
    unittest.main()
