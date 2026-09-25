LOG_STEP_IN "- Setting casefold props"
SET_PROP "vendor" "external_storage.projid.enabled" "1"
SET_PROP "vendor" "external_storage.casefold.enabled" "1"
SET_PROP "vendor" "external_storage.sdcardfs.enabled" "0"
SET_PROP "vendor" "persist.sys.fuse.passthrough.enable" "true"
LOG_STEP_OUT

LOG_STEP_IN "- Enabling IncrementalFS"
SET_PROP "vendor" "ro.incremental.enable" "yes"
LOG_STEP_OUT

LOG_STEP_IN "- Enabling FS Verity"
SET_PROP "vendor" "ro.apk_verity.mode" "2"
LOG_STEP_OUT

if [[ "$SOURCE_PLATFORM_SDK_VERSION" -ge 36 ]]; then
    LOG_STEP_IN "- Updating Codec2 seccomp policy"
    CODEC2_POLICY="$WORK_DIR/vendor/etc/seccomp_policy/samsung.software.media.c2-base-policy"
    CODEC2_OLD_RULE="mremap: arg3 == 3"
    CODEC2_NEW_RULE="mremap: arg3 == 3 || arg3 == MREMAP_MAYMOVE"

    if [ ! -f "$CODEC2_POLICY" ]; then
        LOG "  - Codec2 seccomp policy is not present; skipping"
    else
        if grep -q -F -x "$CODEC2_NEW_RULE" "$CODEC2_POLICY"; then
            LOG "  - MREMAP_MAYMOVE is already allowed"
        elif grep -q -F -x "$CODEC2_OLD_RULE" "$CODEC2_POLICY"; then
            LOG "  - Allowing MREMAP_MAYMOVE in ${CODEC2_POLICY//$WORK_DIR\//}"
            EVAL "sed -i 's/^mremap: arg3 == 3$/mremap: arg3 == 3 || arg3 == MREMAP_MAYMOVE/' \"$CODEC2_POLICY\""
        elif grep -q '^mremap:' "$CODEC2_POLICY"; then
            ABORT "Unsupported mremap rule in ${CODEC2_POLICY//$WORK_DIR\//}"
        else
            LOG "  - Adding the missing mremap rule to ${CODEC2_POLICY//$WORK_DIR\//}"
            EVAL "printf '%s\\n' '$CODEC2_NEW_RULE' >> \"$CODEC2_POLICY\""
        fi

        grep -q -F -x "$CODEC2_NEW_RULE" "$CODEC2_POLICY" || \
            ABORT "Failed to update ${CODEC2_POLICY//$WORK_DIR\//}"

        for CODEC2_SYSCALL_RULE in "setsockopt: 1" "listen: 1" "bind: 1"; do
            if ! grep -q -F -x "$CODEC2_SYSCALL_RULE" "$CODEC2_POLICY"; then
                grep -q -F -x "prctl: 1" "$CODEC2_POLICY" || \
                    ABORT "Unable to locate the Codec2 syscall insertion point"
                LOG "  - Allowing ${CODEC2_SYSCALL_RULE%%:*}"
                EVAL "sed -i '/^prctl: 1$/i$CODEC2_SYSCALL_RULE' \"$CODEC2_POLICY\""
            fi
        done

        for CODEC2_SYSCALL_RULE in "setsockopt: 1" "listen: 1" "bind: 1"; do
            grep -q -F -x "$CODEC2_SYSCALL_RULE" "$CODEC2_POLICY" || \
                ABORT "Failed to add $CODEC2_SYSCALL_RULE to ${CODEC2_POLICY//$WORK_DIR\//}"
        done
    fi
    unset CODEC2_POLICY CODEC2_OLD_RULE CODEC2_NEW_RULE CODEC2_SYSCALL_RULE
    LOG_STEP_OUT
fi

if [[ "$SOURCE_PLATFORM_SDK_VERSION" -ge 37 ]]; then
    LOG_STEP_IN "- Aligning SLMK swap watermark with Android 17 RAM Plus"

    # Android 17's SLMKD re-evaluates its free-swap watermark after RAM Plus
    # has expanded zram.  The Exynos 990 target build.prop has no explicit
    # swap_free_low_percentage, so SLMKD falls back to 55 and then derives
    # 86% from the 8 GiB runtime zram device.  LMKD consequently kills cached
    # apps while more than 7 GiB of swap is still free.  The S24+ source
    # policy explicitly uses 10% for both SLMK policies; retain that policy
    # when the target vendor properties replace the source build.prop.  This
    # changes only the reclaim watermark, not zram capacity or OOM scores.
    SET_PROP "vendor" "ro.slmk.swap_free_low_percentage" "10"
    SET_PROP "vendor" "ro.slmk.2nd.swap_free_low_percentage" "10"

    LOG_STEP_OUT

    LOG_STEP_IN "- Disabling unsupported Codec2 availability accounting"

    # Android 17 enables codec_availability_metrics and consequently queries
    # C2ResourcesCapacityTuning/C2ResourcesExcludedTuning on the component
    # store and C2ResourcesNeededTuning on every component.  Those proposed
    # parameters are absent from the legacy Exynos 990 Codec2 HIDL 1.0 stack,
    # which correctly returns C2_BAD_INDEX (ENXIO, status 6).  Make only the
    # two optional accounting routines return an empty resource set/success,
    # matching CCodec's feature-disabled fallback.  Actual codec creation,
    # buffer allocation and allocation failures remain untouched.
    C2_PLUGIN_32="$WORK_DIR/system/system/lib/libsfplugin_ccodec.so"
    C2_PLUGIN_64="$WORK_DIR/system/system/lib64/libsfplugin_ccodec.so"

    # ARM32 CCodecResources::queryRequiredResources(): return OK.
    C2_REQUIRED_32_FROM="f0b58db004464d4878440068"
    C2_REQUIRED_32_TO="0020704704464d4878440068"
    # ARM32 queryGlobalResources(): initialize the returned vector to empty.
    C2_GLOBAL_32_FROM="2de9f04f9fb0e1490646dff8"
    C2_GLOBAL_32_TO="00210160416081607047dff8"

    # ARM64 CCodecResources::queryRequiredResources(): return OK.
    C2_REQUIRED_64_FROM="3f2303d5ff0302d1fd7b05a9f53300f9f44f07a9fd430191f30300aa340040f9"
    C2_REQUIRED_64_TO="e0031f2ac0035fd6fd7b05a9f53300f9f44f07a9fd430191f30300aa340040f9"
    # ARM64 queryGlobalResources(): initialize the returned vector to empty.
    C2_GLOBAL_64_FROM="3f2303d5ff8304d1fd7b0ca9fc6f0da9fa670ea9f85f0fa9f65710a9f44f11a9fd030391f30308aaa0fafff000f03491"
    C2_GLOBAL_64_TO="1f7d00a91f0900f9e0031f2ac0035fd6fa670ea9f85f0fa9f65710a9f44f11a9fd030391f30308aaa0fafff000f03491"

    if [[ -f "$C2_PLUGIN_32" ]]; then
        if xxd -p -c 0 "$C2_PLUGIN_32" | grep -q "$C2_REQUIRED_32_FROM"; then
            HEX_PATCH "$C2_PLUGIN_32" \
                "$C2_REQUIRED_32_FROM" "$C2_REQUIRED_32_TO" || return 1
        elif ! xxd -p -c 0 "$C2_PLUGIN_32" | grep -q "$C2_REQUIRED_32_TO"; then
            ABORT "Missing ARM32 Codec2 required-resource query pattern"
        fi
        if xxd -p -c 0 "$C2_PLUGIN_32" | grep -q "$C2_GLOBAL_32_FROM"; then
            HEX_PATCH "$C2_PLUGIN_32" \
                "$C2_GLOBAL_32_FROM" "$C2_GLOBAL_32_TO" || return 1
        elif ! xxd -p -c 0 "$C2_PLUGIN_32" | grep -q "$C2_GLOBAL_32_TO"; then
            ABORT "Missing ARM32 Codec2 global-resource query pattern"
        fi
    fi

    if [[ -f "$C2_PLUGIN_64" ]]; then
        if xxd -p -c 0 "$C2_PLUGIN_64" | grep -q "$C2_REQUIRED_64_FROM"; then
            HEX_PATCH "$C2_PLUGIN_64" \
                "$C2_REQUIRED_64_FROM" "$C2_REQUIRED_64_TO" || return 1
        elif ! xxd -p -c 0 "$C2_PLUGIN_64" | grep -q "$C2_REQUIRED_64_TO"; then
            ABORT "Missing ARM64 Codec2 required-resource query pattern"
        fi
        if xxd -p -c 0 "$C2_PLUGIN_64" | grep -q "$C2_GLOBAL_64_FROM"; then
            HEX_PATCH "$C2_PLUGIN_64" \
                "$C2_GLOBAL_64_FROM" "$C2_GLOBAL_64_TO" || return 1
        elif ! xxd -p -c 0 "$C2_PLUGIN_64" | grep -q "$C2_GLOBAL_64_TO"; then
            ABORT "Missing ARM64 Codec2 global-resource query pattern"
        fi
    fi

    unset C2_PLUGIN_32 C2_PLUGIN_64 \
        C2_REQUIRED_32_FROM C2_REQUIRED_32_TO \
        C2_GLOBAL_32_FROM C2_GLOBAL_32_TO \
        C2_REQUIRED_64_FROM C2_REQUIRED_64_TO \
        C2_GLOBAL_64_FROM C2_GLOBAL_64_TO
    LOG_STEP_OUT

    LOG_STEP_IN "- Removing stale legacy OMX performance metadata"

    # Android 17's codec-list generator no longer registers the legacy OMX
    # performance entries from the Exynos 990 target.  Keeping this file makes
    # it emit "cannot update non-existing codec" for every OMX entry.  The
    # actual codec declarations remain in media_codecs.xml and the C2 metadata
    # remains in media_codecs_c2_sec*.xml; only the obsolete performance
    # overlay is removed.
    DELETE_FROM_WORK_DIR "vendor" "etc/media_codecs_performance.xml"

    LOG_STEP_OUT
fi

if ${SOURCE_USE_NATIVE_DISPLAY_STACK:-false}; then
    LOG "- Preserving native SurfaceFlinger timing and HFR properties"
else
    LOG_STEP_IN "- Setting SF flags"
    SET_PROP "vendor" "debug.sf.latch_unsignaled" "1"
    SET_PROP "vendor" "debug.sf.high_fps_late_app_phase_offset_ns" "0"
    SET_PROP "vendor" "debug.sf.high_fps_late_sf_phase_offset_ns" "0"
    LOG_STEP_OUT

    LOG_STEP_IN "- Setting Adaptive HFR flags"
    if [[ "$TARGET_CODENAME" != "c1s" && "$TARGET_CODENAME" != "c2s" ]]; then
        SET_PROP "vendor" "debug.sf.show_refresh_rate_overlay_render_rate" "true"
        SET_PROP "vendor" "ro.surface_flinger.game_default_frame_rate_override" "60"
        SET_PROP "vendor" "ro.surface_flinger.use_content_detection_for_refresh_rate" "true"
        SET_PROP "vendor" "ro.surface_flinger.set_idle_timer_ms" "250"
        SET_PROP "vendor" "ro.surface_flinger.set_touch_timer_ms" "300"
        SET_PROP "vendor" "ro.surface_flinger.set_display_power_timer_ms" "200"
        SET_PROP "vendor" "ro.surface_flinger.enable_frame_rate_override" "true"
    elif [[ "$TARGET_CODENAME" == "c1s" ]]; then
        SET_PROP "vendor" "debug.sf.show_refresh_rate_overlay_render_rate" "true"
        SET_PROP "vendor" "ro.surface_flinger.game_default_frame_rate_override" "60"
        SET_PROP "vendor" "ro.surface_flinger.use_content_detection_for_refresh_rate" "false"
        SET_PROP "vendor" "ro.surface_flinger.enable_frame_rate_override" "false"
    elif [[ "$TARGET_CODENAME" == "c2s" ]]; then
        SET_PROP "vendor" "debug.sf.show_refresh_rate_overlay_render_rate" "true"
        SET_PROP "vendor" "ro.surface_flinger.game_default_frame_rate_override" "60"
        SET_PROP "vendor" "ro.surface_flinger.enable_frame_rate_override" "true"
    fi
    LOG_STEP_OUT
fi

LOG_STEP_IN "- Restoring the Exynos 990 HWUI backend"
# The S24+ source vendor property forces Vulkan and Samsung's hint manager.
# The S20+ target leaves HWUI's Vulkan selector empty and does not define the
# hint-manager override.  Forcing the source values makes Chromium/social
# workloads allocate the wrong GPU path; the capture then reaches 817-834 MB
# of DMA-BUF and triggers LMKD low-watermark reclaim.  Restore the target
# policy instead of disabling GPU acceleration globally.  Codec2 status 6 is
# separately handled above as C2_BAD_INDEX, not as an out-of-memory result.
VENDOR_BUILD_PROP="$WORK_DIR/vendor/build.prop"
if [[ -f "$VENDOR_BUILD_PROP" ]]; then
    # SET_PROP cannot distinguish an absent property from one whose value is
    # deliberately empty.  Remove every occurrence first so a stale source
    # value appended later in the file cannot override the target policy.
    sed -i \
        -e '/^ro\.hwui\.use_vulkan=/d' \
        -e '/^debug\.hwui\.use_hint_manager=/d' \
        "$VENDOR_BUILD_PROP"
    printf '%s\n' 'ro.hwui.use_vulkan=' >> "$VENDOR_BUILD_PROP"
fi
unset VENDOR_BUILD_PROP
LOG_STEP_OUT

if [[ "$SOURCE_PLATFORM_SDK_VERSION" -ge 37 ]]; then
    LOG_STEP_IN "- Fixing legacy AVC HDR-static capability discovery"

    # The Android 11 Exynos AVC decoder reports success for
    # OMX.google.android.index.describeHDRStaticInfo during GetExtensionIndex,
    # but its GetConfig/SetConfig implementations reject the returned index.
    # Android 17 consequently performs the unsupported transaction at every
    # AVC setup and port reconfiguration.  Skip only that false-positive match
    # so the generic OMX fallback returns OMX_ErrorUnsupportedIndex.  HEVC is
    # deliberately untouched because its HDR/HDR10+ path is functional.
    AVC_DECODER_32="$WORK_DIR/vendor/lib/omx/libOMX.Exynos.AVC.Decoder.so"
    AVC_DECODER_64="$WORK_DIR/vendor/lib64/omx/libOMX.Exynos.AVC.Decoder.so"

    AVC_HDR_INDEX_32_FROM="0c129fe50500a0e101108fe0f07f00eb000050e35900000af8119fe5"
    AVC_HDR_INDEX_32_TO="0c129fe50500a0e101108fe0f07f00eb000050e30000a0e1f8119fe5"
    AVC_HDR_INDEX_64_FROM="61ffffb021fc3a91e00314aa35880094000f003441ffffd0"
    AVC_HDR_INDEX_64_TO="61ffffb021fc3a91e00314aa358800941f2003d541ffffd0"

    if [[ -f "$AVC_DECODER_32" ]]; then
        if xxd -p -c 0 "$AVC_DECODER_32" | grep -q "$AVC_HDR_INDEX_32_FROM"; then
            HEX_PATCH "$AVC_DECODER_32" "$AVC_HDR_INDEX_32_FROM" "$AVC_HDR_INDEX_32_TO"
        elif ! xxd -p -c 0 "$AVC_DECODER_32" | grep -q "$AVC_HDR_INDEX_32_TO"; then
            ABORT "Missing ARM32 Exynos AVC HDR-static discovery pattern"
        fi
    fi

    if [[ -f "$AVC_DECODER_64" ]]; then
        if xxd -p -c 0 "$AVC_DECODER_64" | grep -q "$AVC_HDR_INDEX_64_FROM"; then
            HEX_PATCH "$AVC_DECODER_64" "$AVC_HDR_INDEX_64_FROM" "$AVC_HDR_INDEX_64_TO"
        elif ! xxd -p -c 0 "$AVC_DECODER_64" | grep -q "$AVC_HDR_INDEX_64_TO"; then
            ABORT "Missing ARM64 Exynos AVC HDR-static discovery pattern"
        fi
    fi

    unset AVC_DECODER_32 AVC_DECODER_64 \
        AVC_HDR_INDEX_32_FROM AVC_HDR_INDEX_32_TO \
        AVC_HDR_INDEX_64_FROM AVC_HDR_INDEX_64_TO
    LOG_STEP_OUT
fi

if [[ "$SOURCE_PLATFORM_SDK_VERSION" -ge 36 ]]; then
    # Android 17's source image ships the AIDL-only suspend daemon.  The
    # Exynos 990 target still has vendor clients (gpsd/RIL/sensors) linked
    # against android.system.suspend@1.0 HIDL, so those clients repeatedly
    # fail ISystemSuspend::getService() when only the AIDL endpoint exists.
    # Restore the target's dual HIDL+AIDL implementation without importing
    # the target power HAL or changing the source power ABI.
    # Firmware extraction directories use only MODEL_CSC.  TARGET_FIRMWARE
    # also contains the serial number (MODEL/CSC/SERIAL), so replacing every
    # slash with an underscore resolves to a directory that can never exist
    # (for example SM-G986B_AUT_359...).  Keep this in sync with
    # scripts/make_rom.sh and scripts/internal/create_work_dir.sh.
    TARGET_FIRMWARE_MODEL="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")"
    TARGET_FIRMWARE_CSC="$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"
    TARGET_FW_ROOT="$FW_DIR/${TARGET_FIRMWARE_MODEL}_${TARGET_FIRMWARE_CSC}"
    TARGET_SUSPEND_SERVICE="$TARGET_FW_ROOT/system/system/bin/hw/android.system.suspend@1.0-service"
    TARGET_SUSPEND_HIDL="$TARGET_FW_ROOT/system/system/lib64/android.system.suspend@1.0.so"
    TARGET_SUSPEND_PROPS="$TARGET_FW_ROOT/system/system/lib64/libSuspendProperties.so"
    TARGET_SUSPEND_LIBBASE="$TARGET_FW_ROOT/system/system/lib64/libbase.so"
    TARGET_SUSPEND_CONTROL="$TARGET_FW_ROOT/system/system/lib64/android.system.suspend.control-V1-cpp.so"
    TARGET_SUSPEND_MANIFEST="$TARGET_FW_ROOT/system/system/etc/vintf/manifest/android.system.suspend@1.0-service.xml"
    SUSPEND_COMPAT_LIBBASE="$WORK_DIR/system/system/lib64/libbase_suspend_compat.so"
    SUSPEND_COMPAT_CONTROL="$WORK_DIR/system/system/lib64/android.system.suspend.control-V1-cpp-compat.so"
    SUSPEND_OUTPUT_SERVICE="$WORK_DIR/system/system/bin/hw/android.system.suspend-service"

    if [[ -n "$TARGET_FIRMWARE_MODEL" && -n "$TARGET_FIRMWARE_CSC" &&
            -f "$TARGET_SUSPEND_SERVICE" && -f "$TARGET_SUSPEND_HIDL" &&
            -f "$TARGET_SUSPEND_PROPS" && -f "$TARGET_SUSPEND_LIBBASE" &&
            -f "$TARGET_SUSPEND_CONTROL" && -f "$TARGET_SUSPEND_MANIFEST" ]]; then
        LOG_STEP_IN "- Restoring the target HIDL/AIDL system suspend bridge"
        if ! command -v patchelf > /dev/null 2>&1; then
            ABORT "patchelf is required for the target suspend compatibility stack"
            return 1
        fi

        cp -a -T "$TARGET_SUSPEND_SERVICE" \
            "$SUSPEND_OUTPUT_SERVICE" || return 1
        SET_METADATA "system" "system/bin/hw/android.system.suspend-service" \
            0 2000 755 "u:object_r:system_suspend_exec:s0" || return 1

        ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" \
            "system/lib64/android.system.suspend@1.0.so" \
            0 0 644 "u:object_r:system_lib_file:s0" || return 1
        ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" \
            "system/lib64/libSuspendProperties.so" \
            0 0 644 "u:object_r:system_lib_file:s0" || return 1

        # Android 17 changed libbase's string API and the C++ Binder layout of
        # suspend_control.  Loading the Android 13 daemon against the source
        # libraries would therefore fail before main() with unresolved
        # WriteStringToFd/Trim and BnSuspendControlService thunk symbols.
        # Give only these two target libraries private SONAMEs and redirect the
        # daemon to them; replacing the global source libraries would break
        # unrelated Android 17 processes.
        cp -a -T "$TARGET_SUSPEND_LIBBASE" "$SUSPEND_COMPAT_LIBBASE" || return 1
        cp -a -T "$TARGET_SUSPEND_CONTROL" "$SUSPEND_COMPAT_CONTROL" || return 1
        patchelf --set-soname "libbase_suspend_compat.so" \
            "$SUSPEND_COMPAT_LIBBASE" || return 1
        patchelf --set-soname "android.system.suspend.control-V1-cpp-compat.so" \
            "$SUSPEND_COMPAT_CONTROL" || return 1
        patchelf --replace-needed "libbase.so" "libbase_suspend_compat.so" \
            "$SUSPEND_OUTPUT_SERVICE" || return 1
        patchelf --replace-needed \
            "android.system.suspend.control-V1-cpp.so" \
            "android.system.suspend.control-V1-cpp-compat.so" \
            "$SUSPEND_OUTPUT_SERVICE" || return 1
        SET_METADATA "system" "system/lib64/libbase_suspend_compat.so" \
            0 0 644 "u:object_r:system_lib_file:s0" || return 1
        SET_METADATA "system" \
            "system/lib64/android.system.suspend.control-V1-cpp-compat.so" \
            0 0 644 "u:object_r:system_lib_file:s0" || return 1

        # The target manifest advertises both transports.  Keep the source
        # filename so no stale AIDL-only manifest is left beside it.
        cp -a -T "$TARGET_SUSPEND_MANIFEST" \
            "$WORK_DIR/system/system/etc/vintf/manifest/android.system.suspend-service.xml" || return 1
        SET_METADATA "system" "system/etc/vintf/manifest/android.system.suspend-service.xml" \
            0 0 644 "u:object_r:system_file:s0" || return 1
        LOG_STEP_OUT
    else
        ABORT "Target suspend compatibility stack is incomplete in $TARGET_FW_ROOT"
        return 1
    fi

    unset TARGET_FIRMWARE_MODEL TARGET_FIRMWARE_CSC TARGET_FW_ROOT \
        TARGET_SUSPEND_SERVICE TARGET_SUSPEND_HIDL TARGET_SUSPEND_PROPS \
        TARGET_SUSPEND_LIBBASE TARGET_SUSPEND_CONTROL TARGET_SUSPEND_MANIFEST \
        SUSPEND_COMPAT_LIBBASE SUSPEND_COMPAT_CONTROL SUSPEND_OUTPUT_SERVICE
fi

LOG "- Disabling encryption"
LINE=$(sed -n "/^\/dev\/block\/by-name\/userdata/=" "$WORK_DIR/vendor/etc/fstab.exynos990")
sed -i "${LINE}s/,fileencryption=ice//g;${LINE}s/,fileencryption=aes-256-xts:aes-256-cts:v2//g" "$WORK_DIR/vendor/etc/fstab.exynos990"

# ODE
sed -i -e "/ODE/d" -e "/keydata/d" -e "/keyrefuge/d" "$WORK_DIR/vendor/etc/fstab.exynos990"

if [ -f "$WORK_DIR/vendor/ueventd.rc" ]; then
    LOG "- Moving legacy vendor ueventd configuration to vendor/etc"
    mkdir -p "$WORK_DIR/vendor/etc"
    cp -a "$WORK_DIR/vendor/ueventd.rc" "$WORK_DIR/vendor/etc/ueventd.rc" || return 1
    SET_METADATA "vendor" "etc/ueventd.rc" 0 0 644 "u:object_r:vendor_configs_file:s0" || return 1
    DELETE_FROM_WORK_DIR "vendor" "ueventd.rc" || return 1
elif [ ! -f "$WORK_DIR/vendor/etc/ueventd.rc" ]; then
    ABORT "Target vendor has no ueventd.rc to migrate"
    return 1
fi

# For some reason we are missing 2 permissions here: android.hardware.security.model.compatible and android.software.controls
# First one is related to encryption and second one to SmartThings Device Control
LOG "- Patching vendor permissions"
sed -i '$d' "$WORK_DIR/vendor/etc/permissions/handheld_core_hardware.xml"
{
    echo ""
    echo "    <!-- Indicate support for the Android security model per the CDD. -->"
    echo "    <feature name=\"android.hardware.security.model.compatible\"/>"
    echo ""
    echo "    <!--  Feature to specify if the device supports controls.  -->"
    echo "    <feature name=\"android.software.controls\"/>"
    echo "</permissions>"
} >> "$WORK_DIR/vendor/etc/permissions/handheld_core_hardware.xml"

LOG_STEP_IN "- Setting stock Bluetooth profiles"
SET_PROP "product" "bluetooth.profile.asha.central.enabled" "true"
SET_PROP "product" "bluetooth.profile.a2dp.source.enabled" "true"
SET_PROP "product" "bluetooth.profile.avrcp.target.enabled" "true"
SET_PROP "product" "bluetooth.profile.bap.broadcast.assist.enabled" "false"
SET_PROP "product" "bluetooth.profile.bap.broadcast.source.enabled" "false"
SET_PROP "product" "bluetooth.profile.bap.unicast.client.enabled" "false"
SET_PROP "product" "bluetooth.profile.bas.client.enabled" "false"
SET_PROP "product" "bluetooth.profile.csip.set_coordinator.enabled" "false"
SET_PROP "product" "bluetooth.profile.gatt.enabled" "true"
SET_PROP "product" "bluetooth.profile.hap.client.enabled" "false"
SET_PROP "product" "bluetooth.profile.hfp.ag.enabled" "true"
SET_PROP "product" "bluetooth.profile.hid.device.enabled" "true"
SET_PROP "product" "bluetooth.profile.hid.host.enabled" "true"
SET_PROP "product" "bluetooth.profile.map.server.enabled" "true"
SET_PROP "product" "bluetooth.profile.mcp.server.enabled" "false"
SET_PROP "product" "bluetooth.profile.opp.enabled" "false"
SET_PROP "product" "bluetooth.profile.pan.nap.enabled" "true"
SET_PROP "product" "bluetooth.profile.pan.panu.enabled" "true"
SET_PROP "product" "bluetooth.profile.pbap.server.enabled" "true"
SET_PROP "product" "bluetooth.profile.sap.server.enabled" "true"
SET_PROP "product" "bluetooth.profile.ccp.server.enabled" "false"
SET_PROP "product" "bluetooth.profile.vcp.controller.enabled" "false"

if [[ "$SOURCE_PLATFORM_SDK_VERSION" -ge 36 ]]; then
    # Android 16 services.jar uses Bluetooth framework APIs that are not
    # present in the older b0s/r11s prebuilts (for example
    # ScanSettings.Builder#setRssiThreshold).  Keep the source firmware APEX
    # so framework-bluetooth.jar and services.jar remain on the same ABI.
    LOG "  - Keeping source Bluetooth APEX for framework ABI compatibility"
elif [[ "$TARGET_CODENAME" == "r8s" ]]; then
    ADD_TO_WORK_DIR "r11sxxx" "system" "system/apex/com.android.btservices.apex" 0 0 644 "u:object_r:system_file:s0"
else
    ADD_TO_WORK_DIR "b0sxxx" "system" "system/apex/com.android.bt.apex" 0 0 644 "u:object_r:system_file:s0"
fi
LOG_STEP_OUT
