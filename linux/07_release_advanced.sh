#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Memblaze K7 XDMA Lab contributors

# Bounded release follow-up for the exact repository-generated FPGA image.
# Every XDMA request is at most 64 MiB. The full-memory test writes all 64
# chunks before reading any of them so address aliasing cannot hide behind an
# immediate write/read pair.

set -Eeuo pipefail
export LC_ALL=C
umask 077

usage() {
    cat <<'EOF'
Usage:
  ./07_release_advanced.sh --confirm-ddr-write

Run four read-only XDMA engine-ID checks, a bounded two-channel concurrent
round trip, and a 64 x 64 MiB full-4-GiB DDR write/read comparison. The test
overwrites the complete documented FPGA DDR address range. It never writes
FPGA configuration flash or host block devices.

The confirmation also asserts that the active FPGA image was programmed from
the bitstream produced by this checkout. PCI ID alone cannot prove image
identity; the calling release workflow must separately bind this run to the
JTAG report and exact bitstream SHA-256.

Temporary payloads live only in /dev/shm. Evidence is saved under
$HOME/memblaze-xdma-results/<UTC>.
EOF
}

if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
fi
if (( $# != 1 )) || [[ "$1" != "--confirm-ddr-write" ]]; then
    usage >&2
    exit 2
fi

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
readonly log_file="$result_dir/07_release_advanced.log"
readonly manifest_file="$result_dir/full_4g_pattern_manifest.txt"
readonly dmesg_before_file="$result_dir/dmesg_before_advanced.txt"
readonly dmesg_after_file="$result_dir/dmesg_after_advanced.txt"
readonly pcie_before_file="$result_dir/pcie_path_before_advanced.txt"
readonly pcie_after_file="$result_dir/pcie_path_after_advanced.txt"
readonly pcie_status_before_file="$result_dir/pcie_path_status_before_advanced.txt"
readonly pcie_status_after_file="$result_dir/pcie_path_status_after_advanced.txt"
readonly topology_before_file="$result_dir/pcie_topology_before_advanced.txt"
readonly topology_after_file="$result_dir/pcie_topology_after_advanced.txt"
readonly interrupts_before_file="$result_dir/interrupts_before_advanced.txt"
readonly interrupts_after_file="$result_dir/interrupts_after_advanced.txt"
readonly chunk_size=67108864
readonly chunk_count=64
readonly full_ddr_bytes=4294967296
readonly concurrent_address_ch0=0x10000000
readonly concurrent_address_ch1=0x50000000

mkdir -p "$result_dir"
exec > >(tee "$log_file") 2>&1

stop() {
    printf 'STOP: %s\n' "$*" >&2
    printf 'SavedLog=%s\n' "$log_file" >&2
    exit 1
}

for cmd in awk basename cat cmp cut date df diff dmesg grep head lspci mktemp \
    openssl readlink rm sha256sum tail tee timeout uname wc; do
    command -v "$cmd" >/dev/null 2>&1 || stop "missing command: $cmd"
done

if (( EUID == 0 )); then
    sudo_cmd=()
else
    command -v sudo >/dev/null 2>&1 \
        || stop "sudo is required for XDMA access and complete evidence"
    sudo_cmd=(sudo)
    sudo -v || stop "sudo authentication failed"
fi

mapfile -t bdfs < <(lspci -Dnn -d "$expected_id" | awk '{print $1}')
(( ${#bdfs[@]} == 1 )) \
    || stop "expected exactly one $expected_id endpoint; found ${#bdfs[@]}"
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
    || stop "xdma has ${#bound_xdma_devices[@]} bound PCI devices; refusing advanced DMA"
[[ "$(basename "${bound_xdma_devices[0]}")" == "$bdf" ]] \
    || stop "the PCI device bound to xdma is not the target endpoint"

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

for tool in reg_rw dma_to_device dma_from_device; do
    [[ -x "$tools_dir/$tool" ]] || stop "$tool is missing; run 02_build_driver.sh first"
done
[[ -r "$state_file" ]] \
    || stop "quickstart load ownership marker is missing; run 04_load_verify.sh first"

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

# Four concurrent 64 MiB payload files are live during the two-channel test.
# Keep one additional chunk of headroom for tools and the later full-memory test.
readonly required_shm_bytes=$((5 * chunk_size))
available_shm_bytes="$(df -B1 --output=avail /dev/shm | tail -n 1 | awk '{$1=$1; print}')"
[[ "$available_shm_bytes" =~ ^[0-9]+$ ]] \
    || stop "could not determine free /dev/shm space"
(( available_shm_bytes >= required_shm_bytes )) \
    || stop "/dev/shm needs at least $required_shm_bytes free bytes; found $available_shm_bytes"

temp_dir="$(mktemp -d /dev/shm/memblaze-xdma-advanced.XXXXXXXX)"
active_pids=()
capture_started=0
after_captured=0

terminate_active_jobs() {
    local pid
    if (( ${#active_pids[@]} == 0 )); then
        return 0
    fi
    for pid in "${active_pids[@]}"; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    for pid in "${active_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    active_pids=()
}

capture_pcie_path() {
    local output_file="$1"
    local sysfs_path
    local component
    local -a components
    local -a path_bdfs=()
    sysfs_path="$(readlink -f "/sys/bus/pci/devices/$bdf")"
    IFS='/' read -r -a components <<< "$sysfs_path"
    for component in "${components[@]}"; do
        if [[ "$component" =~ ^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-7]$ ]]; then
            path_bdfs+=("$component")
        fi
    done
    (( ${#path_bdfs[@]} >= 1 )) || return 1
    : > "$output_file"
    for component in "${path_bdfs[@]}"; do
        "${sudo_cmd[@]}" lspci -Dvvnn -s "$component" >> "$output_file" || return 1
        printf '\n' >> "$output_file"
    done
}

extract_pcie_status() {
    local input_file="$1"
    local output_file="$2"
    grep -E '^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-7]|^[[:space:]]+(DevSta:|LnkCap:|LnkSta:|LnkSta2:|AERCap:|UESta:|CESta:|RootSta:)' \
        "$input_file" > "$output_file" || true
}

capture_after() {
    local mode="${1:-strict}"
    local pcie_rc=0
    local topology_rc=0
    local dmesg_rc=0
    capture_pcie_path "$pcie_after_file" || pcie_rc=$?
    if (( pcie_rc == 0 )); then
        extract_pcie_status "$pcie_after_file" "$pcie_status_after_file"
    fi
    lspci -Dtv > "$topology_after_file" || topology_rc=$?
    "${sudo_cmd[@]}" dmesg --time-format=raw > "$dmesg_after_file" || dmesg_rc=$?
    after_captured=1
    printf 'AfterCaptureRC=pcie:%s,topology:%s,dmesg:%s\n' \
        "$pcie_rc" "$topology_rc" "$dmesg_rc"
    if (( pcie_rc != 0 || topology_rc != 0 || dmesg_rc != 0 )); then
        if [[ "$mode" == "strict" ]]; then
            return 1
        fi
        printf 'WARN: failure cleanup could not capture every after-test snapshot.\n' >&2
    fi
    return 0
}

finish() {
    local exit_rc=$?
    trap - EXIT INT TERM
    set +e
    terminate_active_jobs
    if (( capture_started == 1 && after_captured == 0 )); then
        capture_after best-effort
    fi
    if [[ -n "$temp_dir" && "$temp_dir" == /dev/shm/memblaze-xdma-advanced.* ]]; then
        rm -rf -- "$temp_dir"
    fi
    exit "$exit_rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'UTC=%s\n' "$(date -u +%FT%TZ)"
printf 'Endpoint=%s\n' "$bdf"
printf 'Subsystem=%s:%s\n' "$subsystem_vendor" "$subsystem_device"
printf 'ImageRequirement=bitstream-produced-by-this-checkout\n'
printf 'DDRWriteConfirmation=--confirm-ddr-write\n'
printf 'MAX_DMA_REQUEST_BYTES=%s\n' "$chunk_size"
printf 'FULL_DDR_BYTES=%s\n' "$full_ddr_bytes"
printf 'WARNING: this test overwrites the complete documented 4 GiB FPGA DDR range.\n'

capture_pcie_path "$pcie_before_file" \
    || stop "could not capture the endpoint PCIe path before testing"
extract_pcie_status "$pcie_before_file" "$pcie_status_before_file"
lspci -Dtv > "$topology_before_file"
"${sudo_cmd[@]}" dmesg --time-format=raw > "$dmesg_before_file"
readonly dmesg_lines_before="$(wc -l < "$dmesg_before_file")"
capture_started=1

printf '\n=== XDMA engine identifiers (read-only) ===\n'
read_engine_identifier() {
    local label="$1"
    local offset="$2"
    local expected_family="$3"
    local expected_channel="$4"
    local output
    local value
    output="$("${sudo_cmd[@]}" "$tools_dir/reg_rw" /dev/xdma0_control "$offset" w)" \
        || stop "reg_rw failed for $label at $offset"
    printf '%s\n' "$output"
    # The pinned vendor reg_rw prints "Read 32-bit value at address ...".
    # Select its final field, then validate the complete 32-bit hex token below.
    value="$(awk '/Read 32-bit value at address/ { candidate=$NF } END { print candidate }' \
        <<< "$output")"
    value="${value,,}"
    [[ "$value" =~ ^0x[0-9a-f]{8}$ ]] \
        || stop "could not parse the $label identifier at $offset"
    printf 'ENGINE_ID_%s=%s\n' "$label" "$value"
    (( (value & 0xffff0000) == expected_family )) \
        || stop "$label identifier $value is outside the expected family"
    (( ((value & 0x00000f00) >> 8) == expected_channel )) \
        || stop "$label identifier $value has the wrong channel number"
    (( (value & 0x000000ff) == 0x06 )) \
        || stop "$label identifier $value has an unexpected interface version"
}
read_engine_identifier H2C0 0x0000 0x1fc00000 0
read_engine_identifier H2C1 0x0100 0x1fc00000 1
read_engine_identifier C2H0 0x1000 0x1fc10000 0
read_engine_identifier C2H1 0x1100 0x1fc10000 1
printf 'CONTROL_ENGINE_IDENTIFIERS=PASS\n'

printf '\n=== XDMA interrupt-mode baseline ===\n'
poll_mode=unavailable
interrupt_mode=unavailable
[[ -r /sys/module/xdma/parameters/poll_mode ]] \
    && poll_mode="$(</sys/module/xdma/parameters/poll_mode)"
[[ -r /sys/module/xdma/parameters/interrupt_mode ]] \
    && interrupt_mode="$(</sys/module/xdma/parameters/interrupt_mode)"
printf 'POLL_MODE=%s\n' "$poll_mode"
printf 'INTERRUPT_MODE=%s\n' "$interrupt_mode"
cat /proc/interrupts > "$interrupts_before_file"

irq_reliable=0
irq_count_before=0
target_irqs=()
shopt -s nullglob
msi_irq_entries=(/sys/bus/pci/devices/"$bdf"/msi_irqs/*)
shopt -u nullglob
if [[ "$poll_mode" == "0" && ${#msi_irq_entries[@]} -gt 0 ]]; then
    irq_reliable=1
    for irq_entry in "${msi_irq_entries[@]}"; do
        irq_number="${irq_entry##*/}"
        if [[ ! "$irq_number" =~ ^[0-9]+$ ]] \
            || (( $(grep -Ec "^[[:space:]]*${irq_number}:" "$interrupts_before_file") != 1 )); then
            irq_reliable=0
            break
        fi
        target_irqs+=("$irq_number")
    done
fi

sum_irq_counts() {
    local interrupts_file="$1"
    shift
    local irq_number
    local line
    local subtotal
    local total=0
    for irq_number in "$@"; do
        line="$(grep -E "^[[:space:]]*${irq_number}:" "$interrupts_file")" || return 1
        subtotal="$(awk '{ value=0; for (i=2; i<=NF; i++) { if ($i ~ /^[0-9]+$/) value += $i; else break } print value }' <<< "$line")"
        [[ "$subtotal" =~ ^[0-9]+$ ]] || return 1
        total=$((total + subtotal))
    done
    printf '%s' "$total"
}

if (( irq_reliable == 1 )); then
    irq_count_before="$(sum_irq_counts "$interrupts_before_file" "${target_irqs[@]}")" \
        || irq_reliable=0
fi
if (( irq_reliable == 1 )); then
    printf 'XDMA_IRQ_SOURCE=dedicated-msi-vectors\n'
    printf 'XDMA_IRQ_VECTORS=%s\n' "${target_irqs[*]}"
    printf 'XDMA_IRQ_COUNT_BEFORE=%s\n' "$irq_count_before"
else
    printf 'XDMA_IRQ_SOURCE=unavailable\n'
    printf 'IRQ_DELTA_STATUS=UNAVAILABLE\n'
    printf 'IRQ_DELTA_REASON=no-reliably-attributable-dedicated-MSI-vector-or-poll-mode-is-not-zero\n'
fi

make_pattern() {
    local output_file="$1"
    local byte_count="$2"
    local label="$3"
    local absolute_address="$4"
    local seed_text
    local key_hex
    local iv_hex
    printf -v seed_text 'memblaze-xdma-release-v1:%s:%s:%016x' \
        "$label" "$byte_count" "$absolute_address"
    key_hex="$(printf '%s:key' "$seed_text" | sha256sum | awk '{print $1}')"
    iv_hex="$(printf '%s:iv' "$seed_text" | sha256sum | awk '{print $1}' | cut -c1-32)"
    head -c "$byte_count" /dev/zero \
        | openssl enc -aes-256-ctr -K "$key_hex" -iv "$iv_hex" -nosalt \
        > "$output_file"
    [[ "$(wc -c < "$output_file")" -eq "$byte_count" ]] \
        || stop "pattern generator produced the wrong size"
}

wall_rate_mib_per_s() {
    local byte_count="$1"
    local elapsed_ns="$2"
    awk -v bytes="$byte_count" -v ns="$elapsed_ns" \
        'BEGIN { if (ns <= 0) exit 1; printf "%.3f", (bytes / 1048576) / (ns / 1000000000) }'
}

launch_transfer() {
    local direction="$1"
    local channel="$2"
    local data_file="$3"
    local byte_count="$4"
    local address_text="$5"
    local command_log="$6"
    local node
    local tool
    if [[ "$direction" == "h2c" ]]; then
        node="/dev/xdma0_h2c_$channel"
        tool="$tools_dir/dma_to_device"
    else
        node="/dev/xdma0_c2h_$channel"
        tool="$tools_dir/dma_from_device"
        : > "$data_file"
    fi
    "${sudo_cmd[@]}" timeout --signal=INT --kill-after=2s 60s \
        "$tool" -d "$node" -f "$data_file" -s "$byte_count" \
        -a "$address_text" -c 1 -v > "$command_log" 2>&1 &
    launched_pid=$!
    active_pids+=("$launched_pid")
}

wait_pair() {
    local label="$1"
    local pid0="$2"
    local pid1="$3"
    local log0="$4"
    local log1="$5"
    local rc0
    local rc1
    set +e
    wait "$pid0"
    rc0=$?
    wait "$pid1"
    rc1=$?
    set -e
    active_pids=()
    printf '\n--- %s channel 0 output ---\n' "$label"
    cat "$log0"
    printf '\n--- %s channel 1 output ---\n' "$label"
    cat "$log1"
    printf '%s_RC_CH0=%s\n' "$label" "$rc0"
    printf '%s_RC_CH1=%s\n' "$label" "$rc1"
    (( rc0 == 0 && rc1 == 0 )) || stop "$label concurrent transfer failed"
}

printf '\n=== Concurrent two-channel 64 MiB round trip ===\n'
make_pattern "$temp_dir/concurrent_tx_ch0.bin" "$chunk_size" concurrent-ch0 "$concurrent_address_ch0"
make_pattern "$temp_dir/concurrent_tx_ch1.bin" "$chunk_size" concurrent-ch1 "$concurrent_address_ch1"
printf 'CONCURRENT_CH0_ADDRESS=0x%08x\n' "$concurrent_address_ch0"
printf 'CONCURRENT_CH1_ADDRESS=0x%08x\n' "$concurrent_address_ch1"
printf 'CONCURRENT_BYTES_PER_CHANNEL=%s\n' "$chunk_size"

concurrent_h2c_start_ns="$(date +%s%N)"
launch_transfer h2c 0 "$temp_dir/concurrent_tx_ch0.bin" "$chunk_size" \
    0x10000000 "$temp_dir/concurrent_h2c_ch0.log"
pid0="$launched_pid"
launch_transfer h2c 1 "$temp_dir/concurrent_tx_ch1.bin" "$chunk_size" \
    0x50000000 "$temp_dir/concurrent_h2c_ch1.log"
pid1="$launched_pid"
wait_pair CONCURRENT_H2C "$pid0" "$pid1" \
    "$temp_dir/concurrent_h2c_ch0.log" "$temp_dir/concurrent_h2c_ch1.log"
concurrent_h2c_end_ns="$(date +%s%N)"

concurrent_c2h_start_ns="$(date +%s%N)"
launch_transfer c2h 0 "$temp_dir/concurrent_rx_ch0.bin" "$chunk_size" \
    0x10000000 "$temp_dir/concurrent_c2h_ch0.log"
pid0="$launched_pid"
launch_transfer c2h 1 "$temp_dir/concurrent_rx_ch1.bin" "$chunk_size" \
    0x50000000 "$temp_dir/concurrent_c2h_ch1.log"
pid1="$launched_pid"
wait_pair CONCURRENT_C2H "$pid0" "$pid1" \
    "$temp_dir/concurrent_c2h_ch0.log" "$temp_dir/concurrent_c2h_ch1.log"
concurrent_c2h_end_ns="$(date +%s%N)"

cmp --silent "$temp_dir/concurrent_tx_ch0.bin" "$temp_dir/concurrent_rx_ch0.bin" \
    || stop "concurrent channel 0 data mismatch"
cmp --silent "$temp_dir/concurrent_tx_ch1.bin" "$temp_dir/concurrent_rx_ch1.bin" \
    || stop "concurrent channel 1 data mismatch"
printf 'CONCURRENT_CH0_SHA256=%s\n' \
    "$(sha256sum "$temp_dir/concurrent_rx_ch0.bin" | awk '{print $1}')"
printf 'CONCURRENT_CH1_SHA256=%s\n' \
    "$(sha256sum "$temp_dir/concurrent_rx_ch1.bin" | awk '{print $1}')"
printf 'CONCURRENT_H2C_WALL_NS=%s\n' "$((concurrent_h2c_end_ns - concurrent_h2c_start_ns))"
printf 'CONCURRENT_C2H_WALL_NS=%s\n' "$((concurrent_c2h_end_ns - concurrent_c2h_start_ns))"
printf 'CONCURRENT_H2C_AGGREGATE_WALL_MIB_PER_S=%s\n' \
    "$(wall_rate_mib_per_s "$((2 * chunk_size))" "$((concurrent_h2c_end_ns - concurrent_h2c_start_ns))")"
printf 'CONCURRENT_C2H_AGGREGATE_WALL_MIB_PER_S=%s\n' \
    "$(wall_rate_mib_per_s "$((2 * chunk_size))" "$((concurrent_c2h_end_ns - concurrent_c2h_start_ns))")"
printf 'CONCURRENT_DMA=PASS\n'
rm -f -- "$temp_dir"/concurrent_*.bin "$temp_dir"/concurrent_*.log

full_h2c_elapsed_ns=0
full_c2h_elapsed_ns=0

run_h2c() {
    local input_file="$1"
    local address_text="$2"
    local start_ns
    local end_ns
    local transfer_rc
    start_ns="$(date +%s%N)"
    set +e
    "${sudo_cmd[@]}" timeout --signal=INT --kill-after=2s 60s \
        "$tools_dir/dma_to_device" -d /dev/xdma0_h2c_0 -f "$input_file" \
        -s "$chunk_size" -a "$address_text" -c 1 -v
    transfer_rc=$?
    set -e
    end_ns="$(date +%s%N)"
    full_h2c_elapsed_ns=$((full_h2c_elapsed_ns + end_ns - start_ns))
    printf 'H2C_RC=%s address=%s size=%s\n' "$transfer_rc" "$address_text" "$chunk_size"
    (( transfer_rc == 0 )) || stop "full-4g H2C failed at $address_text"
}

run_c2h() {
    local output_file="$1"
    local address_text="$2"
    local start_ns
    local end_ns
    local transfer_rc
    : > "$output_file"
    start_ns="$(date +%s%N)"
    set +e
    "${sudo_cmd[@]}" timeout --signal=INT --kill-after=2s 60s \
        "$tools_dir/dma_from_device" -d /dev/xdma0_c2h_0 -f "$output_file" \
        -s "$chunk_size" -a "$address_text" -c 1 -v
    transfer_rc=$?
    set -e
    end_ns="$(date +%s%N)"
    full_c2h_elapsed_ns=$((full_c2h_elapsed_ns + end_ns - start_ns))
    printf 'C2H_RC=%s address=%s size=%s\n' "$transfer_rc" "$address_text" "$chunk_size"
    (( transfer_rc == 0 )) || stop "full-4g C2H failed at $address_text"
}

printf '\n=== Full 4 GiB phase 1: write 64 distinct 64 MiB chunks ===\n'
for (( chunk=0; chunk<chunk_count; chunk++ )); do
    absolute_address=$((chunk * chunk_size))
    printf -v address_text '0x%08x' "$absolute_address"
    make_pattern "$temp_dir/full4g_tx.bin" "$chunk_size" full-4g "$absolute_address"
    pattern_hash="$(sha256sum "$temp_dir/full4g_tx.bin" | awk '{print $1}')"
    printf 'WRITE chunk=%s address=%s size=%s sha256=%s\n' \
        "$chunk" "$address_text" "$chunk_size" "$pattern_hash" \
        | tee -a "$manifest_file"
    run_h2c "$temp_dir/full4g_tx.bin" "$address_text"
done

printf '\n=== Full 4 GiB phase 2: regenerate, read and compare all chunks ===\n'
for (( chunk=0; chunk<chunk_count; chunk++ )); do
    absolute_address=$((chunk * chunk_size))
    printf -v address_text '0x%08x' "$absolute_address"
    make_pattern "$temp_dir/full4g_expected.bin" "$chunk_size" full-4g "$absolute_address"
    run_c2h "$temp_dir/full4g_actual.bin" "$address_text"
    expected_hash="$(sha256sum "$temp_dir/full4g_expected.bin" | awk '{print $1}')"
    actual_hash="$(sha256sum "$temp_dir/full4g_actual.bin" | awk '{print $1}')"
    set +e
    cmp --silent "$temp_dir/full4g_expected.bin" "$temp_dir/full4g_actual.bin"
    compare_rc=$?
    set -e
    printf 'VERIFY chunk=%s address=%s size=%s expected_sha256=%s actual_sha256=%s cmp_rc=%s\n' \
        "$chunk" "$address_text" "$chunk_size" "$expected_hash" "$actual_hash" \
        "$compare_rc" | tee -a "$manifest_file"
    (( compare_rc == 0 )) || stop "full-4g data mismatch at $address_text"
done

printf 'FULL_4G_H2C_WALL_NS=%s\n' "$full_h2c_elapsed_ns"
printf 'FULL_4G_C2H_WALL_NS=%s\n' "$full_c2h_elapsed_ns"
printf 'FULL_4G_H2C_TRANSFER_WALL_MIB_PER_S=%s\n' \
    "$(wall_rate_mib_per_s "$full_ddr_bytes" "$full_h2c_elapsed_ns")"
printf 'FULL_4G_C2H_TRANSFER_WALL_MIB_PER_S=%s\n' \
    "$(wall_rate_mib_per_s "$full_ddr_bytes" "$full_c2h_elapsed_ns")"
printf 'FULL_4G_CHUNK_COUNT=%s\n' "$chunk_count"
printf 'FULL_4G_BYTES_COVERED=%s\n' "$full_ddr_bytes"
printf 'CHUNKED_4G=PASS\n'

capture_after strict || stop "failed to capture complete after-test evidence"

printf '\n=== XDMA channel-interrupt evidence ===\n'
cat /proc/interrupts > "$interrupts_after_file"
if (( irq_reliable == 1 )); then
    irq_count_after="$(sum_irq_counts "$interrupts_after_file" "${target_irqs[@]}")" \
        || stop "dedicated MSI vectors disappeared from /proc/interrupts"
    printf 'XDMA_IRQ_COUNT_AFTER=%s\n' "$irq_count_after"
    if (( irq_count_after > irq_count_before )); then
        printf 'XDMA_IRQ_COUNT_DELTA=%s\n' "$((irq_count_after - irq_count_before))"
        printf 'IRQ_DELTA_STATUS=PASS\n'
    else
        stop "dedicated XDMA MSI interrupt count did not increase during DMA"
    fi
fi

printf '\n=== Kernel and PCIe path deltas ===\n'
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
    | grep -Ei 'xdma|aer|pcie|timeout|fatal|error|fault|iommu' || true)"
if [[ -n "$new_messages" ]]; then
    printf '%s\n' "$new_messages"
    stop "data matched, but new relevant kernel messages require review"
fi
printf 'NEW_RELEVANT_KERNEL_MESSAGES=none\n'

printf 'PCIE_PATH_BEFORE_SHA256=%s\n' \
    "$(sha256sum "$pcie_before_file" | awk '{print $1}')"
printf 'PCIE_PATH_AFTER_SHA256=%s\n' \
    "$(sha256sum "$pcie_after_file" | awk '{print $1}')"
printf 'PCIE_TOPOLOGY_BEFORE_SHA256=%s\n' \
    "$(sha256sum "$topology_before_file" | awk '{print $1}')"
printf 'PCIE_TOPOLOGY_AFTER_SHA256=%s\n' \
    "$(sha256sum "$topology_after_file" | awk '{print $1}')"
if cmp --silent "$pcie_status_before_file" "$pcie_status_after_file"; then
    printf 'PCIE_PATH_STATUS_STABLE=yes\n'
    aer_status_lines_before="$(grep -Ec '^[[:space:]]+(AERCap:|UESta:|CESta:|RootSta:)' \
        "$pcie_status_before_file" || true)"
    aer_status_lines_after="$(grep -Ec '^[[:space:]]+(AERCap:|UESta:|CESta:|RootSta:)' \
        "$pcie_status_after_file" || true)"
    if (( aer_status_lines_before > 0 && aer_status_lines_after > 0 )); then
        printf 'AER_STATUS_CAPTURED=before-and-after\n'
        printf 'AER_STATUS_STABLE=yes\n'
    else
        printf 'AER_STATUS_CAPTURED=UNAVAILABLE\n'
        printf 'AER_STATUS_STABLE=UNAVAILABLE\n'
        printf 'AER_STATUS_REASON=no-AER-status-register-lines-exposed-by-lspci-on-the-sysfs-path\n'
    fi
else
    printf '%s\n' '--- PCIe path status changed during the test ---'
    diff -u "$pcie_status_before_file" "$pcie_status_after_file" || true
    stop "PCIe link/device/AER status changed during the advanced test"
fi

printf '\nPASS: engine IDs, concurrent DMA, and full 4 GiB comparison completed.\n'
printf 'ADVANCED_RELEASE_VALIDATION=PASS\n'
printf 'SavedResult=%s\n' "$result_dir"
