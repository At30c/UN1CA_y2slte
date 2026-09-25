LOG_STEP_IN "- Replacing camera blobs"
BLOBS_LIST="
system/lib64/libenn_wrapper_system.so
system/lib64/libpic_best.arcsoft.so
system/lib64/libarcsoft_dualcam_portraitlighting.so
system/lib64/libdualcam_refocus_gallery_54.so
system/lib64/libdualcam_refocus_gallery_50.so
system/lib64/libhybrid_high_dynamic_range.arcsoft.so
system/lib64/libae_bracket_hdr.arcsoft.so
system/lib64/libface_recognition.arcsoft.so
system/lib64/libDualCamBokehCapture.camera.samsung.so
"
for blob in $BLOBS_LIST
do
    DELETE_FROM_WORK_DIR "system" "$blob" &
done

# shellcheck disable=SC2046
wait $(jobs -p) || exit 1

BLOBS_LIST="
system/lib64/libPortraitDistortionCorrectionCali.arcsoft.so
system/lib64/libMultiFrameProcessing20.camera.samsung.so
system/lib64/libMultiFrameProcessing20Core.camera.samsung.so
system/lib64/libMultiFrameProcessing20Day.camera.samsung.so
system/lib64/libMultiFrameProcessing20Tuning.camera.samsung.so
system/lib64/libMultiFrameProcessing30.camera.samsung.so
system/lib64/libMultiFrameProcessing30.snapwrapper.camera.samsung.so
system/lib64/libMultiFrameProcessing30Tuning.camera.samsung.so
system/lib64/libGeoTrans10.so
system/lib64/vendor.samsung_slsi.hardware.geoTransService@1.0.so
system/lib64/libSwIsp_core.camera.samsung.so
system/lib64/libSwIsp_wrapper_v1.camera.samsung.so
"
for blob in $BLOBS_LIST
do
    ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "$blob" 0 0 644 "u:object_r:system_lib_file:s0" &
done

if [[ "$TARGET_CODENAME" == "c1s" || "$TARGET_CODENAME" == "c2s" ]]; then
    BLOBS_LIST="
    system/lib64/libofi_seva.so
    system/lib64/libofi_klm.so
    system/lib64/libofi_plugin.so
    system/lib64/libofi_rt_framework_user.so
    system/lib64/libofi_service_interface.so
    system/lib64/libofi_gc.so
    system/lib64/vendor.samsung_slsi.hardware.ofi@2.0.so
    system/lib64/vendor.samsung_slsi.hardware.ofi@2.1.so
    "
    for blob in $BLOBS_LIST
    do
        ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "$blob" 0 0 644 "u:object_r:system_lib_file:s0" &
    done
fi

# shellcheck disable=SC2046
wait $(jobs -p) || exit 1

LOG_STEP_OUT

LOG_STEP_IN "- Adding libc++_shared.so dependency for __cxa_demangle symbol"
patchelf --add-needed "libc++_shared.so" "$WORK_DIR/system/system/lib64/libMultiFrameProcessing20Core.camera.samsung.so"
LOG_STEP_OUT

LOG_STEP_IN "- Removing HDR10+ check"

# Android 16 and 17 ask for OMX_VIDEO_HEVCProfileMain10HDR10Plus (0x2000), but
# the Exynos 990 OMX component shipped in the target vendor partition only
# advertises Main, Main10 and Main10HDR10 (0x1, 0x2 and 0x1000).  Its profile
# enumeration then returns OMX_ErrorNoMore, which Stagefright surfaces as
# -ENODATA (-61) and MediaRecorder reports as a recording that could not be
# saved.
#
# patch_hdr10plus_profile.py reuses the unreachable HDR10+ fatal block of
# setupVideoEncoder as a six instruction trampoline and rewrites only the
# profile copy in setupHEVCEncoderParameters, so 0x2000 is translated to the
# legacy 0x1000 for profile verification and OMX configuration while every
# other HEVC profile is left untouched.  Both places are located by decoding
# the instructions around them, so the patch is not bound to one donor build
# and covers every Exynos 990 target that shares this source media stack.
# <expected-shape> is the slot the given source generation is known to use and
# only guards against patching a mismatched donor.
HDR10P_BRIDGE_PATCH()
{
    local EXPECTED_SHAPE="$1"
    local LIBRARY="$WORK_DIR/system/system/lib64/libstagefright.so"

    if ! python3 "$SRC_DIR/platform/exynos990/patches/camera/patch_hdr10plus_profile.py" \
        --expect-shape "$EXPECTED_SHAPE" "$LIBRARY"; then
        ABORT "Could not install the HDR10+ profile bridge, see the error above"
    fi
}

if [[ "$SOURCE_PLATFORM_SDK_VERSION" -lt 36 ]]; then
    # Pre-Android 16 sources pair with the matching legacy media stack, whose
    # HDR10+ rejection is a plain guard in front of the fatal block instead of
    # the profile copy patched above, so keep neutralising that guard here.
    ADD_TO_WORK_DIR "pa3qzcx" "system" "system/lib64/libstagefright.so" 0 0 644 "u:object_r:system_lib_file:s0"
    HEX_PATCH "$WORK_DIR/system/system/lib64/libstagefright.so" \
        "010140f97069059420510034" \
        "010140f91f2003d51f2003d5"
elif [[ "$SOURCE_PLATFORM_SDK_VERSION" -eq 36 ]]; then
    # Android 16 changed the Camera::connect ABI. Replacing this library with
    # the older pa3qzcx blob makes zygote, cameraserver and the media services
    # fail at link time, so retain the source firmware's matched media stack.
    ADD_TO_WORK_DIR "$SOURCE_FIRMWARE" "system" \
        "system/lib64/libstagefright.so" 0 0 644 \
        "u:object_r:system_lib_file:s0"

    # The Android 16 media stack retained Samsung's background recording API,
    # but MediaCodecSource::suspendRecording(bool) is now a no-op. Exynos 990
    # Super Slow Motion still creates its persistent encoder input suspended
    # and relies on that method to resume it, otherwise the recording finishes
    # with zero encoded frames. Start that input active instead.
    HEX_PATCH "$WORK_DIR/system/system/lib64/libstagefright.so" \
        "810240f97ef9019421f5ffd021481091e00314aa2200805225fd0194" \
        "810240f97ef9019421f5ffd021481091e00314aa0200805225fd0194"

    # Android 16 configures temporal SVC for high-frame-rate recordings. The
    # legacy Exynos HEVC OMX encoder does not implement the queried extension
    # and returns ERROR_UNSUPPORTED. Keep the encoder setup going without SVC;
    # AVC encoders that support the extension continue through the same path.
    HEX_PATCH "$WORK_DIR/system/system/lib64/libstagefright.so" \
        "e10740b9e22340b9e00313aa44aa059420020034fa03002a" \
        "e10740b9e22340b9e00313aa44aa059411000014fa03002a"

    HDR10P_BRIDGE_PATCH "stack"
else
    # Android 17 moved both call sites while preserving their semantics.
    # MediaCodecSource::suspendRecording(bool) remains a no-op, so start the
    # persistent encoder input active instead of asking that method to resume
    # it later.
    HEX_PATCH "$WORK_DIR/system/system/lib64/libstagefright.so" \
        "140340f9e00315aa810240f91d2b0294e1f4ff9021d83c91e00314aa2200805206310294" \
        "140340f9e00315aa810240f91d2b0294e1f4ff9021d83c91e00314aa0200805206310294"

    # The Android 17 setupVideoEncoder call site branches 16 instructions to
    # the normal continuation.  Force that branch when the legacy Exynos HEVC
    # OMX encoder reports temporal SVC as unsupported.
    HEX_PATCH "$WORK_DIR/system/system/lib64/libstagefright.so" \
        "e10f40b9e28b40b9e00313aa11f7059400020034fa03002a" \
        "e10f40b9e28b40b9e00313aa11f7059410000014fa03002a"

    # Migrate incremental work directories made with the superseded
    # experiment.  Those variants escaped after x19 was already clobbered and
    # disabled valid CFI checks, changing the original abort into SIGSEGV.
    HDR10P_ASSERT_FROM="e3fbff9063d40d91e10313aa4ef40594203a8bd2"
    HDR10P_ASSERT_NOP="e3fbff9063d40d91e10313aa1f2003d5203a8bd2"
    HDR10P_ASSERT_OLD="e3fbff9063d40d91e10313aa46feff17203a8bd2"
    if xxd -p -c 0 "$WORK_DIR/system/system/lib64/libstagefright.so" | grep -q "$HDR10P_ASSERT_OLD"; then
        HEX_PATCH "$WORK_DIR/system/system/lib64/libstagefright.so" \
            "$HDR10P_ASSERT_OLD" "$HDR10P_ASSERT_FROM"
    elif xxd -p -c 0 "$WORK_DIR/system/system/lib64/libstagefright.so" | grep -q "$HDR10P_ASSERT_NOP"; then
        HEX_PATCH "$WORK_DIR/system/system/lib64/libstagefright.so" \
            "$HDR10P_ASSERT_NOP" "$HDR10P_ASSERT_FROM"
    elif ! xxd -p -c 0 "$WORK_DIR/system/system/lib64/libstagefright.so" | grep -q "$HDR10P_ASSERT_FROM"; then
        ABORT "Missing Android 17 HDR10+ assert restoration pattern"
    fi

    HDR10P_CFI_RESTORE_PATTERNS="
a08315b83f0008eb01350054e2830291e103002ad6f7059420040035e0430091e1830291|a08315b83f0008eb1f2003d5e2830291e103002ad6f7059420040035e0430091e1830291
21310054e00313aae10314aae20317aabbf705942b0000143f0f0071|1f2003d5e00313aae10314aae20317aabbf705942b0000143f0f0071
a1300054e00313aae10314aaa6f705941c000014610240f9a80c00b0|1f2003d5e00313aae10314aaa6f705941c000014610240f9a80c00b0
c12e0054e00313aae10314aae20317aaa8f7059412000014610240f9|1f2003d5e00313aae10314aae20317aaa8f7059412000014610240f9
012f0054e00313aae10314aa8df7059409000014610240f9a80c00b0|1f2003d5e00313aae10314aa8df7059409000014610240f9a80c00b0
a12e0054e00313aae10314aa7ef70594fa03002a8023003500e4006f|1f2003d5e00313aae10314aa7ef70594fa03002a8023003500e4006f
41220054e00313aae10314aae20317aae30318aa1ff70594a0010034|1f2003d5e00313aae10314aae20317aae30318aa1ff70594a0010034
21200054e00313aae1031f2ae20314aae30317aaeaf60594a0010034|1f2003d5e00313aae1031f2ae20314aae30317aaeaf60594a0010034
c1100054789a40f980698ad277c20b91|1f2003d5789a40f980698ad277c20b91
e10a005468f242b9e1530091e2030091|1f2003d568f242b9e1530091e2030091
21060054e1530091e00313aa22008052|1f2003d5e1530091e00313aa22008052
41050054e1530091e00313aa22008052|1f2003d5e1530091e00313aa22008052
210a0054769a40f994698ad275d20b91|1f2003d5769a40f994698ad275d20b91
61060054b50240b935030034769a40f9|1f2003d5b50240b935030034769a40f9
"
    while IFS='|' read -r HDR10P_CFI_ORIGINAL HDR10P_CFI_OLD; do
        [ "$HDR10P_CFI_ORIGINAL" ] || continue
        if xxd -p -c 0 "$WORK_DIR/system/system/lib64/libstagefright.so" | grep -q "$HDR10P_CFI_OLD"; then
            HEX_PATCH "$WORK_DIR/system/system/lib64/libstagefright.so" \
                "$HDR10P_CFI_OLD" "$HDR10P_CFI_ORIGINAL"
        elif ! xxd -p -c 0 "$WORK_DIR/system/system/lib64/libstagefright.so" | grep -q "$HDR10P_CFI_ORIGINAL"; then
            ABORT "Missing Android 17 ACodec CFI restoration pattern"
        fi
    done <<< "$HDR10P_CFI_RESTORE_PATTERNS"

    HDR10P_PROCESS_CACHE_FROM="a88355b81f0100718c05005497fa0594610240f9a80c00b0"
    HDR10P_PROCESS_CACHE_OLD="a88355b81f0100718c0500542b000014610240f9a80c00b0"
    if xxd -p -c 0 "$WORK_DIR/system/system/lib64/libstagefright.so" | grep -q "$HDR10P_PROCESS_CACHE_OLD"; then
        HEX_PATCH "$WORK_DIR/system/system/lib64/libstagefright.so" \
            "$HDR10P_PROCESS_CACHE_OLD" "$HDR10P_PROCESS_CACHE_FROM"
    elif ! xxd -p -c 0 "$WORK_DIR/system/system/lib64/libstagefright.so" | grep -q "$HDR10P_PROCESS_CACHE_FROM"; then
        ABORT "Missing Android 17 ACodec process-cache restoration pattern"
    fi

    # That same experiment rewrote only the second fatal block entry, leaving
    # the block unusable for the trampoline.  Put the stock instructions back
    # so the bridge below starts from an untouched donor.
    HDR10P_BRIDGE_STOCK="48008052e8af00b9f3fbfff073da099182fbfff042143391c0008052e10313aa7cf20594e0fbffb0"
    HDR10P_BRIDGE_PARTIAL="48008052e8af00b9cafdff1773da099182fbfff042143391c0008052e10313aa7cf20594e0fbffb0"
    HDR10P_BRIDGE_DONE="ccfdff17e8af00b9cafdff1773da0991a2035eb85f0840716100005402008252a2031eb87a110014"
    if xxd -p -c 0 "$WORK_DIR/system/system/lib64/libstagefright.so" | grep -q "$HDR10P_BRIDGE_PARTIAL"; then
        HEX_PATCH "$WORK_DIR/system/system/lib64/libstagefright.so" \
            "$HDR10P_BRIDGE_PARTIAL" "$HDR10P_BRIDGE_STOCK"
    elif ! xxd -p -c 0 "$WORK_DIR/system/system/lib64/libstagefright.so" | grep -qE "$HDR10P_BRIDGE_STOCK|$HDR10P_BRIDGE_DONE"; then
        ABORT "Missing Android 17 HDR10+ fatal block pattern"
    fi

    HDR10P_BRIDGE_PATCH "frame"
    unset HDR10P_BRIDGE_STOCK HDR10P_BRIDGE_PARTIAL HDR10P_BRIDGE_DONE \
        HDR10P_ASSERT_FROM HDR10P_ASSERT_NOP HDR10P_ASSERT_OLD \
        HDR10P_CFI_RESTORE_PATTERNS HDR10P_CFI_ORIGINAL HDR10P_CFI_OLD \
        HDR10P_PROCESS_CACHE_FROM HDR10P_PROCESS_CACHE_OLD
fi
LOG_STEP_OUT

LOG_STEP_IN "- Adding prebuilt libs from other devices"
BLOBS_LIST="
system/lib64/libc++_shared.so
"
for blob in $BLOBS_LIST
do
    ADD_TO_WORK_DIR "e2sxxx" "system" "$blob" 0 0 644 "u:object_r:system_lib_file:s0"
done

BLOBS_LIST="
system/lib64/libeden_wrapper_system.so
system/lib64/libhigh_dynamic_range.arcsoft.so
system/lib64/liblow_light_hdr.arcsoft.so
system/lib64/libhigh_res.arcsoft.so
system/lib64/libsnap_aidl.snap.samsung.so
system/lib64/libsuperresolution.arcsoft.so
system/lib64/libsuperresolution_raw.arcsoft.so
system/lib64/libsuperresolution_wrapper_v2.camera.samsung.so
system/lib64/libsuperresolutionraw_wrapper_v2.camera.samsung.so
"
for blob in $BLOBS_LIST
do
    ADD_TO_WORK_DIR "p3sxxx" "system" "$blob" 0 0 644 "u:object_r:system_lib_file:s0" &
done

# shellcheck disable=SC2046
wait $(jobs -p) || exit 1

LOG_STEP_OUT

LOG_STEP_IN "- Adding S21 (p3sxxx) SWISP models"
DELETE_FROM_WORK_DIR "vendor" "saiv/swisp_1.0"
ADD_TO_WORK_DIR "p3sxxx" "vendor" "saiv/swisp_1.0"

BLOBS_LIST="
system/lib64/libSwIsp_core.camera.samsung.so
system/lib64/libSwIsp_wrapper_v1.camera.samsung.so
"
for blob in $BLOBS_LIST
do
    ADD_TO_WORK_DIR "p3sxxx" "system" "$blob" 0 0 644 "u:object_r:system_lib_file:s0"
done
LOG_STEP_OUT

LOG_STEP_IN "- Adding S21 (p3sxxx) SingleTake models"
DELETE_FROM_WORK_DIR "vendor" "etc/singletake"
ADD_TO_WORK_DIR "p3sxxx" "vendor" "etc/singletake"

BLOBS_LIST="
system/priv-app/SingleTakeService/SingleTakeService.apk
system/cameradata/singletake/service-feature.xml
"
for blob in $BLOBS_LIST
do
    ADD_TO_WORK_DIR "p3sxxx" "system" "$blob" 0 0 644 "u:object_r:system_file:s0" &
done

# shellcheck disable=SC2046
wait $(jobs -p) || exit 1

LOG_STEP_OUT
