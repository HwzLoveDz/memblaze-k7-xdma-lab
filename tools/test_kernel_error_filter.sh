#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
export LC_ALL=C

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly repo_root="$(cd -- "$script_dir/.." && pwd)"
readonly exact_wrapper="$repo_root/linux/run_exact_image_regression.sh"
# shellcheck source=linux/lib/kernel_error_filter.sh
source "$repo_root/linux/lib/kernel_error_filter.sh"

readonly temp_root="$(mktemp -d)"
cleanup() {
    rm -rf -- "$temp_root"
}
trap cleanup EXIT

cat > "$temp_root/benign.log" <<'EOF'
[  231.880964] xdma:xdma_mod_init: desc_blen_max: 0xfffffff/268435455, timeout: h2c 10 c2h 10 sec.
test-host kernel: xdma:xdma_mod_init: desc_blen_max: 0xabcdef/11259375, timeout: h2c 20 c2h 30 sec.
[    7.125000] test-host kernel: xdma:xdma_mod_init: desc_blen_max: 0x1/1, timeout: h2c 1 c2h 1 sec.
xdma:xdma_mod_init: desc_blen_max: 0xABC/2748, timeout: h2c 4 c2h 5 sec.
EOF

benign_output="$(memblaze_filter_severe_kernel_messages "$temp_root/benign.log")"
[[ -z "$benign_output" ]] || {
    printf 'FAIL: a normal XDMA timeout-configuration line was classified as severe\n' >&2
    exit 1
}

cat > "$temp_root/severe.log" <<'EOF'
xdma: xfer 0x1,1, s 0x2 timed out, ep 0x0.
xdma: transfer timeout waiting for completion
xdma: transfer_init failed
xdma: engine status error 0x1
xdma: fatal error; xdma:xdma_mod_init: desc_blen_max: 0xfffffff/268435455, timeout: h2c 10 c2h 10 sec.
pcieport 0000:00:01.0: PCIe Bus Error: severity=Corrected
page allocation failure: order:10
Buffer I/O error on dev sda2
JBD2: I/O error when updating journal superblock
Remounting filesystem read-only
EOF

severe_output="$(memblaze_filter_severe_kernel_messages "$temp_root/severe.log")"
expected_severe_output="$(cat "$temp_root/severe.log")"
[[ "$severe_output" == "$expected_severe_output" ]] || {
    printf 'FAIL: one or more real severe-message examples were not retained exactly\n' >&2
    exit 1
}

mkdir "$temp_root/not-a-log"
set +e
memblaze_filter_severe_kernel_messages "$temp_root/not-a-log" \
    > "$temp_root/filter-error.out" 2> "$temp_root/filter-error.err"
filter_error_rc=$?
set -e
(( filter_error_rc != 0 )) || {
    printf 'FAIL: a non-file input was converted into success\n' >&2
    exit 1
}

cleanup_line="$(grep -nF 'run_step CLEANUP bash "$script_dir/99_cleanup.sh"' \
    "$exact_wrapper" | cut -d: -f1)"
post_cleanup_capture_line="$(grep -nF 'capture_state after_cleanup_gate' \
    "$exact_wrapper" | cut -d: -f1)"
filter_line="$(grep -nF 'if ! severe_kernel_messages="$(memblaze_filter_severe_kernel_messages' \
    "$exact_wrapper" | cut -d: -f1)"
[[ "$cleanup_line" =~ ^[0-9]+$ \
    && "$post_cleanup_capture_line" =~ ^[0-9]+$ \
    && "$filter_line" =~ ^[0-9]+$ \
    && "$cleanup_line" -lt "$post_cleanup_capture_line" \
    && "$post_cleanup_capture_line" -lt "$filter_line" ]] || {
    printf 'FAIL: final kernel filtering does not occur after cleanup capture\n' >&2
    exit 1
}

printf 'PASS: benign XDMA timeout configuration is ignored; real errors and filter failures remain fatal.\n'
