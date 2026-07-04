# Ethernet-over-USB patch for ESP-Miner (Bitaxe Gamma / board 601)

## What this is

[PR #1437](https://github.com/bitaxeorg/ESP-Miner/pull/1437) ("Ethernet-over-USB"
by mutatrum) was merged into an early-access/canary build of ESP-Miner in
March 2026 but never landed on the `master` branch, and the standalone
`usb-ethernet` branch on mutatrum's fork hasn't been updated since — meanwhile
master has moved on ~55 commits, including a Stratum V2 refactor that split
`stratum_task.c` into `stratum_v1_task.c`/`stratum_v2_task.c` and a websocket
API refactor that changed how `/api/system` builds its JSON response, among
other things.

`ethernet-over-usb.patch` in this folder is that feature, hand-ported onto
current `master` (verified as of this writing — see "How this was made"
below). It's a plain `git diff`, not a rebase of mutatrum's messy commit
history, so it applies as a single clean patch.

## Quick start

```
./patch_and_build.sh
```

This will, on your own machine:
1. Clone `bitaxeorg/ESP-Miner` (master) into `./ESP-Miner`
2. Apply `ethernet-over-usb.patch`
3. Build it in Docker (matching the project's own documented build method)
4. Drop `esp-miner.bin`, `www.bin`, and a merged flashable
   `esp-miner-merged.bin` into `./output/`, along with `config-601.cvs`
   for your board

Options:
- `--native` — build with a locally-sourced ESP-IDF instead of Docker
- `--skip-build` — just clone + patch, no build (e.g. if you want to open it
  in VSCode with the ESP-IDF extension yourself)
- `--config XXX` — use a different board config (default `601` = Gamma)

Then flash with (from outside Docker):
```
pip install bitaxetool --break-system-packages
bitaxetool --config output/config-601.cvs --firmware output/esp-miner-merged.bin
```
Or use `esp-miner.bin` + `www.bin` for a firmware update on an already
configured device via the AxeOS web UI. Full flashing notes are printed at
the end of `patch_and_build.sh`.

Once flashed, open the AxeOS web UI → Network settings → set "Network Mode"
to **Ethernet-over-USB**, restart. See `ethernet-over-usb-feature-docs.md`
for host-side setup (macOS: System Settings → General → Sharing → Internet
Sharing, share your Wi-Fi/Ethernet connection to the new USB interface;
Linux/Windows instructions are in that file).

## Future updates

Two separate things can go stale here:

1. **Upstream ESP-Miner master moves on** and the patch stops applying
   cleanly. Run `./regenerate_patch.sh` — it recomputes the patch from the
   fork's actual sync point against current master and tests whether it
   still applies. If master has only drifted in unrelated areas, this alone
   fixes it. If master has refactored a file the patch touches (like the
   Stratum V2 split did), you'll get conflict markers and need to resolve
   them by hand — the script tells you which files and gives a pointer to
   the specific pattern (`wifi_is_connected()` → link-agnostic
   `GLOBAL_STATE->SYSTEM_MODULE.is_connected`) that broke last time.

2. **mutatrum pushes new commits** to the `usb-ethernet` branch — same
   command picks those up automatically, since it re-diffs against whatever
   the branch currently looks like.

Either way, `regenerate_patch.sh` overwrites `ethernet-over-usb.patch` in
place, so `patch_and_build.sh` always uses the latest version.

## How this patch was made (for your own auditing)

The `usb-ethernet` branch is messy — dozens of "merge master into branch"
commits interleaved with the actual feature work. The feature itself lives
almost entirely in one commit, `f175f82 "Ethernet-over-USB"`, with several
small follow-up fixup commits after it. The branch's last sync with master
was at commit `bfc422a` (a real master commit — "Add support for fractional
difficulty..."), so `git diff bfc422a usb-ethernet-tip` isolates exactly the
feature's net effect, cleanly, with no unrelated master noise mixed in.

That diff was then 3-way-applied onto current master. Most of it (21 of 28
files) applied without conflict. Seven files needed manual resolution because
of real upstream refactors since the sync point:

- `components/connect/connect.c` / `connect.h` — master renamed the
  network-init entry point (`wifi_init` → the mDNS/hostname work), while the
  branch renamed it differently (`connect_init` + new
  `connect_await_connection`, splitting init from blocking-wait-for-link).
  Resolved by keeping master's mDNS/hostname features and the branch's
  init/await split, since `main.c` (already merged cleanly) calls the
  latter.
- `main/http_server/http_server.c` / `system_api_json.c` — master
  refactored `GET_system_info` to build its JSON via a shared
  `system_api_get_full_json()` helper (also used by the websocket API). The
  branch's inline `networkMode`/`wifiRSSI` additions had to be moved into
  that shared helper instead of the old inline handler.
- `main/screen.c` — two conflicts, both caused by a 3-way-merge context
  mismatch rather than a real logical conflict: the actual RSSI-gating and
  IP-label logic already existed correctly elsewhere in the file from a
  clean hunk; the conflicted fragments were leftover duplicate/stale code
  (including a reference to a `wifi_uptime_label` that no longer exists —
  renamed to `network_uptime_label` elsewhere in the same patch).
- `network.edit.component.html` — additive conflict: merged the branch's
  new network-mode dropdown + WiFi-only field wrapper with master's updated
  PrimeNG field styling.
- `components/connect/CMakeLists.txt` / `main/idf_component.yml` — trivial,
  both sides just added independent lines (mdns vs. esp_tinyusb deps).
- `main/tasks/stratum_task.c` — this file no longer exists; it was split
  into `stratum_v1_task.c`/`stratum_v2_task.c` by the Stratum V2 PR (#1553)
  after the fork's sync point. The one hunk that touched it (swapping a
  WiFi-only connectivity check for a link-agnostic one) was ported by hand
  into both new files, plus two equivalent call sites in
  `protocol_coordinator.c` that didn't exist at the fork's sync point
  either — all four now check `GLOBAL_STATE->SYSTEM_MODULE.is_connected`
  instead of calling `wifi_is_connected()`, so reconnect/heartbeat logic
  works over USB ethernet, not just Wi-Fi.

The resulting patch was verified to apply byte-for-byte cleanly (`git apply
--check`) against current master, and the resulting tree hash was confirmed
identical between a hand-resolved working copy and a fresh checkout with the
patch applied via `git apply`.

**What wasn't verified initially, and what broke**: I didn't have an
ESP-IDF/xtensa toolchain available to compile this myself, so the first
version of this patch was a careful source-level merge but not a
compiler-verified one.

*Bug 1 (fixed):* On the first real build, it failed with:
```
error: implicit declaration of function 'wifi_softap_off'
error: static declaration of 'wifi_softap_off' follows non-static declaration
```
Cause: during the automated (non-conflicting) part of the 3-way merge,
two forward declarations — `static void wifi_softap_on(void);` and
`static void wifi_softap_off(void);` — were silently dropped near the top
of `connect.c`. This didn't produce a conflict marker because the hunk
boundaries on either side of those two lines matched cleanly; git's 3-way
merge has no way to notice a *clean-looking* hunk quietly ate two lines it
shouldn't have. Fixed by restoring both declarations. I also wrote a small
script to scan every changed `.c` file for the same class of bug (a
`static` function called before it's declared/defined) and found no other
instances.

*Bug 2 (fixed):* A second build attempt then got past the firmware compile
entirely (it linked `libconnect.a` successfully) and failed later, in the
Angular web UI build:
```
Can't bind to 'options' since it isn't a known property of 'p-dropdown'.
```
Cause: current master runs PrimeNG v19, which renamed `p-dropdown` to
`p-select` (the branch's UI code predates that rename). Fixed by using
`p-select` in `network.edit.component.html`, matching how every other
dropdown in the current codebase (e.g. `edit.component.html`) already does
it. No `.ts`/module changes were needed — `NetworkEditComponent` is a
non-standalone (`standalone: false`) component declared in `app.module.ts`,
and `SelectModule` is already provided there via the shared `PrimeNGModule`
wrapper, so every other module-based component gets it for free.

Each fix was verified by applying the patch to a genuinely fresh clone of
`bitaxeorg/ESP-Miner` (not just the working copy it was developed against)
and confirming the fix is present and no conflict markers remain. I still
can't run `idf.py build` or `ng build` myself, so treat this as
source-reviewed-and-two-bugs-fixed rather than fully proven — if a third
error shows up, send me the log.

## Files in this folder

- `ethernet-over-usb.patch` — the patch itself
- `patch_and_build.sh` — clone + patch + build, produces `esp-miner.bin` /
  `www.bin` / `esp-miner-merged.bin`
- `regenerate_patch.sh` — recompute the patch against latest upstream/fork
- `ethernet-over-usb-feature-docs.md` — the feature's own usage docs (API
  calls to switch modes, host-side network sharing setup per OS, USB
  descriptor details, limitations)
