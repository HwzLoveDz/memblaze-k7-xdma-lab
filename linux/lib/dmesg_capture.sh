#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Memblaze K7 XDMA Lab contributors

# Shared kernel-log capture helpers. Callers define sudo_cmd as an array before
# invoking these functions. A run selects one backend for every before/after
# capture so byte-prefix comparisons remain meaningful. Plain dmesg is the
# primary backend: util-linux prints monotonic timestamps by default. The
# current-boot kernel journal is the fallback when dmesg itself is unavailable.

MEMBLAZE_KERNEL_LOG_BACKEND=""

memblaze_kernel_log_valid_variable_name() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "$1" != __memblaze_* ]]
}

memblaze_kernel_log_command() {
    case "$MEMBLAZE_KERNEL_LOG_BACKEND" in
        dmesg-default)
            "${sudo_cmd[@]}" dmesg
            ;;
        journalctl-kernel-short-monotonic)
            "${sudo_cmd[@]}" journalctl --dmesg --boot=0 --no-pager \
                --output=short-monotonic
            ;;
        *)
            return 2
            ;;
    esac
}

memblaze_select_kernel_log_text() {
    local __memblaze_output_variable="$1"
    local __memblaze_diagnostics_variable="$2"
    local __memblaze_dmesg_output=""
    local __memblaze_dmesg_rc=0
    local __memblaze_journal_output=""
    local __memblaze_journal_rc=127
    local __memblaze_diagnostics=""

    memblaze_kernel_log_valid_variable_name "$__memblaze_output_variable" || return 2
    memblaze_kernel_log_valid_variable_name "$__memblaze_diagnostics_variable" || return 2
    local -n __memblaze_kernel_log_output_ref="$__memblaze_output_variable"
    local -n __memblaze_kernel_log_diagnostics_ref="$__memblaze_diagnostics_variable"

    if __memblaze_dmesg_output="$("${sudo_cmd[@]}" dmesg 2>&1)"; then
        MEMBLAZE_KERNEL_LOG_BACKEND="dmesg-default"
        __memblaze_kernel_log_output_ref="$__memblaze_dmesg_output"
        __memblaze_kernel_log_diagnostics_ref=""
        return 0
    else
        __memblaze_dmesg_rc=$?
    fi

    if command -v journalctl >/dev/null 2>&1; then
        if __memblaze_journal_output="$("${sudo_cmd[@]}" journalctl --dmesg --boot=0 \
            --no-pager --output=short-monotonic 2>&1)"; then
            MEMBLAZE_KERNEL_LOG_BACKEND="journalctl-kernel-short-monotonic"
            __memblaze_kernel_log_output_ref="$__memblaze_journal_output"
            printf -v __memblaze_diagnostics \
                'plain dmesg failed with exit status %s; captured output follows:\n%s' \
                "$__memblaze_dmesg_rc" "$__memblaze_dmesg_output"
            __memblaze_kernel_log_diagnostics_ref="$__memblaze_diagnostics"
            return 0
        else
            __memblaze_journal_rc=$?
        fi
    else
        __memblaze_journal_output="journalctl was not found"
    fi

    MEMBLAZE_KERNEL_LOG_BACKEND="unavailable"
    __memblaze_kernel_log_output_ref=""
    printf -v __memblaze_diagnostics \
        'plain dmesg failed with exit status %s; captured output follows:\n%s\ncurrent-boot kernel journal failed with exit status %s; captured output follows:\n%s' \
        "$__memblaze_dmesg_rc" "$__memblaze_dmesg_output" \
        "$__memblaze_journal_rc" "$__memblaze_journal_output"
    __memblaze_kernel_log_diagnostics_ref="$__memblaze_diagnostics"
    return 1
}

memblaze_select_kernel_log_file() {
    local output_file="$1"
    local diagnostics_file="$2"
    local dmesg_rc=0
    local journal_rc=127

    : > "$diagnostics_file"
    printf 'KERNEL_LOG_DMESG_ATTEMPT_COMMAND=dmesg\n' >> "$diagnostics_file"
    if "${sudo_cmd[@]}" dmesg > "$output_file" 2>> "$diagnostics_file"; then
        MEMBLAZE_KERNEL_LOG_BACKEND="dmesg-default"
        printf 'KERNEL_LOG_DMESG_ATTEMPT_RC=0\nKERNEL_LOG_BACKEND=dmesg-default\n' \
            >> "$diagnostics_file"
        return 0
    else
        dmesg_rc=$?
    fi
    printf 'KERNEL_LOG_DMESG_ATTEMPT_RC=%s\n' "$dmesg_rc" >> "$diagnostics_file"

    printf 'KERNEL_LOG_JOURNAL_ATTEMPT_COMMAND=journalctl --dmesg --boot=0 --no-pager --output=short-monotonic\n' \
        >> "$diagnostics_file"
    if ! command -v journalctl >/dev/null 2>&1; then
        printf 'journalctl was not found\nKERNEL_LOG_JOURNAL_ATTEMPT_RC=127\nKERNEL_LOG_BACKEND=unavailable\n' \
            >> "$diagnostics_file"
        MEMBLAZE_KERNEL_LOG_BACKEND="unavailable"
        return 1
    fi
    if "${sudo_cmd[@]}" journalctl --dmesg --boot=0 --no-pager \
        --output=short-monotonic > "$output_file" 2>> "$diagnostics_file"; then
        MEMBLAZE_KERNEL_LOG_BACKEND="journalctl-kernel-short-monotonic"
        printf 'KERNEL_LOG_JOURNAL_ATTEMPT_RC=0\nKERNEL_LOG_BACKEND=journalctl-kernel-short-monotonic\n' \
            >> "$diagnostics_file"
        return 0
    else
        journal_rc=$?
    fi

    MEMBLAZE_KERNEL_LOG_BACKEND="unavailable"
    printf 'KERNEL_LOG_JOURNAL_ATTEMPT_RC=%s\nKERNEL_LOG_BACKEND=unavailable\n' \
        "$journal_rc" >> "$diagnostics_file"
    return 1
}

memblaze_capture_kernel_log_text() {
    local __memblaze_output_variable="$1"
    local __memblaze_diagnostics_variable="$2"
    local __memblaze_captured_output=""
    local __memblaze_capture_rc=0
    local __memblaze_diagnostics=""

    memblaze_kernel_log_valid_variable_name "$__memblaze_output_variable" || return 2
    memblaze_kernel_log_valid_variable_name "$__memblaze_diagnostics_variable" || return 2
    local -n __memblaze_kernel_log_output_ref="$__memblaze_output_variable"
    local -n __memblaze_kernel_log_diagnostics_ref="$__memblaze_diagnostics_variable"
    [[ "$MEMBLAZE_KERNEL_LOG_BACKEND" == "dmesg-default" \
        || "$MEMBLAZE_KERNEL_LOG_BACKEND" == "journalctl-kernel-short-monotonic" ]] \
        || return 2

    if __memblaze_captured_output="$(memblaze_kernel_log_command 2>&1)"; then
        __memblaze_kernel_log_output_ref="$__memblaze_captured_output"
        __memblaze_kernel_log_diagnostics_ref=""
        return 0
    else
        __memblaze_capture_rc=$?
    fi

    __memblaze_kernel_log_output_ref=""
    printf -v __memblaze_diagnostics \
        'kernel-log capture with backend %s failed with exit status %s; captured output follows:\n%s' \
        "$MEMBLAZE_KERNEL_LOG_BACKEND" "$__memblaze_capture_rc" \
        "$__memblaze_captured_output"
    __memblaze_kernel_log_diagnostics_ref="$__memblaze_diagnostics"
    return "$__memblaze_capture_rc"
}

memblaze_capture_kernel_log_file() {
    local output_file="$1"
    local diagnostics_file="$2"
    local capture_rc=0

    [[ "$MEMBLAZE_KERNEL_LOG_BACKEND" == "dmesg-default" \
        || "$MEMBLAZE_KERNEL_LOG_BACKEND" == "journalctl-kernel-short-monotonic" ]] \
        || return 2

    : > "$diagnostics_file"
    printf 'KERNEL_LOG_BACKEND=%s\n' "$MEMBLAZE_KERNEL_LOG_BACKEND" \
        >> "$diagnostics_file"
    if memblaze_kernel_log_command > "$output_file" 2>> "$diagnostics_file"; then
        printf 'KERNEL_LOG_CAPTURE_RC=0\n' >> "$diagnostics_file"
        return 0
    else
        capture_rc=$?
    fi

    printf 'KERNEL_LOG_CAPTURE_RC=%s\n' "$capture_rc" >> "$diagnostics_file"
    return "$capture_rc"
}
