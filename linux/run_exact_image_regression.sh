#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Memblaze K7 XDMA Lab contributors

# Protected one-session physical regression for a repository-built bitstream.
# This script is intentionally limited to a persistent Ubuntu Live USB. It
# writes FPGA external DDR and files below HOME and /dev/shm. It does not write
# FPGA configuration flash, host block devices, EFI, BitLocker data, Secure
# Boot state, or MOK enrollment state.

set -Eeuo pipefail
export LC_ALL=C
umask 077

# Argument parsing below consumes "$@" with shift. Preserve the original list
# because systemd-inhibit re-executes this script after parsing.
original_args=("$@")
readonly -a original_args

usage() {
    cat <<'EOF'
Usage:
  ./linux/run_exact_image_regression.sh \
    --confirm-exact-image-and-ddr-write \
    --bitstream /path/to/memblaze_k7_xdma_wrapper.bit \
    --bitstream-sha256 /path/to/memblaze_k7_xdma_wrapper.bit.sha256 \
    --jtag-report /path/to/jtag_program_status.txt \
    --jtag-report-sha256 /path/to/jtag_program_status.txt.sha256 \
    --mok-certificate /path/to/enrolled-MOK.der \
    --mok-private /path/to/enrolled-MOK.priv \
    --expected-live-disk-serial-prefix SERIAL_PREFIX \
    [--expected-bitstream-sha256 64_LOWERCASE_HEX]

The FPGA must already have been programmed over JTAG from the supplied,
repository-built bitstream, and its external power must have remained on while
the host booted Ubuntu. Both files and both hash sidecars are read-only inputs
from the Windows step. Each sidecar contains only one SHA-256 token.

This protected wrapper requires:
  * the validated persistent Ubuntu Live USB and its persistence marker;
  * no NVMe, device-mapper, or EFI filesystem mounted;
  * Secure Boot still enabled;
  * an already-enrolled MOK certificate and its existing private key;
  * exactly one 10ee:7024 / subsystem 10ee:0007 endpoint;
  * permission to overwrite the tested ranges of volatile FPGA DDR.

It never imports or creates a MOK. If enrollment is not already complete, it
stops and leaves evidence; do not start this run expecting an enrollment reboot.
EOF
}

die_usage() {
    printf 'ERROR: %s\n\n' "$*" >&2
    usage >&2
    exit 2
}

confirmation=0
bitstream=""
bitstream_sha_file=""
jtag_report=""
jtag_report_sha_file=""
mok_certificate=""
mok_private=""
expected_live_serial=""
expected_hash_arg=""

while (( $# > 0 )); do
    case "$1" in
        --confirm-exact-image-and-ddr-write)
            confirmation=1
            shift
            ;;
        --bitstream|--bitstream-sha256|--jtag-report|--jtag-report-sha256|--mok-certificate|--mok-private|--expected-live-disk-serial-prefix|--expected-bitstream-sha256)
            (( $# >= 2 )) || die_usage "$1 requires a value"
            case "$1" in
                --bitstream) bitstream="$2" ;;
                --bitstream-sha256) bitstream_sha_file="$2" ;;
                --jtag-report) jtag_report="$2" ;;
                --jtag-report-sha256) jtag_report_sha_file="$2" ;;
                --mok-certificate) mok_certificate="$2" ;;
                --mok-private) mok_private="$2" ;;
                --expected-live-disk-serial-prefix) expected_live_serial="$2" ;;
                --expected-bitstream-sha256) expected_hash_arg="$2" ;;
            esac
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die_usage "unknown argument: $1"
            ;;
    esac
done

(( confirmation == 1 )) || die_usage "the explicit DDR-write and exact-image confirmation is required"
[[ -n "$bitstream" ]] || die_usage "--bitstream is required"
[[ -n "$bitstream_sha_file" ]] || die_usage "--bitstream-sha256 is required"
[[ -n "$jtag_report" ]] || die_usage "--jtag-report is required"
[[ -n "$jtag_report_sha_file" ]] || die_usage "--jtag-report-sha256 is required"
[[ -n "$mok_certificate" ]] || die_usage "--mok-certificate is required"
[[ -n "$mok_private" ]] || die_usage "--mok-private is required"
[[ -n "$expected_live_serial" ]] || die_usage "--expected-live-disk-serial-prefix is required"

for value in "$bitstream" "$bitstream_sha_file" "$jtag_report" "$jtag_report_sha_file" \
    "$mok_certificate" "$mok_private" "$expected_live_serial" "$expected_hash_arg"; do
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] \
        || die_usage "argument values must not contain line breaks"
done
[[ "$expected_live_serial" =~ ^[[:graph:]]+$ ]] \
    || die_usage "the expected Live-USB serial must be one non-whitespace value"
(( ${#expected_live_serial} >= 16 )) \
    || die_usage "the expected Live-USB serial prefix must contain at least 16 characters"
if [[ -n "$expected_hash_arg" ]]; then
    [[ "$expected_hash_arg" =~ ^[0-9a-f]{64}$ ]] \
        || die_usage "--expected-bitstream-sha256 must be 64 lowercase hexadecimal characters"
fi

# Acquire a session-scoped idle inhibitor after argument/help handling and
# before any long operation. No persistent power setting is changed.
if [[ "${MEMBLAZE_IDLE_INHIBITED:-0}" != "1" ]]; then
    command -v systemd-inhibit >/dev/null 2>&1 || {
        printf 'ERROR: systemd-inhibit is required to prevent idle suspend during this run\n' >&2
        exit 1
    }
    exec systemd-inhibit \
        --what=idle \
        --mode=block \
        --who=memblaze-k7-xdma-lab \
        --why='Protected one-session FPGA DDR regression' \
        env MEMBLAZE_IDLE_INHIBITED=1 bash "$0" "${original_args[@]}"
fi

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly kit_root="$(cd -- "$script_dir/.." && pwd)"
readonly dmesg_helper="$script_dir/lib/dmesg_capture.sh"
readonly kernel_error_filter="$script_dir/lib/kernel_error_filter.sh"
readonly manifest="$kit_root/RELEASE_MANIFEST.json"
readonly validator="$kit_root/tools/validate_repo.py"
readonly kernel_log_contract="$kit_root/tools/test_dmesg_capture.sh"
readonly kernel_error_contract="$kit_root/tools/test_kernel_error_filter.sh"
readonly expected_id="10ee:7024"
readonly expected_subsystem_vendor="0x10ee"
readonly expected_subsystem_device="0x0007"
readonly build_tag="b8466090-aba9086b051e"
readonly kernel_release="$(uname -r)"
readonly kernel_build_dir="/lib/modules/$kernel_release/build"
readonly kernel_sign_file="$kernel_build_dir/scripts/sign-file"
readonly standard_build_root="${HOME:?HOME is not set}/memblaze-xdma-work/$build_tag/$kernel_release"
readonly module="$standard_build_root/dma_ip_drivers-b8466090/XDMA/linux-kernel/xdma/xdma.ko"
readonly results_root="$HOME/memblaze-xdma-results"
readonly persistence_marker="$HOME/XDMA_PERSISTENCE_MARKER.txt"

stop_before_write() {
    printf 'STOP_BEFORE_WRITE: %s\n' "$*" >&2
    exit 1
}

stop_before_dma() {
    printf 'STOP_BEFORE_DMA: %s\n' "$*" >&2
    exit 1
}

# This list is checked before mkdir, tee, build extraction, signing, or other
# persistent writes. sudo authentication only creates an ephemeral timestamp.
for cmd in awk bash basename cat cmp cp cut date df dirname dmesg env find findmnt \
    gcc grep head id lspci lsblk make mkdir mktemp modinfo mokutil mv nproc \
    openssl patch python3 readlink rm sed sha256sum sleep sort stat sudo tail \
    tar tee timeout touch tr uname wc xargs; do
    command -v "$cmd" >/dev/null 2>&1 || stop_before_write "missing command: $cmd"
done
[[ -r "$manifest" ]] || stop_before_write "release manifest is missing"
[[ -r "$validator" ]] || stop_before_write "repository validator is missing"
[[ -r "$dmesg_helper" ]] || stop_before_write "kernel-log helper is missing"
[[ -r "$kernel_error_filter" ]] || stop_before_write "kernel-error filter is missing"
[[ -r "$kernel_log_contract" ]] \
    || stop_before_write "kernel-log runtime contract is missing"
[[ -r "$kernel_error_contract" ]] \
    || stop_before_write "kernel-error runtime contract is missing"
# shellcheck source=linux/lib/dmesg_capture.sh
source "$dmesg_helper" || stop_before_write "kernel-log helper could not be loaded"
# shellcheck source=linux/lib/kernel_error_filter.sh
source "$kernel_error_filter" || stop_before_write "kernel-error filter could not be loaded"
sudo_cmd=(sudo)
[[ -r "$bitstream" ]] || stop_before_write "bitstream is unreadable: $bitstream"
[[ -r "$bitstream_sha_file" ]] \
    || stop_before_write "bitstream SHA-256 sidecar is unreadable: $bitstream_sha_file"
[[ -r "$jtag_report" ]] || stop_before_write "JTAG report is unreadable: $jtag_report"
[[ -r "$jtag_report_sha_file" ]] \
    || stop_before_write "JTAG-report SHA-256 sidecar is unreadable: $jtag_report_sha_file"

printf '\n=== Pre-write read-only storage boundary ===\n'
storage_lsblk="$(lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS,MODEL,SERIAL,TRAN)"
storage_findmnt="$(findmnt)"
home_source="$(findmnt -rn -T "$HOME" -o SOURCE)"
printf '%s\n' "$storage_lsblk"
printf '%s\n' "$storage_findmnt"
printf 'HOME_SOURCE=%s\n' "$home_source"

protected_mounts="$(findmnt -rn -o SOURCE,TARGET \
    | awk '$1 ~ /^\/dev\/(nvme[0-9]|mapper\/|dm-)/ { print }')"
[[ -z "$protected_mounts" ]] \
    || stop_before_write "an NVMe or device-mapper filesystem is mounted: $protected_mounts"
storage_swaps="$(awk 'NR > 1 { print }' /proc/swaps)"
protected_swaps="$(awk 'NR > 1 && $1 ~ /^\/dev\/(nvme[0-9]|mapper\/|dm-)/ { print }' \
    /proc/swaps)"
[[ -z "$protected_swaps" ]] \
    || stop_before_write "an NVMe or device-mapper swap is active: $protected_swaps"
[[ "$home_source" != /dev/nvme* && "$home_source" != /dev/mapper/* && "$home_source" != /dev/dm-* ]] \
    || stop_before_write "HOME resolves to a protected block source: $home_source"
if findmnt -rn -M /boot/efi >/dev/null 2>&1; then
    stop_before_write "/boot/efi is mounted"
fi

[[ -s "$persistence_marker" ]] || stop_before_write "the validated persistence marker is missing"
persistence_marker_line="$(head -n 1 "$persistence_marker")"
[[ "$persistence_marker_line" == 'XDMA persistence marker: '* ]] \
    || stop_before_write "the persistence marker has an unexpected format"
root_source="$(findmnt -rn -T / -o SOURCE)"
root_options="$(findmnt -rn -T / -o OPTIONS)"
[[ "$root_source" == "/cow" ]] \
    || stop_before_write "root source is '$root_source', expected the persistent Live-USB /cow overlay"
[[ ",$root_options," == *,rw,* ]] || stop_before_write "the root overlay is not read-write"

cow_device="$(readlink -f /dev/disk/by-label/casper-rw 2>/dev/null || true)"
[[ "$cow_device" == /dev/sd* ]] \
    || stop_before_write "casper-rw does not resolve to the expected removable-disk naming class"
cow_label="$(lsblk -dn -o LABEL "$cow_device" | awk '{$1=$1; print}')"
[[ "$cow_label" == "casper-rw" ]] || stop_before_write "the persistence label is not casper-rw"
cow_parent_name="$(lsblk -dn -o PKNAME "$cow_device" | awk '{$1=$1; print}')"
[[ -n "$cow_parent_name" ]] || stop_before_write "the persistence parent disk could not be identified"
cow_parent="/dev/$cow_parent_name"
cow_serial="$(lsblk -dn -o SERIAL "$cow_parent" | awk '{$1=$1; print}')"
[[ "$cow_serial" == "$expected_live_serial"* ]] \
    || stop_before_write "the persistence disk serial does not match --expected-live-disk-serial-prefix"

sudo -v || stop_before_write "sudo authentication failed"

[[ "$(uname -m)" == "x86_64" ]] \
    || stop_before_write "the pinned XDMA driver workflow requires an x86_64 Linux host"
[[ -e "$kernel_build_dir/Makefile" ]] \
    || stop_before_write "kernel headers are missing for $kernel_release"
[[ -x "$kernel_sign_file" ]] \
    || stop_before_write "kernel module sign-file is missing for $kernel_release"
sudo test -f "$mok_certificate" && [[ -r "$mok_certificate" ]] \
    || stop_before_write "the supplied MOK certificate is not a regular file readable by the current user"
sudo test -f "$mok_private" && sudo test -r "$mok_private" \
    || stop_before_write "the supplied MOK private key is not a readable regular file"
mok_private_owner_mode="$(sudo stat -Lc '%u:%a' "$mok_private")" \
    || stop_before_write "the MOK private-key owner and mode could not be read"
readonly mok_private_owner_mode
case "$mok_private_owner_mode" in
    0:400|0:600|"$(id -u)":400|"$(id -u)":600) ;;
    *)
        stop_before_write "the MOK private key owner/mode must be root or the current user with mode 400 or 600"
        ;;
esac
sudo openssl x509 -inform DER -in "$mok_certificate" -noout -serial >/dev/null 2>&1 \
    || stop_before_write "the supplied MOK certificate is not a readable DER X.509 certificate"
certificate_public_key_sha="$(
    sudo openssl x509 -inform DER -in "$mok_certificate" -pubkey -noout 2>/dev/null \
        | openssl pkey -pubin -outform DER 2>/dev/null \
        | sha256sum | awk '{print $1}'
)" || stop_before_write "the MOK certificate public key could not be read"
private_public_key_sha="$(
    sudo openssl pkey -in "$mok_private" -passin pass: -pubout -outform DER 2>/dev/null \
        | sha256sum | awk '{print $1}'
)" || stop_before_write "the MOK private key could not be parsed non-interactively"
[[ "$certificate_public_key_sha" =~ ^[0-9a-f]{64}$ \
   && "$private_public_key_sha" == "$certificate_public_key_sha" ]] \
    || stop_before_write "the supplied MOK private key does not match the certificate"
set +e
mok_test_output="$(mokutil --test-key "$mok_certificate" 2>&1)"
mok_test_rc=$?
set -e
if ! grep -Fx -- "$mok_certificate is already enrolled" <<< "$mok_test_output" >/dev/null \
    && ! grep -Fx -- "$mok_certificate is already in the built-in trusted keyring" \
        <<< "$mok_test_output" >/dev/null; then
    printf 'MOK_TEST_KEY_RC=%s\n%s\n' "$mok_test_rc" "$mok_test_output" >&2
    stop_before_write "the supplied MOK certificate is not confirmed as enrolled"
fi
printf 'EARLY_TOOLCHAIN_AND_MOK_PREFLIGHT=PASS\n'

boot_dmesg=""
boot_dmesg_diagnostics=""
if ! memblaze_select_kernel_log_text boot_dmesg boot_dmesg_diagnostics; then
    printf '%s\n' "$boot_dmesg_diagnostics" >&2
    stop_before_write "the current kernel log could not be read from dmesg or the current-boot kernel journal"
fi
printf 'KERNEL_LOG_BACKEND=%s\n' "$MEMBLAZE_KERNEL_LOG_BACKEND"
if [[ -n "$boot_dmesg_diagnostics" ]]; then
    printf 'WARN: dmesg was unavailable; using the current-boot kernel journal for this run.\n' >&2
    printf '%s\n' "$boot_dmesg_diagnostics" >&2
fi
if secure_boot_output="$(mokutil --sb-state 2>&1)"; then
    secure_boot_rc=0
else
    secure_boot_rc=$?
fi
storage_errors="$(grep -Ei \
    'attempt to access beyond end of device|Buffer I/O error|JBD2:.*error|Remounting filesystem read-only' \
    <<< "$boot_dmesg" || true)"
[[ -z "$storage_errors" ]] || {
    printf '%s\n' "$storage_errors" >&2
    stop_before_write "the current boot log contains storage I/O, journal, or read-only-remount errors"
}
(( secure_boot_rc == 0 )) || stop_before_write "Secure Boot state could not be read"
grep -Fxi 'SecureBoot enabled' <<< "$secure_boot_output" >/dev/null \
    || stop_before_write "Secure Boot is not enabled; refusing a changed boot-policy boundary"

home_available_bytes="$(df -B1 --output=avail "$HOME" | tail -n 1 | awk '{$1=$1; print}')"
shm_available_bytes="$(df -B1 --output=avail /dev/shm | tail -n 1 | awk '{$1=$1; print}')"
mem_available_kib="$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo)"
[[ "$home_available_bytes" =~ ^[0-9]+$ && "$home_available_bytes" -ge 2147483648 ]] \
    || stop_before_write "HOME needs at least 2 GiB free"
[[ "$shm_available_bytes" =~ ^[0-9]+$ && "$shm_available_bytes" -ge 402653184 ]] \
    || stop_before_write "/dev/shm needs at least 384 MiB free"
[[ "$mem_available_kib" =~ ^[0-9]+$ && "$mem_available_kib" -ge 524288 ]] \
    || stop_before_write "MemAvailable is below 512 MiB"

manifest_values="$(python3 - "$manifest" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    manifest = json.load(stream)
clean = manifest.get("fpga_design", {}).get("clean_build", {})
value = clean.get("bitstream_sha256")
if clean.get("status") != "pass" or clean.get("bitstream_generated") is not True:
    raise SystemExit("manifest clean-build status is not pass")
if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
    raise SystemExit("manifest bitstream SHA-256 is missing or invalid")
print(value)
PY
)" || stop_before_write "could not extract the clean-build bitstream SHA-256 from the manifest"
readonly manifest_bitstream_sha256="$manifest_values"
if [[ -n "$expected_hash_arg" ]]; then
    [[ "$expected_hash_arg" == "$manifest_bitstream_sha256" ]] \
        || stop_before_write "the requested bitstream SHA-256 differs from the repository manifest"
fi
readonly expected_bitstream_sha256="${expected_hash_arg:-$manifest_bitstream_sha256}"

read_single_hash_sidecar() {
    local sidecar="$1"
    local value
    value="$(tr -d '\r' < "$sidecar" | awk '
    NF {
        if (++n != 1 || NF != 1) exit 2
        value=$1
    }
    END {
        if (n != 1) exit 3
        print value
    }
')" || return 1
    value="$(tr '[:upper:]' '[:lower:]' <<< "$value")"
    [[ "$value" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "$value"
}

bitstream_sidecar_value="$(read_single_hash_sidecar "$bitstream_sha_file")" \
    || stop_before_write "the bitstream sidecar must contain exactly one SHA-256 token"
report_sidecar_value="$(read_single_hash_sidecar "$jtag_report_sha_file")" \
    || stop_before_write "the JTAG-report sidecar must contain exactly one SHA-256 token"
actual_bitstream_sha256="$(sha256sum "$bitstream" | awk '{print $1}')"
actual_report_sha256="$(sha256sum "$jtag_report" | awk '{print $1}')"
[[ "$actual_bitstream_sha256" == "$bitstream_sidecar_value" ]] \
    || stop_before_write "the supplied bitstream differs from its Windows sidecar"
[[ "$actual_bitstream_sha256" == "$expected_bitstream_sha256" ]] \
    || stop_before_write "the supplied bitstream differs from the repository clean-build hash"
[[ "$actual_report_sha256" == "$report_sidecar_value" ]] \
    || stop_before_write "the supplied JTAG report differs from its Windows sidecar"

# Vivado and PowerShell normally write these Windows artifacts with CRLF.  The
# report sidecar above authenticates the original bytes first.  Only the
# in-memory parser view is normalized so CRLF cannot turn exact PASS lines into
# false negatives; the authenticated raw report remains unchanged in evidence.
readonly jtag_report_text="$(tr -d '\r' < "$jtag_report")"

require_jtag_line() {
    local exact="$1"
    grep -Fx -- "$exact" <<< "$jtag_report_text" >/dev/null \
        || stop_before_write "JTAG report lacks: $exact"
}

require_jtag_line 'ProgramCommand=completed'
require_jtag_line 'Verification=PASS'
require_jtag_line 'REGISTER.CONFIG_STATUS.BIT00_CRC_ERROR=0'
require_jtag_line 'REGISTER.CONFIG_STATUS.BIT04_END_OF_STARTUP_(EOS)_STATUS=1'
require_jtag_line 'REGISTER.CONFIG_STATUS.BIT06_GWE_STATUS=1'
require_jtag_line 'REGISTER.CONFIG_STATUS.BIT11_INIT_B_INTERNAL_SIGNAL_STATUS=1'
require_jtag_line 'REGISTER.CONFIG_STATUS.BIT12_INIT_B_PIN=1'
require_jtag_line 'REGISTER.CONFIG_STATUS.BIT13_DONE_INTERNAL_SIGNAL_STATUS=1'
require_jtag_line 'REGISTER.CONFIG_STATUS.BIT14_DONE_PIN=1'
require_jtag_line 'REGISTER.CONFIG_STATUS.BIT15_IDCODE_ERROR=0'
require_jtag_line 'REGISTER.CONFIG_STATUS.BIT16_SECURITY_ERROR=0'
require_jtag_line 'PROGRAM.HW_CFGMEM='
require_jtag_line 'PROGRAM.IS_SUPPORTED=1'
grep -Eq '^Part=xc7k325t' <<< "$jtag_report_text" \
    || stop_before_write "JTAG report is not for an XC7K325T"
grep -Eq '^BitstreamBytes=[1-9][0-9]*$' <<< "$jtag_report_text" \
    || stop_before_write "JTAG report lacks a positive bitstream byte count"
if grep -q '^Error=' <<< "$jtag_report_text"; then
    stop_before_write "JTAG report contains an Error field"
fi
report_bitstream_count="$(grep -c '^Bitstream=' <<< "$jtag_report_text" || true)"
[[ "$report_bitstream_count" -eq 1 ]] \
    || stop_before_write "JTAG report must contain exactly one Bitstream path"
report_bitstream_path="$(awk -F= '$1 == "Bitstream" { print substr($0, index($0, "=") + 1); exit }' <<< "$jtag_report_text")"
report_bitstream_path="${report_bitstream_path//\\//}"
report_bitstream_basename="${report_bitstream_path##*/}"
supplied_bitstream_basename="$(basename -- "$bitstream")"
[[ "$report_bitstream_basename" == "$supplied_bitstream_basename" ]] \
    || stop_before_write "the JTAG report names a different bitstream basename"
for report_path_key in PROGRAM.FILE PROGRAM.HW_BITSTREAM; do
    report_program_path_count="$(awk -F= -v key="$report_path_key" '$1 == key { n++ } END { print n + 0 }' <<< "$jtag_report_text")"
    [[ "$report_program_path_count" -eq 1 ]] \
        || stop_before_write "JTAG report must contain exactly one $report_path_key path"
    report_program_path="$(awk -F= -v key="$report_path_key" '$1 == key { print substr($0, index($0, "=") + 1); exit }' <<< "$jtag_report_text")"
    report_program_path="${report_program_path//\\//}"
    [[ "$report_program_path" == "$report_bitstream_path" ]] \
        || stop_before_write "$report_path_key does not match the JTAG Bitstream path"
done
report_bitstream_bytes="$(awk -F= '$1 == "BitstreamBytes" { print $2; exit }' <<< "$jtag_report_text")"
actual_bitstream_bytes="$(stat -Lc '%s' "$bitstream")"
[[ "$report_bitstream_bytes" == "$actual_bitstream_bytes" ]] \
    || stop_before_write "the bitstream size differs from the JTAG report"

printf 'STORAGE_BOUNDARY=PASS\n'
printf 'PERSISTENT_LIVE_USB=PASS\n'
printf 'SECURE_BOOT_PRECHECK=PASS\n'
printf 'WINDOWS_JTAG_EVIDENCE=PASS\n'
printf 'IDLE_INHIBITOR=active\n'
printf 'EXPECTED_BITSTREAM_SHA256=%s\n' "$expected_bitstream_sha256"

readonly utc_stamp="$(date -u +%Y%m%dT%H%M%S.%NZ)"
readonly run_root="$HOME/memblaze-exact-image-runs/$utc_stamp"
readonly step_results_copy="$run_root/step-results"
readonly summary_file="$run_root/final_summary.env"
readonly session_log="$run_root/final_session.log"
readonly results_marker="$run_root/results_start.marker"
readonly bundle_root="$HOME/memblaze-exact-image-bundles"
readonly bundle_name="memblaze_exact_image_regression_${utc_stamp}.tar.gz"
readonly bundle_path="$bundle_root/$bundle_name"
readonly bundle_sidecar="$bundle_path.sha256"

mkdir -p "$run_root" "$step_results_copy" "$bundle_root"
touch "$results_marker"
{
    printf 'KERNEL_LOG_BACKEND=%s\n' "$MEMBLAZE_KERNEL_LOG_BACKEND"
    if [[ -n "$boot_dmesg_diagnostics" ]]; then
        printf '%s\n' "$boot_dmesg_diagnostics"
    fi
} > "$run_root/prewrite_dmesg_selection.log"
printf '%s\n' "$boot_dmesg" > "$run_root/prewrite_boot_dmesg.txt"
cp -- "$jtag_report" "$run_root/windows_jtag_program_status.txt"
printf '%s\n' "$report_sidecar_value" > "$run_root/windows_jtag_program_status.txt.sha256"
printf '%s\n' "$jtag_report_text" > "$run_root/windows_jtag_program_status.normalized-lf.txt"
cp -- "$bitstream" "$run_root/exact_tested_bitstream.bit"
printf '%s\n' "$bitstream_sidecar_value" > "$run_root/exact_tested_bitstream.bit.sha256"
[[ "$(sha256sum "$run_root/windows_jtag_program_status.txt" | awk '{print $1}')" == "$report_sidecar_value" ]] \
    || stop_before_dma "the evidence copy of the JTAG report failed SHA-256 verification"
[[ "$(sha256sum "$run_root/exact_tested_bitstream.bit" | awk '{print $1}')" == "$expected_bitstream_sha256" ]] \
    || stop_before_dma "the evidence copy of the bitstream failed SHA-256 verification"

run_workflow() (
    set -Eeuo pipefail
    cleanup_armed=0
    cleanup_done=0
    final_data_pass=0
    workflow_complete=0
    sudo_keepalive_pid=""
    temp_mok_copy=""
    initial_dmesg_lines=0
    readonly log_flush_poll_attempts=600

    append_summary() {
        printf '%s\n' "$1" >> "$summary_file"
    }

    capture_state() {
        local label="$1"
        local capture_rc=0
        local dmesg_diagnostics="$run_root/${label}_dmesg_capture.log"
        sudo lspci -Dvvnnk > "$run_root/${label}_lspci.txt" || capture_rc=1
        lspci -Dtv > "$run_root/${label}_topology.txt" || capture_rc=1
        if ! memblaze_capture_kernel_log_file \
            "$run_root/${label}_dmesg.txt" "$dmesg_diagnostics"; then
            cat "$dmesg_diagnostics" >&2
            capture_rc=1
        fi
        printf 'STATE_CAPTURE_%s_RC=%s\n' "${label^^}" "$capture_rc"
        return "$capture_rc"
    }

    finish_workflow() {
        local original_rc=$?
        local cleanup_rc=not-run
        local cleanup_attempted=no
        local capture_rc=0
        local final_rc="$original_rc"
        trap - EXIT INT TERM
        set +e

        capture_state final || capture_rc=$?
        if (( cleanup_done == 1 )); then
            cleanup_attempted=yes
            cleanup_rc=0
        elif (( cleanup_armed == 1 )); then
            cleanup_attempted=yes
            printf '\n=== Mandatory XDMA cleanup after success or failure ===\n'
            bash "$script_dir/99_cleanup.sh"
            cleanup_rc=$?
            if (( cleanup_rc == 0 )); then
                cleanup_done=1
            fi
        fi
        capture_state after_cleanup || capture_rc=$?

        if [[ -n "$temp_mok_copy" && "$temp_mok_copy" == /dev/shm/memblaze-mok.*.der ]]; then
            rm -f -- "$temp_mok_copy"
        fi
        if [[ -n "$sudo_keepalive_pid" ]]; then
            kill "$sudo_keepalive_pid" >/dev/null 2>&1 || true
            wait "$sudo_keepalive_pid" >/dev/null 2>&1 || true
        fi

        if (( final_rc == 0 )) && [[ "$cleanup_rc" != "0" ]]; then
            final_rc=1
        fi
        if (( final_rc == 0 && capture_rc != 0 )); then
            final_rc="$capture_rc"
        fi
        {
            printf 'FINAL_DATA_TESTS=%s\n' "$([[ $final_data_pass -eq 1 ]] && printf PASS || printf NOT_PASS)"
            printf 'CLEANUP_ATTEMPTED=%s\n' "$cleanup_attempted"
            printf 'CLEANUP_RC=%s\n' "$cleanup_rc"
            printf 'FINAL_STATE_CAPTURE_RC=%s\n' "$capture_rc"
            printf 'WORKFLOW_COMPLETE=%s\n' "$([[ $workflow_complete -eq 1 ]] && printf yes || printf no)"
            printf 'WORKFLOW_SUBSHELL_FINAL_RC=%s\n' "$final_rc"
            printf 'RUN_ID=%s\n' "$utc_stamp"
        } >> "$summary_file"
        exit "$final_rc"
    }
    trap finish_workflow EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    run_step() {
        local step_name="$1"
        shift
        printf '\n=== START %s ===\n' "$step_name"
        set +e
        "$@"
        local step_rc=$?
        set -e
        printf 'STEP_%s_RC=%s\n' "$step_name" "$step_rc" | tee -a "$summary_file"
        (( step_rc == 0 )) || {
            printf 'STOP: %s failed\n' "$step_name" >&2
            return "$step_rc"
        }
    }

    latest_result_dir() {
        local log_name="$1"
        local marker_file="$2"
        local candidates=()
        local attempt
        for (( attempt=0; attempt<log_flush_poll_attempts; attempt++ )); do
            mapfile -t candidates < <(
                find "$results_root" -mindepth 2 -maxdepth 2 -type f \
                    -name "$log_name" -newer "$marker_file" -printf '%h\n' | sort -u
            )
            if (( ${#candidates[@]} == 1 )) && [[ -s "${candidates[0]}/$log_name" ]]; then
                printf '%s\n' "${candidates[0]}"
                return 0
            fi
            (( ${#candidates[@]} <= 1 )) || return 2
            sleep 0.1
        done
        printf 'LOG_FLUSH_TIMEOUT: no complete %s result appeared within 60 seconds\n' \
            "$log_name" >&2
        return 1
    }

    verify_smoke_result() {
        local marker_file="$1"
        local expected_cases="$2"
        local result_dir
        result_dir="$(latest_result_dir 05_dma_smoke.log "$marker_file")" \
            || return 1
        local log="$result_dir/05_dma_smoke.log"
        local attempt ready=0
        # Each child uses process-substitution tee for its result log. The child
        # can exit just before that tee flushes the final lines, so poll the
        # complete marker and exact counts instead of validating once.
        for (( attempt=0; attempt<log_flush_poll_attempts; attempt++ )); do
            if grep -Fxq 'DMA_DATA_COMPARE=PASS' "$log" \
                && grep -Fxq "SavedResult=$result_dir" "$log" \
                && [[ "$(grep -c '^H2C_RC=0$' "$log" || true)" -eq "$expected_cases" ]] \
                && [[ "$(grep -c '^C2H_RC=0$' "$log" || true)" -eq "$expected_cases" ]] \
                && [[ "$(grep -c '^CMP_RC=0$' "$log" || true)" -eq "$expected_cases" ]]; then
                ready=1
                break
            fi
            sleep 0.1
        done
        (( ready == 1 )) || {
            printf 'LOG_FLUSH_TIMEOUT: smoke result did not become complete within 60 seconds: %s\n' \
                "$log" >&2
            return 1
        }
        for file in dmesg_before_smoke_capture.log dmesg_after_smoke_capture.log; do
            [[ -s "$result_dir/$file" ]] || return 1
        done
        printf 'SMOKE_RESULT_DIR=%s\n' "$result_dir" >> "$summary_file"
    }

    verify_extended_result() {
        local mode="$1"
        local expected_cases="$2"
        local marker_file="$3"
        local result_dir
        result_dir="$(latest_result_dir 06_extended_validation.log "$marker_file")" \
            || return 1
        local required=(
            06_extended_validation.log pattern_manifest.txt
            dmesg_before_extended.txt dmesg_after_extended.txt
            dmesg_before_extended_capture.log dmesg_after_extended_capture.log
            pcie_before_extended.txt pcie_after_extended.txt
            pcie_topology_before.txt pcie_topology_after.txt
        )
        local file attempt ready=0
        for (( attempt=0; attempt<log_flush_poll_attempts; attempt++ )); do
            ready=1
            for file in "${required[@]}"; do
                [[ -s "$result_dir/$file" ]] || ready=0
            done
            if (( ready == 1 )) \
                && grep -Fxq 'EXTENDED_DMA_DATA_COMPARE=PASS' "$result_dir/06_extended_validation.log" \
                && grep -Fxq "SavedResult=$result_dir" "$result_dir/06_extended_validation.log" \
                && [[ "$(grep -c '^WRITE ' "$result_dir/pattern_manifest.txt" 2>/dev/null || true)" -eq "$expected_cases" ]] \
                && [[ "$(grep -c '^VERIFY ' "$result_dir/pattern_manifest.txt" 2>/dev/null || true)" -eq "$expected_cases" ]]; then
                break
            fi
            ready=0
            sleep 0.1
        done
        (( ready == 1 )) || {
            printf 'LOG_FLUSH_TIMEOUT: extended result did not become complete within 60 seconds: %s\n' \
                "$result_dir" >&2
            return 1
        }
        for file in "${required[@]}"; do
            [[ -s "$result_dir/$file" ]] || return 1
        done
        grep -Fq "Mode=$mode" "$result_dir/06_extended_validation.log" || return 1
        grep -Fq 'EXTENDED_DMA_DATA_COMPARE=PASS' "$result_dir/06_extended_validation.log" || return 1
        grep -Fq 'KernelLogPrefix=stable' "$result_dir/06_extended_validation.log" || return 1
        [[ "$(grep -c '^WRITE ' "$result_dir/pattern_manifest.txt" || true)" -eq "$expected_cases" ]] || return 1
        [[ "$(grep -c '^VERIFY ' "$result_dir/pattern_manifest.txt" || true)" -eq "$expected_cases" ]] || return 1
        [[ "$(grep -c '^H2C_RC=0 address=' "$result_dir/06_extended_validation.log" || true)" -eq "$expected_cases" ]] || return 1
        [[ "$(grep -c '^C2H_RC=0 address=' "$result_dir/06_extended_validation.log" || true)" -eq "$expected_cases" ]] || return 1
        awk -v expected="$expected_cases" '
            $1 == "VERIFY" {
                e=""; a=""; c=""
                for (i=1; i<=NF; i++) {
                    if ($i ~ /^expected_sha256=/) { split($i,x,"="); e=x[2] }
                    if ($i ~ /^actual_sha256=/)   { split($i,x,"="); a=x[2] }
                    if ($i ~ /^cmp_rc=/)          { split($i,x,"="); c=x[2] }
                }
                if (e == "" || a == "" || e != a || c != "0") bad=1
                n++
            }
            END { exit (bad || n != expected) }
        ' "$result_dir/pattern_manifest.txt" || return 1
        grep -Fq 'No new matching kernel messages.' "$result_dir/06_extended_validation.log" \
            || return 1
        grep -Fqi '10ee:7024' "$result_dir/pcie_after_extended.txt" || return 1
        printf '%s_RESULT_DIR=%s\n' "${mode//-/_}" "$result_dir" >> "$summary_file"
        printf 'EVIDENCE_%s=PASS\n' "${mode//-/_}" >> "$summary_file"
    }

    verify_advanced_result() {
        local marker_file="$1"
        local result_dir
        result_dir="$(latest_result_dir 07_release_advanced.log "$marker_file")" \
            || return 1
        local required=(
            07_release_advanced.log full_4g_pattern_manifest.txt
            dmesg_before_advanced.txt dmesg_after_advanced.txt
            dmesg_before_advanced_capture.log dmesg_after_advanced_capture.log
            pcie_path_before_advanced.txt pcie_path_after_advanced.txt
            pcie_path_status_before_advanced.txt pcie_path_status_after_advanced.txt
            pcie_topology_before_advanced.txt pcie_topology_after_advanced.txt
            interrupts_before_advanced.txt interrupts_after_advanced.txt
        )
        local file attempt ready=0
        local irq_status irq_reason aer_status aer_captured aer_reason
        for (( attempt=0; attempt<log_flush_poll_attempts; attempt++ )); do
            ready=1
            for file in "${required[@]}"; do
                [[ -s "$result_dir/$file" ]] || ready=0
            done
            if (( ready == 1 )) \
                && grep -Fxq 'ADVANCED_RELEASE_VALIDATION=PASS' "$result_dir/07_release_advanced.log" \
                && grep -Fxq "SavedResult=$result_dir" "$result_dir/07_release_advanced.log" \
                && [[ "$(grep -c '^WRITE chunk=' "$result_dir/full_4g_pattern_manifest.txt" 2>/dev/null || true)" -eq 64 ]] \
                && [[ "$(grep -c '^VERIFY chunk=' "$result_dir/full_4g_pattern_manifest.txt" 2>/dev/null || true)" -eq 64 ]]; then
                break
            fi
            ready=0
            sleep 0.1
        done
        (( ready == 1 )) || {
            printf 'LOG_FLUSH_TIMEOUT: advanced result did not become complete within 60 seconds: %s\n' \
                "$result_dir" >&2
            return 1
        }
        for file in "${required[@]}"; do
            [[ -s "$result_dir/$file" ]] || return 1
        done
        local log="$result_dir/07_release_advanced.log"
        for marker in \
            'ENGINE_ID_H2C0=0x1fc00006' \
            'ENGINE_ID_H2C1=0x1fc00106' \
            'ENGINE_ID_C2H0=0x1fc10006' \
            'ENGINE_ID_C2H1=0x1fc10106' \
            'CONTROL_ENGINE_IDENTIFIERS=PASS' \
            'CONCURRENT_H2C_RC_CH0=0' \
            'CONCURRENT_H2C_RC_CH1=0' \
            'CONCURRENT_C2H_RC_CH0=0' \
            'CONCURRENT_C2H_RC_CH1=0' \
            'CONCURRENT_DMA=PASS' \
            'FULL_4G_CHUNK_COUNT=64' \
            'FULL_4G_BYTES_COVERED=4294967296' \
            'MAX_DMA_REQUEST_BYTES=67108864' \
            'CHUNKED_4G=PASS' \
            'NEW_RELEVANT_KERNEL_MESSAGES=none' \
            'PCIE_PATH_STATUS_STABLE=yes' \
            'ADVANCED_RELEASE_VALIDATION=PASS'; do
            grep -Fxq "$marker" "$log" || return 1
        done
        [[ "$(grep -c '^WRITE chunk=' "$result_dir/full_4g_pattern_manifest.txt" || true)" -eq 64 ]] \
            || return 1
        [[ "$(grep -c '^VERIFY chunk=' "$result_dir/full_4g_pattern_manifest.txt" || true)" -eq 64 ]] \
            || return 1
        [[ "$(grep -c '^H2C_RC=0 address=' "$log" || true)" -eq 64 ]] || return 1
        [[ "$(grep -c '^C2H_RC=0 address=' "$log" || true)" -eq 64 ]] || return 1
        awk '
            $1 == "VERIFY" {
                e=""; a=""; c=""
                for (i=1; i<=NF; i++) {
                    if ($i ~ /^expected_sha256=/) { split($i,x,"="); e=x[2] }
                    if ($i ~ /^actual_sha256=/)   { split($i,x,"="); a=x[2] }
                    if ($i ~ /^cmp_rc=/)          { split($i,x,"="); c=x[2] }
                }
                if (e == "" || a == "" || e != a || c != "0") bad=1
                n++
            }
            END { exit (bad || n != 64) }
        ' "$result_dir/full_4g_pattern_manifest.txt" || return 1
        cmp --silent "$result_dir/pcie_path_status_before_advanced.txt" \
            "$result_dir/pcie_path_status_after_advanced.txt" || return 1

        irq_status="$(awk -F= '$1 == "IRQ_DELTA_STATUS" { print $2; exit }' "$log")"
        case "$irq_status" in
            PASS)
                grep -Eq '^XDMA_IRQ_COUNT_DELTA=[1-9][0-9]*$' "$log" || return 1
                ;;
            UNAVAILABLE)
                grep -Eq '^IRQ_DELTA_REASON=.+$' "$log" || return 1
                irq_reason="$(awk -F= '$1 == "IRQ_DELTA_REASON" { print substr($0, index($0, "=") + 1); exit }' "$log")"
                ;;
            *)
                return 1
                ;;
        esac
        aer_status="$(awk -F= '$1 == "AER_STATUS_STABLE" { print $2; exit }' "$log")"
        aer_captured="$(awk -F= '$1 == "AER_STATUS_CAPTURED" { print $2; exit }' "$log")"
        case "$aer_status" in
            yes)
                [[ "$aer_captured" == 'before-and-after' ]] || return 1
                ;;
            UNAVAILABLE)
                [[ "$aer_captured" == 'UNAVAILABLE' ]] || return 1
                grep -Eq '^AER_STATUS_REASON=.+$' "$log" || return 1
                aer_reason="$(awk -F= '$1 == "AER_STATUS_REASON" { print substr($0, index($0, "=") + 1); exit }' "$log")"
                ;;
            *)
                return 1
                ;;
        esac
        printf 'ADVANCED_RESULT_DIR=%s\n' "$result_dir" >> "$summary_file"
        printf 'CONTROL_ENGINE_IDENTIFIERS=PASS\n' >> "$summary_file"
        printf 'CONCURRENT_DMA=PASS\n' >> "$summary_file"
        printf 'FULL_4G_DATA_COMPARE=PASS\n' >> "$summary_file"
        printf 'PCIE_PATH_STATUS_STABLE=yes\n' >> "$summary_file"
        printf 'IRQ_DELTA_STATUS=%s\n' "$irq_status" >> "$summary_file"
        if [[ "$irq_status" == 'UNAVAILABLE' ]]; then
            printf 'IRQ_DELTA_REASON=%s\n' "$irq_reason" >> "$summary_file"
        fi
        printf 'AER_STATUS_CAPTURED=%s\n' "$aer_captured" >> "$summary_file"
        printf 'AER_STATUS_STABLE=%s\n' "$aer_status" >> "$summary_file"
        if [[ "$aer_status" == 'UNAVAILABLE' ]]; then
            printf 'AER_STATUS_REASON=%s\n' "$aer_reason" >> "$summary_file"
        fi
        printf 'ADVANCED_RELEASE_VALIDATION=PASS\n' >> "$summary_file"
    }

    printf 'RUN_ID=%s\n' "$utc_stamp" > "$summary_file"
    append_summary "EXPECTED_BITSTREAM_SHA256=$expected_bitstream_sha256"
    append_summary 'WINDOWS_JTAG_EVIDENCE=PASS'
    append_summary 'STORAGE_BOUNDARY=PASS'
    append_summary 'PERSISTENT_LIVE_USB=PASS'
    append_summary 'SECURE_BOOT_PRECHECK=PASS'
    append_summary 'IDLE_INHIBITOR=active'
    append_summary "KERNEL_LOG_BACKEND=$MEMBLAZE_KERNEL_LOG_BACKEND"
    append_summary "KERNEL=$kernel_release"
    append_summary "REPOSITORY_ROOT=$kit_root"
    if command -v git >/dev/null 2>&1 && git -C "$kit_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        append_summary "REPOSITORY_COMMIT=$(git -C "$kit_root" rev-parse HEAD)"
        [[ -z "$(git -C "$kit_root" status --porcelain)" ]] \
            || { printf 'STOP: repository worktree is dirty\n' >&2; exit 1; }
    else
        append_summary 'REPOSITORY_COMMIT=unavailable-in-snapshot'
    fi

    printf '\n=== Session identity and read-only boundary ===\n'
    printf 'UTC=%s\n' "$(date -u +%FT%TZ)"
    printf 'RUN_ROOT=%s\n' "$run_root"
    printf 'EXPECTED_BITSTREAM_SHA256=%s\n' "$expected_bitstream_sha256"
    printf 'PHYSICAL_CHAIN=operator-confirmed JTAG SRAM image remained powered through host boot\n'
    printf '%s\n' "$storage_lsblk"
    printf '%s\n' "$storage_findmnt"
    printf '%s\n' '--- /proc/swaps ---'
    if [[ -n "$storage_swaps" ]]; then
        printf '%s\n' "$storage_swaps"
    else
        printf '%s\n' '(none)'
    fi
    printf 'HOME_SOURCE=%s\n' "$home_source"
    printf 'ROOT_SOURCE=%s\n' "$root_source"
    printf 'PERSISTENCE_MARKER=%s\n' "$persistence_marker_line"
    printf 'LIVE_DISK_SERIAL_MATCH=yes\n'
    printf '%s\n' "$secure_boot_output"

    capture_state initial || { printf 'STOP: initial state capture failed\n' >&2; exit 1; }
    initial_dmesg_lines="$(wc -l < "$run_root/initial_dmesg.txt")"

    # Keep sudo authentication alive only during this subshell. The EXIT trap
    # always kills and waits for this exact PID.
    (
        keepalive_sleep_pid=""
        stop_keepalive() {
            trap - EXIT INT TERM
            if [[ -n "$keepalive_sleep_pid" ]]; then
                kill "$keepalive_sleep_pid" >/dev/null 2>&1 || true
                wait "$keepalive_sleep_pid" >/dev/null 2>&1 || true
            fi
            exit 0
        }
        trap stop_keepalive EXIT INT TERM
        while true; do
            sleep 45 &
            keepalive_sleep_pid=$!
            wait "$keepalive_sleep_pid" || exit 0
            keepalive_sleep_pid=""
            sudo -n true >/dev/null 2>&1 || exit
        done
    ) &
    sudo_keepalive_pid=$!

    run_step REPOSITORY_VALIDATE env PYTHONDONTWRITEBYTECODE=1 python3 "$validator"
    run_step KERNEL_LOG_CONTRACT bash "$kernel_log_contract"
    append_summary 'KERNEL_LOG_CONTRACT=PASS'
    run_step KERNEL_ERROR_CONTRACT bash "$kernel_error_contract"
    append_summary 'KERNEL_ERROR_CONTRACT=PASS'

    [[ ! -d /sys/module/xdma ]] \
        || { printf 'STOP: xdma was already loaded before this workflow\n' >&2; exit 1; }
    if compgen -G '/dev/xdma*' >/dev/null; then
        printf 'STOP: XDMA device nodes existed before this workflow\n' >&2
        exit 1
    fi

    run_step PROBE bash "$script_dir/01_probe.sh"
    mapfile -t bdfs < <(lspci -Dnn -d "$expected_id" | awk '{print $1}')
    (( ${#bdfs[@]} == 1 )) || { printf 'STOP: target endpoint count changed after probe\n' >&2; exit 1; }
    readonly bdf="${bdfs[0]}"
    readonly subsystem_vendor="$(<"/sys/bus/pci/devices/$bdf/subsystem_vendor")"
    readonly subsystem_device="$(<"/sys/bus/pci/devices/$bdf/subsystem_device")"
    [[ "${subsystem_vendor,,}" == "$expected_subsystem_vendor" \
       && "${subsystem_device,,}" == "$expected_subsystem_device" ]] \
        || { printf 'STOP: unexpected PCI subsystem\n' >&2; exit 1; }
    read -r bar0_start bar0_end bar0_flags < "/sys/bus/pci/devices/$bdf/resource"
    bar0_size_bytes=$((bar0_end - bar0_start + 1))
    (( bar0_start != 0 && bar0_end >= bar0_start && bar0_size_bytes % 1024 == 0 )) \
        || { printf 'STOP: BAR0 is unassigned or malformed\n' >&2; exit 1; }
    append_summary 'PCI_ENUMERATION=PASS'
    append_summary "ENDPOINT_BDF=$bdf"
    append_summary "ENDPOINT_VID_DID=$expected_id"
    append_summary 'ENDPOINT_SUBSYSTEM=10ee:0007'
    append_summary "PF0_BAR0_RESOURCE_SIZE_KIB=$((bar0_size_bytes / 1024))"
    for link_property in current_link_speed current_link_width max_link_speed max_link_width; do
        if [[ -r "/sys/bus/pci/devices/$bdf/$link_property" ]]; then
            printf '%s=%s\n' "${link_property^^}" "$(<"/sys/bus/pci/devices/$bdf/$link_property")" >> "$summary_file"
        fi
    done

    readonly preserved_root="$HOME/memblaze-xdma-preserved-builds"
    if [[ -e "$standard_build_root" ]]; then
        mkdir -p "$preserved_root"
        readonly preserved_build="$preserved_root/${utc_stamp}_${kernel_release}"
        [[ ! -e "$preserved_build" ]] || { printf 'STOP: preserved build path already exists\n' >&2; exit 1; }
        mv -- "$standard_build_root" "$preserved_build"
        append_summary "PRIOR_BUILD_TREE_PRESERVED=$preserved_build"
    fi
    run_step BUILD bash "$script_dir/02_build_driver.sh"
    [[ -f "$module" ]] || { printf 'STOP: fresh build did not produce xdma.ko\n' >&2; exit 1; }

    temp_mok_copy="$(mktemp /dev/shm/memblaze-mok.XXXXXXXX.der)"
    sudo cat -- "$mok_certificate" > "$temp_mok_copy"
    [[ -s "$temp_mok_copy" ]] || { printf 'STOP: temporary public MOK copy is empty\n' >&2; exit 1; }
    append_summary "MOK_CERTIFICATE_SHA256=$(sha256sum "$temp_mok_copy" | awk '{print $1}')"
    append_summary "MOK_PRIVATE_OWNER_MODE=$mok_private_owner_mode"

    printf '\n=== Sign fresh module with the existing enrolled MOK ===\n'
    sudo "$kernel_sign_file" sha256 "$mok_private" "$mok_certificate" "$module"
    readonly module_signer="$(modinfo -F signer "$module" 2>/dev/null || true)"
    [[ -n "$module_signer" ]] || { printf 'STOP: signed module has no modinfo signer\n' >&2; exit 1; }
    append_summary "SIGNED_MODULE_SHA256=$(sha256sum "$module" | awk '{print $1}')"
    append_summary 'MODULE_SIGNER_PRESENT=yes'

    run_step SECURE_BOOT bash "$script_dir/03_secure_boot_status.sh" "$temp_mok_copy"

    printf '\n=== Pre-load storage boundary recheck ===\n'
    runtime_protected_mounts="$(findmnt -rn -o SOURCE,TARGET \
        | awk '$1 ~ /^\/dev\/(nvme[0-9]|mapper\/|dm-)/ { print }')"
    [[ -z "$runtime_protected_mounts" ]] \
        || { printf 'STOP: a protected filesystem became mounted\n' >&2; exit 1; }
    runtime_protected_swaps="$(awk 'NR > 1 && $1 ~ /^\/dev\/(nvme[0-9]|mapper\/|dm-)/ { print }' \
        /proc/swaps)"
    [[ -z "$runtime_protected_swaps" ]] \
        || { printf 'STOP: a protected swap became active\n' >&2; exit 1; }
    ! findmnt -rn -M /boot/efi >/dev/null 2>&1 \
        || { printf 'STOP: /boot/efi became mounted\n' >&2; exit 1; }
    [[ "$(findmnt -rn -T / -o SOURCE)" == "$root_source" ]] \
        || { printf 'STOP: root overlay source changed\n' >&2; exit 1; }
    [[ ",$(findmnt -rn -T / -o OPTIONS)," == *,rw,* ]] \
        || { printf 'STOP: root overlay became read-only\n' >&2; exit 1; }
    preload_dmesg=""
    preload_dmesg_diagnostics=""
    if ! memblaze_capture_kernel_log_text preload_dmesg preload_dmesg_diagnostics; then
        printf '%s\n' "$preload_dmesg_diagnostics" >&2
        printf 'STOP: kernel log became unreadable before module load\n' >&2
        exit 1
    fi
    preload_storage_errors="$(grep -Ei \
        'attempt to access beyond end of device|Buffer I/O error|JBD2:.*error|Remounting filesystem read-only' \
        <<< "$preload_dmesg" || true)"
    [[ -z "$preload_storage_errors" ]] \
        || { printf 'STOP: storage errors appeared before module load\n' >&2; exit 1; }
    append_summary 'STORAGE_BOUNDARY_PRE_LOAD=PASS'

    cleanup_armed=1
    run_step LOAD bash "$script_dir/04_load_verify.sh"
    append_summary 'XDMA_DRIVER=PASS'

    smoke_marker="$run_root/smoke_default.marker"
    touch "$smoke_marker"
    run_step SMOKE_DEFAULT bash "$script_dir/05_dma_smoke.sh" --confirm-ddr-write
    verify_smoke_result "$smoke_marker" 3 \
        || { printf 'STOP: default smoke evidence validation failed\n' >&2; exit 1; }

    smoke_ch0_marker="$run_root/smoke_64m_ch0.marker"
    touch "$smoke_ch0_marker"
    run_step SMOKE_64M_CH0 bash "$script_dir/05_dma_smoke.sh" \
        --confirm-ddr-write 67108864 0x04000000 0
    verify_smoke_result "$smoke_ch0_marker" 1 \
        || { printf 'STOP: channel-0 64 MiB evidence validation failed\n' >&2; exit 1; }

    smoke_ch1_marker="$run_root/smoke_64m_ch1.marker"
    touch "$smoke_ch1_marker"
    run_step SMOKE_64M_CH1 bash "$script_dir/05_dma_smoke.sh" \
        --confirm-ddr-write 67108864 0x44000000 1
    verify_smoke_result "$smoke_ch1_marker" 1 \
        || { printf 'STOP: channel-1 64 MiB evidence validation failed\n' >&2; exit 1; }
    append_summary 'DMA_DATA_COMPARE=PASS'
    append_summary 'DMA_64M_BOTH_CHANNELS=PASS'

    alias_marker="$run_root/alias_4g.marker"
    touch "$alias_marker"
    run_step ALIAS_4G bash "$script_dir/06_extended_validation.sh" \
        --confirm-ddr-write alias-4g
    verify_extended_result alias-4g 5 "$alias_marker" \
        || { printf 'STOP: alias-4g evidence validation failed\n' >&2; exit 1; }

    chunked_marker="$run_root/chunked_1g.marker"
    touch "$chunked_marker"
    run_step CHUNKED_1G bash "$script_dir/06_extended_validation.sh" \
        --confirm-ddr-write chunked-1g
    verify_extended_result chunked-1g 16 "$chunked_marker" \
        || { printf 'STOP: chunked-1g evidence validation failed\n' >&2; exit 1; }

    advanced_marker="$run_root/release_advanced.marker"
    touch "$advanced_marker"
    run_step RELEASE_ADVANCED bash "$script_dir/07_release_advanced.sh" \
        --confirm-ddr-write
    verify_advanced_result "$advanced_marker" \
        || { printf 'STOP: advanced release evidence validation failed\n' >&2; exit 1; }

    capture_state before_cleanup || { printf 'STOP: pre-cleanup capture failed\n' >&2; exit 1; }
    final_data_pass=1
    run_step CLEANUP bash "$script_dir/99_cleanup.sh"
    cleanup_done=1
    append_summary 'CLEANUP_STATUS=PASS'
    [[ ! -d /sys/module/xdma ]] || { printf 'STOP: xdma remains loaded after cleanup\n' >&2; exit 1; }
    if compgen -G '/dev/xdma*' >/dev/null; then
        printf 'STOP: XDMA nodes remain after cleanup\n' >&2
        exit 1
    fi

    capture_state after_cleanup_gate \
        || { printf 'STOP: post-cleanup capture failed\n' >&2; exit 1; }
    readonly final_dmesg="$run_root/after_cleanup_gate_dmesg.txt"
    final_dmesg_lines="$(wc -l < "$final_dmesg")"
    if (( initial_dmesg_lines > 0 )); then
        if (( final_dmesg_lines < initial_dmesg_lines )) \
            || ! head -n "$initial_dmesg_lines" "$final_dmesg" \
                | cmp --silent - "$run_root/initial_dmesg.txt"; then
            printf 'STOP: kernel ring-buffer prefix changed; final delta is ambiguous\n' >&2
            exit 1
        fi
    fi
    tail -n "+$((initial_dmesg_lines + 1))" "$final_dmesg" > "$run_root/full_session_dmesg_delta.txt"
    if ! severe_kernel_messages="$(memblaze_filter_severe_kernel_messages \
        "$run_root/full_session_dmesg_delta.txt")"; then
        printf 'STOP: severe-kernel-message filter failed\n' >&2
        exit 1
    fi
    if [[ -n "$severe_kernel_messages" ]]; then
        printf '%s\n' "$severe_kernel_messages" > "$run_root/severe_kernel_messages.txt"
        printf 'STOP: severe kernel messages appeared during the session\n' >&2
        exit 1
    fi
    : > "$run_root/severe_kernel_messages.txt"
    append_summary 'NEW_SEVERE_KERNEL_MESSAGES=none'

    workflow_complete=1
    append_summary 'EXACT_IMAGE_PHYSICAL_REGRESSION=PASS'
    printf '\nPASS: exact-image physical regression and cleanup completed.\n'
)

set +e
run_workflow 2>&1 | tee "$session_log"
session_pipeline_status=("${PIPESTATUS[@]}")
set -e
workflow_subshell_rc="${session_pipeline_status[0]}"
session_log_tee_rc="${session_pipeline_status[1]}"
workflow_rc="$workflow_subshell_rc"
if (( workflow_rc == 0 && session_log_tee_rc != 0 )); then
    workflow_rc="$session_log_tee_rc"
fi

# Copy only compact text/binary metadata from child result directories. Random
# DMA payload .bin files remain in HOME but are intentionally excluded from the
# evidence archive because their hashes and byte comparisons are in the logs.
if [[ -d "$results_root" ]]; then
    while IFS= read -r -d '' source_file; do
        case "$source_file" in
            *.bin) continue ;;
        esac
        relative_path="${source_file#"$results_root"/}"
        [[ "$relative_path" != "$source_file" && "$relative_path" != ../* ]] || continue
        destination="$step_results_copy/$relative_path"
        mkdir -p "$(dirname -- "$destination")"
        cp -- "$source_file" "$destination"
    done < <(find "$results_root" -type f -newer "$results_marker" -print0)
fi

{
    printf 'WORKFLOW_SUBSHELL_RC=%s\n' "$workflow_subshell_rc"
    printf 'SESSION_LOG_TEE_RC=%s\n' "$session_log_tee_rc"
    printf 'WORKFLOW_PIPELINE_RC=%s\n' "$workflow_rc"
    printf 'FINAL_EXPERIMENT_RC=%s\n' "$workflow_rc"
    printf 'EVIDENCE_ARCHIVE_EXCLUDES_DMA_PAYLOAD_BINARIES=yes\n'
} >> "$summary_file"

(
    cd "$run_root"
    find . -type f ! -name evidence_files.sha256 -print0 \
        | sort -z \
        | xargs -0 sha256sum > evidence_files.sha256
)

archive_tmp="$bundle_path.tmp.$$"
rm -f -- "$archive_tmp"
tar -C "$(dirname -- "$run_root")" -czf "$archive_tmp" "$(basename -- "$run_root")"
mv -- "$archive_tmp" "$bundle_path"
(
    cd "$bundle_root"
    sha256sum "$bundle_name" > "${bundle_name}.sha256"
)

printf '\n=== Evidence bundle ===\n'
printf 'FINAL_EXPERIMENT_RC=%s\n' "$workflow_rc"
printf 'RUN_ROOT=%s\n' "$run_root"
printf 'EVIDENCE_BUNDLE=%s\n' "$bundle_path"
printf 'EVIDENCE_BUNDLE_SHA256=%s\n' "$(awk '{print $1}' "$bundle_sidecar")"
printf 'EVIDENCE_BUNDLE_SIDECAR=%s\n' "$bundle_sidecar"
exit "$workflow_rc"
