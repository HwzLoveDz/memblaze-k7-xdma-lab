#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Memblaze K7 XDMA Lab contributors

set -Eeuo pipefail
export LC_ALL=C
umask 077

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly dmesg_helper="$script_dir/lib/dmesg_capture.sh"
readonly expected_id="10ee:7024"
readonly results_root="${HOME:?HOME is not set}/memblaze-xdma-results"
readonly utc_stamp="$(date -u +%Y%m%dT%H%M%S.%NZ)"
readonly result_dir="$results_root/$utc_stamp"
readonly log_file="$result_dir/01_probe.log"

mkdir -p "$result_dir"
exec > >(tee "$log_file") 2>&1

stop() {
    printf 'STOP: %s\n' "$*" >&2
    printf 'SavedLog=%s\n' "$log_file" >&2
    exit 1
}

section() {
    printf '\n=== %s ===\n' "$1"
}

for cmd in awk basename cat date dirname dmesg grep lspci readlink tail tee uname; do
    command -v "$cmd" >/dev/null 2>&1 || stop "missing command: $cmd"
done

if (( EUID == 0 )); then
    sudo_cmd=()
else
    command -v sudo >/dev/null 2>&1 || stop "sudo is required for complete read-only PCIe and kernel-log evidence"
    sudo_cmd=(sudo)
fi
[[ -r "$dmesg_helper" ]] || stop "kernel-log helper is missing: $dmesg_helper"
# shellcheck source=linux/lib/dmesg_capture.sh
source "$dmesg_helper" || stop "kernel-log helper could not be loaded"

section "Run identity"
printf 'UTC=%s\n' "$(date -u +%FT%TZ)"
printf 'ExpectedEndpoint=%s\n' "$expected_id"
printf 'ResultDirectory=%s\n' "$result_dir"

section "Kernel"
uname -a

section "Operating system"
if [[ -r /etc/os-release ]]; then
    cat /etc/os-release
else
    printf 'WARN: /etc/os-release is unavailable.\n'
fi

section "PCI devices"
lspci -Dnn

section "PCI topology"
lspci -Dtv

section "Thunderbolt, USB4, and Xilinx matches"
lspci -Dnn | grep -Ei 'xilinx|10ee|thunderbolt|usb4' || true

mapfile -t bdfs < <(lspci -Dnn -d "$expected_id" | awk '{print $1}')
if (( ${#bdfs[@]} == 0 )); then
    stop "no $expected_id endpoint was found; verify FPGA configuration before driver work"
fi
if (( ${#bdfs[@]} != 1 )); then
    printf 'DetectedEndpoints=%s\n' "${bdfs[*]}" >&2
    stop "expected exactly one $expected_id endpoint; found ${#bdfs[@]}"
fi
readonly bdf="${bdfs[0]}"
printf '%s\n' "$bdf" > "$result_dir/endpoint.bdf"

section "Endpoint detail"
printf 'Endpoint=%s\n' "$bdf"
"${sudo_cmd[@]}" lspci -Dvvnn -s "$bdf"
printf 'LSPCI_VERBOSE=CAPTURED\n'

readonly resource_file="/sys/bus/pci/devices/$bdf/resource"
[[ -r "$resource_file" ]] || stop "PCI resource table is unavailable: $resource_file"
read -r bar0_start bar0_end bar0_flags < "$resource_file"
[[ "$bar0_start" =~ ^0x[0-9A-Fa-f]+$ \
   && "$bar0_end" =~ ^0x[0-9A-Fa-f]+$ \
   && "$bar0_flags" =~ ^0x[0-9A-Fa-f]+$ ]] \
    || stop "BAR0 resource line has an unexpected format"
bar0_size_bytes=$((bar0_end - bar0_start + 1))
(( bar0_start != 0 && bar0_end >= bar0_start && bar0_size_bytes % 1024 == 0 )) \
    || stop "BAR0 is unassigned or its active size is not an integer number of KiB"
printf 'PF0_BAR0_RESOURCE_SIZE_KIB=%s\n' "$((bar0_size_bytes / 1024))"

section "Kernel driver state"
lspci -Dnnk -s "$bdf"
if [[ -L "/sys/bus/pci/devices/$bdf/driver" ]]; then
    printf 'BoundDriver=%s\n' "$(basename "$(readlink -f "/sys/bus/pci/devices/$bdf/driver")")"
else
    printf 'BoundDriver=none\n'
fi

section "Thunderbolt authorization"
if command -v boltctl >/dev/null 2>&1; then
    boltctl list || true
else
    printf 'INFO: boltctl is not installed; no authorization state was collected.\n'
fi

section "Relevant kernel log"
readonly dmesg_file="$result_dir/dmesg_probe.txt"
readonly dmesg_diagnostics_file="$result_dir/dmesg_probe_capture.log"
if ! memblaze_select_kernel_log_file "$dmesg_file" "$dmesg_diagnostics_file"; then
    cat "$dmesg_diagnostics_file" >&2
    stop "the kernel log could not be read from dmesg or the current-boot kernel journal"
fi
printf 'KERNEL_LOG_BACKEND=%s\n' "$MEMBLAZE_KERNEL_LOG_BACKEND"
cat "$dmesg_diagnostics_file"
grep -Ei 'pcie|thunderbolt|usb4|xilinx|xdma|aer|iommu|10ee|7024' \
    "$dmesg_file" | tail -n 300 || true

section "Result"
printf 'PASS: exactly one %s endpoint is enumerated.\n' "$expected_id"
printf 'PCI_ENUMERATION=PASS\n'
printf 'Endpoint=%s\n' "$bdf"
printf 'SavedLog=%s\n' "$log_file"
