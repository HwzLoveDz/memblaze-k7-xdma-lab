#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Memblaze K7 XDMA Lab contributors

set -Eeuo pipefail
export LC_ALL=C
umask 077

readonly expected_id="10ee:7024"
readonly expected_subsystem_vendor="0x10ee"
readonly expected_subsystem_device="0x0007"
readonly build_tag="b8466090-aba9086b051e"
readonly kernel_release="$(uname -r)"
readonly source_root="${HOME:?HOME is not set}/memblaze-xdma-work/$build_tag/$kernel_release/dma_ip_drivers-b8466090/XDMA/linux-kernel"
readonly tools_dir="$source_root/tools"
readonly results_root="$HOME/memblaze-xdma-results"
readonly utc_stamp="$(date -u +%Y%m%dT%H%M%S.%NZ)"
readonly result_dir="$results_root/$utc_stamp"
readonly log_file="$result_dir/05_dma_smoke.log"

usage() {
    cat <<'EOF'
Usage:
  ./05_dma_smoke.sh --confirm-ddr-write
      Run the three validated smoke cases.

  ./05_dma_smoke.sh --confirm-ddr-write SIZE ADDRESS CHANNEL
      Run one round-trip. SIZE is decimal bytes, from 1 through 67108864
      (64 MiB). ADDRESS is decimal or 0x-prefixed hexadecimal within the
       4 GiB DDR map. CHANNEL is 0 or 1.

The confirmation also asserts that the FPGA was programmed from the bitstream
produced by this checkout's fpga/build.tcl flow. PCI ID alone cannot prove that
the active image contains the documented external-DDR address map.

  ./05_dma_smoke.sh --help

Examples:
  ./05_dma_smoke.sh --confirm-ddr-write 4096 0x0 0
  ./05_dma_smoke.sh --confirm-ddr-write 67108864 0x04000000 0
EOF
}

if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
fi
argument_error() {
    printf 'ERROR: %s\n\n' "$*" >&2
    usage >&2
    exit 2
}

validate_cli_roundtrip() {
    local size_text="$1"
    local address_text="$2"
    local channel_text="$3"

    [[ "$size_text" =~ ^[0-9]+$ ]] || argument_error "SIZE must be a positive decimal byte count"
    (( ${#size_text} <= 10 )) || argument_error "SIZE is too large"
    validated_size=$((10#$size_text))
    (( validated_size >= 1 && validated_size <= 67108864 )) \
        || argument_error "SIZE must be from 1 through 67108864 bytes (64 MiB)"

    if [[ "$address_text" =~ ^0[xX][0-9a-fA-F]+$ ]]; then
        local address_digits="${address_text:2}"
        (( ${#address_digits} <= 8 )) || argument_error "ADDRESS exceeds the 4 GiB map"
        validated_address=$((16#$address_digits))
    elif [[ "$address_text" =~ ^[0-9]+$ ]]; then
        (( ${#address_text} <= 10 )) || argument_error "ADDRESS exceeds the 4 GiB map"
        validated_address=$((10#$address_text))
    else
        argument_error "ADDRESS must be decimal or 0x-prefixed hexadecimal"
    fi
    (( validated_address >= 0 && validated_address <= 0xffffffff )) \
        || argument_error "ADDRESS is outside the 4 GiB map"
    (( validated_address + validated_size <= 0x100000000 )) \
        || argument_error "ADDRESS + SIZE exceeds the 4 GiB map"

    [[ "$channel_text" =~ ^[01]$ ]] || argument_error "CHANNEL must be 0 or 1"
    validated_channel="$channel_text"
}

if (( $# == 0 )) || [[ "$1" != "--confirm-ddr-write" ]]; then
    argument_error "the explicit --confirm-ddr-write acknowledgement is required"
fi
shift
if (( $# != 0 && $# != 3 )); then
    argument_error "expected no values for the default smoke set, or SIZE ADDRESS CHANNEL"
fi
if (( $# == 3 )); then
    validate_cli_roundtrip "$1" "$2" "$3"
fi

mkdir -p "$result_dir"
exec > >(tee "$log_file") 2>&1

stop() {
    printf 'STOP: %s\n' "$*" >&2
    printf 'SavedLog=%s\n' "$log_file" >&2
    exit 1
}

for cmd in awk basename cmp date dmesg grep head lspci readlink sha256sum tail tee timeout uname wc; do
    command -v "$cmd" >/dev/null 2>&1 || stop "missing command: $cmd"
done

if (( EUID == 0 )); then
    sudo_cmd=()
else
    command -v sudo >/dev/null 2>&1 || stop "sudo is required for XDMA character-device access and kernel-log evidence"
    sudo_cmd=(sudo)
fi

mapfile -t bdfs < <(lspci -Dnn -d "$expected_id" | awk '{print $1}')
(( ${#bdfs[@]} == 1 )) \
    || stop "expected exactly one $expected_id endpoint; found ${#bdfs[@]}"
readonly bdf="${bdfs[0]}"

[[ -d /sys/module/xdma ]] || stop "xdma is not loaded; run 04_load_verify.sh first"
driver_path="$(readlink -f "/sys/bus/pci/devices/$bdf/driver" 2>/dev/null || true)"
[[ "${driver_path##*/}" == "xdma" ]] || stop "the endpoint is not bound to xdma"

shopt -s nullglob
bound_xdma_devices=(/sys/bus/pci/drivers/xdma/????:??:??.?)
shopt -u nullglob
(( ${#bound_xdma_devices[@]} == 1 )) \
    || stop "xdma has ${#bound_xdma_devices[@]} bound PCI devices; refusing DMA in a multi-device state"
[[ "$(basename "${bound_xdma_devices[0]}")" == "$bdf" ]] \
    || stop "the PCI device bound to xdma is not the target endpoint"

[[ -x "$tools_dir/dma_to_device" ]] || stop "dma_to_device is missing; run 02_build_driver.sh first"
[[ -x "$tools_dir/dma_from_device" ]] || stop "dma_from_device is missing; run 02_build_driver.sh first"

for class_name in xdma0_h2c_0 xdma0_c2h_0 xdma0_h2c_1 xdma0_c2h_1; do
    class_device="/sys/class/xdma/$class_name/device"
    [[ -L "$class_device" ]] || stop "sysfs parent link is missing for $class_name"
    [[ "$(basename "$(readlink -f "$class_device")")" == "$bdf" ]] \
        || stop "$class_name does not belong to target endpoint $bdf"
done

readonly subsystem_vendor_file="/sys/bus/pci/devices/$bdf/subsystem_vendor"
readonly subsystem_device_file="/sys/bus/pci/devices/$bdf/subsystem_device"
[[ -r "$subsystem_vendor_file" && -r "$subsystem_device_file" ]] \
    || stop "PCI subsystem identity is unavailable in sysfs"
readonly subsystem_vendor="$(<"$subsystem_vendor_file")"
readonly subsystem_device="$(<"$subsystem_device_file")"
[[ "${subsystem_vendor,,}" == "$expected_subsystem_vendor" \
   && "${subsystem_device,,}" == "$expected_subsystem_device" ]] \
    || stop "unexpected subsystem ${subsystem_vendor}:${subsystem_device}; expected ${expected_subsystem_vendor}:${expected_subsystem_device}"

printf 'UTC=%s\n' "$(date -u +%FT%TZ)"
printf 'Endpoint=%s\n' "$bdf"
printf 'Subsystem=%s:%s\n' "$subsystem_vendor" "$subsystem_device"
printf 'Tools=%s\n' "$tools_dir"
printf 'ImageRequirement=bitstream-produced-by-this-checkout\n'

printf '\nWARNING: this test overwrites data in the selected FPGA external-DDR ranges.\n'
printf 'PCI ID and device nodes do not prove the active FPGA image or DDR map.\n'
printf 'The confirmation flag asserts that this checkout generated the programmed image.\n'
printf 'It does not write the FPGA flash, host partitions, EFI data, or raw host disks.\n'
printf 'DDRWriteConfirmation=--confirm-ddr-write\n'

readonly dmesg_before_file="$result_dir/dmesg_before_smoke.txt"
readonly dmesg_after_file="$result_dir/dmesg_after_smoke.txt"
"${sudo_cmd[@]}" dmesg --time-format=raw > "$dmesg_before_file"
readonly dmesg_lines_before="$(wc -l < "$dmesg_before_file")"

run_roundtrip() {
    local name="$1"
    local size="$2"
    local address_text="$3"
    local channel="$4"
    local case_dir="$result_dir/$name"
    local tx="$case_dir/tx.bin"
    local rx="$case_dir/rx.bin"
    local h2c_node="/dev/xdma0_h2c_$channel"
    local c2h_node="/dev/xdma0_c2h_$channel"

    [[ -c "$h2c_node" ]] || stop "missing H2C node: $h2c_node"
    [[ -c "$c2h_node" ]] || stop "missing C2H node: $c2h_node"
    mkdir -p "$case_dir"

    printf '\n=== %s: size=%s address=%s channel=%s ===\n' "$name" "$size" "$address_text" "$channel"
    head -c "$size" /dev/urandom > "$tx"
    printf 'TX_SHA256='
    sha256sum "$tx" | awk '{print $1}'

    set +e
    "${sudo_cmd[@]}" timeout --signal=INT --kill-after=2s 15s \
        "$tools_dir/dma_to_device" \
        -d "$h2c_node" -f "$tx" -s "$size" -a "$address_text" -c 1 -v
    h2c_rc=$?
    set -e
    printf 'H2C_RC=%s\n' "$h2c_rc"
    (( h2c_rc == 0 )) || stop "$name H2C failed; C2H was not attempted"

    : > "$rx"
    set +e
    "${sudo_cmd[@]}" timeout --signal=INT --kill-after=2s 15s \
        "$tools_dir/dma_from_device" \
        -d "$c2h_node" -f "$rx" -s "$size" -a "$address_text" -c 1 -v
    c2h_rc=$?
    set -e
    printf 'C2H_RC=%s\n' "$c2h_rc"
    (( c2h_rc == 0 )) || stop "$name C2H failed"

    printf 'RX_SHA256='
    sha256sum "$rx" | awk '{print $1}'
    set +e
    cmp --silent "$tx" "$rx"
    cmp_rc=$?
    set -e
    printf 'CMP_RC=%s\n' "$cmp_rc"
    (( cmp_rc == 0 )) || stop "$name data mismatch"
    printf 'PASS: %s matched byte-for-byte.\n' "$name"
}

if (( $# == 0 )); then
    printf 'TestSet=4KiB/ch0/0x0,1MiB/ch0/0x10000000,1MiB/ch1/0x20000000\n'
    run_roundtrip "4KiB_ch0_addr0" 4096 0x0 0
    run_roundtrip "1MiB_ch0_addr10000000" 1048576 0x10000000 0
    run_roundtrip "1MiB_ch1_addr20000000" 1048576 0x20000000 1
    case_count=3
else
    printf -v normalized_address '0x%08x' "$validated_address"
    address_tag="${normalized_address#0x}"
    run_roundtrip "custom_${validated_size}_ch${validated_channel}_addr${address_tag}" \
        "$validated_size" "$normalized_address" "$validated_channel"
    case_count=1
fi

printf '\n=== New relevant kernel messages ===\n'
"${sudo_cmd[@]}" dmesg --time-format=raw > "$dmesg_after_file"
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
    stop "DMA data matched, but new relevant kernel messages require review"
else
    printf 'No new matching kernel messages.\n'
fi

printf '\nPASS: %s DMA round-trip case(s) completed with matching data.\n' "$case_count"
printf 'DMA_DATA_COMPARE=PASS\n'
printf 'SavedResult=%s\n' "$result_dir"
