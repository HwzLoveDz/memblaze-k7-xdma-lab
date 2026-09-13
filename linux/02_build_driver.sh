#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Memblaze K7 XDMA Lab contributors

set -Eeuo pipefail
export LC_ALL=C
umask 077

readonly expected_id="10ee:7024"
readonly expected_sha="aba9086b051e2e29ee6a38a0b655857010e75400d7c410340334938586be23a2"
readonly build_tag="b8466090-aba9086b051e"
readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly kit_root="$(cd -- "$script_dir/.." && pwd)"
readonly archive="$kit_root/vendor/xdma_linux_kernel_b8466090.tar.gz"
readonly source_manifest="$kit_root/vendor/xdma_linux_kernel_b8466090.sha256"
readonly patch_file="$script_dir/patches/0001-portable-kbuild.patch"
readonly normalized_makefile_sha="aec0196e6dff7dc9d9a2f5733ef417914a9e8e5fa38b7efcd05be6b7be7eb89f"
readonly patched_makefile_sha="70d5346d0d7d823c199cef71fe3a037f4e2ad5260144d7649131e785a5375dc5"
readonly kernel_release="$(uname -r)"
readonly work_root="${HOME:?HOME is not set}/memblaze-xdma-work/$build_tag/$kernel_release"
readonly checkout_root="$work_root/dma_ip_drivers-b8466090"
readonly source_root="$checkout_root/XDMA/linux-kernel"
readonly results_root="$HOME/memblaze-xdma-results"
readonly utc_stamp="$(date -u +%Y%m%dT%H%M%S.%NZ)"
readonly result_dir="$results_root/$utc_stamp"
readonly log_file="$result_dir/02_build_driver.log"

mkdir -p "$result_dir"
exec > >(tee "$log_file") 2>&1

stop() {
    printf 'STOP: %s\n' "$*" >&2
    printf 'SavedLog=%s\n' "$log_file" >&2
    exit 1
}

for cmd in awk cat date dirname gcc grep lspci make modinfo nproc patch sed sha256sum tar tee uname; do
    command -v "$cmd" >/dev/null 2>&1 || stop "missing command: $cmd"
done

[[ "$(uname -m)" == "x86_64" ]] || stop "this pinned XDMA driver workflow requires an x86_64 Linux host"
[[ -r "$archive" ]] || stop "vendor archive is missing: $archive"
[[ -r "$source_manifest" ]] || stop "vendor source manifest is missing: $source_manifest"
[[ -r "$patch_file" ]] || stop "portable Kbuild patch is missing: $patch_file"
[[ -e "/lib/modules/$kernel_release/build/Makefile" ]] \
    || stop "matching kernel headers are missing: /lib/modules/$kernel_release/build"

mapfile -t bdfs < <(lspci -Dnn -d "$expected_id" | awk '{print $1}')
(( ${#bdfs[@]} == 1 )) \
    || stop "expected exactly one $expected_id endpoint before building; found ${#bdfs[@]}"

printf 'UTC=%s\n' "$(date -u +%FT%TZ)"
printf 'Endpoint=%s\n' "${bdfs[0]}"
printf 'Kernel=%s\n' "$kernel_release"
printf 'Archive=%s\n' "$archive"
printf 'Source=%s\n' "$source_root"

actual_sha="$(sha256sum "$archive" | awk '{print $1}')"
printf 'ArchiveSHA256=%s\n' "$actual_sha"
[[ "$actual_sha" == "$expected_sha" ]] || stop "vendor archive SHA-256 mismatch"

if [[ ! -f "$source_root/readme.txt" ]]; then
    mkdir -p "$work_root"
    tar -xzf "$archive" -C "$work_root"
fi

readonly driver_makefile="$source_root/xdma/Makefile"
[[ -f "$source_root/xdma/xdma_mod.c" ]] || stop "driver source extraction is incomplete"
[[ -f "$driver_makefile" ]] || stop "driver Makefile is missing"
(cd "$checkout_root" && sha256sum --check --strict "$source_manifest") \
    || stop "extracted vendor source differs from the pinned source manifest"
grep -q 'PCI_DEVICE(0x10ee, 0x7024)' "$source_root/xdma/xdma_mod.c" \
    || stop "pinned driver source does not contain PCI ID $expected_id"

# The pinned vendor archive contains a CRLF-encoded driver Makefile. Normalize
# only the extracted per-kernel working copy so the portable patch applies
# consistently; the archived source and its verified SHA-256 remain untouched.
if grep -q $'\r$' "$driver_makefile"; then
    sed -i 's/\r$//' "$driver_makefile"
    printf 'MakefileLineEndings=normalized\n'
else
    printf 'MakefileLineEndings=not-needed\n'
fi
if grep -q $'\r$' "$driver_makefile"; then
    stop "driver Makefile still contains CRLF line endings after normalization"
fi

makefile_sha="$(sha256sum "$driver_makefile" | awk '{print $1}')"
if [[ "$makefile_sha" == "$patched_makefile_sha" ]]; then
    printf 'PatchStatus=already-applied\n'
elif [[ "$makefile_sha" == "$normalized_makefile_sha" ]] \
    && patch --dry-run --silent -d "$checkout_root" -p1 < "$patch_file"; then
    patch -d "$checkout_root" -p1 < "$patch_file"
    printf 'PatchStatus=applied\n'
else
    stop "driver Makefile is neither the normalized pinned source nor the exact patched form"
fi

grep -Fq 'ccflags-y := -I$(src)/../include $(XVC_FLAGS)' "$driver_makefile" \
    || stop "portable include path was not found after patching"
[[ "$(sha256sum "$driver_makefile" | awk '{print $1}')" == "$patched_makefile_sha" ]] \
    || stop "patched driver Makefile hash is unexpected"
if grep -Eq '/home/[^/]+/' "$driver_makefile"; then
    stop "driver Makefile still contains a per-user /home path"
fi

printf '\n=== Clean prior generated outputs ===\n'
make -C "$source_root/xdma" clean
make -C "$source_root/tools" clean

printf '\n=== Driver build ===\n'
make -C "$source_root/xdma" -j"$(nproc)"

printf '\n=== Userspace tools build ===\n'
make -C "$source_root/tools" -j"$(nproc)"

readonly module="$source_root/xdma/xdma.ko"
[[ -f "$module" ]] || stop "xdma.ko was not produced"
[[ -x "$source_root/tools/dma_to_device" ]] || stop "dma_to_device was not produced"
[[ -x "$source_root/tools/dma_from_device" ]] || stop "dma_from_device was not produced"

printf '\n=== Module metadata ===\n'
modinfo "$module" | grep -E '^(filename|version|vermagic|signer|sig_key|sig_hashalgo):' || true

cat > "$result_dir/build_paths.env" <<EOF
XDMA_SOURCE_ROOT='$source_root'
XDMA_MODULE='$module'
XDMA_TOOLS='$source_root/tools'
EOF

printf '\nPASS: driver and tools built; nothing was installed or loaded.\n'
printf 'Module=%s\n' "$module"
printf 'SavedLog=%s\n' "$log_file"
