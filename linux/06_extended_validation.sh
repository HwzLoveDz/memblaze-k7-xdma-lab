#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Memblaze K7 XDMA Lab contributors

# Extended follow-up validated on the target Memblaze hardware on 2026-09-14.
# Both modes completed with byte-for-byte matches. The script deliberately uses
# only 64 MiB-or-smaller XDMA requests; it never submits one 1 GiB request.

set -Eeuo pipefail
export LC_ALL=C
umask 077

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly dmesg_helper="$script_dir/lib/dmesg_capture.sh"

usage() {
    cat <<'EOF'
Usage:
  ./06_extended_validation.sh --confirm-ddr-write chunked-1g
      Write sixteen distinct 64 MiB patterns, then regenerate and verify each
      chunk. No individual DMA request is larger than 64 MiB.

  ./06_extended_validation.sh --confirm-ddr-write alias-4g
      Write distinct 1 MiB sentinels at 0, 1, 2, and 3 GiB plus 0xFFF00000,
      then read every sentinel back to detect gross address aliasing.

  ./06_extended_validation.sh --help

Both tests overwrite the selected external-DDR ranges. The confirmation flag
is mandatory and also asserts that the FPGA was programmed from the bitstream
produced by this checkout's fpga/build.tcl flow. PCI ID alone cannot prove the
active image or DDR map. Temporary payloads live only in /dev/shm; logs and hashes are saved under
$HOME/memblaze-xdma-results/<UTC>.
EOF
}

if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
fi
if (( $# != 2 )) || [[ "$1" != "--confirm-ddr-write" ]]; then
    usage >&2
    exit 2
fi
readonly test_mode="$2"
case "$test_mode" in
    chunked-1g|alias-4g) ;;
    *)
        printf 'ERROR: unknown subcommand: %s\n\n' "$test_mode" >&2
        usage >&2
        exit 2
        ;;
esac

readonly expected_id="10ee:7024"
readonly expected_subsystem_vendor="0x10ee"
readonly expected_subsystem_device="0x0007"
readonly build_tag="b8466090-aba9086b051e"
readonly kernel_release="$(uname -r)"
readonly source_root="${HOME:?HOME is not set}/memblaze-xdma-work/$build_tag/$kernel_release/dma_ip_drivers-b8466090/XDMA/linux-kernel"
readonly tools_dir="$source_root/tools"
readonly state_file="$HOME/.local/state/memblaze-xdma-quickstart/active-xdma-load.state"
readonly results_root="$HOME/memblaze-xdma-results"
readonly utc_stamp="$(date -u +%Y%m%dT%H%M%S.%NZ)"
readonly result_dir="$results_root/$utc_stamp"
readonly log_file="$result_dir/06_extended_validation.log"
readonly manifest_file="$result_dir/pattern_manifest.txt"
readonly dmesg_before_file="$result_dir/dmesg_before_extended.txt"
readonly dmesg_after_file="$result_dir/dmesg_after_extended.txt"
readonly dmesg_before_diagnostics="$result_dir/dmesg_before_extended_capture.log"
readonly dmesg_after_diagnostics="$result_dir/dmesg_after_extended_capture.log"
readonly pcie_before_file="$result_dir/pcie_before_extended.txt"
readonly pcie_after_file="$result_dir/pcie_after_extended.txt"
readonly topology_before_file="$result_dir/pcie_topology_before.txt"
readonly topology_after_file="$result_dir/pcie_topology_after.txt"

mkdir -p "$result_dir"
exec > >(tee "$log_file") 2>&1

stop() {
    printf 'STOP: %s\n' "$*" >&2
    printf 'SavedLog=%s\n' "$log_file" >&2
    exit 1
}

for cmd in awk basename cat cmp cut date df dirname dmesg grep head lspci mktemp openssl readlink rm sha256sum tail tee timeout uname wc; do
    command -v "$cmd" >/dev/null 2>&1 || stop "missing command: $cmd"
done

if (( EUID == 0 )); then
    sudo_cmd=()
else
    command -v sudo >/dev/null 2>&1 || stop "sudo is required for XDMA access and complete evidence"
    sudo_cmd=(sudo)
fi
[[ -r "$dmesg_helper" ]] || stop "kernel-log helper is missing: $dmesg_helper"
# shellcheck source=linux/lib/dmesg_capture.sh
source "$dmesg_helper" || stop "kernel-log helper could not be loaded"

mapfile -t bdfs < <(lspci -Dnn -d "$expected_id" | awk '{print $1}')
(( ${#bdfs[@]} == 1 )) || stop "expected exactly one $expected_id endpoint; found ${#bdfs[@]}"
readonly bdf="${bdfs[0]}"

readonly subsystem_vendor_file="/sys/bus/pci/devices/$bdf/subsystem_vendor"
readonly subsystem_device_file="/sys/bus/pci/devices/$bdf/subsystem_device"
[[ -r "$subsystem_vendor_file" && -r "$subsystem_device_file" ]] \
    || stop "PCI subsystem identity is unavailable in sysfs"
readonly subsystem_vendor="$(<"$subsystem_vendor_file")"
readonly subsystem_device="$(<"$subsystem_device_file")"
[[ "${subsystem_vendor,,}" == "$expected_subsystem_vendor" \
   && "${subsystem_device,,}" == "$expected_subsystem_device" ]] \
    || stop "unexpected subsystem ${subsystem_vendor}:${subsystem_device}"

[[ -d /sys/module/xdma ]] || stop "xdma is not loaded; run 04_load_verify.sh first"
driver_path="$(readlink -f "/sys/bus/pci/devices/$bdf/driver" 2>/dev/null || true)"
[[ "${driver_path##*/}" == "xdma" ]] || stop "the endpoint is not bound to xdma"

shopt -s nullglob
bound_xdma_devices=(/sys/bus/pci/drivers/xdma/????:??:??.?)
shopt -u nullglob
(( ${#bound_xdma_devices[@]} == 1 )) \
    || stop "xdma has ${#bound_xdma_devices[@]} bound PCI devices; refusing extended DMA"
[[ "$(basename "${bound_xdma_devices[0]}")" == "$bdf" ]] \
    || stop "the PCI device bound to xdma is not the target endpoint"

for class_name in xdma0_h2c_0 xdma0_c2h_0; do
    class_device="/sys/class/xdma/$class_name/device"
    [[ -L "$class_device" ]] || stop "sysfs parent link is missing for $class_name"
    [[ "$(basename "$(readlink -f "$class_device")")" == "$bdf" ]] \
        || stop "$class_name does not belong to target endpoint $bdf"
done

[[ -x "$tools_dir/dma_to_device" ]] || stop "dma_to_device is missing"
[[ -x "$tools_dir/dma_from_device" ]] || stop "dma_from_device is missing"
[[ -c /dev/xdma0_h2c_0 && -c /dev/xdma0_c2h_0 ]] || stop "channel-0 XDMA nodes are missing"
[[ -r "$state_file" ]] || stop "quickstart load ownership marker is missing; run 04_load_verify.sh"

printf 'ImageRequirement=bitstream-produced-by-this-checkout\n'
printf 'WARNING: PCI ID and device nodes do not prove the active FPGA image or DDR map.\n'
printf 'DDRWriteConfirmation=--confirm-ddr-write\n'

marker_value() {
    local key="$1"
    awk -F= -v wanted="$key" \
        '$1 == wanted { print substr($0, index($0, "=") + 1); found=1; exit } END { if (!found) exit 1 }' \
        "$state_file"
}
marker_bdf="$(marker_value BDF)" || stop "ownership marker is missing BDF"
marker_boot_id="$(marker_value BOOT_ID)" || stop "ownership marker is missing BOOT_ID"
[[ "$marker_bdf" == "$bdf" ]] || stop "ownership marker BDF does not match the endpoint"
[[ "$marker_boot_id" == "$(</proc/sys/kernel/random/boot_id)" ]] \
    || stop "ownership marker belongs to another boot"

if [[ "$test_mode" == "chunked-1g" ]]; then
    readonly max_buffer_size=67108864
else
    readonly max_buffer_size=1048576
fi
readonly required_shm_bytes=$((3 * max_buffer_size + 16777216))
available_shm_bytes="$(df -B1 --output=avail /dev/shm | tail -n 1 | awk '{$1=$1; print}')"
[[ "$available_shm_bytes" =~ ^[0-9]+$ ]] || stop "could not determine free /dev/shm space"
(( available_shm_bytes >= required_shm_bytes )) \
    || stop "/dev/shm needs at least $required_shm_bytes free bytes; found $available_shm_bytes"

temp_dir="$(mktemp -d /dev/shm/memblaze-xdma.XXXXXXXX)"
after_captured=0
capture_started=0

capture_after() {
    local mode="${1:-strict}"
    local pcie_rc=0
    local topology_rc=0
    local dmesg_rc=0
    "${sudo_cmd[@]}" lspci -Dvvnn > "$pcie_after_file" || pcie_rc=$?
    lspci -Dtv > "$topology_after_file" || topology_rc=$?
    if memblaze_capture_kernel_log_file "$dmesg_after_file" "$dmesg_after_diagnostics"; then
        dmesg_rc=0
    else
        dmesg_rc=$?
    fi
    cat "$dmesg_after_diagnostics"
    after_captured=1
    printf 'AfterCaptureRC=pcie:%s,topology:%s,dmesg:%s\n' \
        "$pcie_rc" "$topology_rc" "$dmesg_rc"
    if (( pcie_rc != 0 || topology_rc != 0 || dmesg_rc != 0 )); then
        if [[ "$mode" == "strict" ]]; then
            return 1
        fi
        printf 'WARN: best-effort failure cleanup could not capture every after-test snapshot.\n' >&2
    fi
    return 0
}

finish() {
    local exit_rc=$?
    trap - EXIT
    set +e
    if (( capture_started == 1 && after_captured == 0 )); then
        capture_after best-effort
    fi
    if [[ -n "$temp_dir" && "$temp_dir" == /dev/shm/memblaze-xdma.* ]]; then
        rm -rf -- "$temp_dir"
    fi
    exit "$exit_rc"
}
trap finish EXIT

printf 'UTC=%s\n' "$(date -u +%FT%TZ)"
printf 'Mode=%s\n' "$test_mode"
printf 'Endpoint=%s\n' "$bdf"
printf 'Subsystem=%s:%s\n' "$subsystem_vendor" "$subsystem_device"
printf 'DDRWriteConfirmation=--confirm-ddr-write\n'
printf 'SCRIPT_BASELINE=VALIDATED_ON_MEMBLAZE_2026-09-14\n'
printf 'INFO: no individual DMA request in this script exceeds 64 MiB.\n'
printf 'WARNING: selected volatile FPGA DDR ranges will be overwritten.\n'

"${sudo_cmd[@]}" lspci -Dvvnn > "$pcie_before_file"
lspci -Dtv > "$topology_before_file"
if ! memblaze_select_kernel_log_file "$dmesg_before_file" "$dmesg_before_diagnostics"; then
    cat "$dmesg_before_diagnostics" >&2
    stop "the pre-test kernel log could not be read from dmesg or the current-boot kernel journal"
fi
printf 'KERNEL_LOG_BACKEND=%s\n' "$MEMBLAZE_KERNEL_LOG_BACKEND"
cat "$dmesg_before_diagnostics"
readonly dmesg_lines_before="$(wc -l < "$dmesg_before_file")"
capture_started=1

make_pattern() {
    local output_file="$1"
    local byte_count="$2"
    local absolute_address="$3"
    local seed_text
    local key_hex
    local iv_hex

    printf -v seed_text 'memblaze-xdma-pattern-v1:%s:%016x' "$test_mode" "$absolute_address"
    key_hex="$(printf '%s:key' "$seed_text" | sha256sum | awk '{print $1}')"
    iv_hex="$(printf '%s:iv' "$seed_text" | sha256sum | awk '{print $1}' | cut -c1-32)"
    head -c "$byte_count" /dev/zero \
        | openssl enc -aes-256-ctr -K "$key_hex" -iv "$iv_hex" -nosalt \
        > "$output_file"
    [[ "$(wc -c < "$output_file")" -eq "$byte_count" ]] \
        || stop "pattern generator produced the wrong size"
}

run_h2c() {
    local input_file="$1"
    local byte_count="$2"
    local address_text="$3"
    set +e
    "${sudo_cmd[@]}" timeout --signal=INT --kill-after=2s 30s \
        "$tools_dir/dma_to_device" \
        -d /dev/xdma0_h2c_0 -f "$input_file" -s "$byte_count" -a "$address_text" -c 1 -v
    local transfer_rc=$?
    set -e
    printf 'H2C_RC=%s address=%s size=%s\n' "$transfer_rc" "$address_text" "$byte_count"
    (( transfer_rc == 0 )) || stop "H2C failed at $address_text"
}

run_c2h() {
    local output_file="$1"
    local byte_count="$2"
    local address_text="$3"
    : > "$output_file"
    set +e
    "${sudo_cmd[@]}" timeout --signal=INT --kill-after=2s 30s \
        "$tools_dir/dma_from_device" \
        -d /dev/xdma0_c2h_0 -f "$output_file" -s "$byte_count" -a "$address_text" -c 1 -v
    local transfer_rc=$?
    set -e
    printf 'C2H_RC=%s address=%s size=%s\n' "$transfer_rc" "$address_text" "$byte_count"
    (( transfer_rc == 0 )) || stop "C2H failed at $address_text"
}

write_pattern_at() {
    local byte_count="$1"
    local absolute_address="$2"
    local address_text
    local hash
    printf -v address_text '0x%08x' "$absolute_address"
    make_pattern "$temp_dir/tx.bin" "$byte_count" "$absolute_address"
    hash="$(sha256sum "$temp_dir/tx.bin" | awk '{print $1}')"
    printf 'WRITE address=%s size=%s sha256=%s\n' "$address_text" "$byte_count" "$hash" \
        | tee -a "$manifest_file"
    run_h2c "$temp_dir/tx.bin" "$byte_count" "$address_text"
}

verify_pattern_at() {
    local byte_count="$1"
    local absolute_address="$2"
    local address_text
    local expected_hash
    local actual_hash
    printf -v address_text '0x%08x' "$absolute_address"
    make_pattern "$temp_dir/expected.bin" "$byte_count" "$absolute_address"
    run_c2h "$temp_dir/actual.bin" "$byte_count" "$address_text"
    expected_hash="$(sha256sum "$temp_dir/expected.bin" | awk '{print $1}')"
    actual_hash="$(sha256sum "$temp_dir/actual.bin" | awk '{print $1}')"
    set +e
    cmp --silent "$temp_dir/expected.bin" "$temp_dir/actual.bin"
    local compare_rc=$?
    set -e
    printf 'VERIFY address=%s size=%s expected_sha256=%s actual_sha256=%s cmp_rc=%s\n' \
        "$address_text" "$byte_count" "$expected_hash" "$actual_hash" "$compare_rc" \
        | tee -a "$manifest_file"
    (( compare_rc == 0 )) || stop "data mismatch at $address_text"
}

if [[ "$test_mode" == "chunked-1g" ]]; then
    readonly chunk_size=67108864
    readonly chunk_count=16
    printf '\n=== Phase 1: write all sixteen 64 MiB chunks ===\n'
    for (( chunk=0; chunk<chunk_count; chunk++ )); do
        write_pattern_at "$chunk_size" "$((chunk * chunk_size))"
    done
    printf '\n=== Phase 2: regenerate, read, and verify every chunk ===\n'
    for (( chunk=0; chunk<chunk_count; chunk++ )); do
        verify_pattern_at "$chunk_size" "$((chunk * chunk_size))"
    done
else
    readonly sentinel_size=1048576
    sentinel_addresses=(0 1073741824 2147483648 3221225472 4293918720)
    printf '\n=== Phase 1: write all five address-alias sentinels ===\n'
    for address in "${sentinel_addresses[@]}"; do
        write_pattern_at "$sentinel_size" "$address"
    done
    printf '\n=== Phase 2: regenerate, read, and verify every sentinel ===\n'
    for address in "${sentinel_addresses[@]}"; do
        verify_pattern_at "$sentinel_size" "$address"
    done
fi

capture_after strict || stop "failed to capture complete after-test PCIe/topology/dmesg evidence"

printf '\n=== New relevant kernel messages ===\n'
dmesg_lines_after="$(wc -l < "$dmesg_after_file")"
if (( dmesg_lines_before > 0 )); then
    if (( dmesg_lines_after < dmesg_lines_before )) \
        || ! head -n "$dmesg_lines_before" "$dmesg_after_file" \
            | cmp --silent - "$dmesg_before_file"; then
        stop "kernel ring buffer prefix changed; new DMA messages cannot be isolated safely"
    fi
fi
printf 'KernelLogPrefix=stable\n'
new_messages="$(tail -n "+$((dmesg_lines_before + 1))" "$dmesg_after_file" \
    | grep -Ei 'xdma|aer|pcie|timeout|fatal|error|fault' || true)"
if [[ -n "$new_messages" ]]; then
    printf '%s\n' "$new_messages"
    stop "data matched, but new relevant kernel messages require review"
else
    printf 'No new matching kernel messages.\n'
fi

printf '\nPASS: %s completed with byte-for-byte data matches.\n' "$test_mode"
printf 'EXTENDED_DMA_DATA_COMPARE=PASS\n'
printf 'SavedResult=%s\n' "$result_dir"
