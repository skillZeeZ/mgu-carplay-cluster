#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 mgu-carplay-cluster contributors
#
# mcc.sh -- set up a rooted BMW iDrive 7 (MGU) head unit for:
#   1. a larger CarPlay/Android Auto map on the instrument cluster (panel)
#   2. the Apple/Google Maps arrival (ETA) pill on the cluster map
#
# It is a thin, reversible layer on top of the already-installed GPL tools
# "Maps on cluster" (robertnisipeanu/idrive-apps: robertn_waze_cluster +
# waze-on-cluster + cluster-render). It does NOT patch binaries and NEVER
# touches carplay/aapd. See mcc-lib.sh for the full safety contract.
#
# Run it ON the head unit over SSH, e.g.:
#   sh /tmp/mcc/bin/mcc.sh diagnose
#   sh /tmp/mcc/bin/mcc.sh full-map on
#   sh /tmp/mcc/bin/mcc.sh eta check
#
# NOTE: none of this has been run on a car, executed, or linted anywhere (the
# author had no vehicle access and no POSIX shell to test with). Start with
# `diagnose`, keep the backup it makes, and expect to verify on a unit.

set -u

# shellcheck disable=SC1007  # 'CDPATH= cd' is an intentional env-prefixed command, not an assignment
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=bin/mcc-lib.sh
. "$SELF_DIR/mcc-lib.sh"

usage() {
    cat <<'EOF'
mgu-carplay-cluster -- cluster map + ETA pill helper for a rooted iDrive 7

Usage: sh mcc.sh <command> [options]

Commands:
  diagnose              Read-only report: versions, patch/ETA state, current
                        map target. Safe to run any time. Start here.

  full-map on           Put the map on the whole-cluster `panel` target
                        (centred). Persists in local.conf; takes effect when
                        waze-on-cluster next starts (a head-unit restart).
      [--fill]            Stretch the map edge to edge (0,0,1920,720).
                          WARNING: `panel` draws OVER the gauges, so a filled
                          map can COVER THE SPEEDOMETER. Opt-in only.
      [--rect X,Y,W,H]    Custom target rectangle instead of --fill.
  full-map off          Back to the native under-gauge map slot (target = map).
  full-map status       Show the configured and running map target.

  eta check             Read-only: installed version vs the release that has
                        the ETA request, plus the real woc-patch.sh status.
  eta update            Update waze-on-cluster + the app through mgu-updater
                        (needs the head unit online). The updater's activate
                        re-applies the patch; verify afterwards with
                        `eta check`. Does NOT patch anything itself.

  revert                Restore the local.conf this tool last backed up.
  help                  This text.

Never done by this tool: stop/restart carplay or aapd, or write the binary
patch. Re-patching is the app's "Patch" button / the updater's activate.
EOF
}

require_installed() {
    [ -d "$WOC_DIR" ] || die "waze-on-cluster not installed ($WOC_DIR missing). Install 'Maps on cluster' from the Store first."
}

installed_version() { json_version "$WOC_COMPONENT" 2>/dev/null; }

render_target() { # from status.json, or empty
    [ -r "$WOC_STATUS" ] || return 0
    sed -n 's/.*"target"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$WOC_STATUS" | head -n1
}

# ----- diagnose (read-only) ------------------------------------------------ #
cmd_diagnose() {
    require_installed
    log "=== mgu-carplay-cluster diagnose ==="
    log "waze-on-cluster version: $(installed_version || echo unknown)  (current upstream: $RECOMMENDED_VERSION)"
    log "cluster-render version : $(json_version "$CR_COMPONENT" 2>/dev/null || echo unknown)"
    log "local.conf target      : $(conf_get target "$WOC_LOCAL" 2>/dev/null || echo '<unset -> map>')"
    log "local.conf map_rect    : $(conf_get map_rect "$WOC_LOCAL" 2>/dev/null || echo '<unset -> centred>')"
    log "running map target     : $(render_target || true)  (empty = render idle / map not up)"
    if [ -f "$WOC_PATCH" ]; then
        log "--- woc-patch.sh status (read-only) ---"
        sh "$WOC_PATCH" status 2>&1 | sed 's/^/    /'
        log "(ETA pill needs a 'showui' edit present; 'mapurl: \"map\"' = no ETA requested)"
    else
        warn "woc-patch.sh not found at $WOC_PATCH"
    fi
    log "=== end diagnose ==="
}

# ----- full-map ------------------------------------------------------------ #
cmd_fullmap() {
    _sub=${1:-}; [ $# -gt 0 ] && shift
    case "$_sub" in
        on)     fullmap_on "$@" ;;
        off)    fullmap_off ;;
        status) fullmap_status ;;
        *)      die "full-map: expected on|off|status" ;;
    esac
}

fullmap_on() {
    require_installed; need_root
    _rect="$PANEL_ENLARGE_RECT"; _mode="enlarged 1.5x (aspect kept)"
    while [ $# -gt 0 ]; do
        case "$1" in
            --fill)    _rect="$PANEL_FULL_RECT"; _mode="edge-to-edge (stretched)" ;;
            --rect)    [ $# -ge 2 ] || die "--rect needs X,Y,W,H"; shift; _rect="$1"; _mode="custom rect $1" ;;
            --centred|--centered) _rect=""; _mode="1:1 centred (not enlarged)" ;;
            *)         die "full-map on: unknown option '$1'" ;;
        esac
        shift
    done

    _b=$(backup_file "$WOC_LOCAL") || true
    [ -n "${_b:-}" ] && log "backed up local.conf -> $_b"
    ensure_header "$WOC_LOCAL"

    conf_set target panel "$WOC_LOCAL" || die "failed to set target"
    if [ -n "$_rect" ]; then
        conf_set map_rect "$_rect" "$WOC_LOCAL" || die "failed to set map_rect"
    else
        conf_unset map_rect "$WOC_LOCAL" || true
    fi
    log "configured: target = panel, $_mode"
    warn "panel draws OVER the gauges: a larger map can COVER THE SPEEDOMETER. '--fill' also stretches/upscales the 1088x480 picture; some clusters reject the panel scene and fall back. For the integrated under-gauge map, use: full-map off"
    log "Takes effect on the next waze-on-cluster start (a head-unit restart)."
    log "Live preview from a shell (blocks until Ctrl-C): waze-on-cluster -c $WOC_CURRENT/waze-on-cluster.conf run panel"
}

fullmap_off() {
    require_installed; need_root
    _b=$(backup_file "$WOC_LOCAL") || true
    [ -n "${_b:-}" ] && log "backed up local.conf -> $_b"
    conf_unset target "$WOC_LOCAL" || true
    conf_unset map_rect "$WOC_LOCAL" || true
    log "removed target/map_rect overrides -> back to the native under-gauge map slot (target = map)."
    log "Takes effect on the next waze-on-cluster start (a head-unit restart)."
}

fullmap_status() {
    require_installed
    log "configured target : $(conf_get target "$WOC_LOCAL" 2>/dev/null || echo '<unset -> map>')"
    log "configured map_rect: $(conf_get map_rect "$WOC_LOCAL" 2>/dev/null || echo '<unset -> centred>')"
    log "running target    : $(render_target || true)"
}

# ----- eta ----------------------------------------------------------------- #
cmd_eta() {
    _sub=${1:-}; [ $# -gt 0 ] && shift
    case "$_sub" in
        check)  eta_check ;;
        update) eta_update ;;
        *)      die "eta: expected check|update" ;;
    esac
}

eta_check() {
    require_installed
    _wv=$(installed_version)
    log "waze-on-cluster version: ${_wv:-unknown}  (current upstream: $RECOMMENDED_VERSION)"
    if [ -z "${_wv:-}" ]; then
        warn "cannot read version from $WOC_COMPONENT; check with: node $UPDATER status --json"
    elif ver_ge "$_wv" "$RECOMMENDED_VERSION"; then
        log "This version carries the patch's own ETA request (ShowUI 'Edit 6')."
    else
        log "Older than $RECOMMENDED_VERSION: it lacks the patch's ShowUI 'Edit 6'."
    fi
    log ""
    log "There are TWO cases, and the status below tells which you are in:"
    log "  A) Older carplay build: ETA comes only from the patch's Edit 6. Then updating"
    log "     waze-on-cluster + re-applying the patch may add it -> 'sh mcc.sh eta update'."
    log "  B) Newer BMW carplay (e.g. 23.12.3, setShowUiUrl): stock ALREADY requests"
    log "     showETA=yes, so an update changes nothing. A missing pill is then Apple-side,"
    log "     not something this tool can fix. (Your firmware may be such a build.)"
    if [ -f "$WOC_PATCH" ]; then
        log "--- woc-patch.sh status: map URL / ShowUI state (ground truth) ---"
        sh "$WOC_PATCH" status 2>&1 | grep -iE 'mapurl|showui|map URL|ETA' | sed 's/^/    /'
        log "    (a 'showui:' line present = your build has the edit site; 'NOT APPLIED' /"
        log "     'not applicable' = it does not, which usually means case B)"
    fi
    log "Honest caveats: upstream documents the card only as 'arrival time' -- kilometres"
    log "are NOT documented; the Apple Maps pill is not marked car-verified upstream."
}

eta_update() {
    require_installed
    log "NOTE: on a newer carplay build (case B in 'eta check') an update changes NOTHING."
    log "The reliable path is the Store/app update, which refreshes, installs and re-applies"
    log "the patch for you. This command is a convenience and needs the head unit ONLINE."
    _node=$(command -v node 2>/dev/null || true)
    if [ -z "${_node:-}" ] || [ ! -f "$UPDATER" ]; then
        warn "mgu-updater CLI not found ($UPDATER). Use the Store/app: update 'Maps on cluster',"
        warn "then re-apply the patch (Patch entfernen -> Patchen)."
        return 1
    fi
    _tmp="/tmp/mcc-updater.$$"
    log "mgu-updater check (refresh the catalogue so a newer version is seen) ..."
    "$_node" "$UPDATER" check > "$_tmp" 2>&1 || warn "check returned nonzero (the CLI may not support it; the Store does)"
    sed 's/^/    /' "$_tmp"
    for _id in waze-on-cluster robertn_waze_cluster; do
        log "mgu-updater install $_id ..."
        if "$_node" "$UPDATER" install "$_id" > "$_tmp" 2>&1; then
            sed 's/^/    /' "$_tmp"
        else
            sed 's/^/    /' "$_tmp"
            warn "install $_id returned nonzero (see output above)"
        fi
    done
    rm -f "$_tmp"
    log ""
    log "If it upgraded, the deploy step re-applies the patch (patchd activate) and shows a"
    log "restart pending; it does NOT restart carplay. If nothing changed, do it from the app:"
    log "Patch entfernen -> Patchen. Never run 'woc-patch.sh apply' by hand. Then: sh mcc.sh eta check"
}

# ----- revert -------------------------------------------------------------- #
cmd_revert() {
    require_installed; need_root
    # shellcheck disable=SC2012  # busybox has no stat sort; ls -t on our own backup dirs is fine
    _latest=$(ls -1dt "$MCC_BACKUPS"/*/ 2>/dev/null | head -n1)
    if [ -n "${_latest:-}" ] && [ -f "${_latest}waze-on-cluster.local.conf" ]; then
        _b=$(backup_file "$WOC_LOCAL") || true
        [ -n "${_b:-}" ] && log "safety copy of current local.conf -> $_b"
        if cp -p "${_latest}waze-on-cluster.local.conf" "$WOC_LOCAL"; then
            chmod 0644 "$WOC_LOCAL" 2>/dev/null || true
            log "restored local.conf from $_latest"
        else
            die "restore failed"
        fi
    else
        warn "no backup found; removing this tool's overrides instead"
        conf_unset target "$WOC_LOCAL" || true
        conf_unset map_rect "$WOC_LOCAL" || true
    fi
    log "NOTE: 'eta update' is a forward change (component versions) and is NOT undone here."
    log "Changes take effect on the next waze-on-cluster start (a head-unit restart)."
}

# --------------------------------------------------------------------------- #
_cmd=${1:-help}; [ $# -gt 0 ] && shift
case "$_cmd" in
    diagnose)             cmd_diagnose ;;
    full-map|fullmap|map) cmd_fullmap "$@" ;;
    eta)                  cmd_eta "$@" ;;
    revert)               cmd_revert ;;
    help|-h|--help)       usage ;;
    *) err "unknown command: $_cmd"; echo; usage; exit 1 ;;
esac
