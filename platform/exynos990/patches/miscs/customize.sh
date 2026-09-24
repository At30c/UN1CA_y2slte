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
# of DMA-BUF, triggers LMKD low-watermark reclaim, and Codec2 reports
# C2_NO_MEMORY ("system resources: 6").  Restore the target policy instead of
# disabling GPU acceleration globally.
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
    TARGET_FW_ROOT="$FW_DIR/$(tr '/' '_' <<< "$TARGET_FIRMWARE")"
    TARGET_SUSPEND_SERVICE="$TARGET_FW_ROOT/system/system/bin/hw/android.system.suspend@1.0-service"
    TARGET_SUSPEND_HIDL="$TARGET_FW_ROOT/system/system/lib64/android.system.suspend@1.0.so"
    TARGET_SUSPEND_PROPS="$TARGET_FW_ROOT/system/system/lib64/libSuspendProperties.so"
    TARGET_SUSPEND_MANIFEST="$TARGET_FW_ROOT/system/system/etc/vintf/manifest/android.system.suspend@1.0-service.xml"

    if [[ -f "$TARGET_SUSPEND_SERVICE" && -f "$TARGET_SUSPEND_HIDL" &&
            -f "$TARGET_SUSPEND_PROPS" && -f "$TARGET_SUSPEND_MANIFEST" ]]; then
        LOG_STEP_IN "- Restoring the target HIDL/AIDL system suspend bridge"
        cp -a -T "$TARGET_SUSPEND_SERVICE" \
            "$WORK_DIR/system/system/bin/hw/android.system.suspend-service" || return 1
        SET_METADATA "system" "system/bin/hw/android.system.suspend-service" \
            0 2000 755 "u:object_r:system_suspend_exec:s0" || return 1

        ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" \
            "system/lib64/android.system.suspend@1.0.so" \
            0 0 644 "u:object_r:system_lib_file:s0" || return 1
        ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" \
            "system/lib64/libSuspendProperties.so" \
            0 0 644 "u:object_r:system_lib_file:s0" || return 1

        # The target manifest advertises both transports.  Keep the source
        # filename so no stale AIDL-only manifest is left beside it.
        cp -a -T "$TARGET_SUSPEND_MANIFEST" \
            "$WORK_DIR/system/system/etc/vintf/manifest/android.system.suspend-service.xml" || return 1
        SET_METADATA "system" "system/etc/vintf/manifest/android.system.suspend-service.xml" \
            0 0 644 "u:object_r:system_file:s0" || return 1
        LOG_STEP_OUT
    else
        LOG "  - Target has no dual suspend service; keeping the source AIDL service"
    fi

    unset TARGET_FW_ROOT TARGET_SUSPEND_SERVICE TARGET_SUSPEND_HIDL \
        TARGET_SUSPEND_PROPS TARGET_SUSPEND_MANIFEST
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
