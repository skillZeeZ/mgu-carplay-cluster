# mgu-carplay-cluster

Helper for a **rooted BMW iDrive 7 (MGU)** head unit that configures two things
on the instrument cluster (Kombi):

1. **A larger CarPlay / Android Auto map** on the whole-cluster `panel` target
   (optionally stretched edge-to-edge — with real caveats, see below).
2. **The Apple / Google Maps arrival (ETA) pill** on the cluster map.

It is a thin, reversible layer **on top of** the GPL project
[**Maps on cluster**](https://github.com/robertnisipeanu/idrive-apps)
(`robertn_waze_cluster` + `waze-on-cluster` + `cluster-render`). It writes the
documented config override and drives the already-installed tools — it **does
not** re-implement or write any binary patch.

> ### ⚠️ Honest status — read this
> - **Nothing here has been run on a car, executed, or even linted.** It was
>   written from the upstream source and a read-only probe of one unit. Treat
>   it as a reviewed starting point: run `diagnose` first, keep the backup it
>   makes, verify on your unit.
> - This is for **your own rooted vehicle**. Head-unit changes can misbehave;
>   there is boot recovery for the *patch*, not for your config mistakes.
> - **A bigger map covers the gauges.** The `panel` target draws **over** the
>   gauges, and there is **no "bigger *and* under the gauges"** option.
>   `full-map on` enlarges to 1.5× (aspect kept) on `panel`, which already sits
>   over the gauges; `--fill` stretches edge-to-edge and can **hide the
>   speedometer**. The crisp, integrated map is the under-gauge `map` slot
>   (`full-map off`). Some clusters also reject the panel scene and fall back.
> - **The ETA pill is best-effort.** Upstream documents it only as an
>   "arrival-time" card — **kilometres are not documented** — and the Apple
>   Maps pill specifically is **not marked car-verified** upstream. It may not
>   appear even when everything is configured correctly.

## How each feature works

### The map on the cluster
`waze-on-cluster` draws the phone's cluster map as a video layer via
`cluster-render`. Its `target` chooses the render slot
(sizes from upstream `cluster-render/README.md`):

| target | size | where |
|---|---|---|
| `map`   | 1088×480 | central map area, **under** the gauges (upstream default) |
| `panel` | 1920×720 | the whole cluster, **over** the gauges |

`full-map on` sets `target = panel` with `map_rect = 144,0,1632,720` — a 1.5×,
aspect-preserving enlargement, centred. `--fill` uses `0,0,1920,720`
(edge-to-edge, stretched); `--centred` uses no rect (1:1). Every `panel` option
draws over the gauges. Both keys live in the per-unit `local.conf`, which the
service auto-loads (`waze-on-cluster -c …/waze-on-cluster.conf`, verified in
`src/main.cpp`) and which the app/`patchd` do **not** override (the app only
sends `cluster`/`hud`/`guide`, never a map target). Changes take effect at the
next head-unit start.

### The ETA pill — why it is missing, and the real fix
The arrival pill is requested by the CarPlay patch's **ShowUI edit** ("Edit 6",
URL `maps:/car/instrumentcluster?showETA=yes`). Per upstream `PATCH.md`
(rollback table), **Edit 6 ships only in the current release line** — releases
up to 0.10.3 do not have it. A unit on **0.10.0** writes only the plain map URL
(`patchd` reports `mapurl: "map"`) and **never asks for ETA**, so the map and
the turn/lane banner work but the pill never shows.

There are **two cases**, and `eta check` (which reads `woc-patch.sh status`)
tells which one you are in:

- **Older carplay build** — ETA comes only from the patch's Edit 6. Updating
  `waze-on-cluster` + the app to the current version (upstream 0.10.6) and
  re-applying the patch (the updater's deploy step runs `patchd activate`, no
  carplay restart) **may add** the request. `eta update` does the update;
  verify with `eta check` afterwards.
- **Newer BMW carplay** (e.g. 23.12.3, which has `AlternateDisplays::
  setShowUiUrl()`) — stock CarPlay **already** sends `showETA=yes` via
  `SHOW_UI_OPTIONS`, so Edit 6 and an update change nothing. A missing pill is
  then an Apple-side limitation this tool cannot fix.

So the update is a **candidate, not a confirmed fix** — and on many 23.x
firmwares it is a no-op. Only the car can say which case applies.

> Editing `/etc/carplay.conf` is **not** the fix and this tool does not touch
> it: where that path matters, `SHOW_UI_OPTIONS` already defaults to
> `showETA=yes`.

## Requirements
- Rooted iDrive 7 MGU with **Maps on cluster** installed
  (`robertn_waze_cluster`, `waze-on-cluster`, `cluster-render`).
- Root SSH access to the head unit.
- For `eta update`: the head unit must be **online** (the updater fetches from
  GitHub).

## Usage

Run `bin/mcc.sh` **on the head unit** over SSH. Always start read-only:

```sh
sh /tmp/mcc/bin/mcc.sh diagnose          # versions, patch/ETA state, map target
sh /tmp/mcc/bin/mcc.sh full-map on       # panel map, centred (safe default)
sh /tmp/mcc/bin/mcc.sh full-map on --fill   # edge-to-edge (COVERS THE GAUGES)
sh /tmp/mcc/bin/mcc.sh full-map off      # back to the native under-gauge slot
sh /tmp/mcc/bin/mcc.sh eta check         # version + real ShowUI/mapurl state
sh /tmp/mcc/bin/mcc.sh eta update        # update tool+app (then verify)
sh /tmp/mcc/bin/mcc.sh revert            # restore the backed-up local.conf
```

`full-map` changes take effect on the next head-unit start.

### From Windows (optional helper)
`remote/mcc-ssh.ps1` copies `bin/` + `config/` to the unit and runs a command,
in the same SSH style as the MGU installer (identity key + source-address
bind):

```powershell
# read-only check (host/bind come from the installer's ssh_host / ssh_bind):
.\remote\mcc-ssh.ps1 -HeadUnit 169.254.68.60 -Bind 169.254.140.211 `
    -Key C:\MGU\ssh\data\enrollments\<VIN>\id_rsa -Command diagnose

# over Tailscale, use the tailnet host and your forwarded SSH port:
.\remote\mcc-ssh.ps1 -HeadUnit 100.x.y.z -Port 2222 -Key <key> -Command 'full-map on'
```

The runner uses `scp` to copy the files. If the head unit has no `scp` (some
BusyBox builds), copy `bin/` + `config/` with a tar-over-ssh pipe instead (the
way the MGU installer's own probes transfer files), then run `mcc.sh` over SSH.

## Safety contract
- **Never** stops, kills or restarts `carplay` or `aapd` (SIGTERM makes CarPlay
  core-dump and restarts the head unit).
- **Never** writes the binary patch. Re-patching is the app's *Patch* button /
  the updater's `activate` (`patchd`, with boot recovery).
- Only writes under `/var/opt` and always backs a file up first
  (`/var/opt/mgu-carplay-cluster/backups/<timestamp>/`).

## Repository layout
```
bin/mcc.sh              main CLI (diagnose / full-map / eta / revert)
bin/mcc-lib.sh          POSIX-sh / BusyBox helpers + safety contract
config/waze-on-cluster.local.conf   reference template for the override keys
remote/mcc-ssh.ps1      Windows SSH runner (optional)
LICENSE                 GNU GPL v3
```

## Credits and license
The on-car tools this configures — **Maps on cluster**, `waze-on-cluster` and
`cluster-render` — are by **Robert Nisipeanu**
([robertnisipeanu/idrive-apps](https://github.com/robertnisipeanu/idrive-apps)),
GPL-3.0-or-later. All credit for the hard parts (the CarPlay/AA cluster patch
and the renderer) goes there.

This repository is licensed **GPL-3.0-or-later** to match. See [`LICENSE`](LICENSE).
It ships no BMW code and no upstream binaries.
