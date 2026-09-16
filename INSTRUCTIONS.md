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
