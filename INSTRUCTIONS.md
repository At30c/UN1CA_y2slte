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

## Validação da nova beta e escopo do spam do AppZygote (2026-09-20)

O log `logcat_android_20260920_212440.log` mostra que a nova beta melhorou o
início do sistema: `zygote64` (PID 7381) e `zygote_next` (PID 7505) são
iniciados normalmente e continuam presentes no relatório do watchdog. Não há
spam de `ZygoteProcess` durante o boot; o primeiro erro só aparece quando o
Chrome é aberto.

O problema, entretanto, não foi eliminado. O Chrome instalado é a versão
153.0.8010.49 (versionCode 801004904), que substitui a cópia antiga da
`product` (782710233). Ao criar o processo nativo isolado, ocorreram:

- `19.200` mensagens `Got error connecting to zygote` entre 21:24:56 e
  21:26:43;
- dois `Fatal signal 6 (SIGABRT)` em processos `zygote-child` (PIDs 20658 e
  21165), aproximadamente 7 ms depois do aviso de `SystemMemoryProcess`;
- falhas de `capset`/capacidades no `crash_dump64`, sem tombstone útil;
- timeout de canal GPU no processo principal do Chrome, consequência da morte
  do filho nativo;
- `WATCHDOG KILLING SYSTEM PROCESS` em `ActivityManager:procStart`, seguido de
  `PLATFORM WATCHDOG RESET`.

Portanto, a nova beta deslocou o sintoma para o caminho de inicialização do
Chrome/AppZygote, mas ainda não corrigiu a incompatibilidade. O aviso de
`JoinCgroup` em `SystemMemoryProcess` continua sendo apenas um aviso de ação
de memória ignorada na hierarquia cgroup v2; o abort ocorre logo depois e não
há evidência, neste log, de que o `zygote64` regular ou a criação básica dos
cgroups seja a causa primária. O próximo A/B deve manter o restante da build e
instalar somente o Chrome/Trichrome da `product`, comparando o caminho antigo
(`libmonochrome_64.so`) com o atual (`libchrome.so`).

Observação de reprodução: a árvore usada para esta análise contém o arquivo
vazio `platform/exynos990/patches/cgroup_legacy/disable`. O executor de módulos
ignora qualquer módulo que possua esse marcador; portanto, se ele estava
presente no momento da build, o `cgroup_legacy/customize.sh` não foi aplicado.

### Tombstone do processo principal do Chrome

O tombstone de 20/09 às 21:25:34 pertence ao processo principal do Chrome
(`pid 20607`, `ppid 7381`), não ao `zygote-child`. Ele registra `SIGTRAP` com a
mensagem fatal do Chromium:

```text
[FATAL:content/browser/gpu/browser_gpu_channel_host_factory.cc:49]
Timed out waiting for GPU channel.
```

Os frames nativos apontam para `libchrome.so` da versão 153.0.8010.49. Isso é
um abort intencional do Chromium após não receber o canal do processo GPU; o
`Data Abort` exibido no ESR não deve ser interpretado isoladamente como uma
falha de memória do kernel. A sequência causal permanece: o processo nativo
do AppZygote (`zygote-child`) aborta primeiro, o processo GPU não fica
disponível, o Chrome dispara o timeout e só então gera esse tombstone.

## Nova captura com Chrome/WebView da `product` (2026-09-20)

O arquivo `logcat_android_20260920_213635.log` contém três ciclos do mesmo
softreboot. A captura confirmou que trocar somente o Chrome atualizado não
resolve o problema:

- o Chrome 153 da partição `/data` falha com `libchrome.so`;
- depois, o Chrome 149 da `product` é realmente carregado de
  `/product/app/Chrome64/Chrome64.apk`, usando
  `/product/app/TrichromeLibrary64/TrichromeLibrary64.apk!libmonochrome_64.so`;
- mesmo com essa versão antiga, o processo `zygote-child` aborta e o Chrome
  termina com o mesmo `Timed out waiting for GPU channel`.

Isso descarta a versão específica de `libchrome.so` como causa suficiente. O
problema comum é o caminho `NativeOnlySandboxedProcessService`/AppZygote e a
especialização do processo no sistema/kernel atual.

Há também uma falha de configuração que precisa ser corrigida antes de novos
A/Bs. Na inicialização do zygote e após cada watchdog, o `init` registra:

```text
SetCgroup::ExecuteForTask: failed to open /dev/cpuset/foreground-boost/tasks
Failed to apply SystemServiceCapacityHigh task profile
init: failed to set task profiles
```

O grupo `foreground-boost` não existe no S20+. O arquivo vazio
`platform/exynos990/patches/cgroup_legacy/disable` faz o executor ignorar o
módulo que substitui esse perfil pelo grupo existente `foreground`; portanto,
essa build foi testada sem a correção de perfis. O próximo teste deve remover
esse marcador (ou habilitar o módulo corretamente), confirmar no log que não há
mais `foreground-boost`, e só então repetir o teste do Chrome antigo.

O WebView também não foi totalmente validado como `product`: o log mostra a
cópia `/product` (versionCode 777821504) sendo ignorada porque há uma versão
`/data` mais nova (155.0.8059.4, versionCode 805900413). O WebView 155 consegue
criar um sandbox regular, mas isso não testa o caminho NativeOnly/AppZygote do
Chrome.

## Auditoria do módulo `cgroup_legacy` (2026-09-20)

O módulo não foi aplicado na build usada no log. O arquivo vazio
`platform/exynos990/patches/cgroup_legacy/disable` faz
`scripts/internal/apply_modules.sh` retornar antes de executar o
`customize.sh`. Isso é confirmado pelos artefatos da build: o
`task_profiles.json` ainda aponta `ForegroundBoostCapacityCPUs` e
`SystemServiceCapacityHigh` para `foreground-boost`, o `cgroupmem.rc` não está
no `work_dir`, e o `cgroups.json` ainda marca o controlador `memory` como
`Optional`.

Quando habilitado, o módulo deve corrigir a parte de perfis legados: o arquivo
doador troca `SystemServiceCapacityHigh` para `cpuset/foreground` e
`NormalIoPriority` para `blkio/normal`, grupos que existem no S20+. O
`cgroupmem.rc` tenta ativar `memory` em `/sys/fs/cgroup`, `apps` e `system` em
vários estágios do boot. Isso pode eliminar as falhas de
`foreground-boost`/`NormalIoPriority`, mas não prova sozinho que o
`zygote-child` deixará de abortar: o Android continua emitindo o aviso de que
`SystemMemoryProcess` em `memory` na hierarquia v2 será ignorado, e o arquivo
não cria os nós `apps`/`system` caso eles não existam.

O módulo também copia `libchrome.so` para `/system/lib64` e `/vendor/lib64`,
mas isso não substitui as bibliotecas embarcadas nos APKs do Chrome/WebView
(`libmonochrome_64.so` no Chrome da `product` ou `libchrome.so` dentro do APK
atual). Portanto, essa cópia não é uma correção direta do crash do Chromium e
deve ser validada por ABI antes de ser mantida.

Conclusão: o módulo é uma correção plausível e específica para o erro de
perfis/cgroups observado, porém a captura atual não o testou. O A/B correto é
remover o marcador `disable`, reconstruir, verificar no log a ausência de
`foreground-boost`/`Failed to apply SystemServiceCapacityHigh`, e só então
avaliar novamente o `zygote-child`, o canal GPU e o softreboot.

## Incompatibilidade adicional da pilha gráfica (2026-09-20)

O timeout do Chromium não deve ser tratado apenas como mensagem secundária.
Pouco antes do primeiro `zygote-child` abortar, o Chrome pede
`android.hardware.graphics.allocator.IAllocator/default`, mas o
`servicemanager` informa que essa instância não existe no VINTF. O mesmo aviso
aparece durante o boot para `surfaceflinger`, `bootanim`, `mediaswcodec` e
outros clientes, portanto é uma incompatibilidade sistêmica, não exclusiva do
Chrome.

O vendor do S20+ declara somente a implementação HIDL antiga:
`android.hardware.graphics.allocator@2.0::IAllocator/default`,
`android.hardware.graphics.composer@2.3::IComposer/default` e
`android.hardware.graphics.mapper@2.1::IMapper/default` em
`vendor/etc/vintf/manifest.xml`. O serviço correspondente também é HIDL em
`android.hardware.graphics.allocator@2.0-service.rc`. Já a pilha de sistema
trazida do S24+ contém clientes AIDL (`IAllocator`/`IComposer`) e tenta
consultar essas instâncias AIDL.

O módulo `unica/mods/zzz_legacy_graphics_mapper` só remove a barreira de nível
de API para permitir o fallback interno Gralloc 3/2 do `libui`; ele não cria
um serviço AIDL nem corrige o VINTF. Na imagem atualmente analisada, os bytes
do gate ainda estão no estado original, então esse fallback também não foi
aplicado. O kernel Mali e o `vendor.gralloc-2-0` chegam a iniciar e há várias
alocações bem-sucedidas, mas isso não elimina a falha de descoberta da
interface gráfica.

Não é correto apenas adicionar `IAllocator/default` AIDL ao manifesto: isso
publicaria um serviço que o vendor não implementa. A correção precisa ser uma
destas duas opções, validada em A/B: fazer `libgui`/`libui` usar de fato o
fallback HIDL 2.0/2.1 compatível com o vendor, ou portar/fornecer uma ponte
AIDL real para allocator/composer/mapper. O erro `Timed out waiting for GPU
channel` deve ser reavaliado depois dessa compatibilidade e da ativação do
`cgroup_legacy`; ele pode ser consequência da falha de inicialização do
processo GPU, não uma falha física do Mali.

## Comparação com `MonsterROM/framework_compat` (2026-09-20)

O patch enviado por `devcore94/MonsterROM` confirma a mesma incompatibilidade
de geração. `0001-Avoid-unsupported-AIDL-HAL-probes.patch` remove de
`Watchdog.smali` as entradas AIDL
`android.hardware.graphics.allocator.IAllocator/` e
`android.hardware.graphics.composer3.IComposer/`, além de fazer o
`AudioService` usar diretamente o fallback HIDL quando o serviço AIDL de áudio
não existe.

O nosso `services.jar` contém exatamente essas sondagens em
`smali/com/android/server/Watchdog.smali` e o mesmo teste AIDL/HIDL em
`smali/com/android/server/audio/AudioService.smali`, portanto o patch é um
candidato plausível para ser portado como patch de `services.jar`, após
validar o contexto e os registradores da revisão atual.

Esse patch reduz sondagens e mensagens de VINTF do framework, mas não corrige
o crash do GPU por si só. No nosso log, a requisição que precede o abort vem do
próprio processo Chrome (`uid=10248`), não do `Watchdog`; o patch não toca
`libgui`, `libui`, `gralloc`, `mapper` nem fornece um servidor AIDL. Portanto,
ele deve ser tratado como uma correção complementar para o spam/framework,
enquanto a compatibilidade gráfica HIDL/AIDL continua sendo necessária para
resolver o canal GPU.

## Validação da beta `logcat_android_20260920_223614.log` (2026-09-20)

Nesta build o módulo `cgroup_legacy` entrou: o `init` processou
`/system/etc/init/cgroupmem.rc` (linha 8167) e não há mais falha de
`foreground-boost` nem de `SystemServiceCapacityHigh`. Restam somente a
condição de corrida inicial de `NormalIoPriority` (o nó
`/dev/blkio/normal/cgroup.procs` ainda não existe nas linhas 8457–9180) e o
aviso esperado de que `SystemMemoryProcess` não pode aplicar `memory` na
hierarquia cgroup v2.

O problema funcional, porém, continua. O Chrome (`pid=19194`) consegue criar
janela/superfície e há várias alocações `mali_gralloc_allocate` bem-sucedidas;
ele também percorre o fallback (`mapper 4.x` e `mapper 3.x` não suportados,
seguido de `Arm Module v1.0`). Logo, a ausência AIDL do allocator é um
problema de compatibilidade e gera spam, mas não impediu toda a renderização.

A sequência determinante é: `zygote-child` 19243 aborta com `SIGABRT` em
22:36:31.318, o framework repete `Connection refused`, o Chromium encerra
com `Timed out waiting for GPU channel` em 22:37:07.045 e, após nova tentativa
do child 19677, o `system_server` fica bloqueado em
`AppZygote.connectToZygoteIfNeededLocked` até o `PLATFORM WATCHDOG RESET` de
22:38:13.577. O tombstone do primeiro child não traz a causa porque o
`crash_dump64` não conseguiu abrir `/proc/19243`; portanto ainda não há prova
de que o kernel/Mali seja o responsável direto.

Também confirmei que o patch `framework_compat` do MonsterROM ainda não foi
aplicado nesta imagem: `services.jar` continua contendo as sondagens AIDL em
`Watchdog.smali`. Aplicá-lo pode eliminar as sondagens do framework, mas não
deve ser considerado correção do `zygote-child`/GPU, pois o Chrome faz a
requisição gráfica diretamente.

Conclusão da nova build: o ajuste de perfis cgroup resolveu aquele ramo de
erros, mas não resolveu o softreboot. O próximo teste deve separar as
variáveis: (1) corrigir a criação tardia de `/dev/blkio/normal`, (2) aplicar o
patch `framework_compat` isoladamente e (3) capturar o child com tombstone
válido para descobrir o motivo do `SIGABRT`, sem adicionar um serviço AIDL
falso ao VINTF.

## Rastreamento do timeout GPU até o kernel (2026-09-20)

O caminho mostrado pelo tombstone não é um arquivo do kernel. O binário que
dispara o abort é
`/product/app/TrichromeLibrary64/TrichromeLibrary64.apk!libmonochrome_64.so`,
com a string de origem `../../content/browser/gpu/browser_gpu_channel_host_factory.cc`
e a mensagem em `:49`. A cópia correspondente existe em
`out/target/y2s/work_dir/product/app/TrichromeLibrary64/TrichromeLibrary64.apk`;
ela está stripped, mas `strings` confirma tanto o caminho quanto a mensagem.

Essa linha é um watchdog do Chromium, não o watchdog do Mali: ele chama
`LOG(FATAL)` quando o canal IPC com o processo GPU não é estabelecido. No log,
o primeiro `zygote-child` morre às 22:36:31.318 e o Chromium aborta às
22:37:07.045, intervalo de aproximadamente 35,7 s. Isso coincide com o
temporizador de Android do Chromium (watchdog do GPU mais fator de reinício e
5 s), portanto o timeout é consequência de o processo sandbox/GPU não chegar
ao estado de canal pronto.

O kernel usado pela imagem foi localizado e confirmado no próprio artefato:
`out/target/y2s/work_dir/kernel/boot.img` contém um `Image` de 43.241.488
bytes, versão `4.19.325-cip119-st3-ExtremeKRNL-Nexus-v1+`, igual ao
`out/kernel_tmp-exynos990/build/out/y2s/Image`. O driver GPU correspondente é
`drivers/gpu/arm/bv_r38p1` (Mali DDK r38p1), e a inicialização registrada é
`mali 18500000.mali: GPU identified as 0x0 arch 9.0.8 r0p1`.

Há uma incompatibilidade real no lado do kernel/DT, mas ela não é a linha que
gera o timeout do Chromium: o driver imprime `No OPPs found in device tree!
Scaling timeouts using 100000 kHz` porque o DT y2s usa a tabela Samsung
`gpu_dvfs_table` e não fornece um `operating-points-v2` aceito pelo Mali. O
código que emite essa mensagem é
`drivers/gpu/arm/bv_r38p1/mali_kbase_core_linux.c:3319-3354`; ele apenas
escolhe a frequência de referência para calcular timeouts internos do driver.
Também estão desativados `CONFIG_MALI_DMA_FENCE` e
`CONFIG_MALI_DMA_BUF_MAP_ON_DEMAND`, mas o log mostra alocações
`mali_gralloc_allocate` bem-sucedidas e não mostra fault/reset/fence do Mali.

Conclusão: o arquivo do Chromium mostra exatamente por que ele responde com
`Timed out waiting for GPU channel`, mas não aponta para um arquivo-fonte do
kernel. A cadeia observada é `AppZygote/zygote-child` abortado → nenhum canal
GPU pronto → watchdog do Chromium → abort do Chrome → espera do
`system_server`. O próximo teste deve capturar a causa do `SIGABRT` do
`zygote-child`; alterar apenas a frequência/timeout do Mali ou a linha 49 do
Chromium esconderia o sintoma sem fazer o processo sandbox iniciar.

## Aplicação do patch `framework_compat` do MonsterROM (2026-09-20)

Foi adicionado o módulo
`platform/exynos990/patches/framework_compat/` com o patch revisado enviado
por `devcore94/MonsterROM`:
`smali/system/framework/services.jar/0001-Avoid-unsupported-AIDL-HAL-probes.patch`.
O conteúdo foi mantido, incluindo o cabeçalho Git e os créditos originais:
autor `ditternation <ditternation@localhost>`. `devcore94` é a origem do
patch no MonsterROM; At30c não é o autor dessa alteração.

O patch remove de `Watchdog.smali` somente as sondagens AIDL de áudio e
gráficos que o vendor Exynos 990 não implementa, e elimina de `AudioService`
o teste de `android.hardware.audio.core.IModule/default` antes do fallback
HIDL. Ele será aplicado automaticamente por `scripts/internal/apply_modules.sh`
antes dos módulos `unica`, seguindo a convenção `smali/.../*.jar/*.patch`.

Validação feita contra o `services.jar` atualmente decodificado:

```text
git diff --check
git apply --check --directory=out/target/y2s/apktool/system/framework/services.jar \
  --unsafe-paths platform/exynos990/patches/framework_compat/smali/system/framework/services.jar/0001-Avoid-unsupported-AIDL-HAL-probes.patch
```

Ambas passaram. A alteração ainda precisa de uma nova build para entrar no
`services.jar` flashável. O patch reduz as consultas VINTF ausentes do
framework e força o fallback HIDL de áudio; não cria um servidor AIDL e não
é, isoladamente, uma correção comprovada para o `zygote-child`/timeout GPU.

## Validação da build com `framework_compat` instalado (2026-09-20 23:48)

A build usada na captura `logcat_android_20260920_234820.log` realmente
contém o patch: `out/target/y2s/make_rom-20260920_225943.log` registra
`Processing "Framework compatibility" by @ditternation` e
`Applying "Avoid unsupported AIDL HAL probes"` ao `services.jar`.

O boot desta imagem chega a `sys.boot_completed=1` às 23:45:46. O kernel é o
ExtremeKRNL `4.19.325-cip119-st3-ExtremeKRNL-Nexus-v1+`, build `#9`. O módulo
`cgroup_legacy` continua ativo: não há mais `foreground-boost` nem falha de
`SystemServiceCapacityHigh`; resta apenas o aviso esperado de que
`SystemMemoryProcess` não consegue aplicar o controlador `memory` na
hierarquia cgroup v2.

O teste do Chrome reproduz o problema em duas tentativas:

```text
23:48:39.066  JoinCgroup(SystemMemoryProcess) ignorado
23:48:39.073  zygote-child 19780: SIGABRT
23:49:14.697  Chrome 19724: Timed out waiting for GPU channel
23:49:45.516  JoinCgroup(SystemMemoryProcess) ignorado
23:49:45.518  zygote-child 20226: SIGABRT
23:50:18.151  system_server bloqueado em ActivityManager:procStart por 71 s
23:50:18.193  PLATFORM WATCHDOG RESET
```

O `crash_dump64` falha novamente ao abrir `/proc/19780` e `/proc/20226`,
portanto ainda não há backtrace do processo que realmente aborta. O Chrome
principal, entretanto, gera tombstone válido e confirma o mesmo abort
intencional de Chromium em `browser_gpu_channel_host_factory.cc:49`, usando
`/product/app/TrichromeLibrary64/TrichromeLibrary64.apk!libmonochrome_64.so`.
O stack do watchdog agora fecha o elo restante: `system_server` fica preso em
`ZygoteProcess.waitForConnectionToNativeZygote` →
`AppZygote.connectToZygoteIfNeededLocked` enquanto o socket do AppZygote está
recusando conexões.

Conclusão desta A/B: o patch de compatibilidade foi aplicado corretamente e
reduz somente as sondagens do `Watchdog`/áudio do framework; ele não altera a
requisição AIDL gráfica feita diretamente pelo Chrome e não corrige o abort do
`NativeOnlySandboxedProcessService`. O processo Chrome chega a criar janela,
Surface e carregar Vulkan antes da morte do child; não há fault/reset do Mali
no intervalo. A causa primária continua sendo a inicialização do
`zygote-child`/AppZygote nativo, ainda sem tombstone útil, e o timeout GPU e o
softreboot permanecem consequências.

## Captura manual durante a inicialização do Chrome (2026-09-20 23:58)

Foi feita uma captura direcionada com o aparelho conectado e `su` disponível,
iniciando simultaneamente `logcat -b all`, `dmesg -w`, snapshots de processos,
lista de tombstones e, depois, executando:

```text
adb shell am force-stop com.android.chrome
adb shell am start -W -n com.android.chrome/com.google.android.apps.chrome.Main
```

A abertura retornou `Status: ok`, `LaunchState: COLD` e `TotalTime: 2347` ms.
Os artefatos estão em
`out/target/y2s/manual-chrome-capture-20260920-235817/` (`logcat.txt`,
`dmesg.txt`, `process-snapshots.txt`, `crash-buffer-final.txt`,
`tombstones.latest` e `launch.txt`).

A sequência reproduzida foi:

```text
23:58:21.618  zygote-child 3399 cria cgroup uid_10248/pid_3399
23:58:21.620  SystemMemoryProcess: controlador memory ignorado no cgroup v2
23:58:21.627  zygote-child 3399: SIGABRT
23:58:57.316  Chrome 3294: Timed out waiting for GPU channel
23:58:58.107  Chrome 3294: SIGTRAP; abort de browser_gpu_channel_host_factory.cc:49
23:59:27.932  zygote-child 5968 cria cgroup uid_10248/pid_5968
23:59:27.942  zygote-child 5968: SIGABRT
```

Durante o intervalo houve 12.860 mensagens `ZygoteProcess: Got error connecting
to zygote, retrying. msg= Connection refused`, seguidas de falha explícita no
socket `com.android.internal.os.AppZygoteInit/...` e nova tentativa de iniciar
`NativeOnlySandboxedProcessService0`. O Chrome principal chegou a criar janela,
Surface e carregar `libmonochrome_64.so`/Vulkan antes do timeout. O `dmesg` não
registrou fault, reset ou fence do Mali; os `capset failed` pertencem ao
`crash_dump64` depois que o child já havia desaparecido. O polling de processos
não capturou um snapshot do child porque ele termina em poucos milissegundos.

Conclusão: a captura manual confirma que o primeiro evento é o `SIGABRT` do
`zygote-child`/AppZygote; o erro de GPU do Chrome ocorre cerca de 36 s depois e
é consequência da ausência do processo sandbox/canal GPU. Ainda não há
tombstone/backtrace do child para apontar a instrução exata; a próxima coleta
deve observar o fork/abort com instrumentação mais próxima do processo.

## Auditoria completa de `crash_dump64` e capabilities (2026-09-21)

O spam de `capset failed` não é o primeiro erro. Na captura manual, o filho do
Chrome (UID 10248) aborta primeiro (`zygote-child` 3399 às 23:58:21.627 e
5968 às 23:59:27.942). Depois disso, o handler de sinal do Bionic cria o helper
3407/5970. Em `external/android-tools/vendor/core/debuggerd/handler/debuggerd_handler.cpp`,
`raise_caps()` copia `CapPrm` para `CapInh`, chama `capset()` e tenta elevar
cada bit para o conjunto ambient antes de executar `crash_dump64`. Por isso o
log mostra um `capset failed` seguido de dezenas de `failed to raise ambient
capability`.

O kernel retorna `-EPERM` quando o novo conjunto herdável contém bits fora do
bounding set (`out/kernel_tmp-exynos990/security/commoncap.c`) ou quando um
bit ambient não está simultaneamente em `CapPrm` e `CapInh`. O estado de
capabilities deixado pelo child/sandbox não é compatível com essa preparação,
mas isso é consequência do abort, não a evidência de que `crash_dump64` o
causou. Em seguida o helper tenta abrir `/proc/<pid>` e encontra `ENOENT`, pois
o child já saiu. O mesmo `crash_dump64` realiza vários dumps normais de outros
processos na mesma captura, portanto não há falha global do helper.

Há uma hipótese adicional para a causa primária: o sandbox Linux do Chromium
usa `capset()` para remover capabilities e valida o resultado. Isso torna o
`SIGABRT` do child compatível com uma falha na inicialização do sandbox, mas
ainda é necessário capturar `CapInh/CapPrm/CapEff/CapBnd/CapAmb`, `NoNewPrivs`
e `Seccomp` do child para confirmar. O Chrome foi criado pelo `zygote64`
(PID 20560), não diretamente pelo `zygote_next`; o `zygote_next` (PID 7476)
está ativo separadamente. Mesmo assim, o serviço `zygote_next` é `user root`
sem uma diretiva `capabilities`, portanto deve ser auditado antes de ser usado
para iniciar processos nativos.

Não foi aplicado patch de supressão de logs: alterar `debuggerd_handler.cpp`
sem reconstruir o `com.android.runtime.apex` apenas esconderia a evidência e
não corrigiria o abort do Chrome. O próximo teste deve coletar os conjuntos de
capabilities/seccomp durante o fork e fazer uma A/B com o caminho do sandbox.

## Linha de investigação do `SIGABRT` no native child (2026-09-21)

A cadeia nativa foi confrontada com o código do Android 17: Chrome inicia
`NativeOnlySandboxedProcessService` através de `AppZygote`; o serviço usa o
socket reservado `zygote_next`, que executa a espécie `android-native-app`. No
filho, o `re_initialize_prologue` da espécie cria o cgroup, instala o filtro
seccomp de app-zygote e só depois chama `PR_SET_NO_NEW_PRIVS`; a troca de UID e
a transição SELinux vêm ainda depois. Referências oficiais: [child_process.rs](https://android.googlesource.com/platform/system/zygote/+/refs/heads/android17-release/zygote/src/child_process.rs), [android_native.rs](https://android.googlesource.com/platform/system/zygote/+/refs/heads/android17-release/zygote/src/species/android_native.rs) e [server.rs](https://android.googlesource.com/platform/system/zygote/+/refs/heads/android17-release/zygote/src/server.rs).

Isso isolou uma hipótese testável e mais forte que o cgroup: o kernel entregue
tem `CONFIG_SECCOMP=y`, `CONFIG_SECCOMP_FILTER=y`, BPF e JIT habilitados
(`out/kernel_tmp-exynos990/out/.config:459,660-661`), mas o próprio
`kernel/seccomp.c:382-390` recusa instalar um filtro com `-EACCES` se o processo
não tiver `CAP_SYS_ADMIN` efetivo e ainda não tiver `NoNewPrivs`. A biblioteca
instalada contém `set_app_zygote_seccomp_filter` e a mensagem fatal
`Could not set seccomp filter of size`, confirmando que essa etapa está no
artefato usado pela ROM (`system/lib64/libseccomp_policy.so`). O caminho AOSP
de instalação está documentado em [seccomp_policy.cpp](https://android.googlesource.com/platform/bionic/+/master/libc/seccomp/seccomp_policy.cpp).

O `SIGABRT` imediato, sem `SIGSYS`, é compatível com esse `PLOG(FATAL)` caso o
`prctl(PR_SET_SECCOMP)` receba `EPERM/EACCES`, mas a captura não contém ainda a
mensagem fatal porque o child dura poucos milissegundos e a auditoria já estava
perdendo milhares de eventos. Portanto isto é uma causa provável, não uma
confirmação final. A política SELinux dá `sys_admin` a `zygote_next`
(`plat_sepolicy.cil:83292-83335`), e o serviço é `user root` sem diretiva
`capabilities` em `system/etc/init/zygote_next.rc:1-6`; falta verificar o estado
real herdado em `/proc` (`CapEff`, `CapBnd`, `NoNewPrivs` e `Seccomp`). Política
SELinux permissiva não prova que a capability esteja efetiva no processo.

Os erros de `SystemMemoryProcess`, `/dev/blkio` e `crash_dump64` continuam
secundários: o cgroup do child é criado antes do abort, o helper só roda depois
que o PID desaparece, e os perfis agregados ignoram falhas dos subperfis. Não
foi aplicado patch; o próximo teste precisa capturar o estado do `zygote_next`
e, se possível, o `logcat -b crash` imediatamente durante a abertura do Chrome.

Um detalhe adicional torna o teste de capability prioritário: o `raise_caps()`
do handler não enumera `CapEff`; ele copia `CapPrm` para `CapInh` e depois tenta
elevar o conjunto ambient. A lista observada (0–5 e 9–37) mostra que o child
carregava esses bits no conjunto permitido, mas o `capset` falhou porque pelo
menos um deles não cabia no bounding set. Isso não prova que
`CAP_SYS_ADMIN` (bit 21) estava efetivo no instante do `PR_SET_SECCOMP`; é
precisamente `CapEff` e `CapBnd` que precisam ser medidos no `zygote_next`/fork.

## Teste diferencial após o watchdog (2026-09-21)

O dumpstate do watchdog mostrou que o evento não era isolado: o mesmo ciclo se
repetia em horários diferentes — `zygote-child` aborta, o `AppZygote` perde a
conexão, `ActivityManager:procStart` fica bloqueado por 70 segundos e o
Watchdog reinicia o `system_server` (`PLATFORM WATCHDOG RESET`). Isso explica o
spam posterior de `ZygoteProcess: ... Connection refused`: ele é consequência
do zygote reiniciado, não a origem do primeiro aborto.

Foi feita uma verificação ao vivo depois do reset. Tanto `zygote_next` (PID
7476) quanto `zygote64` (PID 11067) estavam com `CapPrm`, `CapEff` e `CapBnd`
iguais a `0x3fffffffff`, `NoNewPrivs=0` e `Seccomp=0`. Portanto, a hipótese de
que o zygote pai simplesmente não possuía `CAP_SYS_ADMIN` foi descartada para
esse estado em execução. O `zygote_next` também tem regras SELinux explícitas
para `setpcap`, `sys_admin` e cgroup v2. O child ainda precisa ser observado no
instante do fork; o estado do pai não prova que a transição de capabilities e
seccomp do filho terminou corretamente.

O sandbox comum do WebView continua funcionando (`webview_zygote` com
`NoNewPrivs=1`, `Seccomp=2`, e processos isolados criados normalmente). Isso
estreita o problema para a especialização do caminho nativo/AppZygote usado pelo
Chrome, e não para todos os sandboxes do sistema.

Foram repetidos dois testes de abertura do Chrome, cada um com captura por mais
de um minuto. Um usou flags de renderização por software e o outro usou a
abertura normal. Ambos abriram `ChromeTabbedActivity`; o teste normal criou o
`com.android.chrome_zygote`, o processo principal, `sandboxed_process0` e
`privileged_process0`, sem novo `zygote-child`, `SIGABRT`, `crash_dump64`,
`capset`, timeout de GPU ou watchdog. Assim, a falha não foi reproduzida nessa
sessão; isso não demonstra que o patch do cgroup resolveu a causa, apenas que o
estado pós-reset está estável. O teste com flags não permite atribuir causalidade
à GPU porque a sintaxe de flags do Chrome ainda não foi confirmada.

Conclusão operacional atual: `crash_dump64` continua sendo um observador
secundário, e o erro de GPU só deve ser tratado como causa primária se voltar a
aparecer sem o `SIGABRT` anterior. A próxima coleta útil é reproduzir a falha a
frio com logcat limpo e instrumentar especificamente a instalação do filtro
seccomp/transição de capabilities do `android-native-app`; aplicar um patch de
silenciamento no handler ou no cgroup neste momento esconderia a evidência.

## Comparação entre navegadores Chromium (2026-09-21)

O aparelho não possui Firefox instalado neste momento, portanto não foi possível
fazer uma comparação direta com Gecko. Ele possui, porém, o Samsung Internet
(`com.sec.android.app.sbrowser`), que também usa Chromium. Após encerrá-lo e
abri-lo com captura limpa por 55 segundos, ele criou normalmente o processo
principal, `sandboxed_process0` e `privileged_process0` — inclusive um segundo
`sandboxed_process0` — sem `zygote-child`, `SIGABRT`, `crash_dump64`, `capset`,
timeout de GPU ou watchdog.

Os processos do Samsung Internet exibiram a mesma assinatura de sandbox esperada
do Chromium: `Seccomp=2`, capabilities zeradas; os processos isolados tinham
`NoNewPrivs=1`. O Chrome apresentou a mesma arquitetura no teste anterior. Há
uma ressalva importante: essa captura só mostrou `SandboxedProcessService`; ela
não mostrou `NativeOnlySandboxedProcessService`, que é justamente o caminho
AppZygote/nativo associado ao aborto observado anteriormente. Portanto o teste
prova que o sandbox Chromium comum funciona, mas ainda não valida o caminho
nativo que está sob suspeita; também não há evidência de que todo Chromium seja
inevitavelmente incompatível com o kernel.

A correlação com “Chromium falha, Firefox funciona” continua útil para priorizar
`AppZygote`/seccomp/capabilities e a inicialização dos processos nativos, mas não
isola ainda qual etapa quebra no boot problemático. O próximo A/B conclusivo deve
ser feito após reinicialização, com Chrome e Samsung Internet iniciados antes de
qualquer outro navegador, preservando o logcat desde o início.

## A/B após reinicialização com Firefox (2026-09-21)

Foi feito um reboot real e o Chrome foi aberto assim que `sys.boot_completed=1`.
No log permanente, ele iniciou às 03:02:27, criou o processo principal, o
`com.android.chrome_zygote`, `SandboxedProcessService0` e
`privileged_process0`; não houve `zygote-child`, `SIGABRT`, `crash_dump64`,
timeout de GPU ou watchdog nessa inicialização fria.

O Firefox (`org.mozilla.firefox`) foi localizado e aberto em seguida. Ele criou
o processo principal e vários processos Gecko (`tab_disable_art_image_*` e
`gpu_disable_art_image_`) diretamente a partir do `zygote64`, sem
`AppZygote`/`zygote_next`; a sessão permaneceu estável por 50 segundos. Isso
confirma a diferença arquitetural observada pelo usuário: Firefox não depende
do caminho Chromium/AppZygote. Ao mesmo tempo, o Chrome também passou nesse boot,
logo o defeito não é reproduzido deterministicamente apenas por iniciar o
navegador.

O próximo teste precisa provocar especificamente o serviço
`NativeOnlySandboxedProcessService` do Chrome (o serviço aparece nos logs antigos
antes do `zygote-child`), em vez de testar somente a abertura da atividade e o
`SandboxedProcessService` comum. Só então será possível capturar a transição de
capabilities/seccomp que diferencia o caso que falha do caso estável.

## Relatório `chrome://gpu` (2026-09-21)

O relatório fornecido pelo aparelho confirma que a GPU está ativa, e não
desabilitada por `--disable-gpu`: Canvas, composição, rasterização, vídeo,
WebGL e WebGPU aparecem como `Hardware accelerated`; OpenGL e Vulkan estão
`Enabled`; o dispositivo ativo é o Mali-G77 (`0x13b5/0x90800011`); e o backend
Skia é `GaneshVulkan`. A linha `Command Line` não contém `--disable-gpu`, e o
campo `GPU process crash count` está em `0`.

As entradas em `Driver Bug Workarounds` são compatibilidades normais do
Chromium para Mali/Android (MSAA 4x, virtualized contexts, limitações de
textura e extensões); não há, nesse relatório, indicação de GPU bloqueada,
context lost ou reset do driver. Portanto não foi a GPU que “foi desativada”
para fazer os navegadores abrirem. O timeout antigo do canal GPU pode ter sido
transitório ou consequência do `zygote-child`/processo nativo ausente; este
relatório isolado não prova que o driver seja a causa primária.

## Estado funcional atual e workaround confirmado (2026-09-21)

Durante a sessão que permaneceu estável, o aparelho não estava executando a beta
do Chrome. A instalação ativa foi confirmada ao vivo como:

```text
com.android.chrome          /product/app/Chrome64        149.0.7827.102
com.google.android.webview  /product/app/WebViewGoogle64  148.0.7778.215
```

Essas são as versões da `product`/base, depois do downgrade que já havia sido
observado como workaround. O Chrome ativo criou `com.android.chrome_zygote`,
`SandboxedProcessService0` e `PrivilegedProcessService0` normalmente; não houve
`NativeOnlySandboxedProcessService`, `zygote-child` ou watchdog nessa sessão.

Assim, o que tornou o aparelho utilizável foi a combinação do Chrome/WebView
compatíveis da `product` com a reinicialização dos processos após o reboot — não
`--disable-gpu` e não uma alteração no `debuggerd`. O módulo `cgroup_legacy`
deve permanecer habilitado (sem o marcador `disable`) para que os arquivos de
cgroup/tarefa compatíveis sejam instalados. Isso é um workaround operacional;
a beta 153 e seu caminho nativo ainda precisam de uma correção própria antes de
serem reativados.

## Reprodução com Microsoft Edge/Chromium (2026-09-21)

O Microsoft Edge instalado (`com.microsoft.emmx`, versão `153.0.4234.49`,
`target_sdk_version=36`, split `chrome`) reproduziu o mesmo defeito ao ser
aberto por `am start -W -n com.microsoft.emmx/com.microsoft.ruby.Main`. A captura
controlada está em `/tmp/edge-20260921-032428.log`.

O encadeamento observado foi explícito:

```text
03:24:32.558  ActivityManager: Start proc ... com.microsoft.emmx:privileged_process0
03:24:32.676  libc: Fatal signal 6 (SIGABRT) ... tid ... (zygote-child)
03:24:32.938  libc: capset failed: Operation not permitted
03:24:32.958  crash_dump64: failed to open /proc/...
03:24:32.959  libc: Crash due to signal: crash_dump helper failed ...
03:24:32.651+ ZygoteProcess: Got error connecting to zygote, retrying
```

Foram contadas 11.923 mensagens de `Connection refused` durante a captura.
Também apareceu o aviso de `SystemMemoryProcess`/cgroup v2, mas ele continua
sendo um aviso de ação ignorada, não a causa imediata do aborto. Portanto o
problema é reproduzível em dois aplicativos Chromium independentes (Chrome e
Edge) e está no caminho comum de inicialização nativa/AppZygote/zygote-child;
não é um defeito exclusivo do APK do Chrome. O `capset` e o `crash_dump64` são
consequências do processo filho já abortado.

Esse teste não demonstrou que a GPU seja a origem: o Edge chegou a iniciar a
atividade e o processo privilegiado antes do aborto, e a captura não contém um
timeout de GPU anterior ao `SIGABRT`. O workaround continua sendo manter
Chrome/WebView/Chromium em versões compatíveis da `product` ou usar Firefox
enquanto o caminho nativo da beta não for corrigido.

## A/B do Edge com as flags usadas no Chrome (2026-09-21)

Foi repetido no Edge o procedimento de abertura usado durante o teste do
Chrome, sem alteração permanente na ROM. Foram tentadas as duas sintaxes que
aparecem na captura histórica:

```text
adb shell am force-stop com.microsoft.emmx
adb shell am start -W -n com.microsoft.emmx/com.microsoft.ruby.Main \
  --esa command-line-flags --disable-gpu \
  --esa command-line-flags --disable-gpu-compositing

adb shell am force-stop com.microsoft.emmx
adb shell am start -W -n com.microsoft.emmx/com.microsoft.ruby.Main \
  --es args --disable-gpu
```

Ambas retornaram `Status: ok` e abriram a atividade do Edge, mas ambas
reproduziram o mesmo aborto do processo nativo:

```text
03:33:38.945  libc: Fatal signal 6 (SIGABRT) ... (zygote-child)
03:33:38.953  libc: capset failed: Operation not permitted

03:36:16.518  libc: Fatal signal 6 (SIGABRT) ... (zygote-child)
03:36:16.634  crash_dump64: failed to open /proc/...
```

As capturas foram salvas em `/tmp/edge-disable-gpu-20260921-033336.log` e
`/tmp/edge-disable-gpu-es-20260921-033610.log`. O segundo teste ainda registrou
7.795 recusas de conexão ao zygote. Portanto a flag `--disable-gpu` não é a
solução para esse caminho: o processo privilegiado/AppZygote morre antes de um
eventual problema gráfico. O Chrome que abriu anteriormente não provou que a
flag o corrigiu; ele estava usando a versão compatível da `product` e um estado
estável após o reset.

## Regressão reproduzida no Chrome após reboot (2026-09-21 03:44)

O log permanente `logcat_android_20260921_033344.log` mostra que o problema
voltou mesmo com o Chrome/WebView da `product` (Chrome `149.0.7827.102`). O
aparelho havia acabado de reiniciar (`uptime` de aproximadamente um minuto), e
o Chrome foi iniciado às 03:44:41:

```text
03:44:41.353  ActivityManager: Start proc ... com.android.chrome
03:44:41.559  libprocessgroup: cgroup uid_10248 criado
03:44:43.181  libprocessgroup: cgroup do pid 15127 criado
03:44:43.183  SystemMemoryProcess: ação de memory ignorada no cgroup v2
03:44:43.191  libc: Fatal signal 6 (SIGABRT) ... (zygote-child)
03:44:43.235  libc: capset failed: Operation not permitted
03:44:43.277  crash_dump64: failed to open /proc/15127
03:45:19.079  chromium: Timed out waiting for GPU channel
03:45:21.087  DEBUG: SIGTRAP; abort message = GPU channel timeout
```

Após o primeiro aborto foram contadas 6.713 mensagens de `Connection refused`.
O `dumpsys activity` ainda identifica o serviço
`NativeOnlySandboxedProcessService0` do Chrome, mas com `thread=null`, enquanto
o processo principal permanece vivo esperando o child nativo. Isso confirma a
ordem causal já observada: o `zygote-child` morre primeiro, o socket do
AppZygote deixa de responder e o timeout da GPU ocorre depois.

Conclusão atualizada: o downgrade para a `product` reduz a frequência, mas não
elimina o defeito. O problema continua reproduzível a frio no caminho comum
`NativeOnlySandboxedProcessService`/AppZygote/`zygote_next`; não deve ser
considerado resolvido por versão do Chrome, `--disable-gpu` ou pelo aviso de
`SystemMemoryProcess`.

## Auditoria profunda de zygote, AppZygote, seccomp, namespaces e init (2026-09-21)

Foi feita uma coleta direta no aparelho, sem alterar a ROM. O estado atual é:

```text
ro.zygote=zygote64
zygote64       PID 15928  domain=u:r:zygote:s0       Seccomp=0
zygote_next    PID  7128  domain=u:r:zygote_next:s0  Seccomp=0
webview_zygote PID 28336  domain=u:r:webview_zygote:s0 Seccomp=2 NoNewPrivs=1
Chrome         PID 29598  domain=u:r:untrusted_app_34:s0 Seccomp=2
```

O Chrome principal tem `PPid=zygote64`; portanto `zygote_next` está ativo, mas
não é o pai direto do Chrome nesta build. O `zygote_next` é iniciado pelo
gatilho `persist.zygote.zygote_next.start_on_boot=true` em
`system/etc/init/zygote_next.rc`. Os sockets `/dev/socket/zygote` e
`/dev/socket/zygote_next` existem e têm permissões `root:system 0660`.

O kernel expõe `CONFIG_SECCOMP=y` e `CONFIG_SECCOMP_FILTER=y`, mas não possui
`CONFIG_USER_NS` nem `CONFIG_IPC_NS`; também não possui `CONFIG_CGROUP_PIDS` e
`CONFIG_CGROUP_DEVICE`. Os namespaces `user` e `ipc` não aparecem em `/proc`.
Isso é uma diferença real em relação a kernels AOSP mais completos e pode ser
relevante para o sandbox nativo Chromium, embora o log não prove sozinho que
essa seja a chamada que aborta.

O caminho que falha foi isolado:

1. `com.android.chrome:privileged_process0` inicia normalmente e o processo
   `com.android.chrome_zygote` chega a existir.
2. O serviço comum `SandboxedProcessService0` chega a funcionar em sessões
   anteriores.
3. A falha ocorre ao iniciar
   `NativeOnlySandboxedProcessService0`. Nesse momento o AppZygote perde o
   socket `com.android.internal.os.AppZygoteInit/<uuid>` e passa a registrar
   `Connection refused`.
4. Logo depois o processo filho aborta como `zygote-child`.

No log de 03:45:49, a ordem é explícita:

```text
2043309  AppZygote: retry starting ... NativeOnlySandboxedProcessService0
2043312  libprocessgroup: Created cgroup ... pid_15623
2043314  JoinCgroup/SystemMemoryProcess ignorado no cgroup v2
2043321  libc: Fatal signal 6 (SIGABRT) ... zygote-child
2043324  crash_dump64: falha ao abrir /proc/15623
```

O aviso `SystemMemoryProcess` não é uma negação SELinux: o `libprocessgroup`
deliberadamente ignora essa ação quando o controlador `memory` está na
hierarquia cgroup v2. O controlador está ativo (`cgroup.controllers` e
`cgroup.subtree_control` contêm `memory`), mas a build também registra no boot
falhas ao abrir `/dev/blkio/normal/cgroup.procs` e montagens legacy `freezer`
com `Device or resource busy`. Isso indica que o módulo `cgroup_legacy` ainda
mistura perfis de cgroup do S24+ com a topologia legacy do kernel; a mistura
não deve ser considerada validada apenas porque o grupo v2 foi montado.

Não foram encontrados `avc: denied` envolvendo zygote/Chrome no instante do
aborto. Há perda de eventos (`kauditd hold queue overflow`), portanto a
ausência de AVC não elimina completamente uma negação, mas o sinal observável
continua sendo a especialização nativa/AppZygote, não a GPU nem o zygote64
principal.

## Veredito após reprodução limpa do Chrome (2026-09-21 11:27)

Foi feita uma reprodução sem flags, com o logcat limpo antes de abrir o Chrome.
A ordem observada foi:

```text
11:26:59.835  zygote64: Forked child process 7663
11:26:59.836  ActivityManager: Start proc 7663:com.android.chrome
11:27:00.383  libprocessgroup: Created cgroup .../apps/uid_10248/pid_7719
11:27:00.388  SystemMemoryProcess: JoinCgroup(memory) ignorado em cgroup v2
11:27:00.393  libc: Fatal signal 6 (SIGABRT) em zygote-child 7719
11:27:00.404  crash_dump64: failed to open /proc/7719
```

O processo principal do Chrome chega a criar a janela e continua vivo; quem
abortou foi o filho nativo criado para o sandbox. As recusas de conexão ao
zygote aparecem imediatamente depois do abort e não antes dele. Não houve
`GPU channel timeout` nessa janela de reprodução; os timeouts de GPU dos
tombstones anteriores são consequência de o processo auxiliar não existir.

Foi verificado ainda o código efetivamente usado pelo build em
`external/android-tools/vendor/core/libprocessgroup/task_profiles.cpp`: entre
as linhas 975–987, qualquer ação `JoinCgroup` cujo controlador esteja na
hierarquia cgroup v2 é deliberadamente descartada com o aviso
`will be ignored`. Portanto, o `cgroupmem.rc` do módulo
`platform/exynos990/patches/cgroup_legacy` não torna o perfil
`SystemMemoryProcess` aplicável ao filho; ele apenas habilita `memory` e
mantém uma configuração híbrida. O mesmo boot registra falhas em
`/dev/blkio/normal/cgroup.procs` e leituras de `cgroup.procs` do Freecess.

### Conclusão técnica

O problema primário está no caminho de especialização do filho nativo
Chromium/AppZygote (zygote-child), provocado por incompatibilidade entre o
userspace Android 17, os perfis/cgroups legados importados e as capacidades/
namespaces disponíveis no kernel 4.19. O `zygote64` principal não é a origem:
ele permanece executando e cria processos comuns. A GPU e `crash_dump64` são
efeitos posteriores. A hipótese mais acionável é remover ou adaptar o módulo
`cgroup_legacy`; a confirmação binária final exige uma build A/B sem esse
módulo, mantendo Chrome/APEX/kernel idênticos.

## Verificação e correção do módulo cgroup_legacy (2026-09-21)

O sistema da ROM vem de `SM-S926B_EUX` (S24+), enquanto o vendor vem de
`SM-G986B_AUT` (S20+). Portanto, os arquivos nativos do firmware alvo não
podem substituir os descritores do sistema: o S20+ usa `/acct` e não define
`SystemServiceCapacityHigh`, mas os `init.rc` do S24+ usam `/dev/acct` e esse
perfil. O módulo agora usa os descritores `e2sxxx` compatíveis, que mantêm
`/dev/acct`, remapeiam `foreground-boost` para `foreground` e removem o
perfil `cpu_mid` inexistente no kernel/ vendor do S20+.

O `libcgrouprc.so` e o `libchrome.so` do sistema permanecem os binários do
S24+; a comparação ELF mostrou somente dependências padrão (`libbase`,
`libc++`, `libc`, `libm`, `libdl`) e os símbolos `LIBCGROUPRC`/`LIBCGROUPRC_30`,
todos disponíveis no runtime. O `vendor/lib64/libchrome.so` do doador foi
removido por não ser uma dependência do cgroup.

O `cgroupmem.rc` é mantido porque o kernel 4.19 desta build expõe
`CONFIG_MEMCG=y`, `CONFIG_MEMCG_SWAP=y` e `memory_recursiveprot`; no aparelho,
`memory` está disponível em `/sys/fs/cgroup`, `apps` e `system`. A verificação
foi corrigida: o freezer v2 já está implementado no kernel e os grupos-filhos
expõem `cgroup.freeze`; ele não aparece em `cgroup.controllers` porque não é
um controlador separado. A única interface v2 ausente era `cgroup.kill`.

## Backport de cgroup.kill (2026-09-21)

Foi adicionado `platform/exynos990/patches/extremekrnl/patches/0002-cgroup2-add-cgroup-kill-interface.patch`.
O backport implementa a interface `cgroup.kill` no core cgroup2 do kernel 4.19:
aceita somente `1`, mata processos de usuário do grupo e de todos os
descendentes, ignora threads do kernel, rejeita cgroups threaded e fecha a
condição de corrida de fork marcando o grupo durante a iteração e terminando
filhos criados nesse intervalo. O freezer v2 existente não foi duplicado nem
alterado.

O `task_profiles.json` compatível `e2sxxx` agora também declara o atributo
`CgroupKill` (`cgroup2/cgroup.kill`), de modo que o userspace S24+ possa usar a
interface quando o kernel atualizado estiver instalado. O aplicador de patches
do ExtremeKRNL passou a percorrer todos os patches em ordem, mantendo
idempotência para builds incrementais. A compilação do objeto
`kernel/cgroup/cgroup.o`, a aplicação/reversão do patch, a sintaxe do script e
o JSON foram validados localmente.

O módulo foi atualizado para a versão 2.2/`versionCode=4`. Ainda é necessária
uma nova build/flash para verificar no aparelho `/sys/fs/cgroup/apps/cgroup.kill`
e testar a escrita controlada `echo 1 > .../cgroup.kill`; a função é uma
capacidade de gerenciamento de processos e não, por si só, uma correção
garantida para o crash do Chrome.

## Verificação no aparelho e créditos dos patches (2026-09-21)

Foi feita uma leitura somente no aparelho conectado `RX8NB005S3Z`, sem escrever
em nenhum cgroup. O kernel atualmente instalado confirma:

```text
/sys/fs/cgroup:        cgroup.freeze=no  cgroup.kill=no
/sys/fs/cgroup/apps:   cgroup.freeze=yes cgroup.kill=no
/sys/fs/cgroup/system: cgroup.freeze=yes cgroup.kill=no
features: nsdelegate, memory_recursiveprot
controllers: memory
```

Isso confirma que o freezer v2 já está ativo nos grupos-filhos e que o
`cgroup.kill` ainda não aparece porque a imagem com o patch 0002 ainda não foi
buildada/flashada. Depois do flash, a mesma leitura deve mostrar
`cgroup.kill=yes` em `apps` e `system`.

Também foram corrigidos 11 cabeçalhos de patches que usavam identidades
genéricas (`UN1CA maintainers`, `UN1CA y2slte`, `Codex`, `localhost` ou domínio
de exemplo). Eles agora usam o crédito solicitado:
`From: At30c <PabloAtsoc9993@outlook.com>`. Autores reais de terceiros não
foram alterados.

## Variante A/B para os APEX de runtime (2026-09-21)

Foi adicionada uma variante selecionável para testar a hipótese de que a
mescla ARM32 do runtime está relacionada ao crash de navegadores Chromium.
`EXYNOS990_RUNTIME32_APEX_MODE="source_apex"` agora é o padrão da plataforma:
preserva os APEX originais do S24+. O modo anterior continua disponível com
`EXYNOS990_RUNTIME32_APEX_MODE="merged"`; ele importa o payload ARM32 do r11s
para `com.android.runtime`/`com.android.i18n`, além dos binários de linker e
das bibliotecas soltas de compatibilidade.

Essa opção não troca nem remove `com.android.vndk.v30`: o VNDK 30 continua
sendo necessário para a interface do vendor do S20+. O teste altera somente
o caminho dos APEX de Runtime/I18n/ART e seus complementos ARM32.

O modo `source_apex` já está aplicado diretamente em
`platform/exynos990/config.sh`, portanto basta carregar o ambiente e iniciar a
build. Ele preserva integralmente os APEX originais do S24+
(`com.android.runtime`, `com.android.i18n` e ART) e não instala o linker,
nem mescla esses arquivos dentro dos APEX. Para que os serviços ARM32 do
vendor ainda possam iniciar, ela instala o linker e os quatro Bionic básicos
do donor como arquivos standalone em `/system/bin` e `/system/lib`; a única
exceção adicional é o `system/lib/libstagefright.so`, mantido porque o módulo
WFD aplica um patch direto nele. As dependências ARM32 não-Bionic são
resolvidas recursivamente. As propriedades de compatibilidade restantes
continuam sendo aplicadas. A variante é
intencionalmente diagnóstica: serviços legados 32-bit (por exemplo OMX) podem
deixar de iniciar, mas o resultado separa a causa APEX da causa Chromium/GPU.

Exemplo:

```bash
source buildenv.sh y2s
aether
```

Para testar novamente o comportamento anterior sem editar arquivos, use
`EXYNOS990_RUNTIME32_APEX_MODE=merged aether` depois de carregar o ambiente.

A sintaxe dos scripts foi validada com `bash -n`; a geração atual continua
produzindo `EXYNOS990_RUNTIME32_APEX_MODE="source_apex"` por padrão. Nenhuma
build ou instalação dessa variante foi executada ainda.

Durante o primeiro teste da variante, o módulo WFD falhou porque o
`libstagefright.so` isolado ainda dependia de `libcrypto.so`. O resolvedor do
WFD agora percorre automaticamente o `DT_NEEDED` não-Bionic do stagefright;
essa árvore contém 185 bibliotecas do r11s e não apresentou dependências
ausentes. O fechamento foi verificado com `readelf` sem instalar ou modificar
o aparelho.

O teste seguinte revelou uma dependência cruzada nos binários WFD do r9s:
`libhdcp2.so` precisava de `libion.so`, disponível apenas no prebuilt r11s.
O resolvedor agora pesquisa os dois doadores (r9s primeiro para os binários WFD
e r11s como fallback), incluindo o fechamento completo de todos os roots WFD.
O novo levantamento totalizou 214 bibliotecas resolvidas, sem ausências.

Na execução seguinte, a validação ainda encontrou `libstagefright.so` →
`lib_soundaliveresampler.so`. O resolvedor agora também é chamado no limite da
validação: se qualquer `DT_NEEDED` estiver faltando no `work_dir`, ele busca a
biblioteca nos dois doadores, instala o fechamento e só então valida o ELF.
Dependências previamente marcadas durante ciclos não podem mais mascarar um
arquivo que não foi instalado.

O primeiro flash do modo `source_apex` mostrou que o vendor ARM32 não iniciava
porque `/system/bin/linker` não existia. O diagnóstico no aparelho registrou
`init: cannot execv(...)` para os serviços DRM, áudio, GeoTrans e OMX. A
variante agora extrai o linker/Bionic ARM32 do Runtime donor sem modificar o
APEX do S24+, eliminando essa causa de bootloop.

Na confirmação seguinte no aparelho `RX8NB005S3Z`, `/system/bin/linker`,
`linker_asan`, `libc.so`, `libdl.so` e `libm.so` estavam ausentes; `bootanim`
continuava `running`, `sys.boot_completed` não era publicado e o uptime voltou
a reiniciar. Isso confirma que o bootloop observado era a ausência do runtime
ARM32 standalone, não uma morte do zygote 64-bit.

Após a instalação do runtime standalone, o erro seguinte ficou explícito:
`libprocessgroup.so` do VNDK 30 não encontrava `libcgrouprc.so` no namespace
32-bit. O módulo `cgroup_legacy` agora instala o `libcgrouprc.so` ARM32 e os
`libbase.so`/`libc++.so` correspondentes do mesmo donor r11s em `system/lib`;
as bibliotecas Bionic continuam vindo do runtime standalone.

## Captura confirmada do crash do Chrome e mitigação AppZygote (2026-09-21)

Na captura `logcat_android_20260921_160613.log`, o Chrome foi aberto sem
flags. O processo nativo do sandbox (`zygote-child`, PID 19316) abortou
primeiro:

```text
16:10:12.612  libprocessgroup: SystemMemoryProcess ... controller memory ... will be ignored
16:10:12.617  libc: Fatal signal 6 (SIGABRT) ... pid 19316 (zygote-child)
16:10:12.634  crash_dump64: failed to open /proc/19316: No such file or directory
```

O `crash_dump64` falhou nesse filho porque ele já havia desaparecido quando o
helper tentou abrir `/proc`. O processo principal do Chrome permaneceu vivo e
abortou depois, desta vez com captura completa. Foi criado no aparelho
`/data/tombstones/tombstone_15` às 16:10:48:

```text
Executable: /system/bin/app_process64
Cmdline: com.android.chrome
pid: 19270, ppid: 7021
signal 5 (SIGTRAP), code 1 (TRAP_BRKPT)
Abort message: '[FATAL:content/browser/gpu/browser_gpu_channel_host_factory.cc:49] Timed out waiting for GPU channel.'
```

O tombstone confirma que o timeout de GPU é consequência da morte do filho
native/AppZygote: o canal GPU nunca fica disponível. Ele não aponta para um
defeito independente no `crash_dump64` ou no driver GPU. Depois do timeout, o
framework entrou novamente em loop de `Connection refused`; às 16:12:00 o
`system_server` morreu e o zygote foi encerrado pelo init, produzindo o
soft-reboot observado.

Foi adicionada a variante experimental `unica/mods/appzygote_compat`. Ela
define `ro.unica.disable_app_zygote=true` e aplica
`services.jar/0001-Route-native-sandbox-away-from-AppZygote.patch`. O patch é
propriedade-gated e, quando ativo, força somente a ramificação de serviços
native que usaria `AppZygote` a seguir pelo zygote regular. O zygote comum e o
WebView zygote não são alterados. Isso é uma mitigação A/B reversível para
testar a causa primária; não é um patch no `libchrome.so` nem uma desativação
global da GPU.

Validações realizadas:

1. `bash -n unica/mods/appzygote_compat/customize.sh`.
2. `git diff --check`.
3. `git apply --check` do patch contra o `ProcessList.smali` Android 17
   atualmente decodificado.
4. Aplicação do patch em uma cópia temporária, confirmando `.locals 39`, uso
   de `invoke-static/range` válido e o desvio antes de
   `createAppZygoteForProcessIfNeeded()`.

O próximo teste deve gerar/instalar uma build com esse módulo, abrir o Chrome
sem flags e verificar se deixam de aparecer `zygote-child`/`crash_dump64` e o
timeout `browser_gpu_channel_host_factory.cc:49`. Se a ROM não iniciar ou
outros serviços nativos falharem, remova o módulo `appzygote_compat` e repita
o A/B; isso indicará que o fallback precisa ser limitado por pacote em vez de
ser aplicado a todos os serviços native.

O teste seguinte mostrou que misturar o `libc++.so` Android 33 do S20+ com o
`liblog.so`/`libbase.so` Android 37 do r11s causava o símbolo ausente
`_ZNSt3__122__libcpp_verbose_abortEPKcz`. O conjunto foi unificado no r11s
para manter o ABI C++ consistente.

A varredura recursiva dos 649 ELF32 presentes no `work_dir` também encontrou
clientes vendor que precisavam de `android.frameworks.sensorservice@1.0.so`,
`android.hardware.sensors@1.0.so`, `libGLESv3.so`, `libminijail.so` e
`libcap.so`. A variante `source_apex` agora instala os três primeiros do
firmware alvo e os dois últimos do donor r11s antes da validação WFD.

## Correção do patch AppZygote para o Apktool 3.0.3-16 (2026-09-21)

A primeira tentativa do `appzygote_compat` usava `v36`/`v37` e escrevia em
`v18`. Embora esses registradores fossem válidos pelo total de `.locals`, o
assembler desta versão do Apktool rejeita instruções não-range acima de `v15`.
Isso causou o erro `maximum allowed register ... v15` durante a build de
`services.jar`.

O patch foi corrigido para usar somente `v14`/`v15` na leitura da propriedade.
Quando `ro.unica.disable_app_zygote=true`, ele salta diretamente para
`:cond_1f`, o caminho do zygote normal, sem sobrescrever `v18`; com a
propriedade falsa, a decisão original de AppZygote permanece intacta.

Validação concluída:

1. `git apply --check` passou no `ProcessList.smali` decodificado.
2. `git diff --check` passou.
3. `java -Xmx2097m -jar out/tools/bin/apktool.jar b -j 1 .../services.jar`
   concluiu com exit code 0 e gerou `dist/services.jar`.

Ainda não houve flash nem validação no aparelho; a correção resolve o erro de
smali da build, mas sua eficácia contra o crash do Chrome só pode ser medida
após instalar uma ROM nova.

## Backport `cgroup.kill` registrado no repositório do kernel (2026-09-21)

O backport foi confirmado no kernel instalado e registrado no repositório
`At30c/SSM_990v2BYEXTREME`:

```text
Commit: f645ea00fb89 cgroup: add cgroup.kill to legacy cgroup2
Branch: main
Remote: origin/main
```

O commit contém somente:

```text
include/linux/cgroup-defs.h
kernel/cgroup/cgroup.c
```

O `cgroup.kill` foi deliberadamente marcado com `CFTYPE_NOT_ON_ROOT`, portanto
o arquivo não aparece em `/sys/fs/cgroup/cgroup.kill`; ele aparece nos cgroups
descendentes, por exemplo `/sys/fs/cgroup/apps/cgroup.kill`.

Validação no aparelho após o flash:

1. `/sys/fs/cgroup/apps/cgroup.kill` existe.
2. `/sys/fs/cgroup/apps/cgroup.freeze` continua disponível.
3. Um processo `sleep` foi movido para um cgroup temporário e terminou após
   `printf 1 > cgroup.kill`.
4. O cgroup temporário foi removido sem deixar resíduos.

Os diretórios de build não foram incluídos no commit; apenas os dois arquivos
do backport foram enviados ao repositório do kernel.

## Teste da nova build: framework estabiliza, mas o native Chromium child continua falhando (2026-09-21 17:15–17:22)

Na nova build instalada, o kernel confirmou novamente:

```text
4.19.325-cip119-st3-ExtremeKRNL-Nexus-v1+ #2
/sys/fs/cgroup/apps/cgroup.kill: presente
/sys/fs/cgroup/apps/cgroup.freeze: presente
```

O teste funcional de `cgroup.kill` continuou passando: um `sleep` temporário
foi movido para um cgroup descartável e morreu após `printf 1 > cgroup.kill`.

Chrome e Edge foram iniciados explicitamente com `am start`. Ambos mantiveram
o processo principal e criaram a Activity, mas o processo nativo
`NativeOnlySandboxedProcessService` falhou no mesmo ponto:

```text
zygote_next: zygote: Native Zygote: Exiting server
libc: Fatal signal 6 (SIGABRT) ... (zygote-child)
crash_dump64: failed to open /proc/<pid>: No such file or directory
ActivityManager: Process ... NativeOnlySandboxedProcessService0 failed to attach
```

O padrão se repetiu para o Chrome e para o Edge, confirmando que é uma falha
comum do caminho Chromium nativo, não de um APK específico. Não apareceu
`Timed out waiting for GPU channel` nesta execução, e `system_server`, zygote64
e zygote_next permaneceram vivos por mais de dez minutos; o patch do framework
evitou a escalada anterior para SIGTRAP/soft-reboot, mas não corrigiu o child.

Um A/B com SELinux permissivo não eliminou o `SIGABRT`; o teste foi restaurado
para `Enforcing`. Os pais `zygote64` e `zygote_next` continuam com
`CapEff=CapBnd=0x3fffffffff`, `NoNewPrivs=0` e `Seccomp=0`. Assim, o próximo
alvo é a transição do child nativo para seccomp/capabilities em
`zygote_next`; `cgroup.kill`, o aviso `SystemMemoryProcess` e a GPU ficam como
efeitos secundários nesta fase.

## Chrome abre após limpar dados, mas páginas não carregam (2026-09-21 17:25)

Foi aberta uma URL real (`https://example.com`) após limpar os dados do Chrome.
A conectividade do aparelho estava normal: Wi-Fi conectado, validado e com
rota/DNS disponíveis. A `ChromeTabbedActivity` permaneceu em primeiro plano,
mas o conteúdo não carregou.

O log mostrou o motivo: ao tentar criar os renderers, o Chrome entrou em loop
de `NativeOnlySandboxedProcessService0`. Cada tentativa gerou um novo UID
isolado, iniciou o `zygote_next` e morreu imediatamente:

```text
ActivityManager: Start proc ... NativeOnlySandboxedProcessService0
zygote_next: Native Zygote: Exiting server
libc: Fatal signal 6 (SIGABRT) ... (zygote-child)
crash_dump64: failed to open /proc/<pid>
ActivityManager: Process ... failed to attach
```

Não houve erro de DNS/rede nem timeout de GPU nessa tentativa. Portanto,
limpar os dados apenas permite que a Activity inicial seja criada; páginas
dependem do renderer nativo, que continua incompatível com a cadeia
`zygote_next`/seccomp/capabilities.

## Correção da segunda seleção de `zygote_next` no `framework.jar` (2026-09-21)

A investigação mostrou que o fallback anterior no `services.jar` não era
suficiente. Ele evita a criação do `AppZygote`, mas `Process.start()` faz uma
segunda decisão independente no `framework.jar`: quando
`Flags.nativeFrameworkPrototype()` é verdadeiro e o bit `0x8` está presente
em `runtimeFlags`, ele seleciona diretamente `NATIVE_ZYGOTE_PROCESS`. Na base
Android 17 atual, `RELEASE_NATIVE_FRAMEWORK_PROTOTYPE` está habilitado; por
isso os processos `NativeOnlySandboxedProcessService` ainda entravam em
`zygote_next` depois de contornar o AppZygote.

O módulo `unica/mods/appzygote_compat` foi atualizado para a versão 1.1. Ele
agora aplica também
`framework.jar/0001-Disable-native-zygote-on-legacy-vendor.patch` e define:

```properties
ro.unica.disable_app_zygote=true
ro.unica.disable_native_zygote=true
```

Com a segunda propriedade ativa, `Process.start()` salta para o
`ZYGOTE_PROCESS` Java regular antes de considerar o bit de processo nativo.
Quando a propriedade está ausente ou falsa, o fluxo original permanece
inalterado. O patch usa apenas `v1`/`v2`, que são sobrescritos pelo código
original depois da escolha do zygote, evitando o limite de registradores que
já causou falha no Apktool.

Validações realizadas:

1. `git apply --check` passou contra o `Process.smali` atualmente decodificado.
2. O patch foi aplicado a uma cópia limpa do `framework.jar` decodificado.
3. O Apktool `3.0.3-16-17254568-SNAPSHOT` recompilou todas as sete classes DEX
   e gerou `dist/framework.jar` com exit code 0.
4. `unzip -t` não encontrou erros no JAR remontado.
5. `bash -n` e `git diff --check` passaram nos arquivos do módulo.

O `services.jar` presente no `out` já continha o primeiro patch, o que também
confirma que ele entrou na build anterior. A nova correção do `framework.jar`
ainda não está no aparelho: é necessária uma nova build/instalação antes do
teste funcional. Depois do flash, a evidência esperada é a ausência de
`zygote_next: Native Zygote: Exiting server` ao abrir Chrome/Edge, seguida da
criação estável dos renderers e carregamento de páginas. Se o filho ainda
abortar, o log do novo caminho regular deve permitir separar a falha de
especialização de uma falha interna do Chromium.

## Módulo KernelSU para o teste AppZygote/zygote_next (2026-09-21)

Foi gerado o módulo de teste específico para a build instalada:

```text
out/target/y2s/appzygote-compat-ksu-v1.1.zip
SHA-256: b997c08c06a54730ef4a5315b51a1191ab4ba0dae5a7557a2ed345bbd702cceb
```

Antes de montar o módulo, os JARs locais e os do aparelho foram comparados. Os
dois pares eram idênticos:

```text
framework.jar  8361ab40e2f9f4d98a595753054d311cc4bd019c243b111f6a970407af1185c6
services.jar   373e210fc5d861d51c4ada3ddf8218034bea8dc4dbebc1716829bebc0ccc7e7b
```

O ZIP contém o `framework.jar` remontado com o novo patch, o `services.jar`
já presente na build e as duas propriedades de fallback. O instalador recusa
qualquer fingerprint ou hash diferente para impedir que um framework de outra
build seja montado. O arquivo passou em `unzip -t`, os scripts passaram em
`bash -n`, e a instalação pelo `ksud 3.3.0` confirmou os hashes-base.

O primeiro reboot foi concluído normalmente, mas não constituiu teste do
patch: `/system/framework/framework.jar` manteve o hash original e
`ro.unica.disable_native_zygote` não foi criada. A inspeção mostrou o módulo
em `modules_update`, com `update=true`, e nenhum link
`/data/adb/metamodule`. Essa versão do KernelSU Next delega a montagem de
arquivos de `/system` a um metamódulo; sem `meta-overlayfs`, Magic Mount ou
equivalente, o diretório `system/` de módulos regulares não é sobreposto. O
mesmo estado pendente também foi observado no ReZygisk já instalado.

O módulo v1.1 ficou preparado no aparelho, mas ainda não está ativo. Instalar
um metamódulo é uma mudança global: além deste teste, ativará outros módulos
pendentes, incluindo ReZygisk. Portanto isso não foi feito automaticamente.
Após escolher e instalar um backend de montagem compatível, reinicie e só
considere o patch ativo se:

```text
sha256sum /system/framework/framework.jar
0335d0adbb5e089d08eb0e695ec7dd34043fa99ecd094c497cd259ebf7d38538

getprop ro.unica.disable_native_zygote
true
```

## Resultado do A/B com o Zygote Java regular (2026-09-21 18:25)

O Meta-Overlayfsx 1.3.4 foi instalado. Como a integração do KernelSU deste
kernel não disparou `post-fs-data` automaticamente, o evento foi acionado uma
vez pelo `ksud`. O metamódulo montou a imagem ext4 e sobrepôs os dois JARs sem
conflitos. Antes do teste foram confirmados:

```text
/system/framework/framework.jar = 0335d0ad...d38538 (patch ativo)
ro.unica.disable_app_zygote=true
ro.unica.disable_native_zygote=true
Overlayfsx: Modules Mounted: 1, File Conflicts: False
```

Após um soft reboot, o Chrome foi aberto com `https://example.com`. O desvio
funcionou exatamente como implementado: os filhos apareceram com PPID do
`zygote64` Java regular, não houve a sequência anterior de `SIGABRT`,
`capset failed` ou falha do `crash_dump64`, e não houve tentativa funcional
de iniciar o renderer através de `zygote_next`.

Entretanto, o teste também provou que esse fallback não pode ser usado como
solução. `NativeOnlySandboxedProcessService0` não possui uma classe Java
carregável no APK base. Ao ser iniciado pelo Zygote Java, cada renderer morreu
com:

```text
java.lang.RuntimeException: Unable to create service
org.chromium.content.app.NativeOnlySandboxedProcessService0
Caused by: java.lang.ClassNotFoundException: Didn't find class
"org.chromium.content.app.NativeOnlySandboxedProcessService0"
```

Foram observadas 148 ocorrências desse `ClassNotFoundException` no teste. Isso
confirma duas coisas: o patch realmente retirou os filhos do `zygote_next`,
mas o Chromium atual depende obrigatoriamente do caminho Native Zygote para
esses serviços. A correção definitiva deve manter `NATIVE_ZYGOTE_PROCESS` e
corrigir sua especialização; redirecioná-lo para `ZYGOTE_PROCESS` apenas troca
o abort nativo por uma falha determinística de carregamento Java.

O módulo KernelSU `appzygote_compat_ksu` foi desabilitado e o aparelho foi
reiniciado. O framework voltou ao hash original
`8361ab40...1185c6`, a propriedade experimental deixou de existir e o boot
foi concluído. Também foi adicionado `unica/mods/appzygote_compat/disable`
para impedir que essa variante comprovadamente inválida entre em builds
futuras. A captura completa está em
`out/target/y2s/ksu-appzygote-test-20260921-1825/`.

## Diagnóstico TRACE do Native Zygote (2026-09-21)

Depois de confirmar que `NativeOnlySandboxedProcessService` não pode ser
redirecionado ao Zygote Java, foi preparada uma variante que mantém o caminho
nativo original e apenas aumenta a observabilidade. O novo módulo de
plataforma está em:

```text
platform/exynos990/patches/zzzzz_zygote_next_trace/
```

Ele substitui somente `system/etc/init/zygote_next.rc`. Socket, usuário,
grupo, prioridade, gatilho de inicialização e comportamento de restart foram
preservados. A linha do serviço passou a usar:

```text
--log-level TRACE --trace-level TRACE
```

Também foi acrescentado `stdio_to_kmsg`. A ROM é `ro.debuggable=1` e já usa
essa diretiva em outros serviços; assim, um panic Rust emitido em stderr pode
ser preservado no buffer do kernel mesmo quando o filho morre antes de o
`crash_dump64` anexar. O próprio binário `zygote_next --help` no aparelho
confirmou suporte aos dois argumentos de nível de log.

O código Android 17 confirma que, depois do último ponto atualmente visível
(`cgroup::create`), o filho executa `set_cpuset_policy`, `set_sched_policy`,
securebits/capabilities, seccomp, `setresuid` e a transição SELinux. O TRACE
deve identificar em qual dessas fronteiras ocorre o panic, evitando outro
patch comportamental por tentativa.

O ReZygisk foi deixado `enabled=false` e seu marcador de remoção foi revertido;
o módulo permanece instalado, mas não será executado no próximo boot. O módulo
KernelSU `appzygote_compat_ksu` também continua desabilitado. O Meta-Overlayfsx
permanece ativo apenas como backend de montagem.

Validações realizadas:

1. `zygote_next --help` confirmou `--log-level` e `--trace-level`.
2. `stdio_to_kmsg` já é aceito pelos arquivos init da mesma imagem.
3. A comparação com o RC original mostrou apenas comentários, níveis TRACE e
   redirecionamento de stderr como diferenças.
4. `git diff --check` passou.

O patch ainda requer nova build/flash. No teste seguinte, capture `logcat -b
all`, `dmesg` e eventos `zygote_next` desde antes de abrir o Chrome.

## Módulo KernelSU de TRACE do Native Zygote (2026-09-21 18:55)

Para testar a mesma instrumentação sem gerar outra ROM, foi criado e instalado
o módulo KernelSU `zygote_next_trace_ksu` 1.1. O ZIP final está em:

```text
out/target/y2s/zygote-next-trace-ksu-v1.1.zip
sha256 4319a9bb9a2ba06dee74983c42cebc0a6db75fdd8494044fe49d29d1228ea9ba
```

O módulo foi limitado ao binário `zygote_next` desta build. O instalador exige
o SHA-256 original
`b16225e7f4c41c5ebda007c2605ef831228bdbe8fff6a1392fae77e9dea47064`.
Ele monta um wrapper ELF AArch64 estático, sem libc e sem abrir descritores,
que preserva todos os argumentos do `init`, troca `INFO` por `TRACE`, acrescenta
`--trace-level TRACE` e executa a cópia intacta em
`/system/bin/zygote_next.real`. O código-fonte do wrapper e os arquivos de
empacotamento permanecem em:

```text
out/target/y2s/zygote-next-trace-ksu-src/
```

O Meta-Overlayfsx inicialmente atribuiu `system_file` aos dois executáveis. A
versão 1.1 corrige isso no `post-fs-data.sh`: o wrapper recebe novamente
`zygote_next_exec`, preservando a transição stock `init` -> `zygote_next`, e a
cópia real permanece `system_file`. A regra SELinux do módulo permite somente
o segundo `exec` sem transição e o relabel necessário pelo domínio privado do
KernelSU.

Nesta integração do KernelSU, `post-fs-data` ainda não é disparado
automaticamente. Depois do reboot o Android iniciou normalmente com o binário
stock; foi necessário executar uma vez:

```text
su -c /data/adb/ksu/bin/ksud post-fs-data
```

Após isso, o overlay apresentou os hashes esperados, o serviço foi reiniciado
isoladamente com `setprop ctl.restart zygote_next` e voltou saudável. A
validação ao vivo confirmou:

```text
contexto: u:r:zygote_next:s0
PID: 20818
zygote.zygote_next.server_ready=true
socket /dev/socket/zygote_next em LISTEN
NoNewPrivs=0
Seccomp=0
argv: /system/bin/zygote_next --name zygote_next --species android-native-app
      --log-level TRACE --arg-buf-padding ... --trace-level TRACE
```

Não houve falha de argumento, negação SELinux ou restart em loop. O módulo está
instalado e habilitado; `appzygote_compat_ksu` e ReZygisk continuam
desabilitados. O próximo passo é reproduzir a abertura do Chrome/Edge com
`logcat -b all` e `dmesg` já capturando, agora que o Native Zygote realmente
está emitindo TRACE.

## Causa explícita do SIGABRT do Native Zygote (2026-09-21 19:03)

Com o módulo TRACE ativo, o Chrome aberto reproduziu 18 aborts consecutivos de
`NativeOnlySandboxedProcessService`; uma segunda abertura controlada reproduziu
o mesmo padrão. Os artefatos completos estão em:

```text
out/target/y2s/native-zygote-trace-20260921-185847/
```

Além de `logcat -b all` e `dmesg`, foi feita uma captura ftrace dos eventos
`raw_syscalls`, `sched_process_*` e `signal_*`, filtrada pelo PID 20818 do
`zygote_next` e herdada pelos filhos. O tracing foi desligado e os filtros
foram removidos após quatro segundos. O Chrome foi encerrado sem limpar seus
dados para evitar que a repetição bloqueasse `system_server`; o aparelho
permaneceu com `sys.boot_completed=1`, `system_server` PID 7602 e
`zygote_next` PID 20818.

O ftrace identificou o primeiro erro fatal de forma determinística. Em nove
filhos conferidos, a especialização executou esta sequência:

```text
prctl(PR_CAPBSET_READ, 0..37) = 1
prctl(PR_CAPBSET_DROP, 0..37) = 0
prctl(PR_CAPBSET_READ, 38)    = -EINVAL
write(2, ..., 145)            = 145
rt_tgsigqueueinfo(..., SIGABRT, ...) = 0
```

Portanto, o abort não nasce no cgroup, na GPU, no `crash_dump64`, no seccomp
nem em uma negação SELinux. O cgroup termina antes do erro; o primeiro retorno
incompatível é a consulta da capability 38. O código Android 17 em
`system/zygote/zygote/src/child_process.rs` percorre o complemento de
`cap_bound` e usa `cap_within_bound(...).expect("Failed to check capability
bound")`; o `EINVAL` do kernel vira panic e `SIGABRT`.

O header do ExtremeKRNL confirma a incompatibilidade:

```text
include/uapi/linux/capability.h:
CAP_AUDIT_READ = 37
CAP_LAST_CAP   = CAP_AUDIT_READ
```

O userspace do Android 17 foi compilado com as capabilities modernas:

```text
CAP_PERFMON            = 38
CAP_BPF                = 39
CAP_CHECKPOINT_RESTORE = 40
CAP_LAST_CAP            = CAP_CHECKPOINT_RESTORE
```

O código AOSP usado para a comparação foi o branch oficial
`android17-release`, commit
`c24023080df0bdb5988c1e0c641d494574a97c40`. A árvore local também confirma
que o `init` moderno exige por `static_assert` que `CAP_LAST_CAP` seja
`CAP_CHECKPOINT_RESTORE`.

O spam do `crash_dump64` é consequência: o filho já iniciou o handler do
`SIGABRT` e desaparece antes de o helper abrir `/proc/<pid>`. O próximo patch
deve backportar ao kernel 4.19 a ABI das capabilities 38–40, incluindo os nomes
correspondentes em `COMMON_CAP2_PERMS` do SELinux. Apenas silenciar o panic ou
o helper esconderia a incompatibilidade sem corrigi-la.

## Backport da ABI de capabilities exigida pelo Android 17 (2026-09-21 21:31)

Foi criado o patch do ExtremeKRNL:

```text
platform/exynos990/patches/extremekrnl/patches/0003-capabilities-add-android17-bounding-set-abi.patch
```

O autor registrado no patch é `At30c <PabloAtsoc9993@outlook.com>`. O patch
adiciona ao kernel 4.19 os números de ABI de `CAP_PERFMON` (38), `CAP_BPF` (39)
e `CAP_CHECKPOINT_RESTORE` (40), eleva `CAP_LAST_CAP` para 40 e acrescenta os
três nomes em `COMMON_CAP2_PERMS` do SELinux. A numeração e os nomes seguem o
Linux upstream v5.9. Isto faz `PR_CAPBSET_READ` e `PR_CAPBSET_DROP` reconhecerem
os bits consultados pelo Native Zygote do Android 17; não afirma implementar as
funcionalidades modernas de perf, BPF ou checkpoint/restore associadas a essas
capabilities.

O `customize.sh` do ExtremeKRNL aplica automaticamente todos os arquivos
`patches/*.patch`, portanto o novo patch já entra no fluxo normal e também na
chave do cache do kernel. As validações realizadas foram:

```text
git apply --check: aprovado antes da aplicação
git apply --reverse --check: aprovado depois da aplicação
kernel/capability.o: compilado
security/commoncap.o: compilado
security/selinux/avc.o: compilado
kernel/sysctl.o: compilado
Image completo: compilado e linkado com sucesso
```

O gerador do SELinux produziu também os novos bits esperados:

```text
CAPABILITY2__PERFMON            0x00000040U
CAPABILITY2__BPF                0x00000080U
CAPABILITY2__CHECKPOINT_RESTORE 0x00000100U
```

O artefato usado para a validação local foi:

```text
out/kernel_tmp-exynos990/out/arch/arm64/boot/Image
tamanho: 43241488 bytes
sha256: c7d11a613258a3568b2e2c534ce2db3c0974d7f9d6f15232be19d2cdb6791b84
```

Esta etapa comprova aplicação, compilação e integração do patch, mas ainda não
comprova o comportamento em execução. É necessário gerar/instalar uma build
que contenha esse kernel e repetir a abertura do Chrome/Edge. O resultado
esperado no ftrace é que as consultas 38, 39 e 40 deixem de retornar `-EINVAL`;
o kernel deve publicar `CAP_LAST_CAP=40`, permitindo que o laço do zygote
termine normalmente sem `SIGABRT`. O número 41 é apenas o primeiro índice fora
da ABI e não precisa ser consultado pelo zygote.

### Validação no aparelho (2026-09-21)

A build contendo o backport foi instalada e o Chrome voltou a funcionar. Isso
confirma em execução que a causa do abort do `zygote-child` era a ABI incompleta
de capabilities do kernel 4.19: o Android 17 consultava `CAP_PERFMON` (38), mas
o kernel anterior encerrava em `CAP_AUDIT_READ` (37) e devolvia `-EINVAL`.
O patch `0003-capabilities-add-android17-bounding-set-abi.patch` deve permanecer na
configuração de produção. Os módulos `appzygote_compat` e
`zzzzz_zygote_next_trace` continuam sendo apenas tentativas/instrumentação de
diagnóstico e podem ser retirados depois de uma última validação sem TRACE.

## Captura para diagnóstico de vídeo Telegram/Discord (2026-09-21 22:54)

O aparelho estava desconectado e a sessão anterior do tmux não estava ativa.
O script persistente foi restaurado em:

```text
scripts/capture_logcat_tmux.sh
```

A sessão destacada foi iniciada novamente:

```text
tmux attach -t y2s-logcat
tmux capture-pane -pt y2s-logcat:0 -S -40
```

Ela permanece aguardando o ADB e cria um diretório
`out/target/y2s/boot-diagnostics-<data>` quando o aparelho voltar a aparecer.
Cada conexão recebe um marcador `DEVICE_CONNECTED_<data>` e todos os buffers
do logcat são capturados até a desconexão. O script passou em `bash -n` e não
limpa o buffer anterior, para preservar o primeiro erro ao reproduzir a falha
de reprodução de vídeo nos aplicativos Telegram e Discord.

Em 2026-09-21 23:00 o script foi corrigido para usar `tee`: o mesmo fluxo agora
aparece ao vivo no painel do tmux e continua sendo salvo em `logcat.txt`. A
sessão foi reiniciada e confirmou a exibição de eventos atuais do aparelho.

### Diagnóstico do vídeo Telegram/Discord: geração de buffers (2026-09-21)

O log persistente confirmou que o decoder Exynos inicia normalmente e que a
alocação Mali também é concluída. A falha só aparece quando o `ACodec` troca a
Surface: `BufferQueueProducer` rejeita o buffer reutilizado com `-22` porque a
geração do buffer antigo não coincide com a geração nova da fila:

```text
[OMX.Exynos.avc.dec] setting surface generation to 11550745
BufferQueueProducer: attachBuffer: generation number mismatch [buffer 0] [queue 11550745]
ACodec: failed to attach buffer ... Invalid argument (22)
MediaCodec.native_setSurface
ExoPlayerImplInternal: Playback error
```

A análise do `libgui.so` do S926B encontrou a causa no
`android::Surface::attachBuffer`: o binário importado só copia
`mGenerationNumber` para o `GraphicBuffer` quando `mSharedBufferMode` está
ativo. O vídeo usa buffers comuns, portanto o buffer chega à checagem de
`BufferQueueProducer::attachBuffer` com a geração antiga. A checagem da fila
não foi removida; ela deve continuar protegendo buffers de outra geração.

Foi preparado o módulo `unica/mods/zzzz_surface_generation_compat`, que altera
somente duas sequências ARM64 do `libgui.so` do S926B: torna incondicional a
cópia em `Surface::attachBuffer()` e mantém a geração local atualizada em
`Surface::setGenerationNumber()`. As sequências originais e substitutas foram
validadas por desmontagem; em ambos os casos apenas o salto condicional vira
`nop`, sem remover a checagem de geração do `BufferQueueProducer`.

O primeiro A/B foi testado no aparelho por bind-mount temporário, com reinício do
zygote e reprodução controlada no Telegram via scrcpy. O `libgui.so` alterado
foi carregado, mas o log continuou mostrando `generation number mismatch`
seguido de `MediaCodec.native_setSurface`/`Playback error`; portanto o primeiro
bypass não é uma correção suficiente e não deve ser incorporado à build ainda.

Também foi testada uma segunda variante temporária, que tornava incondicional
a atualização em `Surface::setGenerationNumber` além da escrita em
`Surface::attachBuffer`. Mesmo com as duas alterações, o log de 23:41:42
continuou rejeitando o buffer pela geração da fila. Isso descarta a hipótese
de que apenas essas duas escritas condicionais sejam a causa. Uma terceira
variante, que neutralizava a checagem de geração dentro de
`BufferQueueProducer::attachBuffer`, foi usada inicialmente somente como
diagnóstico; o bind-mount foi removido com reboot completo e o hash de
`libgui.so` retornou ao original. Na captura de 2026-09-22, porém, o módulo de
duas escritas já estava efetivamente carregado e o mesmo erro continuou
ocorrendo. Isso confirmou que a rejeição acontece no produtor, depois de
`Surface::setOutputSurface`, e não apenas nas escritas locais de `Surface`.

Por solicitação, a variante do produtor foi incorporada ao módulo, com versão
1.1. Ela altera somente a sequência ARM64 de
`BufferQueueProducer::attachBuffer` que compara
`GraphicBuffer::mGenerationNumber` com a geração da fila:

```text
09c841b908e540b91f01096be1190054
 ->
09c841b908e540b91f01096b1f2003d5
```

A comparação permanece no binário para facilitar diagnóstico, mas o `b.ne`
que retornava `-EINVAL` (`generation number mismatch`) vira `nop`. As demais
validações de slot, fence, fila e conexão continuam intactas. Esta é uma
compatibilidade específica para o buffer de vídeo reutilizado que chega com
geração 0; ainda não é evidência de que o comportamento seja seguro para todos
os produtores.

Validações locais realizadas:

1. A sequência original aparece exatamente uma vez no `libgui.so` da build.
2. A substituição mantém o mesmo tamanho e o resultado continua sendo um ELF
   AArch64 válido.
3. `bash -n` e `git diff --check` passaram.

Ainda é necessário gerar/instalar uma build com o módulo 1.1 e repetir o vídeo
do Telegram/Discord. O sucesso esperado é o desaparecimento conjunto de
`generation number mismatch`, `attachBuffer ... (-22)` e
`MediaCodec.native_setSurface`; se surgir corrupção, soft-reboot ou erro de
fence, o patch deve ser revertido e a solução deve voltar para uma troca de
surface sem reutilização de `setOutputSurface`.

### Causa do retorno `-22` no caminho ACodec

O retorno não é um erro aleatório do driver. O fluxo AOSP é explícito:

1. `MediaCodec::connectToSurface()` escolhe uma geração nova, chama
   `surface->setGenerationNumber()` e desconecta/reconecta a surface para
   descartar buffers livres antigos.
2. O caminho legado `ACodec::handleSetSurface()` percorre os buffers de saída
   já registrados e chama `surface->attachBuffer()` para reanexá-los à nova
   surface.
3. `BufferQueueProducer::attachBuffer()` compara a geração do
   `GraphicBuffer` com a geração atual da fila e retorna `BAD_VALUE` (`-22`)
   quando elas diferem.

No log, a sequência observada é exatamente essa: o decoder define `15191042`,
mas o buffer reanexado ainda informa `0`. Portanto, a incompatibilidade está
na propagação da geração durante a migração de buffers entre surfaces no
`libgui`/`ACodec` importado, e não no codec AVC, no gralloc ou no cgroup. A
implementação de referência pode ser conferida em:

```text
frameworks/native/libs/gui/BufferQueueProducer.cpp::attachBuffer
frameworks/av/media/libstagefright/ACodec.cpp::handleSetSurface
```

O módulo 1.1 continua sendo uma hipótese de compatibilidade para confirmar o
diagnóstico. A correção definitiva deve sincronizar a geração do
`GraphicBuffer` no caminho `ACodec`/`Surface` antes do `attachBuffer`, mantendo
a validação do produtor, em vez de simplesmente ignorar a divergência.

O módulo consolidado contém agora as duas escritas condicionais e a
compatibilidade do produtor, mas ainda precisa ser validado em uma build/flash em que o `libgui.so` seja
carregado antes do zygote. Binds feitos depois do boot não são evidência
suficiente, porque `libgui.so` já fica mapeado no zygote.

O scrcpy foi usado para controlar o aparelho e confirmar a reprodução visual,
mas não altera a cadeia `MediaCodec`/`Surface`; o erro permanece nessa troca
de superfície, não na alocação inicial do Mali.

### Backport enviado ao repositório próprio do kernel

O repositório `SSM_990v2BYEXTREME` já continha os commits de
`memory_recursiveprot` e `cgroup.kill`. O único trecho faltante do diagnóstico
do zygote foi aplicado diretamente no kernel e enviado para `origin/main`:

```text
50782bcd1df5 capabilities: add Android 17 bounding-set ABI
```

Arquivos alterados no kernel:

```text
include/uapi/linux/capability.h
security/selinux/include/classmap.h
```

O patch `0003` continua no repositório da ROM como fallback para clones antigos
do kernel. Quando o build usar o kernel a partir de `50782bcd1df5`, o
`customize.sh` detectará que o patch já foi aplicado e não o duplicará. Os
diretórios gerados `build/out`, `out` e `toolchain/clang_14` não foram incluídos
no commit do kernel.

## Correções preparadas para publicação (2026-09-22)

Foram validadas e preparadas para envio as correções de compatibilidade que
estavam no working tree:

- `__desixtification`: seleção explícita entre os APEXes Runtime de origem e o
  payload ARM32 legado, com linker/Bionic standalone e dependências mínimas.
- `cgroup_legacy`: descritores cgroup/task profiles compatíveis com a base S24+,
  `CgroupKill`, `libcgrouprc`/dependências coerentes e remoção do
  `vendor/lib64/libchrome.so` doador.
- `zzzz_wfd_compat`: resolução recursiva das dependências ARM32 entre os
  doadores r9s/r11s e validação ELF sem correções manuais biblioteca por
  biblioteca.
- `config.sh` e `gen_config_file.sh`: propagação de
  `EXYNOS990_RUNTIME32_APEX_MODE` para reproduzir a variante de runtime usada
  no teste do Chromium.
- Cabeçalhos `From:` dos patches corrigidos para `At30c
  <PabloAtsoc9993@outlook.com>`, conforme a autoria solicitada.
- O patch `platform/exynos990/patches/extremekrnl/patches/0002-cgroup2-add-cgroup-kill-interface.patch`
  foi incluído no conjunto de compatibilidade do kernel.

As validações locais foram `bash -n` nos scripts alterados e `git diff --check`.
Os módulos `unica/mods/appzygote_compat`, `zzzzz_zygote_next_trace` e
`scripts/capture_logcat_tmux.sh` permanecem fora deste envio por serem
diagnósticos/experimentais, não correções confirmadas.
