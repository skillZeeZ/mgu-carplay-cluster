# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-11-17
### Added
- `bin/mcc.sh` with `diagnose`, `full-map on|off|status`, `eta check|update`
  and `revert`, plus `bin/mcc-lib.sh` (POSIX-sh / BusyBox helpers).
- `config/waze-on-cluster.local.conf` reference template (`target`, `map_rect`).
- `remote/mcc-ssh.ps1` Windows SSH runner.
- GPL-3.0 license and documentation.

### Notes
- Not run on a car, executed, or linted. All behaviour derived from upstream
  `robertnisipeanu/idrive-apps` source and a read-only unit probe.
- `full-map on` uses the `panel` target centred (safe default); `--fill`
  stretches edge-to-edge, which draws over the gauges (can cover the
  speedometer) and upscales the 1088×480 picture.
- The ETA pill needs the ShowUI edit ("Edit 6"), which ships only in the
  current `waze-on-cluster` release line (upstream 0.10.6); 0.10.0 asks for the
  map without ETA. Fix = update + re-apply the patch, then verify via
  `woc-patch.sh status`.
