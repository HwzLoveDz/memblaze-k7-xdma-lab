#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Memblaze K7 XDMA Lab contributors

"""Generate or verify the repository's deterministic SHA256SUMS.txt."""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "SHA256SUMS.txt"
GENERATED_DIRECTORY_NAMES = {"__pycache__", ".pytest_cache", ".mypy_cache"}
GENERATED_SUFFIXES = {".pyc", ".pyo"}


def hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def repository_files() -> list[tuple[str, Path]]:
    files: list[tuple[str, Path]] = []
    for path in ROOT.rglob("*"):
        relative = path.relative_to(ROOT)
        if ".git" in relative.parts or relative == MANIFEST.relative_to(ROOT):
            continue
        if GENERATED_DIRECTORY_NAMES.intersection(relative.parts):
            continue
        if path.suffix.lower() in GENERATED_SUFFIXES:
            continue
        if path.is_symlink():
            raise ValueError(f"symbolic links are not supported: {relative.as_posix()}")
        if not path.is_file():
            continue

        posix_path = relative.as_posix()
        if "\n" in posix_path or "\r" in posix_path:
            raise ValueError(f"unsupported newline in path: {posix_path!r}")
        files.append((posix_path, path))

    return sorted(files, key=lambda item: item[0])


def render_manifest() -> tuple[bytes, int]:
    files = repository_files()
    lines = [f"{hash_file(path)}  {relative}\n" for relative, path in files]
    return "".join(lines).encode("utf-8"), len(files)


def write_atomic(content: bytes) -> None:
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            prefix=".SHA256SUMS.",
            suffix=".tmp",
            dir=ROOT,
            delete=False,
        ) as stream:
            temporary_path = Path(stream.name)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_path, MANIFEST)
    finally:
        if temporary_path is not None and temporary_path.exists():
            temporary_path.unlink()


def check_manifest(expected: bytes, file_count: int) -> int:
    try:
        actual = MANIFEST.read_bytes()
    except FileNotFoundError:
        print("ERROR: SHA256SUMS.txt is missing", file=sys.stderr)
        return 1

    if actual != expected:
        print(
            "ERROR: SHA256SUMS.txt does not match the current repository tree; "
            "regenerate it after finalizing all release files",
            file=sys.stderr,
        )
        return 1

    print(f"SHA256SUMS_CHECK=PASS files={file_count}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Generate a sorted SHA256SUMS.txt for the repository, or verify the "
            "existing manifest with --check."
        )
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify that SHA256SUMS.txt exactly matches the current tree",
    )
    args = parser.parse_args()

    try:
        content, file_count = render_manifest()
        if args.check:
            return check_manifest(content, file_count)
        write_atomic(content)
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print(f"SHA256SUMS_GENERATED=PASS files={file_count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
