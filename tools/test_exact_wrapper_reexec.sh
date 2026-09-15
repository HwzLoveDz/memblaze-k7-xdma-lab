#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
export LC_ALL=C

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly repo_root="$(cd -- "$script_dir/.." && pwd)"
readonly wrapper="$repo_root/linux/run_exact_image_regression.sh"
readonly temp_root="$(mktemp -d)"
readonly capture="$temp_root/systemd-inhibit.args"

cleanup() {
    rm -rf -- "$temp_root"
}
trap cleanup EXIT

cat > "$temp_root/systemd-inhibit" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\0' "$@" > "${MEMBLAZE_TEST_CAPTURE:?}"
EOF
chmod 700 "$temp_root/systemd-inhibit"

args=(
    --confirm-exact-image-and-ddr-write
    --bitstream /tmp/test.bit
    --bitstream-sha256 /tmp/test.bit.sha256
    --jtag-report /tmp/jtag.txt
    --jtag-report-sha256 /tmp/jtag.txt.sha256
    --mok-certificate /tmp/mok.der
    --mok-private /tmp/mok.priv
    --expected-live-disk-serial-prefix 0123456789abcdef
    --expected-bitstream-sha256 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
)

PATH="$temp_root:$PATH" MEMBLAZE_TEST_CAPTURE="$capture" \
    bash "$wrapper" "${args[@]}"

mapfile -d '' -t actual < "$capture"
expected=(
    --what=idle
    --mode=block
    --who=memblaze-k7-xdma-lab
    '--why=Protected one-session FPGA DDR regression'
    env
    MEMBLAZE_IDLE_INHIBITED=1
    bash
    "$wrapper"
    "${args[@]}"
)

[[ ${#actual[@]} -eq ${#expected[@]} ]] || {
    printf 'FAIL: expected %d re-exec arguments, captured %d\n' \
        "${#expected[@]}" "${#actual[@]}" >&2
    exit 1
}

for index in "${!expected[@]}"; do
    [[ "${actual[$index]}" == "${expected[$index]}" ]] || {
        printf 'FAIL: re-exec argument %d: expected <%s>, captured <%s>\n' \
            "$index" "${expected[$index]}" "${actual[$index]}" >&2
        exit 1
    }
done

printf 'PASS: systemd-inhibit re-exec preserves every validated wrapper argument.\n'
