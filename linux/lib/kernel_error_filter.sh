#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

# Print severe kernel messages from one captured dmesg file. The XDMA module
# reports its configured H2C/C2H timeout values during a successful load; that
# exact informational line is not a transfer timeout.
memblaze_filter_severe_kernel_messages() {
    local input_file="$1"
    local candidates=""
    local grep_rc=0
    local line=""
    local benign_xdma_timeout_parameters='^(\[[^]]+\][[:space:]]+)?([^[:space:]]+[[:space:]]+kernel:[[:space:]]+)?xdma:xdma_mod_init: desc_blen_max: 0x[0-9a-fA-F]+/[0-9]+, timeout: h2c [0-9]+ c2h [0-9]+ sec\.$'
    [[ -f "$input_file" && -r "$input_file" ]] || {
        printf 'kernel-error filter input is unreadable: %s\n' "$input_file" >&2
        return 2
    }

    if candidates="$(grep -Ei \
        'PCIe Bus Error|AER:.*(corrected|uncorrected|fatal).*error|page allocation failure|BUG:|Oops:|kernel panic|Call Trace:|xdma.*(timed out|timeout|failed|error)|Buffer I/O error|JBD2:.*error|Remounting filesystem read-only|attempt to access beyond end of device' \
        "$input_file")"; then
        :
    else
        grep_rc=$?
        (( grep_rc == 1 )) && return 0
        return "$grep_rc"
    fi

    while IFS= read -r line; do
        [[ "$line" =~ $benign_xdma_timeout_parameters ]] && continue
        printf '%s\n' "$line"
    done <<< "$candidates"
}
