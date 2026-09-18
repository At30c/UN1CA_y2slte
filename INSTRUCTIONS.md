# Current One UI 9 Port Handoff Instructions

This document records the investigation and changes made after the request to inspect the latest `y2s` boot logs. It is intended as a handoff for other developers or AI assistants working on the same branch.

## Repository state

- Repository: `/home/ats0c/UN1CA-y2slte`
- Active branch during this investigation: `seventeen`
- No full ROM build was started as part of this investigation.
- The fixes described below were prepared on `seventeen`; check the branch history for their final commit identifiers.
- Do not discard unrelated local modifications. The working tree already contains other ongoing work.

## Persistent logcat capture

A dedicated, reconnect-safe logcat capture was added at:

```text
scripts/capture_logcat_tmux.sh
```

The detached `y2s-logcat` tmux session was started on 2026-09-16 at 16:49:21
(-0300). Its current output is:

```text
out/target/y2s/boot-diagnostics-20260916-164921/logcat.txt
```

The script remains in an infinite loop even when no device is connected. It
waits for ADB, confirms that `adb get-state` reports `device`, writes a
`DEVICE_CONNECTED_<date>_<time>` marker, captures all logcat buffers with
`threadtime`, writes `LOGCAT_DISCONNECTED_<date>_<time>` when the transport
goes away, and then waits for the next connection. ADB-server failures and
not-ready transports are retried instead of closing the tmux pane.

Useful commands:

```bash
tmux attach -t y2s-logcat
tmux capture-pane -pt y2s-logcat:0 -S -40
```

The earlier `y2s-logs` session remains active with its existing logcat,
dmesg, and snapshot panes so that the previous diagnostics are not
interrupted. The new session is the canonical persistent logcat capture for
future boots. Set `ADB_SERIAL` to target a specific device when more than one
ADB transport is present.

Validation performed after adding the script:

1. `bash -n scripts/capture_logcat_tmux.sh`
2. `git diff --check`
3. Confirmed that `y2s-logcat` remains attached while the device is connected
   and that its log contains `DEVICE_CONNECTED_2026-09-16_16:49:21-0300`.

## Logs inspected

The latest active capture is:

```text
out/target/y2s/boot-diagnostics-20260916-124734/
```

Files used: `logcat.txt`, `dmesg.txt`, and `snapshot.txt`.

The `y2s-logs` tmux session was still active, and the device was visible through ADB as a normal Android device. The newest boot cycle begins near this marker in `logcat.txt`:

```text
==== DEVICE_CONNECTED_2026-09-16_13:38:18 ====
```

## Graphics result

The previous graphics fixes are working in this boot cycle:

- There is no new `ion_open failed with Permission denied` message.
- There is no new `output buffer not gpu writeable` abort.
- There is no new `gralloc-mapper is missing` abort.
- SurfaceFlinger, the Exynos graphics allocator 2.0 service, and composer 2.3 start successfully.
- The composer is killed only after `system_server` dies; it is not the origin of the current boot loop.

Do not revert the legacy mapper or ION SELinux fixes while investigating the current failure.

## Current fatal boot failure

The boot progresses into Android framework startup, but `system_server` dies with this verifier error:

```text
java.lang.VerifyError: Verifier rejected class
com.android.server.wm.WindowManagerService:
void WindowManagerService.changeDisplayScale(...) failed to verify:
return-object not expected
```

The invalid instruction came from:

```text
unica/mods/settings/smali/system/framework/services.jar/
0004-Allow-disable-screen-capture-detection.patch
```

The affected method has return type `V` (`void`):

```smali
.method public final changeDisplayScale(Landroid/view/MagnificationSpec;ZLandroid/view/IInputFilter;)V
```

The old injected sequence was therefore invalid:

```smali
invoke-static {}, Ljava/util/Collections;->emptyList()Ljava/util/List;
move-result-object p0
return-object p0
```

It also used `v3` despite the method declaring `.locals 3`. In this method, `v3` aliases parameter register `p0`, so writing to `v3` overwrote the `WindowManagerService` instance.

## Patch applied

The patch source was corrected to use an existing local register and the proper return opcode:

```smali
const/4 v2, 0x0

invoke-static {v0, v1, v2}, Landroid/provider/Settings$System;->getInt(Landroid/content/ContentResolver;Ljava/lang/String;I)I

move-result v0

if-eqz v0, :unica_ss_notify

return-void
```

The patch metadata was updated from 63 to 59 inserted lines, and the affected hunk count was updated accordingly.

The other injected early return in `registerScreenRecordingCallback(...)Z` remains:

```smali
return v1
```

That instruction is correct because that method returns a boolean (`Z`).

## Validation performed

The updated patch passed all of the following checks:

1. `git apply --stat`
2. `git apply --numstat`
3. `git diff --check`
4. The old patch was reverse-applied to copies of both affected decoded smali files.
5. The new patch passed `git apply --check` against those reconstructed clean files.
6. The new patch was applied successfully to those files.
7. The resulting `changeDisplayScale(...)V` method contains `return-void`, uses valid local registers, and no longer contains `return-object`.

## Non-fatal log item

`PlayIntegrityHooks.shouldBypassTaskPermission()` logs a caught `NullPointerException` because `PackageManager` is not ready during early `ActivityManagerService` construction. It is not the fatal exception responsible for this boot loop. Do not treat it as the current boot blocker unless a later log shows it escaping the hook.

## Required next step

Generate a fresh build so that `services.jar` is rebuilt from the corrected patch, install it, and capture a new boot log. The currently installed build still contains the invalid old bytecode and will continue restarting until replaced.

When reviewing the next log, first verify that all of these strings are absent:

```text
return-object not expected
ion_open failed with Permission denied
output buffer not gpu writeable
gralloc-mapper is missing
```

Then identify the first fatal exception in the newest boot cycle instead of acting on errors inherited from older cycles in the same appended log file.

## Selective repository upload

On 2026-09-16, the tracked local changes were selectively prepared for
upload on branch `seventeen`. The following tracked files were intentionally
left out and remain local for separate review:

```text
platform/exynos990/patches/extremekrnl/customize.sh
scripts/download_fw.sh
scripts/internal/build_incremental_ota_zip.sh
scripts/make_rom.sh
```

Untracked files were also intentionally left out:

```text
apply.out
last_kmsg
scripts/capture_logcat_tmux.sh
```

## PackageManagerService verifier correction

The boot cycle beginning at
`DEVICE_CONNECTED_2026-09-16_18:45:14-0300` exposed a second verifier
failure in `PackageManagerService.verifyReplacingVersionCode(...)`:

```text
register v3 has type Reference: java.lang.String but expected Integer
```

The fault was in
`unica/mods/settings/smali/system/framework/services.jar/0002-Allow-app-downgrade.patch`.
Its injected Settings lookup overwrote live registers `v3` and `v4`; `v3`
was the integer argument later passed to `isDowngradePermitted(IZ)Z`.

The first correction attempted to use local registers `v16` through `v18`,
but Apktool's non-range smali instructions reject registers above `v15` even
when the method has enough total locals. The patch now uses the method
parameter aliases `p0` through `p2`, whose original values were already
copied into locals and are no longer needed at this point. It uses
`move-object/from16`, `invoke-virtual/range`, `const-string`, `const/16`, and
`invoke-static/range`, preserving the original `v3` and `v4` types:

```smali
iget-object v0, v2, Lcom/android/server/pm/InstallPackageHelper;->mContext:Landroid/content/Context;
move-object/from16 p0, v0
invoke-virtual/range {p0 .. p0}, Landroid/content/Context;->getContentResolver()Landroid/content/ContentResolver;
move-result-object p0
const-string p1, "unica_allow_downgrade"
const/16 p2, 0x0
invoke-static/range {p0 .. p2}, Landroid/provider/Settings$System;->getInt(Landroid/content/ContentResolver;Ljava/lang/String;I)I
move-result v0
```

Validation performed:

1. Reversed the old patch against the generated `PackageManagerService.smali`.
2. Applied the corrected patch successfully to the reconstructed clean file.
3. Confirmed that `v3` remains the integer argument at the
   `isDowngradePermitted(IZ)Z` call and that the new invoke uses contiguous
   parameter aliases `p0..p2`.
4. Rebuilt the decoded `services.jar` directly with Apktool v3.0.3-11;
   smaling and APK assembly completed successfully.
5. No full ROM build or device installation has been performed yet.

The next required step is a fresh build and boot test so the corrected
`services.jar` replaces the currently installed bytecode.

## Verifier fixes for the downgrade and HMA patches

On 2026-09-16, the two verifier failures found in the boot diagnostics were
corrected in their patch sources:

- `unica/mods/settings/smali/system/framework/services.jar/0002-Allow-app-downgrade.patch`
  now restores parameter `p1` from the original `PackageInfoLite` saved in
  `v5` after the Settings lookup. The lookup still uses `p0..p2` as its
  temporary contiguous range, but the later `checkDowngrade(...)` call now
  receives the correct `PackageInfoLite` reference instead of the temporary
  setting-name `String`.
- `unica/mods/hma/smali/system/framework/services.jar/0001-Introduce-HideAppListUtils.patch`
  now uses `v0` for the temporary boolean/context values in
  `ActivityStarter.executeRequest(...)`. Register `v6`, which contains the
  live `resultWho` `String`, is no longer overwritten. The block is entered
  only while the original result code in `v0` is zero, so the false branches
  restore the same zero result and the archiver path overwrites `v0` as it did
  previously.

Validation completed:

1. Reversed the previous patch versions against the decoded Smali and applied
   the corrected versions successfully.
2. Rebuilt a temporary full decoded `services.jar` with Apktool v3.0.3-11;
   both `classes.dex` and `classes2.dex` smaled and the APK was assembled
   successfully.
3. Updated the patch metadata for the additional downgrade restoration
   instructions and ran `git diff --check`.

No full ROM build, installation, or post-fix device boot test has been run
yet. A real incremental build was started with
`./scripts/make_rom.sh -c --no-rom-zip`, but it was intentionally interrupted
by the user during work-directory creation so they can run the build
themselves. It did not reach APK/JAR assembly or produce an installable ROM.
The next step is to build and install a fresh ROM, then confirm that the
`PackageManagerService` `PackageInfoLite` verifier error and the
`ActivityStarter.executeRequest(...)` `String`/`Conflict` verifier error are
absent from a new boot cycle.

## Legacy BPF connectivity crash fix

The boot cycle beginning at
`DEVICE_CONNECTED_2026-09-16_21:06:55-0300` reached app optimization but then
restarted because `system_server` aborted inside
`LocalNetEventHandler::GetRingbuf()`. On the Exynos 990 Linux 4.19 kernel,
`netbpfload` correctly skips `local_net_note_op_ringbuf` (that map requires
kernel 5.10 or newer), while `netlog.bpf` also fails with `Invalid argument`.
The framework nevertheless tried to construct `LocalNetEventListener`, which
caused the native `SIGABRT`. `bootchecker` then issued
`reboot,rescueparty_by_bootchecker R2` after the repeated crashes.

The following source changes were made:

- `platform/exynos990/patches/tethering_legacy/patches/service-connectivity.jar/0001-disable-local-net-event-listener-on-legacy-bpf.patch`
  makes `ConnectivityService$Dependencies.getLocalNetEventListener(...)`
  return `null`. `ConnectivityService` already checks for a null listener
  before starting it, so networking remains available while only this
  optional local-net telemetry is disabled.
- `platform/exynos990/patches/tethering_legacy/customize.sh` now extracts
  `service-connectivity.jar` from the Tethering APEX payload, applies the
  smali patch, rebuilds the jar, and places it back before rebuilding and
  signing `apex_payload.img`. The generated Apktool cache is removed after
  the jar is returned to the payload.

Validation performed:

1. `bash -n platform/exynos990/patches/tethering_legacy/customize.sh`.
2. `git diff --check`.
3. Applied the patch to a decoded `service-connectivity.jar` with
   `git apply --check` and rebuilt it using the repository's `scripts/apktool.sh`.
4. Re-decoded the rebuilt jar and confirmed the method contains only
   `const/4 p0, 0x0` followed by `return-object p0`.

No full ROM build or device installation has been performed. Run a fresh build
and boot test next, then verify that `LocalNetEventHandler: BpfRingbuf init
failed`, `Fatal signal 6` in `system_server`, and the rescue-party reboot are
absent from the new connection cycle.

## Logcat tmux session reopened

The persistent `y2s-logcat` tmux session was recreated on 2026-09-16 at
21:44:45 (-0300) after the previous tmux server was no longer running. It is
using `scripts/capture_logcat_tmux.sh`, remains detached, waits indefinitely
for ADB/device availability, and records connection/disconnection markers.
The current capture file is:

```text
out/target/y2s/boot-diagnostics-20260916-214445/logcat.txt
```

At recreation time no ADB device was connected; the session is still alive and
will begin a new `DEVICE_CONNECTED_<date>_<time>` section when the phone is
available. Attach with:

```bash
tmux attach -t y2s-logcat
```

## Consolidated legacy BPF event-consumer handling

The next boot diagnostic cycle showed that the first `LocalNetEventHandler`
fix was effective: that abort no longer appeared. The same
`libservice-connectivity.so` still had a second fatal startup path,
`LoopbackEventHandler::Start()`, reached through
`BpfEventPoller.nativeInitLoopbackEventConsumer()`. Its missing map was
`/sys/fs/bpf/netd_shared/map_netd_loopback_access_ringbuf`.

The native inventory found exactly two fatal connectivity ring-buffer
consumers in this APEX:

- `LocalNetEventHandler`, using `map_netd_local_net_note_op_ringbuf`, disabled
  by patch `0001-disable-local-net-event-listener-on-legacy-bpf.patch`.
- `LoopbackEventHandler`, using `map_netd_loopback_access_ringbuf`, disabled
  by patch `0002-disable-loopback-event-consumer-on-legacy-bpf.patch`.

`customize.sh` now applies both patches to the decoded
`service-connectivity.jar` before rebuilding the Tethering APEX payload, so a
new missing ring buffer is handled in the same pass instead of requiring a
one-at-a-time boot/fix cycle. `libmemevents.so` has a separate
`MemBpfRingbuf` consumer for `map_bpfMemEvents_ams_rb`; the log only reports a
non-fatal initialization error for it, so it remains enabled to preserve the
available memory-event telemetry and is not part of the `system_server`
abort.

Validation completed on 2026-09-16:

1. Applied both patch files cleanly to a fresh `--no-debug-info` decode of the
   source `service-connectivity.jar`; the loopback patch was also
   reverse-applied and re-applied against the already patched decode.
2. Rebuilt and re-decoded the patched `service-connectivity.jar` from that
   fresh decode with Apktool v3.0.3-11 successfully.
3. Confirmed `getLocalNetEventListener(...)` returns `null` and the
   `systemReadyInternal` path contains no call to
   `nativeInitLoopbackEventConsumer()`.
4. Ran `bash -n platform/exynos990/patches/tethering_legacy/customize.sh` and
   `git diff --check`.

No full ROM build or device installation has been performed after the second
patch. Build and boot a fresh image, then check the next connection section
for any remaining `system_server` abort.

## Logcat tmux session restarted

The persistent `y2s-logcat` session was restarted on 2026-09-16 at
23:36:31 (-0300) after the previous capture file had been removed by a build
cleanup while the tmux process still held the deleted file open. The session
is detached, survives terminal and device disconnects, and is currently
capturing into:

```text
out/target/y2s/boot-diagnostics-20260916-233631/logcat.txt
```

The phone was already available through ADB when the session was started, so
the file contains a new `DEVICE_CONNECTED_2026-09-16_23:36:31-0300` marker.
Attach with:

```bash
tmux attach -t y2s-logcat
```

## SDHMS RescueParty soft-reboot fix

The cycle beginning at `DEVICE_CONNECTED_2026-09-16_23:36:31-0300` was not a
kernel reboot or a zygote failure. `com.sec.android.sdhms` crashed repeatedly
in its `SDHMS Handler Thread` with:

```text
java.lang.IllegalArgumentException: No enum constant
com.sec.android.sdhms.thermal.overheatcontrol.overheatcomplex.OverheatComplexType.DEX
```

`RescueParty` detected the repeated SDHMS crashes and intentionally triggered
`WARM_REBOOT` at 23:37:29. The generated Samsung Device Health Manager APK
contained `<DEX formula="SKIN" temp="470" />` in `assets/ssrm_default.xml`,
but the target APK's `OverheatComplexType` enum has no `DEX` member. The
problem came from `unica/patches/dvfs/customize.sh`, which copied
`assets/siop_default.xml` into the `ssrm_default.xml` destination in both
asset-installation branches, even though the repository already provides the
separate compatible `assets/ssrm_default.xml` file.

The script now copies `$MODPATH/assets/ssrm_default.xml` for that destination
in both branches. This removes the accidental DEX entry from the SSRM fallback
policy; the separate SIOP fallback required the additional correction below.
No ROM build or device install was performed after this source correction; build and boot-test it next, then
verify that `No enum constant ...OverheatComplexType.DEX`, repeated
`com.sec.android.sdhms` crashes, and `reboot,rescueparty_warm_reboot_by_com.sec.android.sdhms`
are absent from the next capture.

## SDHMS fallback SIOP DEX enum fix

The next test still reported `OverheatComplexType.DEX` after the
`ssrm_default.xml` correction. The generated APK had the corrected SSRM asset,
but it also installed `assets/siop_default.xml` from this patch. SDHMS parses
that fallback policy during startup, and the target enum only defines
`LTB`, `LCD`, `GDM`, `GDMLTB`, `SS`, and `EMR`; it does not define `DEX`.

The unsupported `<DEX formula="SKIN" temp="470" />` entry was removed from
`unica/patches/dvfs/assets/siop_default.xml`. The target-specific
`siop_y2s_exynos990.xml` policy already contains compatible overheat types and
remains unchanged. No build, installation, or device test was performed after
this source correction; build a fresh image and confirm that the SDHMS handler
no longer throws `No enum constant ...OverheatComplexType.DEX`.

## Logcat capture reopened for app-launch failure

On 2026-09-17 at 01:57:15 (-0300), the persistent `y2s-logcat` tmux session
was recreated because the previous capture process was no longer running after
the build cleanup. The phone was in recovery at recreation time, so the script
is waiting for a normal ADB connection and will record a new
`DEVICE_CONNECTED_<date>_<time>` section when Android boots. The current output
file is:

```text
out/target/y2s/boot-diagnostics-20260917-015715/logcat.txt
```

The capture is detached and survives terminal/device disconnects. Attach with:

```bash
tmux attach -t y2s-logcat
```

## Logcat capture reopened after Chrome/WebView downgrade

On 2026-09-17 at 03:17:27 (-0300), the persistent `y2s-logcat` session was
recreated after the previous tmux server was unavailable. It is detached,
survives terminal and device disconnects, and is waiting for the next ADB
connection. The new output file is:

```text
out/target/y2s/boot-diagnostics-20260917-031727/logcat.txt
```

The phone's Chrome and WebView downgrade was reported to stop the AppZygote
soft-reboot loop; preserve the next boot capture to verify that result.

## Logcat capture reopened again

On 2026-09-17 at 03:23:40 (-0300), `y2s-logcat` was recreated because the
previous tmux server and capture process had exited. It is detached and
waiting for the next ADB connection. The new capture file is:

```text
out/target/y2s/boot-diagnostics-20260917-032340/logcat.txt
```

## Logcat capture reopened again

On 2026-09-17 at 12:19:59 (-0300), the `y2s-logcat` tmux session was
recreated after the previous tmux server and capture process exited. It is
detached and survives terminal and device disconnects. The phone connected at
12:20:06 (-0300), and the new capture file is:

```text
out/target/y2s/boot-diagnostics-20260917-121959/logcat.txt
```

## SystemUI crash: media library ABI mismatch

In the connection cycle captured in
`out/target/y2s/boot-diagnostics-20260917-121959/logcat.txt`, `com.android.systemui`
repeatedly crashes while creating the video wallpaper player:

```text
java.lang.UnsatisfiedLinkError: dlopen failed: cannot locate symbol
_ZN7android10MppWrapper28renderAndReleaseOutputBufferEillRKNS_2spINS_8AMessageEEE
referenced by /system/lib64/libmediasndk.so
```

The failure starts in `SemMediaPlayer`/`ImageWallpaper` and causes
`Process com.android.systemui has crashed too many times`, leaving the device
without SystemUI. The relevant log is around lines 390542-390650.

The source is an ABI mismatch introduced by the Paradigm Audio eraser block:
`unica/mods/paradigm/customize.sh` unconditionally imports the `pa2qxxx`
`libmediasndk.so` and `libmediasndk.mediacore.samsung.so` at lines 111-112.
The flashed `libmediasndk.so` hash is identical to that prebuilt. It requires
the old `MppWrapper::renderAndReleaseOutputBuffer(...AMessage)` symbol, while
the source S926B `libmppclient.so` in the image exports the newer signature
with an additional boolean argument. The matching S926B media libraries exist
under `out/fw/SM-S926B_EUX/system/system/lib64/`.

No source fix has been applied yet. The safe correction is to use a coherent
media-library set from the source firmware or disable this Audio eraser import;
do not mix `pa2qxxx` media libraries with the S926B `libmppclient.so`.

The failure was also confirmed live with the phone connected: the active
wallpaper is `com.samsung.android.wallpaper.res/Default_Video_Wallpaper_ZVLB.mp4`,
and `SystemUI` continues to crash/restart with the same linker error. The
latest repeated crash is recorded around lines 700125-700169 of the capture.

## Initial display density corrected for native resolution mapping

On 2026-09-17, the connected SM-S926B donor port was running the FHD mode at
1080x2400 with a logical density of 337 dpi. There was no persistent
`display_density_forced` override; the value came from the native Android 16
`DensityMapping` in `services.jar`. The generated vendor properties had
`ro.sf.lcd_density=450` and `ro.sf.init.lcd_density=450`, and the native path
scaled its static 450 dpi base by 1080/1440. The original G986B target's FHD
behavior is 450 dpi, so the donor mapping made the UI oversized.

Two source safeguards were added. `platform/exynos990/patches/miscs/customize.sh`
now preserves an existing `ro.sf.init.lcd_density` (the donor and original
target both define 600) and only falls back to `ro.sf.lcd_density` when that
property is missing. `unica/patches/product_feature/customize.sh` also patches
the native `LocalDisplayAdapter` path on Exynos990 ports to bypass the donor
resolution density map while retaining native mode/HFR handling; the target's
static density is consequently used in FHD. The temporary `wm density`
override used during diagnosis was reset, and no build or flash was performed
after these source changes; build and boot-test them next.

## AppZygote SystemMemoryProcess crash: memory controller bake (2026-09-18)

The Android 16+ donor's sandboxed zygote specialization on Exynos990 aborts
its children (`F libc: Fatal signal 6, zygote-child`) when the
`SystemMemoryProcess` profile applies `JoinCgroup memory system`: the Exynos990
kernel exposes the cgroup v2 `memory` controller on the root
(`/sys/fs/cgroup/cgroup.controllers` = memory) but Samsung's init never enables
it, so the action is logged as "will be ignored" and the child aborts. Post-boot
the cgroupfs is unreachable even for root+permissive (KSU `su` uid 0, no `avc:`
denials; `+memory`/`mkdir` denied), so the controller can only be enabled at
boot.

The One UI 8.5 cgroup userspace swap (cgroups.json/task_profiles.json/
libcgrouprc.so, commit 0e9b59db) does NOT prevent the abort once baked
(verified on-device after flash; the earlier "module active => 20/20 clean" A/B
was a lifecycle artifact, not a config effect). `cgroups.json` already carries
`memory NeedsActivation:true`/`Optional:true` and it is never activated.

The baked fix adds `prebuilts/samsung/e2sxxx/system/etc/init/cgroupmem.rc`
(pushed into `/system/etc/init` by the cgroup_legacy module) which issues
idempotent `write +memory` to the `cgroup.subtree_control` chain (root, apps,
system) across the `early-init`, `init`, `post-fs-data`, `zygote-start` and
`boot` triggers, before the fs lock engages. Validate after flash that
`/sys/fs/cgroup/cgroup.subtree_control` reads `memory` and that cold-started
Chrome/WebView cycles no longer SIGABRT their app-zygote children.

Note: libchrome.so porting (commits e45eb9a8/aa7969ab) is unrelated to the
crash path and was not part of the fix.

Follow-up (same day, build flashed): the rc activation worked - the kernel
memory controller now reports active on the root, apps and system subtrees,
and fresh AppZygote spawns that previously aborted 100% of the time now mostly
survive (0-1 aborts per 8-14 cold cycles, system_server no longer restarts).
However `libprocessgroup` still logs "JoinCgroup ... memory ... will be
ignored" even with the kernel controller enabled: it treats controllers marked
`NeedsActivation` as inactive unless IT activated them during init, and Samsung
init never performs that activation. The remaining abort ties to that ignored
join. Fix: `cgroups.json`'s memory Cgroups2 entry no longer carries
`NeedsActivation`/`MaxActivationDepth`/`Optional`, so the runtime considers the
controller available and the profile join is applied instead of ignored. This
rides with `cgroupmem.rc` (kernel-side enable). Validate after flash that the
"will be ignored" line no longer appears and cold cycles are 0 aborts.
