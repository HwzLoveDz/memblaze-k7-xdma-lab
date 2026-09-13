#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Memblaze K7 XDMA Lab contributors

set -Eeuo pipefail
export LC_ALL=C
umask 077

readonly expected_id="10ee:7024"
readonly state_root="$HOME/.local/state/memblaze-xdma-quickstart"
readonly state_file="$state_root/active-xdma-load.state"
readonly results_root="${HOME:?HOME is not set}/memblaze-xdma-results"
readonly utc_stamp="$(date -u +%Y%m%dT%H%M%S.%NZ)"
readonly result_dir="$results_root/$utc_stamp"
readonly log_file="$result_dir/99_cleanup.log"

mkdir -p "$result_dir"
exec > >(tee "$log_file") 2>&1

stop() {
    printf 'STOP: %s\n' "$*" >&2
    printf 'SavedLog=%s\n' "$log_file" >&2
    exit 1
}

for cmd in awk basename date lspci readlink rm rmmod sha256sum tee udevadm uname; do
    command -v "$cmd" >/dev/null 2>&1 || stop "missing command: $cmd"
done

if [[ ! -d /sys/module/xdma ]]; then
    udevadm settle || stop "udev did not settle while checking the already-unloaded state"
    if compgen -G '/dev/xdma*' >/dev/null; then
        stop "xdma is not loaded, but XDMA device nodes still exist"
    fi
    if [[ -e "$state_file" ]]; then
        rm -f -- "$state_file"
        printf 'INFO: removed a stale quickstart ownership marker.\n'
    fi
    printf 'PASS: xdma is not loaded; no cleanup was needed.\n'
    printf 'CLEANUP_STATUS=PASS\n'
    printf 'CLEANUP_RC=0\n'
    printf 'SavedLog=%s\n' "$log_file"
    exit 0
fi

[[ -r "$state_file" ]] \
    || stop "xdma is loaded but no quickstart ownership marker exists; refusing to unload a possibly unrelated module"

marker_value() {
    local key="$1"
    awk -F= -v wanted="$key" \
        '$1 == wanted { print substr($0, index($0, "=") + 1); found=1; exit } END { if (!found) exit 1 }' \
        "$state_file"
}

marker_format="$(marker_value FORMAT)" || stop "cleanup state is missing FORMAT"
marker_bdf="$(marker_value BDF)" || stop "cleanup state is missing BDF"
marker_boot_id="$(marker_value BOOT_ID)" || stop "cleanup state is missing BOOT_ID"
marker_kernel="$(marker_value KERNEL)" || stop "cleanup state is missing KERNEL"
marker_module="$(marker_value MODULE_PATH)" || stop "cleanup state is missing MODULE_PATH"
marker_module_sha256="$(marker_value MODULE_SHA256)" || stop "cleanup state is missing MODULE_SHA256"

[[ "$marker_format" == "1" ]] || stop "unsupported cleanup-state format"
[[ "$marker_boot_id" == "$(</proc/sys/kernel/random/boot_id)" ]] \
    || stop "cleanup marker belongs to a different boot"
[[ "$marker_kernel" == "$(uname -r)" ]] || stop "cleanup marker kernel does not match the running kernel"
[[ -f "$marker_module" ]] || stop "the module recorded by 04_load_verify.sh no longer exists"
current_module_sha256="$(sha256sum "$marker_module" | awk '{print $1}')"
[[ "$current_module_sha256" == "$marker_module_sha256" ]] \
    || stop "the recorded module file changed after it was loaded"

mapfile -t bdfs < <(lspci -Dnn -d "$expected_id" | awk '{print $1}')
(( ${#bdfs[@]} == 1 )) \
    || stop "expected the one recorded $expected_id endpoint during cleanup; found ${#bdfs[@]}"
printf 'Endpoint=%s\n' "${bdfs[0]}"
[[ "${bdfs[0]}" == "$marker_bdf" ]] || stop "enumerated endpoint does not match the quickstart ownership marker"
driver_path="$(readlink -f "/sys/bus/pci/devices/${bdfs[0]}/driver" 2>/dev/null || true)"
[[ "${driver_path##*/}" == "xdma" ]] || stop "the recorded endpoint is no longer bound to xdma"

shopt -s nullglob
bound_xdma_devices=(/sys/bus/pci/drivers/xdma/????:??:??.?)
shopt -u nullglob
(( ${#bound_xdma_devices[@]} == 1 )) \
    || stop "xdma has ${#bound_xdma_devices[@]} bound PCI devices; refusing a global unload"
[[ "$(basename "${bound_xdma_devices[0]}")" == "$marker_bdf" ]] \
    || stop "the device bound to xdma does not match the quickstart ownership marker"

if (( EUID == 0 )); then
    sudo_cmd=()
else
    command -v sudo >/dev/null 2>&1 || stop "sudo is required to unload xdma"
    sudo_cmd=(sudo)
fi

if command -v fuser >/dev/null 2>&1; then
    printf '\n=== Processes using XDMA nodes ===\n'
    shopt -s nullglob
    xdma_nodes=(/dev/xdma*)
    shopt -u nullglob
    if (( ${#xdma_nodes[@]} == 0 )); then
        printf 'No XDMA device nodes are present.\n'
    else
        "${sudo_cmd[@]}" fuser -v "${xdma_nodes[@]}" 2>/dev/null || true
        if "${sudo_cmd[@]}" fuser "${xdma_nodes[@]}" >/dev/null 2>&1; then
            stop "an XDMA node is still in use; close only the listed test process and retry"
        fi
    fi
else
    printf 'WARN: fuser is unavailable; open-node detection was skipped.\n'
fi

if ! "${sudo_cmd[@]}" rmmod xdma; then
    stop "rmmod xdma failed"
fi
[[ ! -d /sys/module/xdma ]] || stop "xdma is still loaded"
udevadm settle || stop "udev did not settle after unloading xdma"

if compgen -G '/dev/xdma*' >/dev/null; then
    stop "xdma unloaded, but XDMA device nodes still exist"
fi
rm -f -- "$state_file"
printf 'PASS: xdma unloaded and XDMA device nodes disappeared.\n'
printf 'CLEANUP_STATUS=PASS\n'
printf 'CLEANUP_RC=0\n'
printf 'SavedLog=%s\n' "$log_file"
