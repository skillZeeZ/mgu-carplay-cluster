# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 mgu-carplay-cluster contributors
#
# Shared helpers for mcc.sh. POSIX sh / BusyBox ash safe (the MGU head unit
# runs BusyBox on Linux 4.14). Sourced, not executed.
#
# SAFETY CONTRACT (read before editing):
#   * This project NEVER stops, kills or restarts `carplay` or `aapd`.
#     Upstream: "CarPlay dumps core on SIGTERM, which restarts the head unit."
#   * It NEVER re-implements or writes the binary patches to /usr/bin/carplay
#     or /usr/bin/aapd. Re-patching is left to the Maps-on-cluster app /
#     patchd (which has boot recovery). We only read `woc-patch.sh status`.
#   * It only writes under /var/opt (no remount of / needed) and always backs
#     up a file before changing it.

# ----- paths (upstream layout; see idrive-apps/native/waze-on-cluster) ------
WOC_DIR="/var/opt/waze-on-cluster"
WOC_CURRENT="$WOC_DIR/current"
WOC_LOCAL="$WOC_DIR/waze-on-cluster.local.conf"
WOC_COMPONENT="$WOC_CURRENT/component.json"
WOC_PATCH="$WOC_CURRENT/woc-patch.sh"
WOC_STATUS="/run/waze-on-cluster/status.json"
CR_COMPONENT="/var/opt/cluster-render/current/component.json"
UPDATER="/var/opt/mgu-updater/current/updater.js"

MCC_STATE="/var/opt/mgu-carplay-cluster"
MCC_BACKUPS="$MCC_STATE/backups"

# The CarPlay ETA request -- the ShowUI "Edit 6" that asks the phone for the
# arrival pill -- ships only in the current waze-on-cluster release line.
# Releases up to 0.10.3 do not have it; 0.10.0 writes the plain map URL
# (patchd reports mapurl "map") and never asks for ETA. So there is no simple
# version threshold that means "ETA works": to get the pill you run the
# current release AND re-apply the patch, then read woc-patch.sh status to see
# whether the ShowUI edit actually took on this carplay build. Current upstream:
RECOMMENDED_VERSION="0.10.6"

# ID7 cluster panel is 1920x720 (upstream README "Map size and upload").
# NOTE: the `panel` render target draws OVER the gauges (cluster-render
# README), so ANY map on it sits over the gauges; a larger one can cover the
# speedometer/tacho. There is no "bigger AND under the gauges" option.
#   PANEL_ENLARGE_RECT: 1.5x of 1088x480, aspect kept, centred (144 px margins).
#                       Bigger and undistorted, but over the gauges.
#   PANEL_FULL_RECT    : edge to edge; maximal but stretched (aspect 2.27->2.67)
#                        and covers the whole cluster incl. the gauges.
PANEL_ENLARGE_RECT="144,0,1632,720"
PANEL_FULL_RECT="0,0,1920,720"

# ----- output ---------------------------------------------------------------
log()  { printf '[mcc] %s\n' "$*"; }
warn() { printf '[mcc] WARN: %s\n' "$*" >&2; }
err()  { printf '[mcc] ERROR: %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

is_root() { [ "$(id -u 2>/dev/null)" = "0" ]; }
need_root() { is_root || die "must run as root on the head unit"; }

ts() { date -u +%Y%m%d-%H%M%S 2>/dev/null || date +%Y%m%d-%H%M%S; }

# ----- locate the tool binary / main conf (installed layout can vary) -------
find_woc_bin() {
    if [ -x "$WOC_CURRENT/waze-on-cluster" ]; then
        printf '%s\n' "$WOC_CURRENT/waze-on-cluster"; return 0
    fi
    _b=$(command -v waze-on-cluster 2>/dev/null) && [ -n "$_b" ] && { printf '%s\n' "$_b"; return 0; }
    return 1
}

find_main_conf() {
    for _c in "$WOC_CURRENT/waze-on-cluster.conf" \
              "$WOC_DIR/waze-on-cluster.conf" \
              "$WOC_CURRENT/etc/waze-on-cluster.conf"; do
        [ -f "$_c" ] && { printf '%s\n' "$_c"; return 0; }
    done
    _c=$(find "$WOC_CURRENT" -name 'waze-on-cluster.conf' -type f 2>/dev/null | head -n1)
    [ -n "$_c" ] && { printf '%s\n' "$_c"; return 0; }
    return 1
}

# ----- tiny JSON / conf readers (no jq on the unit) -------------------------
json_version() { # file -> first "version":"X.Y.Z"
    [ -f "$1" ] || return 1
    sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -n1
}

# true if version $1 >= version $2 (dotted X.Y.Z). Runs in a subshell so IFS
# and positional params do not leak to the caller.
ver_ge() (
    a=$1; b=$2
    a=$(printf '%s' "$a" | tr -cd '0-9.')
    b=$(printf '%s' "$b" | tr -cd '0-9.')
    IFS=.
    # shellcheck disable=SC2086
    set -- $a; a1=${1:-0}; a2=${2:-0}; a3=${3:-0}
    # shellcheck disable=SC2086
    set -- $b; b1=${1:-0}; b2=${2:-0}; b3=${3:-0}
    [ "${a1:-0}" -gt "${b1:-0}" ] && exit 0
    [ "${a1:-0}" -lt "${b1:-0}" ] && exit 1
    [ "${a2:-0}" -gt "${b2:-0}" ] && exit 0
    [ "${a2:-0}" -lt "${b2:-0}" ] && exit 1
    [ "${a3:-0}" -ge "${b3:-0}" ]
)

# value of KEY in a `key = value` conf FILE (last occurrence wins), trimmed.
conf_get() { # key file
    [ -f "$2" ] || return 1
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\(.*\)\$/\1/p" "$2" \
        | sed 's/[[:space:]]*$//' | tail -n1
}

# ----- conf editors (idempotent, atomic; keep every other line) ------------
conf_set() { # key value file
    _k=$1; _v=$2; _f=$3; _tmp="$_f.mcc.$$"
    if [ -f "$_f" ]; then
        awk -v k="$_k" -v v="$_v" '
            BEGIN { done = 0 }
            {
                if (done == 0 && $0 ~ ("^[ \t]*" k "[ \t]*=")) {
                    print k " = " v; done = 1; next
                }
                print
            }
            END { if (done == 0) print k " = " v }
        ' "$_f" > "$_tmp" || { rm -f "$_tmp"; return 1; }
    else
        printf '%s = %s\n' "$_k" "$_v" > "$_tmp" || { rm -f "$_tmp"; return 1; }
    fi
    mv "$_tmp" "$_f"
    chmod 0644 "$_f" 2>/dev/null || true   # the service runs as hmi_5000 and must read it
}

conf_unset() { # key file  (remove any line setting KEY)
    _k=$1; _f=$2; _tmp="$_f.mcc.$$"
    [ -f "$_f" ] || return 0
    awk -v k="$_k" '
        { if ($0 ~ ("^[ \t]*" k "[ \t]*=")) next; print }
    ' "$_f" > "$_tmp" || { rm -f "$_tmp"; return 1; }
    mv "$_tmp" "$_f"
    chmod 0644 "$_f" 2>/dev/null || true
}

ensure_header() { # file -- create with an SPDX header if it does not exist
    [ -f "$1" ] && return 0
    mkdir -p "$(dirname "$1")" 2>/dev/null || true
    {
        printf '# SPDX-License-Identifier: GPL-3.0-or-later\n'
        printf '# waze-on-cluster local overrides. Managed in part by mgu-carplay-cluster.\n'
        printf '# Each key replaces the default from the built-in waze-on-cluster.conf.\n'
    } > "$1"
    chmod 0644 "$1" 2>/dev/null || true
}

backup_file() { # file -> copies it under MCC_BACKUPS/<run-ts>/, echoes the copy
    [ -f "$1" ] || return 0
    _dir="$MCC_BACKUPS/$MCC_RUN_TS"
    mkdir -p "$_dir" 2>/dev/null || { warn "cannot create backup dir $_dir"; return 1; }
    _dst="$_dir/$(basename "$1")"
    cp -p "$1" "$_dst" 2>/dev/null || { warn "backup of $1 failed"; return 1; }
    printf '%s\n' "$_dst"
}

# One timestamp per mcc.sh run, shared by all backups of that run.
MCC_RUN_TS="${MCC_RUN_TS:-$(ts)}"
