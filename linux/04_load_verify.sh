#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Memblaze K7 XDMA Lab contributors

set -Eeuo pipefail
export LC_ALL=C
umask 077

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly dmesg_helper="$script_dir/lib/dmesg_capture.sh"
readonly expected_id="10ee:7024"
readonly build_tag="b8466090-aba9086b051e"
readonly kernel_release="$(uname -r)"
readonly source_root="${HOME:?HOME is not set}/memblaze-xdma-work/$build_tag/$kernel_release/dma_ip_drivers-b8466090/XDMA/linux-kernel"
readonly module="$source_root/xdma/xdma.ko"
readonly state_root="$HOME/.local/state/memblaze-xdma-quickstart"
readonly state_file="$state_root/active-xdma-load.state"
readonly results_root="$HOME/memblaze-xdma-results"
readonly utc_stamp="$(date -u +%Y%m%dT%H%M%S.%NZ)"
readonly result_dir="$results_root/$utc_stamp"
readonly log_file="$result_dir/04_load_verify.log"

mkdir -p "$result_dir"
exec > >(tee "$log_file") 2>&1

stop() {
    printf 'STOP: %s\n' "$*" >&2
    printf 'SavedLog=%s\n' "$log_file" >&2
    exit 1
}

for cmd in awk basename cat cmp date dirname dmesg grep head insmod lspci mv readlink rm rmmod sha256sum tail tee udevadm uname wc; do
    command -v "$cmd" >/dev/null 2>&1 || stop "missing command: $cmd"
done

if (( EUID == 0 )); then
    sudo_cmd=()
else
    command -v sudo >/dev/null 2>&1 || stop "sudo is required to load and verify the module"
    sudo_cmd=(sudo)
fi
[[ -r "$dmesg_helper" ]] || stop "kernel-log helper is missing: $dmesg_helper"
# shellcheck source=linux/lib/dmesg_capture.sh
source "$dmesg_helper" || stop "kernel-log helper could not be loaded"

mapfile -t bdfs < <(lspci -Dnn -d "$expected_id" | awk '{print $1}')
(( ${#bdfs[@]} == 1 )) \
    || stop "expected exactly one $expected_id endpoint; found ${#bdfs[@]}"
readonly bdf="${bdfs[0]}"
[[ -f "$module" ]] || stop "built module is missing; run 02_build_driver.sh first"

readonly subsystem_vendor_file="/sys/bus/pci/devices/$bdf/subsystem_vendor"
readonly subsystem_device_file="/sys/bus/pci/devices/$bdf/subsystem_device"
[[ -r "$subsystem_vendor_file" && -r "$subsystem_device_file" ]] \
    || stop "PCI subsystem identity is unavailable in sysfs"
readonly subsystem_vendor="$(<"$subsystem_vendor_file")"
readonly subsystem_device="$(<"$subsystem_device_file")"
[[ "${subsystem_vendor,,}" == "0x10ee" && "${subsystem_device,,}" == "0x0007" ]] \
    || stop "unexpected subsystem ${subsystem_vendor}:${subsystem_device}; expected 0x10ee:0x0007"

if [[ -d /sys/module/xdma ]]; then
    stop "xdma is already loaded; run 99_cleanup.sh and identify any existing driver before retrying"
fi

bound_driver="none"
if [[ -L "/sys/bus/pci/devices/$bdf/driver" ]]; then
    bound_driver="$(basename "$(readlink -f "/sys/bus/pci/devices/$bdf/driver")")"
fi
[[ "$bound_driver" == "none" ]] \
    || stop "endpoint is already bound to driver '$bound_driver'; this script will not unbind it"
if [[ -e "$state_file" ]]; then
    rm -f -- "$state_file"
    printf 'INFO: removed a stale quickstart cleanup marker while xdma was not loaded.\n'
fi

printf 'UTC=%s\n' "$(date -u +%FT%TZ)"
printf 'Endpoint=%s\n' "$bdf"
printf 'Subsystem=%s:%s\n' "$subsystem_vendor" "$subsystem_device"
printf 'Module=%s\n' "$module"

printf '\n=== Endpoint before load ===\n'
"${sudo_cmd[@]}" lspci -Dvvnnk -s "$bdf"
readonly dmesg_before_file="$result_dir/dmesg_before_load.txt"
readonly dmesg_after_file="$result_dir/dmesg_after_load.txt"
readonly dmesg_before_diagnostics="$result_dir/dmesg_before_load_capture.log"
readonly dmesg_after_diagnostics="$result_dir/dmesg_after_load_capture.log"
if ! memblaze_select_kernel_log_file "$dmesg_before_file" "$dmesg_before_diagnostics"; then
    cat "$dmesg_before_diagnostics" >&2
    stop "the pre-load kernel log could not be read from dmesg or the current-boot kernel journal"
fi
printf 'KERNEL_LOG_BACKEND=%s\n' "$MEMBLAZE_KERNEL_LOG_BACKEND"
cat "$dmesg_before_diagnostics"
readonly dmesg_lines_before="$(wc -l < "$dmesg_before_file")"
loaded_by_script=0

show_new_kernel_messages() {
    if ! memblaze_capture_kernel_log_file "$dmesg_after_file" "$dmesg_after_diagnostics"; then
        cat "$dmesg_after_diagnostics" >&2
        return 3
    fi
    cat "$dmesg_after_diagnostics"
    local dmesg_lines_after
    dmesg_lines_after="$(wc -l < "$dmesg_after_file")"
    if (( dmesg_lines_before > 0 )); then
        if (( dmesg_lines_after < dmesg_lines_before )) \
            || ! head -n "$dmesg_lines_before" "$dmesg_after_file" \
                | cmp --silent - "$dmesg_before_file"; then
            printf 'ERROR: kernel ring buffer prefix changed; new load messages cannot be isolated safely.\n' >&2
            return 2
        fi
    fi
    printf 'KernelLogPrefix=stable\n'
    tail -n "+$((dmesg_lines_before + 1))" "$dmesg_after_file" \
        | grep -Ei 'xdma|10ee|7024|aer|pcie|iommu|lockdown|verification|key|timeout|fatal|error' \
        || true
}

cleanup_after_failure() {
    local exit_rc=$?
    set +e
    if (( exit_rc != 0 && loaded_by_script == 1 )) && [[ -d /sys/module/xdma ]]; then
        printf 'INFO: verification failed; attempting to unload the module loaded by this script.\n' >&2
        if "${sudo_cmd[@]}" rmmod xdma; then
            rm -f -- "$state_file"
        else
            printf 'WARN: automatic unload failed; run 99_cleanup.sh after closing XDMA users.\n' >&2
        fi
    fi
}
trap cleanup_after_failure EXIT

printf '\n=== Module load ===\n'
set +e
"${sudo_cmd[@]}" insmod "$module" interrupt_mode=0 h2c_timeout=10 c2h_timeout=10
insmod_rc=$?
set -e
printf 'INSMOD_RC=%s\n' "$insmod_rc"
if (( insmod_rc != 0 )); then
    printf '\n=== Relevant kernel messages ===\n'
    show_new_kernel_messages || printf 'WARN: kernel-log delta was ambiguous after the failed load.\n' >&2
    stop "xdma.ko did not load; if the kernel reports a key rejection, follow the manual MOK signing guide"
fi
loaded_by_script=1

"${sudo_cmd[@]}" udevadm settle
[[ -d /sys/module/xdma ]] || stop "xdma is absent from /sys/module after insmod"
driver_path="$(readlink -f "/sys/bus/pci/devices/$bdf/driver" 2>/dev/null || true)"
[[ "${driver_path##*/}" == "xdma" ]] || stop "the endpoint is not bound to xdma"

shopt -s nullglob
bound_xdma_devices=(/sys/bus/pci/drivers/xdma/????:??:??.?)
shopt -u nullglob
(( ${#bound_xdma_devices[@]} == 1 )) \
    || stop "xdma bound ${#bound_xdma_devices[@]} PCI devices; expected only the target endpoint"
[[ "$(basename "${bound_xdma_devices[0]}")" == "$bdf" ]] \
    || stop "the only PCI device bound to xdma is not the target endpoint"

required_nodes=(
    /dev/xdma0_control
    /dev/xdma0_h2c_0
    /dev/xdma0_c2h_0
    /dev/xdma0_h2c_1
    /dev/xdma0_c2h_1
)
for node in "${required_nodes[@]}"; do
    [[ -c "$node" ]] || stop "required character device is missing: $node"
    class_device="/sys/class/xdma/${node##*/}/device"
    [[ -L "$class_device" ]] || stop "sysfs parent link is missing for $node"
    [[ "$(basename "$(readlink -f "$class_device")")" == "$bdf" ]] \
        || stop "$node does not belong to target endpoint $bdf"
done

printf '\n=== Endpoint after load ===\n'
"${sudo_cmd[@]}" lspci -Dvvnnk -s "$bdf"

printf '\n=== XDMA device nodes ===\n'
ls -l /dev/xdma*

printf '\n=== Relevant kernel messages ===\n'
show_new_kernel_messages \
    || stop "kernel ring buffer changed during load; refusing an ambiguous PASS"

mkdir -p "$state_root"
readonly module_sha256="$(sha256sum "$module" | awk '{print $1}')"
readonly boot_id="$(</proc/sys/kernel/random/boot_id)"
state_tmp="$state_file.tmp.$$"
cat > "$state_tmp" <<EOF
FORMAT=1
BDF=$bdf
BOOT_ID=$boot_id
KERNEL=$kernel_release
MODULE_PATH=$module
MODULE_SHA256=$module_sha256
EOF
mv -f -- "$state_tmp" "$state_file"

trap - EXIT
printf '\nPASS: xdma loaded, bound to %s, and both H2C/C2H channel pairs exist.\n' "$bdf"
printf 'XDMA_DRIVER=PASS\n'
printf 'DriverPath=%s\n' "$driver_path"
printf 'CleanupState=%s\n' "$state_file"
printf 'SavedLog=%s\n' "$log_file"
