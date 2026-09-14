#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Memblaze K7 XDMA Lab contributors

# Deterministic tests for the kernel-log backend.  These tests use command
# shims; they neither read the host kernel ring buffer nor require sudo.

set -Eeuo pipefail
export LC_ALL=C

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly repository_root="$(cd -- "$script_dir/.." && pwd)"
readonly helper="$repository_root/linux/lib/dmesg_capture.sh"
fake_bin="$(mktemp -d)" || {
    printf 'FAIL: could not create the command-shim directory\n' >&2
    exit 1
}
readonly fake_bin

cleanup() {
    rm -rf -- "$fake_bin"
}
trap cleanup EXIT INT TERM

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    [[ "$actual" == "$expected" ]] \
        || fail "$label: expected '$expected', got '$actual'"
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"
    [[ "$haystack" == *"$needle"* ]] \
        || fail "$label: missing '$needle'"
}

write_command() {
    local name="$1"
    local body="$2"
    printf '#!/usr/bin/env bash\n%s\n' "$body" > "$fake_bin/$name"
    chmod +x "$fake_bin/$name"
}

[[ -r "$helper" ]] || fail "kernel-log helper is missing"

# The Ubuntu 24.04 target does not accept this invented util-linux format.
# Keep the exact regression check separate from the command-shim tests so a
# future helper refactor cannot accidentally reintroduce it elsewhere.
if grep -RFn --include='*.sh' -- '--time-format=raw' "$repository_root/linux"; then
    fail "unsupported dmesg --time-format=raw was reintroduced"
fi

PATH="$fake_bin:$PATH"
export PATH
sudo_cmd=()

# shellcheck source=linux/lib/dmesg_capture.sh
source "$helper"

printf '%s\n' '=== dmesg success selects the plain, target-compatible backend ==='
write_command dmesg "printf '%s\\n' 'first dmesg snapshot'"
write_command journalctl "printf '%s\\n' 'journalctl must not run' >&2; exit 91"
MEMBLAZE_KERNEL_LOG_BACKEND=""
selected_output=""
selected_diagnostics="not-cleared"
memblaze_select_kernel_log_text selected_output selected_diagnostics \
    || fail "plain dmesg selection unexpectedly failed"
assert_equal 'dmesg-default' "$MEMBLAZE_KERNEL_LOG_BACKEND" 'selected backend'
assert_equal 'first dmesg snapshot' "$selected_output" 'plain dmesg output'
assert_equal '' "$selected_diagnostics" 'plain dmesg diagnostics'

# Once selected, the backend must remain fixed for before/after comparisons.
write_command dmesg "printf '%s\\n' 'second dmesg snapshot'"
write_command journalctl "printf '%s\\n' 'journal replacement'; exit 0"
captured_output=""
captured_diagnostics="not-cleared"
memblaze_capture_kernel_log_text captured_output captured_diagnostics \
    || fail "capture from the selected dmesg backend failed"
assert_equal 'second dmesg snapshot' "$captured_output" 'second dmesg output'
assert_equal '' "$captured_diagnostics" 'second dmesg diagnostics'
assert_equal 'dmesg-default' "$MEMBLAZE_KERNEL_LOG_BACKEND" 'fixed dmesg backend'

printf '%s\n' '=== failed dmesg falls back once and preserves its rc and stderr ==='
write_command dmesg "printf '%s\\n' 'dmesg denied by fixture' >&2; exit 37"
write_command journalctl "printf '%s\\n' 'first journal snapshot'"
MEMBLAZE_KERNEL_LOG_BACKEND=""
selected_output=""
selected_diagnostics=""
memblaze_select_kernel_log_text selected_output selected_diagnostics \
    || fail "journal fallback unexpectedly failed"
assert_equal 'journalctl-kernel-short-monotonic' "$MEMBLAZE_KERNEL_LOG_BACKEND" \
    'selected fallback backend'
assert_equal 'first journal snapshot' "$selected_output" 'journal fallback output'
assert_contains "$selected_diagnostics" 'exit status 37' 'dmesg failure rc'
assert_contains "$selected_diagnostics" 'dmesg denied by fixture' 'dmesg failure stderr'

# Make dmesg succeed after selection.  A correct implementation still uses the
# journal, preserving one output format for the whole before/after sequence.
write_command dmesg "printf '%s\\n' 'late dmesg must not replace the backend'"
write_command journalctl "printf '%s\\n' 'second journal snapshot'"
captured_output=""
captured_diagnostics=""
memblaze_capture_kernel_log_text captured_output captured_diagnostics \
    || fail "capture from the selected journal backend failed"
assert_equal 'second journal snapshot' "$captured_output" 'second journal output'
assert_equal 'journalctl-kernel-short-monotonic' "$MEMBLAZE_KERNEL_LOG_BACKEND" \
    'fixed journal backend'

printf '%s\n' '=== both backends failing preserves both return codes and errors ==='
write_command dmesg "printf '%s\\n' 'dmesg hard failure' >&2; exit 41"
write_command journalctl "printf '%s\\n' 'journal hard failure' >&2; exit 42"
MEMBLAZE_KERNEL_LOG_BACKEND=""
selected_output="not-cleared"
selected_diagnostics=""
set +e
memblaze_select_kernel_log_text selected_output selected_diagnostics
selection_rc=$?
set -e
assert_equal '1' "$selection_rc" 'dual-backend failure status'
assert_equal 'unavailable' "$MEMBLAZE_KERNEL_LOG_BACKEND" 'unavailable backend marker'
assert_equal '' "$selected_output" 'dual-backend output'
assert_contains "$selected_diagnostics" 'exit status 41' 'failed dmesg rc'
assert_contains "$selected_diagnostics" 'dmesg hard failure' 'failed dmesg stderr'
assert_contains "$selected_diagnostics" 'exit status 42' 'failed journal rc'
assert_contains "$selected_diagnostics" 'journal hard failure' 'failed journal stderr'

printf '%s\n' '=== file API preserves the selected backend and diagnostics ==='
write_command dmesg "printf '%s\\n' 'first file snapshot'"
write_command journalctl "printf '%s\\n' 'file journal must not run' >&2; exit 71"
MEMBLAZE_KERNEL_LOG_BACKEND=""
file_output="$fake_bin/kernel-log.out"
file_diagnostics="$fake_bin/kernel-log.diag"
memblaze_select_kernel_log_file "$file_output" "$file_diagnostics" \
    || fail "plain dmesg file selection unexpectedly failed"
assert_equal 'first file snapshot' "$(cat "$file_output")" 'plain dmesg file output'
assert_contains "$(cat "$file_diagnostics")" 'KERNEL_LOG_DMESG_ATTEMPT_RC=0' \
    'plain dmesg file rc'
assert_equal 'dmesg-default' "$MEMBLAZE_KERNEL_LOG_BACKEND" 'file backend selection'

write_command dmesg "printf '%s\\n' 'second file snapshot'"
write_command journalctl "printf '%s\\n' 'late file journal must not run' >&2; exit 72"
memblaze_capture_kernel_log_file "$file_output" "$file_diagnostics" \
    || fail "capture from the selected file backend failed"
assert_equal 'second file snapshot' "$(cat "$file_output")" 'second dmesg file output'
assert_contains "$(cat "$file_diagnostics")" 'KERNEL_LOG_CAPTURE_RC=0' \
    'second dmesg file rc'
assert_equal 'dmesg-default' "$MEMBLAZE_KERNEL_LOG_BACKEND" 'fixed file backend'

write_command dmesg "printf '%s\\n' 'file dmesg denied' >&2; exit 73"
write_command journalctl "printf '%s\\n' 'journal file snapshot'"
MEMBLAZE_KERNEL_LOG_BACKEND=""
memblaze_select_kernel_log_file "$file_output" "$file_diagnostics" \
    || fail "journal file fallback unexpectedly failed"
assert_equal 'journal file snapshot' "$(cat "$file_output")" 'journal file output'
assert_contains "$(cat "$file_diagnostics")" 'file dmesg denied' \
    'journal file fallback retained dmesg stderr'
assert_contains "$(cat "$file_diagnostics")" 'KERNEL_LOG_DMESG_ATTEMPT_RC=73' \
    'journal file fallback retained dmesg rc'
assert_contains "$(cat "$file_diagnostics")" 'KERNEL_LOG_JOURNAL_ATTEMPT_RC=0' \
    'journal file fallback rc'
assert_equal 'journalctl-kernel-short-monotonic' "$MEMBLAZE_KERNEL_LOG_BACKEND" \
    'journal file backend selection'

write_command dmesg "printf '%s\\n' 'late file dmesg must not replace journal'"
write_command journalctl "printf '%s\\n' 'selected journal file failure' >&2; exit 74"
set +e
memblaze_capture_kernel_log_file "$file_output" "$file_diagnostics"
file_capture_rc=$?
set -e
assert_equal '74' "$file_capture_rc" 'selected journal file failure status'
assert_contains "$(cat "$file_diagnostics")" 'selected journal file failure' \
    'selected journal file stderr'
assert_contains "$(cat "$file_diagnostics")" 'KERNEL_LOG_CAPTURE_RC=74' \
    'selected journal file failure rc'
assert_equal 'journalctl-kernel-short-monotonic' "$MEMBLAZE_KERNEL_LOG_BACKEND" \
    'fixed failing journal file backend'

write_command dmesg "printf '%s\\n' 'file dmesg hard failure' >&2; exit 75"
write_command journalctl "printf '%s\\n' 'file journal hard failure' >&2; exit 76"
MEMBLAZE_KERNEL_LOG_BACKEND=""
set +e
memblaze_select_kernel_log_file "$file_output" "$file_diagnostics"
file_selection_rc=$?
set -e
assert_equal '1' "$file_selection_rc" 'dual-backend file failure status'
assert_contains "$(cat "$file_diagnostics")" 'file dmesg hard failure' \
    'dual-backend file dmesg stderr'
assert_contains "$(cat "$file_diagnostics")" 'KERNEL_LOG_DMESG_ATTEMPT_RC=75' \
    'dual-backend file dmesg rc'
assert_contains "$(cat "$file_diagnostics")" 'file journal hard failure' \
    'dual-backend file journal stderr'
assert_contains "$(cat "$file_diagnostics")" 'KERNEL_LOG_JOURNAL_ATTEMPT_RC=76' \
    'dual-backend file journal rc'
assert_equal 'unavailable' "$MEMBLAZE_KERNEL_LOG_BACKEND" \
    'dual-backend file unavailable marker'

printf '%s\n' 'PASS: kernel-log compatibility and diagnostics contract.'
