# Current One UI 9 Port Handoff Instructions

This document records the investigation and changes made after the request to inspect the latest `y2s` boot logs. It is intended as a handoff for other developers or AI assistants working on the same branch.

## Repository state

- Repository: `/home/ats0c/UN1CA-y2slte`
- Active branch during this investigation: `seventeen`
- An incremental ROM build for the cgroup A/B test completed the work-dir
  generation at 19:16. The flashable build was subsequently generated and
  installed on the connected SM-S926B for on-device A/B validation.
- The fixes described below were prepared on `seventeen`; check the branch history for their final commit identifiers.
- Do not discard unrelated local modifications. The working tree already contains other ongoing work.

## Atualização da branch

Em 2026-09-19, a branch local `seventeen` foi atualizada por fast-forward de
`3faf492f` para `c4607c8a` (`cgroup: revamp One UI 8.5 compatibility patch`),
incorporando os sete commits mais recentes de `origin/seventeen`. As alterações
locais rastreadas e os arquivos não rastreados foram preservados; o conflito
documental em `INSTRUCTIONS.md` foi combinado mantendo os registros locais e
as novas notas do upstream. Nenhum build ou flash foi executado.

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

## ExtremeKRNL cgroup v2 compatibility

The `y2s` boot log showed the Android userspace requesting the cgroup v2 mount
option `memory_recursiveprot`, which is not implemented by the ExtremeKRNL
4.19 cgroup parser. The kernel rejected that option and Android retried the
mount without it. This was non-fatal, but generated an avoidable init error
and exposed a userspace/kernel capability mismatch.

The ExtremeKRNL integration now applies:

```text
platform/exynos990/patches/extremekrnl/patches/0001-accept-memory-recursiveprot-on-legacy-cgroup2.patch
```

The patch makes the legacy parser accept `memory_recursiveprot` as a no-op.
This preserves the exact behavior of Android's existing retry path while
allowing the initial cgroup v2 mount to complete without the error. The
`customize.sh` integration is idempotent and includes the patched kernel
working tree in the existing cache key, so a stale kernel image is rebuilt.

Validation performed:

1. `git apply --check` succeeds against the current ExtremeKRNL source.
2. `bash -n platform/exynos990/patches/extremekrnl/customize.sh` succeeds.
3. `git diff --check` succeeds for the integration changes.
4. The patched `kernel/cgroup/cgroup.o` compiled successfully with the
   current ExtremeKRNL configuration.

No full kernel or ROM build was run in this step. Build and boot validation
remain required; the expected result is that `cgroup2: unknown option
"memory_recursiveprot"` and `Mounting memcg with memory_recursiveprot failed`
no longer appear in the new boot log.

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

## A/B test do abort do zygote (2026-09-19)

O aparelho foi conectado por USB para um teste controlado. Ao abrir o Chrome,
o log mostrou a sequência: criação do cgroup do filho, aviso de que
`SystemMemoryProcess`/`JoinCgroup memory` seria ignorado e `SIGABRT` no
`zygote-child`; o spam `ZygoteProcess: Connection refused` começou logo
depois. Os controllers `memory` estavam ativos no root, `apps` e `system`.
O teste inicial levantou a hipótese de que o abort vinha exclusivamente do
perfil, mas o A/B instalado abaixo mostrou que essa hipótese é incompleta.

Para isolar essa causa, o perfil `SystemMemoryProcess` em
`prebuilts/samsung/e2sxxx/system/etc/task_profiles.json` foi temporariamente
mantido sem ações (`"Actions": []`). Isso é apenas um A/B diagnóstico: não é
a correção definitiva porque remove a movimentação desse processo para o
cgroup `system`. O JSON foi validado localmente. Um build incremental foi
iniciado com `source buildenv.sh y2s && ./scripts/make_rom.sh -c
--no-rom-zip` e concluiu a geração do `work_dir` às 19:16. A build flashável
foi então gerada pelo usuário e instalada no SM-S926B; a validação ocorreu no
fingerprint `samsung/e2sxxx/e2s:17/CP2A.260605.016/S926BXXUHZZHL`.

Resultado do A/B instalado: o perfil sem ações eliminou o aviso
`JoinCgroup ... memory ... will be ignored`, mas **não eliminou** o
`zygote-child SIGABRT`: ainda ocorreram aborts às 20:03:37 (PID 18836) e
20:04:43 (PID 19300). Nesses eventos o cgroup do filho foi criado
normalmente; logo, a causa não é somente o `JoinCgroup` do
`SystemMemoryProcess`. O `crash_dump64` também não conseguiu abrir `/proc` do
filho antes de ele desaparecer, portanto ainda falta um tombstone utilizável
para identificar a chamada que dispara o abort.

O spam `ZygoteProcess: Got error connecting to zygote, retrying. msg=
Connection refused` continua em ritmo alto (mais de 52 mil linhas entre
20:03 e 20:09), mesmo com `zygote`/`zygote_next` em execução e os sockets
correspondentes escutando. Ele é um problema separado, ainda não corrigido;
a propriedade `ro.vendor.redirect_socket_calls=true` e o caminho de conexão
do `system_server` precisam ser investigados.

O log também fechou a causa do soft-reboot: às 20:05:13 o `Watchdog` matou o
`system_server` porque ele ficou 71 s bloqueado em
`ActivityManager:procStart`, dentro de
`ZygoteProcess.waitForConnectionToZygote()` ->
`AppZygote.connectToZygoteIfNeededLocked()`. Em seguida o zygote registrou
`Zygote failed to write to system_server FD: Connection refused` e saiu; o
`init` reiniciou o zygote e o `system_server` (novo PID 19820 às 20:05:15).
Assim, o spam não é apenas cosmético: ele trava o start de processos e causa
o soft-reboot. O socket recusado é o AppZygote do Chrome (`uid 10248`), que
está abortando antes de ficar disponível.

Teste de controle após o reinício do `system_server`: `adb shell am start -W
-a android.settings.SETTINGS` abriu `SettingsHomepageActivity` em 864 ms,
com `system_server` (PID 19820) e zygote ativos e sem novo abort/refusal no
intervalo observado. Isso restringe a falha ao caminho de AppZygote usado pelo
Chrome/sandbox, e não a toda criação de processos normais.

Também permanece um crash independente do Chrome: `SIGTRAP` em
`libchrome.so`, com `Timed out waiting for GPU channel`, sem relação direta
com o abort do zygote. O perfil sem ações continua sendo apenas um A/B
diagnóstico e não deve ser tratado como correção final, pois remove a
colocação de `SystemMemoryProcess` no cgroup `system`.

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

The temporary `wm density` override used during diagnosis was reset. The
temporary `SMALI_PATCH` added to
`unica/patches/product_feature/customize.sh` to bypass the native density map
was reverted on request; no build or flash was performed after the change.

## Reversão do ajuste de DPI

Em 2026-09-17, removi o bloco `SMALI_PATCH` de
`unica/patches/product_feature/customize.sh`, conforme solicitado. Nenhum build
ou flash foi executado após a reversão.

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

## Logcat capture prepared again

On 2026-09-19 at 18:51:56 (-0300), the detached persistent `y2s-logcat` tmux
session was recreated with `scripts/capture_logcat_tmux.sh`. The phone was not
connected at startup, so the capture is waiting for ADB and will create a new
`DEVICE_CONNECTED_<date>_<time>` marker automatically when the device becomes
available. The current output file is:

```text
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt
```

Attach with:

```bash
tmux attach -t y2s-logcat
```

## ART/APEX comparison and revised AppZygote diagnosis (2026-09-19)

The ART comparison was completed between the decompressed S926B source,
the original G986B target, and the r11s donor:

```text
S926B source:  com.google.android.art_compressed.apex, versionCode 371000140, SDK 37, lib64 only
r11s donor:    com.google.android.art_compressed.apex, versionCode 361154460, SDK 36, lib + lib64
G986B target:  com.google.android.art_compressed.apex, versionCode 331711080, SDK 33, lib + lib64
```

The inner APEX manifest identifies all three packages as `com.android.art`.
The r11s package is therefore an older Android 16 ART, while the S926B source
framework is Android 17. Replacing the complete S926B ART with r11s would mix
the Android 16 64-bit ART libraries and Java runtime with the Android 17
framework and is not a safe compatibility fix. The r11s package should not be
enabled wholesale merely to provide ARM32 files.

The repository contains a separate module,
`platform/exynos990/patches/zzz_runtime32_compat`, whose
`customize.sh` would copy the complete r11s ART APEX. That module is disabled
by its `disable` marker. The active
`platform/exynos990/patches/__desixtification/customize.sh` imports r11s
system libraries and merges Runtime/I18n content, but it does not replace the
ART APEX. The current work-dir ART APEX has the same SHA-256 as the S926B
source APEX, confirming that the observed 2026-09-19 boot was not running the
r11s ART.

This supersedes the earlier hypothesis that the current `zygote-child`
`SIGABRT` was caused solely by the `SystemMemoryProcess` memory join or by an
r11s ART replacement. The A/B test with the profile actions removed still
reproduced the abort. In the latest capture, the child successfully creates
`/sys/fs/cgroup/apps/uid_10248/pid_28075`, receives the cgroup-v2 memory join
warning, and aborts approximately 5 ms later:

```text
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:349717
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:349721
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:349723
```

The subsequent `ZygoteProcess: Connection refused` messages are the
system-server retry loop after the native AppZygote child/service failure;
they are not proof that the regular Java `zygote64` process was the original
fault. The native specialization path still needs to be isolated among
cpuset/task-profile application, seccomp/`NO_NEW_PRIVS`, SELinux context
transition, and capability setup. Audit queue overflow occurs at the same
time, so a native-AppZygote AVC may be missing from the captured log.

The confirmed independent configuration mismatch remains the imported
`SystemServiceCapacityHigh` profile requiring
`/dev/cpuset/foreground-boost`, while the target vendor init does not create
that group. Fix and test that mismatch separately, then compare the child
abort count, the `zygote_next` state, and the connection-refused rate. Do not
activate `zzz_runtime32_compat` as an ART fix without first designing an
ARM32-only merge that preserves the S926B ART 64-bit payload.

## Cadeia do Chrome Native AppZygote e causa provável do SIGABRT (2026-09-19)

Uma investigação adicional do APK, do `services.jar` e do logcat confirmou a
cadeia de inicialização usada pelo Chrome. O Chrome principal é iniciado pelo
zygote regular e funciona inicialmente (PID 28010):

```text
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:347603
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:347767
```

O manifesto do Chrome declara `NativeOnlySandboxedProcessService0` como
`nativeService=true`, `isolatedProcess=true` e `useAppZygote=true`. Por isso,
o serviço passa pela seguinte cadeia:

```text
Chrome
  -> services.jar / ProcessList
  -> AppZygote
  -> NativeZygoteProcess
  -> zygote_next
  -> zygote-child
```

As implementações desmontadas confirmam essa rota em
`ProcessList.smali`, `ActiveServices.smali` e `NativeZygoteProcess.smali`; não
foi encontrada uma seleção incorreta do zygote pelo `services.jar`:

```text
out/target/y2s/apktool/system/framework/services.jar/smali/com/android/server/am/ProcessList.smali:14487
out/target/y2s/apktool/system/framework/services.jar/smali/com/android/server/am/ActiveServices.smali:6449
out/target/y2s/apktool/system/framework/framework.jar/smali_classes3/android/os/NativeZygoteProcess.smali:312
```

No boot analisado, `zygote_next` inicia, cria o cgroup do processo nativo e o
filho aborta quase imediatamente:

```text
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:349686
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:349717
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:349723
```

O spam abaixo é consequência da morte do AppZygote: o `system_server` tenta
reconectar ao socket privado que deixou de existir e agenda nova tentativa do
`NativeOnlySandboxedProcessService0`. Não é evidência de que o `zygote64`
regular tenha morrido primeiro:

```text
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:7588824
```

Sem o processo nativo, o Chrome principal não recebe o canal GPU e aborta
depois com `Timed out waiting for GPU channel`. Esse crash é um efeito
posterior da falha do sandbox nativo, não uma prova de que o driver GPU seja a
causa inicial:

```text
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:390960
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:390966
```

O APK em `/product/app/Chrome64` também não é o binário efetivamente usado.
Ele é ignorado porque o Chrome atualizado em `/data/app` tem versão
`801004904`, superior à versão `782710233` da partição `product`:

```text
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:19238
```

O backtrace do crash aponta para `libchrome.so` dentro do APK atualizado em
`/data/app`. Portanto, alterar somente o APK Chrome da `product` não controla
o código nativo que falha durante esse boot.

O teste A/B também mostrou que remover as ações de `SystemMemoryProcess`
silencia o aviso de `JoinCgroup`, mas não elimina o `SIGABRT`: os PIDs 18836 e
19300 continuam abortando mesmo sem o aviso. A causa ainda precisa ser
isolada entre aplicação de task profile/cpuset, capability setup,
seccomp/`NO_NEW_PRIVS`, transição SELinux e bibliotecas nativas. O logcat não
contém o tombstone interno do `zygote-child`, e houve overflow da fila de
auditoria, portanto uma AVC específica pode ter sido perdida.

Os problemas de cgroup permanecem como incompatibilidades independentes:

```text
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:8324
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:9256
```

O runtime ainda rejeita `memory_recursiveprot`, apesar de o patch existir no
código-fonte do kernel, e o perfil `SystemServiceCapacityHigh` requer o grupo
`/dev/cpuset/foreground-boost`, que não é criado pela inicialização do alvo.
É necessário validar o hash da imagem `boot.img` realmente flashada e capturar
o tombstone nativo para confirmar qual dessas incompatibilidades participa do
abort.

Próximos testes controlados:

1. Desabilitar/remover temporariamente o Chrome atualizado e testar a versão
   compatível da `product`, mantendo o restante da imagem inalterado.
2. Após um novo abort, preservar imediatamente o tombstone do
   `zygote-child`, além do logcat, para obter a mensagem de abort e o contexto
   nativo.
3. Comparar o hash do `boot.img` flashado com o artefato de kernel que contém
   o patch `memory_recursiveprot`.
4. Corrigir/testar separadamente o perfil `foreground-boost` e comparar a
   contagem de aborts, o estado de `zygote_next` e a frequência de
   `Connection refused`.

Não desviar permanentemente o serviço nativo para o zygote regular nem
desabilitar o sandbox do Chrome: isso reduziria a segurança. Nenhuma alteração
de código foi feita durante esta investigação; esta seção apenas documenta
os resultados e os testes recomendados.

## Adaptação das configurações vendor do zygote do S24+ (2026-09-19)

Foi feita uma comparação completa das referências a `zygote`, `app_zygote`,
`zygote_next`, serviços nativos, propriedades, `task_profiles` e SELinux entre
`out/fw/SM-S926B_EUX/vendor` e o vendor Exynos 990 usado pelo S20+.

O S24+ não possui `zygote_next` na partição `vendor`: não há arquivo `.rc`,
propriedade ou serviço vendor contendo `zygote_next`/`android-native-app`. O
serviço é iniciado exclusivamente pelo system em
`system/etc/init/zygote_next.rc`, através do binário
`/system/bin/zygote_next`. Portanto, nenhum serviço `zygote_next` foi copiado
para o vendor do S20+.

As configurações vendor relevantes encontradas no S24+ foram:

1. `ro.zygote=zygote64` e listas ABI somente arm64, que já eram aplicadas pelo
   módulo de desixtification e agora também ficam explícitas no novo módulo.
2. O seletor BoringSSL vendor que importa
   `boringssl_self_test.${ro.zygote}.rc`. O alvo possuía apenas os gatilhos
   genéricos no `boringssl_self_test.rc`; ele agora usa o mesmo seletor do
   S24+ e recebe `boringssl_self_test.zygote64.rc`, executando somente o
   self-test de 64 bits.
3. Os serviços `boringssl_self_test32_vendor` e
   `boringssl_self_test64_vendor` passaram a declarar explicitamente `user
   root`, como no donor. Os binários continuam sendo os do S20+/Exynos 990;
   nenhum executável do S24+ foi importado.

A adaptação foi isolada em:

```text
platform/exynos990/patches/zzz_zygote_vendor_compat/
```

O módulo também registra `file_context-vendor` e `fs_config-vendor` para que
os dois arquivos `.rc` recebam `vendor_configs_file` e permissões 0644. As
variantes vendor `zygote32`, `zygote64_32` e `no_zygote` do S24+ não foram
copiadas porque o alvo foi configurado como arm64-only (`ro.zygote=zygote64`;
`ro.vendor.product.cpu.abilist32` vazio).

A política SELinux do S24+ não foi substituída: as regras `app_zygote` e
`zygote` já existem no vendor alvo com os tipos API 30, e copiar os CIL do S24+
(API 34/SoC diferente) seria incompatível e inseguro. Da mesma forma, o
`task_profiles.json` vendor do S24+ contém perfis EMS específicos do hardware
S5E9945, portanto não foi importado como se fosse configuração de zygote.

Validação estática realizada:

- `ro.zygote` e a ABI final permanecem `zygote64`/arm64-only;
- o vendor não contém referência a `zygote_next` antes nem depois da
  adaptação;
- o novo import BoringSSL aponta para o arquivo `zygote64` correto;
- não foram copiados binários, bibliotecas ou políticas SELinux do S24+.

É necessário gerar e instalar uma nova build para validar no aparelho. O teste
deve verificar se o self-test vendor executa sem erro e, separadamente, se o
Chrome atualizado ainda causa o abort do AppZygote; esta alteração não desvia
o sandbox nativo para o zygote regular.

### Validação da build e do aparelho

A build `out/target/y2s/make_rom-20260919_230510.log` processou o módulo
`Zygote vendor compatibility` e terminou com sucesso em 31min27s. No
`work_dir`, os arquivos gerados são idênticos aos assets do módulo e os
metadados `vendor_configs_file`/0644 foram registrados.

No SM-S926B conectado, a validação em runtime confirmou:

```text
ro.zygote=zygote64
ro.product.cpu.abilist=arm64-v8a
ro.product.cpu.abilist32=[]
ro.vendor.product.cpu.abilist=arm64-v8a
init.svc.zygote=running
init.svc.zygote_next=running
```

O init importou o arquivo vendor selecionado por propriedade e executou
`boringssl_self_test64_vendor` com UID 0; o processo terminou com status 0.
Isso confirma que a adaptação do vendor foi aplicada corretamente.

O smoke test abriu o Chrome atualizado (`versionCode=801004904`,
`153.0.8010.49`) em 2,7s, mas o log ainda registrou `SIGABRT` no
`zygote-child` (PID 22929) e continuou exibindo `ZygoteProcess: Connection
refused`. Portanto, a alteração vendor/BoringSSL entrou e está funcional, mas
não resolve sozinha a falha do AppZygote nativo do Chrome. O downgrade para a
versão da `product` continua sendo o próximo A/B de compatibilidade mais
importante.

## Port do suporte `memory_recursiveprot` do cgroup2 (2026-09-20)

A solicitação para portar as funções cgroup2 do AOSP foi reduzida ao recurso
que realmente está ausente no kernel 4.19 do ExtremeKRNL: a extensão
`memory_recursiveprot`. O kernel já possui o subsistema cgroup2 e os
controladores necessários; substituir todo o cgroup por uma implementação de
um kernel AOSP mais novo teria alto risco de incompatibilidade com o vendor
Exynos 990.

O patch
`platform/exynos990/patches/extremekrnl/patches/0001-accept-memory-recursiveprot-on-legacy-cgroup2.patch`
foi ampliado para portar a implementação funcional, não apenas ignorar a
opção de montagem. Ele agora:

- adiciona `CGRP_ROOT_MEMORY_RECURSIVE_PROT` ao conjunto de flags do root;
- reconhece, aplica e exibe `memory_recursiveprot` nas operações de mount e
  remount do cgroup2;
- anuncia a feature em `/sys/kernel/cgroup/features`;
- porta o cálculo recursivo de proteção para `memory.min` e `memory.low` em
  `mm/memcontrol.c`, preservando o comportamento antigo quando a flag não é
  usada.

Validação realizada:

1. O patch foi aplicado e revertido em uma cópia limpa da árvore do
   ExtremeKRNL, confirmando que pode ser reaplicado pelo `customize.sh` sem
   depender de alterações locais.
2. `kernel/cgroup/cgroup.o` e `mm/memcontrol.o` foram compilados com a
   configuração arm64 do alvo e o Clang 14 usado pelo projeto, sem erros.
3. Nenhuma imagem de boot foi gerada ou flashada nesta etapa.

O próximo teste deve gerar uma nova imagem do kernel, confirmar no aparelho
que a montagem mostra `memory_recursiveprot` e repetir o teste do Chrome/AppZygote.
Esse port melhora a compatibilidade do contrato cgroup2, mas ainda não prova
que ele seja a única causa do `SIGABRT` no `zygote-child`.

## Correção dos perfis cgroup incompatíveis (2026-09-20)

O primeiro boot com `memory_recursiveprot` ativo confirmou o recurso no
kernel, mas revelou dois problemas de integração no userspace:

- `SystemServiceCapacityHigh` apontava para o grupo S24+
  `/dev/cpuset/foreground-boost`, inexistente no vendor do S20+;
- perfis de I/O eram aplicados antes de os grupos
  `/dev/blkio/top`, `high`, `normal` e `low` serem criados pelo `init.rc` em
  `early-fs`.

As correções foram feitas em `prebuilts/samsung/e2sxxx`:

1. `ForegroundBoostCapacityCPUs` e `SystemServiceCapacityHigh` agora usam o
   grupo existente `/dev/cpuset/foreground`, preservando uma política de CPU
   válida sem importar o grupo específico do S24+.
2. `SystemMemoryProcess` voltou a aplicar `JoinCgroup` no grupo v2
   `memory/system`, agora que o kernel instalado expõe `memory` e o boot
   confirmou `cgroup.subtree_control=memory`.
3. `cgroupmem.rc` cria os quatro grupos blkio no `early-init` e ajusta as
   permissões de `cgroup.procs`, eliminando a corrida com os primeiros perfis
   de processo. A criação posterior do vendor continua idempotente.

Validação local:

- `task_profiles.json` passou pelo parser JSON;
- `git diff --check` passou;
- o aparelho confirmou que `normal` já existe depois do boot, enquanto
  `foreground-boost` não existe, validando a escolha do fallback para
  `foreground`.

Ainda não foi gerada uma nova build após essa alteração. O próximo boot deve
ser verificado para confirmar a ausência de `foreground-boost/tasks` e a
redução dos avisos `blkio/normal/cgroup.procs`; o aviso do kernel
`mem_cgroup_update_lru_size(... lru_size -1)` deve ser acompanhado
separadamente, pois não é causado diretamente por esses perfis.

## Isolamento pós-fork do AppZygote (2026-09-20)

Foi repetido um teste controlado no SM-S926B após a criação dos grupos blkio.
Os perfis que o zygote nativo usa (`CPUSET_SP_DEFAULT`,
`SCHED_SP_DEFAULT`, `CPUSET_SP_FOREGROUND`, `SCHED_SP_FOREGROUND`,
`CPUSET_SP_TOP_APP`, `SCHED_SP_TOP_APP` e `SystemMemoryProcess`) foram
aplicados a processos temporários com `/system/bin/settaskprofile` e todos
retornaram `Profile ... is applied successfully`/`rc=0`. Os grupos relevantes
(`/dev/blkio/high`, `/dev/blkio/normal`, `/dev/cpuctl/foreground`,
`/dev/cpuset/foreground` e `/dev/cpuset/top-app`) existem no aparelho, e os
hashes de `task_profiles.json` e `cgroups.json` instalados coincidem com os
arquivos gerados em `work_dir`.

Ao iniciar o Chrome 153.0.8010.49, o filho ainda aborta sempre no mesmo ponto:

```text
libprocessgroup: Created cgroup /sys/fs/cgroup/apps/uid_10248/pid_<pid>
libprocessgroup: A JoinCgroup action in the SystemMemoryProcess profile is used for controller memory in the cgroup v2 hierarchy and will be ignored
libc: Fatal signal 6 (SIGABRT) ... (zygote-child)
```

O intervalo entre o aviso do perfil e o `SIGABRT` foi de aproximadamente 7 ms,
sem erro de cgroup, AVC ou GPU. O `crash_dump64` também não consegue gerar um
tombstone desse filho (`capset failed: Operation not permitted`), portanto a
ausência de backtrace não identifica a função que abortou. O kernel expõe
`CONFIG_SECCOMP=y`/`CONFIG_SECCOMP_FILTER=y`, `cap_last_cap=37` e o zygote
regular/nativo permanece vivo; não há evidência de que `clone3` seja exigido
(o zygote AOSP Android 17 usa `fork` nessa revisão).

A comparação dos manifestos mostra a diferença relevante entre a versão que
funcionava na partição `product` e a atualização que falha. Ambas usam
`NativeOnlySandboxedProcessService0/1` com `useAppZygote=true` e
`nativeService=true`, porém:

| versão | preload Java | biblioteca do NativeService |
| --- | --- | --- |
| 149.0.7827.102 (product) | `org.chromium.chrome.app.TrichromeZygotePreload` | `libmonochrome_64.so` |
| 153.0.8010.49 (atualizada) | `org.chromium.content_public.app.ZygotePreload` | `libchrome.so` |

Isso desloca a hipótese principal para a especialização/carregamento do
NativeService da biblioteca Chrome nova em conjunto com o zygote nativo, não
para a criação do cgroup2. O próximo A/B deve instalar somente o Chrome da
`product` (mantendo o restante da build) e repetir o mesmo smoke test; se o
`zygote-child` sobreviver, o kernel/cgroup fica descartado como causa primária
e a investigação deve comparar os requisitos nativos de `libchrome.so` com
`libmonochrome_64.so`.
