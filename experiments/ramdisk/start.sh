#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# sudo commands intentionally redirect into logs owned by the Ubuntu user.
# shellcheck disable=SC2024
set -Eeuo pipefail
export LC_ALL=C
umask 077

src="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$src" == /cdrom/* ]]; then
    if [[ -f "$src/SHA256SUMS.txt" ]]; then
        ( cd "$src" && sha256sum --check --quiet SHA256SUMS.txt )
    fi
    dst="$HOME/MEMBLAZE_RAMDISK_2026-10-01"
    mkdir -p "$dst"
    cp -a -- "$src/." "$dst/"
    exec bash "$dst/start.sh" "$@"
fi
(( EUID != 0 )) || { echo 'Run as your Ubuntu user, without sudo.' >&2; exit 1; }
[[ $# == 0 ]] || { echo 'Usage: bash start.sh' >&2; exit 1; }

run="$HOME/memblaze-ramdisk-runs/$(date -u +%Y%m%dT%H%M%S)"
mkdir -p "$run"
say() { printf '%s\n' "$*" | tee -a "$run/summary.log"; }
fail() { say "STOP: $*"; exit 1; }
socket="$run/ramdisk.sock"
pidfile="$run/nbdkit.pid"
mountpoint="$HOME/FPGA_RAM"
support="$src/support"
[[ -f "$support/04_load_verify.sh" ]] || support="$src/../../linux"
[[ -f "$support/04_load_verify.sh" && -f "$support/99_cleanup.sh" ]] \
    || fail 'XDMA load/cleanup scripts are missing.'

# One instance across users; no stale-file deletion or lock stealing.
[[ ! -L /tmp/memblaze-fpga-ramdisk.lock ]] || fail 'lock path is a symlink'
exec 9>/tmp/memblaze-fpga-ramdisk.lock
flock -n 9 || fail 'another FPGA RAM disk session is active'

driver_owned=0
attached=0
mounted=0
server_job=''
nbd_dev=''
client_pid=''
server_pid=''

connection_pid() {
    cat "/sys/block/${nbd_dev##*/}/pid" 2>/dev/null || true
}

owned_nbd() {
    [[ "$nbd_dev" =~ ^/dev/nbd[0-9]+$ && -b "$nbd_dev" ]] || return 1
    [[ "$(stat -c %t "$nbd_dev")" == 2b ]] || return 1
    [[ -r "/sys/block/${nbd_dev##*/}/pid" ]] || return 1
    [[ "$client_pid" =~ ^[1-9][0-9]*$ && "$(connection_pid)" == "$client_pid" ]] || return 1
    [[ "$(sudo blockdev --getsize64 "$nbd_dev")" == 4294967296 ]] || return 1
}

# ShellCheck 0.9 does not follow the EXIT trap's call into this function.
# shellcheck disable=SC2317
cleanup() {
    local rc=$? clean_rc=0
    trap - EXIT INT TERM
    set +e
    if (( mounted )); then
        if [[ "$(findmnt -rn -M "$mountpoint" -o SOURCE)" != "$nbd_dev" ]]; then
            say "CLEANUP=BLOCKED: mount source changed; server PID=$server_pid retained."
            exit 1
        fi
        while ! sudo umount "$mountpoint"; do
            say "Close files/terminals using $mountpoint, then press Enter to retry cleanup."
            if ! read -r </dev/tty; then
                say "CLEANUP=BLOCKED: keep server PID=$server_pid alive until $mountpoint is unmounted."
                say "Then: sudo nbd-client -d $nbd_dev; sudo kill -TERM $server_pid"
                exit 1
            fi
        done
        mounted=0
    fi
    if (( attached )); then
        if owned_nbd && sudo timeout 20s nbd-client -d "$nbd_dev"; then
            for (( attempt=0; attempt<50; attempt++ )); do
                [[ ! "$(connection_pid)" =~ ^[1-9][0-9]*$ \
                    && "$(cat "/sys/block/${nbd_dev##*/}/size")" == 0 ]] && break
                sleep 0.1
            done
            if [[ "$(connection_pid)" =~ ^[1-9][0-9]*$ \
                || "$(cat "/sys/block/${nbd_dev##*/}/size")" != 0 ]]; then
                say "CLEANUP=BLOCKED: $nbd_dev is still disconnecting; server PID=$server_pid retained."
                exit 1
            fi
            attached=0
        else
            say "CLEANUP=BLOCKED: could not disconnect the owned $nbd_dev; server PID=$server_pid retained."
            exit 1
        fi
    fi
    if [[ -n "$server_pid" && -r "/proc/$server_pid/cmdline" ]]; then
        if sudo grep -zFq -- "$socket" "/proc/$server_pid/cmdline"; then
            sudo kill -TERM "$server_pid" || clean_rc=1
            for (( attempt=0; attempt<50; attempt++ )); do
                sudo kill -0 "$server_pid" 2>/dev/null || break
                sleep 0.1
            done
            if sudo kill -0 "$server_pid" 2>/dev/null; then
                sudo grep -zFq -- "$socket" "/proc/$server_pid/cmdline" \
                    && sudo kill -KILL "$server_pid"
            fi
        else
            say 'Server PID no longer identifies this session; refusing to signal it.'
            exit 1
        fi
    elif [[ -n "$server_job" ]]; then
        # If startup failed before the pidfile, stop only our direct child.
        kill -TERM "$server_job" 2>/dev/null || true
    fi
    [[ -z "$server_job" ]] || wait "$server_job" 2>/dev/null
    rm -f -- "$socket" "$pidfile"
    if (( driver_owned )); then
        bash "$support/99_cleanup.sh" >"$run/driver-cleanup.log" 2>&1 || clean_rc=1
    fi
    if [[ -n "$nbd_dev" && "$(connection_pid)" =~ ^[1-9][0-9]*$ ]]; then
        say "CLEANUP: $nbd_dev still has a connection PID"
        clean_rc=1
    fi
    say "RAMDISK_CLEANUP_RC=$clean_rc"
    say "LOG_DIRECTORY=$run"
    if (( rc == 130 || rc == 143 )); then rc=0; fi
    (( clean_rc == 0 )) || rc=1
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sudo -v
say "LOG_DIRECTORY=$run"
say "KERNEL=$(uname -r)"
say 'Preparing 4 GiB FPGA DDR RAM disk...'

deps_ok() {
    command -v nbdkit >/dev/null && command -v nbd-client >/dev/null \
        && command -v mkfs.ext4 >/dev/null && nbdkit python --dump-plugin >/dev/null 2>&1
}
if ! deps_ok; then
    if [[ -d "$src/debs" ]]; then
        packages=("$src"/debs/*.deb)
        sudo apt-get install -y --no-install-recommends "${packages[@]}" \
            >"$run/install.log" 2>&1 || { tail -n 30 "$run/install.log"; fail 'dependency install failed'; }
    else
        sudo apt-get update >"$run/install.log" 2>&1
        sudo apt-get install -y --no-install-recommends nbdkit nbdkit-plugin-python nbd-client \
            >>"$run/install.log" 2>&1 || { tail -n 30 "$run/install.log"; fail 'dependency install failed'; }
    fi
fi
deps_ok || fail 'nbdkit Python plugin / nbd-client unavailable'
sudo modprobe nbd || fail "nbd kernel module missing; install linux-modules-extra-$(uname -r) and retry"

mapfile -t endpoints < <(lspci -Dnn -d 10ee:7024 | awk '{print $1}')
(( ${#endpoints[@]} == 1 )) || fail '10ee:7024 absent or ambiguous; configure FPGA before host enumeration'
if [[ ! -d /sys/module/xdma ]]; then
    if ! bash "$support/04_load_verify.sh" >"$run/driver-load.log" 2>&1; then
        tail -n 35 "$run/driver-load.log"
        fail 'XDMA load failed; see driver-load.log'
    fi
    driver_owned=1
fi
sudo python3 "$src/xdma_backend.py" >"$run/device-check.log" 2>&1 \
    || { cat "$run/device-check.log"; fail 'FPGA DDR identity/alignment check failed'; }
say "ENDPOINT=${endpoints[0]}"

mkdir -p "$mountpoint"
findmnt -rn -M "$mountpoint" >/dev/null && fail 'FPGA_RAM is already mounted'
[[ -z "$(find "$mountpoint" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
    || fail 'FPGA_RAM directory must be empty before mounting'

for candidate in /sys/block/nbd*; do
    [[ -d "$candidate" ]] || continue
    candidate_dev="/dev/${candidate##*/}"
    [[ -b "$candidate_dev" && "$(cat "$candidate/size")" == 0 ]] || continue
    [[ ! "$(cat "$candidate/pid" 2>/dev/null || true)" =~ ^[1-9][0-9]*$ ]] || continue
    [[ -z "$(find "$candidate/holders" -mindepth 1 -maxdepth 1 -print -quit)" ]] || continue
    findmnt -rn -S "$candidate_dev" >/dev/null && continue
    nbd_dev="$candidate_dev"
    break
done
[[ -n "$nbd_dev" ]] || fail 'no unused NBD device is available'

say 'Clearing FPGA DDR (4 GiB)...'
sudo python3 "$src/xdma_backend.py" --zero >"$run/zero-ddr.log" 2>&1 \
    || { cat "$run/zero-ddr.log"; fail 'DDR zero fill failed'; }

# Keep terminal Ctrl+C away from the server until cleanup has unmounted ext4.
setsid --wait sudo -n nbdkit --foreground --exit-with-parent --unix "$socket" --pidfile "$pidfile" \
    python "$src/xdma_nbd.py" device=0 >"$run/nbdkit.log" 2>&1 &
server_job=$!
for (( attempt=0; attempt<100; attempt++ )); do
    [[ -S "$socket" && -s "$pidfile" ]] && break
    kill -0 "$server_job" 2>/dev/null || { cat "$run/nbdkit.log"; fail 'nbdkit exited at startup'; }
    sleep 0.1
done
[[ -S "$socket" && -s "$pidfile" ]] || fail 'nbdkit startup timed out'
server_pid="$(sudo cat "$pidfile")"
attach_rc=0
sudo timeout 30s nbd-client -u "$socket" "$nbd_dev" -b 512 -t 30 -L \
    >"$run/nbd-client.log" 2>&1 || attach_rc=$?
for (( attempt=0; attempt<20; attempt++ )); do
    client_pid="$(connection_pid)"
    [[ "$client_pid" =~ ^[1-9][0-9]*$ ]] && break
    (( attach_rc == 0 )) || break
    sleep 0.1
done
if [[ "$client_pid" =~ ^[1-9][0-9]*$ ]] \
    && sudo grep -zFq -- "$socket" "/proc/$client_pid/cmdline"; then
    attached=1
fi
(( attach_rc == 0 )) || { cat "$run/nbd-client.log"; fail 'NBD attach failed'; }
(( attached )) || fail 'NBD client PID does not identify this session'
owned_nbd || fail 'NBD device identity/capacity mismatch'
findmnt -rn -S "$nbd_dev" >/dev/null && fail 'selected NBD is already mounted'
[[ -z "$(find "/sys/block/${nbd_dev##*/}/holders" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
    || fail 'selected NBD has another holder'

# The sole format target is the owned NBD export backed by FPGA DDR.
sudo mkfs.ext4 -q -F -m 0 -L FPGA_RAM \
    -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 "$nbd_dev" >"$run/mkfs.log" 2>&1
sudo mount -t ext4 -o nosuid,nodev "$nbd_dev" "$mountpoint"
mounted=1
sudo chown "$(id -u):$(id -g)" "$mountpoint"
python3 "$src/file_demo.py" "$mountpoint" | tee "$run/file-demo.json"
say 'RAMDISK_FILE_COMPARE=PASS'
say "RAMDISK_DEVICE=$nbd_dev"
say "RAMDISK_MOUNT=$mountpoint"
say 'Ready: use ~/FPGA_RAM to copy/open temporary files. Power loss loses their contents.'
say 'Do not run other DDR-write experiments while this filesystem is mounted.'
say 'Keep this terminal open. Press Ctrl+C here to unmount and clean up.'
wait "$server_job"
fail 'nbdkit stopped unexpectedly'
