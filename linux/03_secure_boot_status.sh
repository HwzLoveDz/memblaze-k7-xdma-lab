#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Memblaze K7 XDMA Lab contributors

set -Eeuo pipefail
export LC_ALL=C
umask 077

usage() {
    cat <<'EOF'
Usage:
  ./03_secure_boot_status.sh
  ./03_secure_boot_status.sh /path/to/signing-certificate.der

This step only reads Secure Boot, module-signature, and optional certificate
enrollment metadata. It never imports a key or changes firmware settings.
EOF
}

if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
fi
if (( $# > 1 )); then
    usage >&2
    exit 2
fi

readonly expected_id="10ee:7024"
readonly build_tag="b8466090-aba9086b051e"
readonly kernel_release="$(uname -r)"
readonly source_root="${HOME:?HOME is not set}/memblaze-xdma-work/$build_tag/$kernel_release/dma_ip_drivers-b8466090/XDMA/linux-kernel"
readonly module="$source_root/xdma/xdma.ko"
readonly optional_certificate="${1:-}"
readonly results_root="$HOME/memblaze-xdma-results"
readonly utc_stamp="$(date -u +%Y%m%dT%H%M%S.%NZ)"
readonly result_dir="$results_root/$utc_stamp"
readonly log_file="$result_dir/03_secure_boot_status.log"

mkdir -p "$result_dir"
exec > >(tee "$log_file") 2>&1

stop() {
    printf 'STOP: %s\n' "$*" >&2
    printf 'SavedLog=%s\n' "$log_file" >&2
    exit 1
}

for cmd in awk cat date grep lspci modinfo mokutil tee tr uname; do
    command -v "$cmd" >/dev/null 2>&1 || stop "missing command: $cmd"
done

mapfile -t bdfs < <(lspci -Dnn -d "$expected_id" | awk '{print $1}')
(( ${#bdfs[@]} == 1 )) \
    || stop "expected exactly one $expected_id endpoint; found ${#bdfs[@]}"
[[ -f "$module" ]] || stop "built module is missing; run 02_build_driver.sh first"

printf 'UTC=%s\n' "$(date -u +%FT%TZ)"
printf 'Endpoint=%s\n' "${bdfs[0]}"
printf 'ModuleFile=xdma.ko\n'

printf '\n=== Secure Boot state (read-only) ===\n'
set +e
secure_boot_output="$(mokutil --sb-state 2>&1)"
secure_boot_rc=$?
set -e
printf '%s\n' "$secure_boot_output"
printf 'MokutilSecureBootRC=%s\n' "$secure_boot_rc"

printf '\n=== Kernel lockdown state (read-only) ===\n'
if [[ -r /sys/kernel/security/lockdown ]]; then
    cat /sys/kernel/security/lockdown
else
    printf 'INFO: /sys/kernel/security/lockdown is unavailable.\n'
fi

printf '\n=== Module metadata (read-only) ===\n'
modinfo "$module" | grep -E '^(version|vermagic|sig_hashalgo):' || true
module_signer="$(modinfo -F signer "$module" 2>/dev/null || true)"
module_sig_key="$(modinfo -F sig_key "$module" 2>/dev/null || true)"
module_vermagic="$(modinfo -F vermagic "$module" 2>/dev/null || true)"
printf 'RunningKernel=%s\n' "$kernel_release"
printf 'ModuleVermagic=%s\n' "$module_vermagic"
if [[ -n "$module_signer" ]]; then
    printf 'ModuleSignerPresent=yes\n'
else
    printf 'ModuleSignerPresent=no\n'
fi
if [[ -n "$module_sig_key" ]]; then
    printf 'ModuleSignatureKeyPresent=yes\n'
else
    printf 'ModuleSignatureKeyPresent=no\n'
fi

normalize_hex_integer() {
    local value
    value="$(printf '%s' "$1" | tr -d '[:space:]:')"
    if [[ "$value" == 0x* || "$value" == 0X* ]]; then
        value="${value:2}"
    fi
    if [[ ! "$value" =~ ^[0-9A-Fa-f]+$ ]]; then
        return 0
    fi
    value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
    while [[ ${#value} -gt 1 && "$value" == 0* ]]; do
        value="${value#0}"
    done
    printf '%s' "$value"
}

certificate_key_match=not-tested
certificate_enrollment=not-tested
certificate_serial_state=not-tested
if [[ -n "$optional_certificate" ]]; then
    [[ "$optional_certificate" != *$'\n'* && "$optional_certificate" != *$'\r'* ]] \
        || stop "certificate path contains a line break"
    [[ -r "$optional_certificate" ]] || stop "certificate is not readable: $optional_certificate"
    command -v openssl >/dev/null 2>&1 || stop "openssl is required to inspect the supplied public certificate"
    printf '\n=== Optional enrolled-key check (read-only) ===\n'
    set +e
    certificate_serial_output="$(openssl x509 -inform DER -in "$optional_certificate" -noout -serial 2>/dev/null)"
    certificate_serial_rc=$?
    set -e
    if (( certificate_serial_rc == 0 )); then
        certificate_serial="$(awk -F= 'tolower($1) ~ /^[[:space:]]*serial[[:space:]]*$/ { print $2; exit }' \
            <<< "$certificate_serial_output")"
    else
        certificate_serial=""
    fi
    normalized_certificate_serial="$(normalize_hex_integer "$certificate_serial")"
    normalized_module_sig_key="$(normalize_hex_integer "$module_sig_key")"
    if [[ -n "$normalized_certificate_serial" ]]; then
        certificate_serial_state=parsed
    else
        certificate_serial_state=unavailable
    fi
    printf 'CertificateSerialState=%s\n' "$certificate_serial_state"
    if [[ -n "$normalized_module_sig_key" \
          && -n "$normalized_certificate_serial" \
          && "$normalized_module_sig_key" == "$normalized_certificate_serial" ]]; then
        certificate_key_match=yes
    else
        certificate_key_match=no
    fi
    printf 'CertificateSerialMatchesModuleSigKey=%s\n' "$certificate_key_match"

    set +e
    test_key_output="$(mokutil --test-key "$optional_certificate" 2>&1)"
    test_key_rc=$?
    set -e
    printf 'MokutilTestKeyRC=%s\n' "$test_key_rc"
    printf 'MokutilTestKeyDecisionSource=text\n'
    # mokutil can prepend a keyring-access warning before its certificate result.
    # Accept exactly one recognized complete line and ignore unrelated lines;
    # never decide from a substring or the version-dependent return code.
    recognized_enrollment=""
    recognized_text=""
    recognized_count=0
    while IFS= read -r test_key_line || [[ -n "$test_key_line" ]]; do
        candidate_enrollment=""
        candidate_text=""
        case "$test_key_line" in
            "$optional_certificate is already enrolled")
                candidate_enrollment=yes
                candidate_text=already-enrolled
                ;;
            "$optional_certificate is already in the built-in trusted keyring")
                candidate_enrollment=yes
                candidate_text=kernel-trusted
                ;;
            "$optional_certificate is not enrolled")
                candidate_enrollment=no
                candidate_text=not-enrolled
                ;;
            "$optional_certificate is already in the enrollment request")
                candidate_enrollment=pending
                candidate_text=pending
                ;;
            "$optional_certificate is blocked in "?*)
                candidate_enrollment=blocked
                candidate_text=blocked
                ;;
        esac
        if [[ -n "$candidate_enrollment" ]]; then
            recognized_count=$((recognized_count + 1))
            recognized_enrollment="$candidate_enrollment"
            recognized_text="$candidate_text"
        fi
    done <<< "$test_key_output"
    if (( recognized_count == 1 )); then
        certificate_enrollment="$recognized_enrollment"
        printf 'MokutilTestKeyText=%s\n' "$recognized_text"
    else
        certificate_enrollment=unknown
        printf 'MokutilTestKeyText=unrecognized\n'
    fi
    printf 'CertificateEnrollment=%s\n' "$certificate_enrollment"
fi

printf '\n=== Assessment ===\n'
status=0
secure_boot_output_lc="$(printf '%s' "$secure_boot_output" | tr '[:upper:]' '[:lower:]')"
if (( secure_boot_rc != 0 )); then
    printf 'WAIT: Secure Boot state could not be determined.\n'
    printf 'SECURE_BOOT_STATUS=CHECK\n'
    status=2
elif [[ "$secure_boot_output_lc" == *'secureboot enabled'* ]]; then
    printf 'SECURE_BOOT=enabled\n'
    if [[ -z "$module_signer" ]]; then
        printf 'WAIT: Secure Boot is enabled and modinfo did not expose a signer for xdma.ko. Sign it, enroll its public certificate, and confirm that local modinfo can parse the signature before loading.\n'
        printf 'SECURE_BOOT_STATUS=CHECK\n'
        status=3
    elif [[ "$certificate_key_match" == "yes" && "$certificate_enrollment" == "yes" ]]; then
        printf 'READY: the module signature key matches the serial of the supplied certificate, and mokutil explicitly reports it enrolled.\n'
        printf 'The successful load in 04_load_verify.sh is the final proof that this kernel accepts it.\n'
        printf 'SECURE_BOOT_STATUS=READY\n'
    else
        printf 'CHECK: Secure Boot is enabled, but this run did not prove that the module signing key matches an enrolled certificate.\n'
        printf 'Re-run with the exact public DER certificate used to sign this xdma.ko.\n'
        printf 'SECURE_BOOT_STATUS=CHECK\n'
        status=4
    fi
elif [[ "$secure_boot_output_lc" == *'secureboot disabled'* ]]; then
    printf 'SECURE_BOOT=disabled\n'
    printf 'READY: Secure Boot is not reported as enabled; local kernel policy may still enforce signatures.\n'
    printf 'The successful load in 04_load_verify.sh remains the final acceptance test.\n'
    printf 'SECURE_BOOT_STATUS=READY\n'
else
    printf 'CHECK: mokutil returned an unrecognized Secure Boot state.\n'
    printf 'SECURE_BOOT_STATUS=CHECK\n'
    status=2
fi

printf 'SavedLog=%s\n' "$log_file"
exit "$status"
