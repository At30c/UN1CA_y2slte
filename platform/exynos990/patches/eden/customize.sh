LOG_STEP_IN "- Fixing EDEN debug logging"

# Remove log.tag.EDEN=INFO from vendor/build.prop
VENDOR_BUILD_PROP="$WORK_DIR/vendor/build.prop"
if [ -f "$VENDOR_BUILD_PROP" ]; then
    LOG "- Removing \"log.tag.EDEN=INFO\" from vendor/build.prop"
    EVAL "sed -i '/^log\.tag\.EDEN=INFO$/d' \"$VENDOR_BUILD_PROP\""
fi

# Remove log.tag.EDEN=INFO from system/system/build.prop
SYSTEM_BUILD_PROP="$WORK_DIR/system/system/build.prop"
if [ -f "$SYSTEM_BUILD_PROP" ]; then
    LOG "- Removing \"log.tag.EDEN=INFO\" from system/system/build.prop"
    EVAL "sed -i '/^log\.tag\.EDEN=INFO$/d' \"$SYSTEM_BUILD_PROP\""
fi

LOG_STEP_OUT

if [[ "$SOURCE_PLATFORM_SDK_VERSION" -ge 37 ]]; then
    LOG_STEP_IN "- Restoring the target EDEN HIDL system bridge"

    # The S24+ source contributes the Android 17 AIDL EDEN stub, while the
    # Exynos 990 vendor service is still
    # vendor.samsung_slsi.hardware.eden_runtime@1.0 (HIDL).  Keeping the
    # source system bridge makes model cleanup call the AIDL interface against
    # a HIDL service and is what produces the eden_runtime SIGSEGV/restart
    # sequence seen in the boot capture.  Restore the three matched target
    # system-side libraries as a unit; do not mix one of them with the source
    # AIDL stub.
    EDEN_SYSTEM_BLOBS="
system/lib64/libeden_nn_on_system.so
system/lib64/libeden_rt_stub.edensdk.samsung.so
system/lib64/vendor.samsung_slsi.hardware.eden_runtime@1.0.so
"
    for blob in $EDEN_SYSTEM_BLOBS; do
        ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "$blob" 0 0 644 "u:object_r:system_lib_file:s0"
    done

    LOG_STEP_OUT
    unset EDEN_SYSTEM_BLOBS
fi

LOG_STEP_IN "- Patching libvpl.so (64-bit only)"

LIBVPL_64="$WORK_DIR/vendor/lib64/libvpl.so"
PATCH_SCRIPT="$SRC_DIR/platform/exynos990/patches/eden/patch_libvpl_unload.py"

if [ ! -f "$PATCH_SCRIPT" ]; then
    ABORT "patch_libvpl_unload.py not found: ${PATCH_SCRIPT//$SRC_DIR\//}"
fi

if [ ! -f "$LIBVPL_64" ]; then
    LOG "\033[0;33m! vendor/lib64/libvpl.so not found, skipping...\033[0m"
else
    LOG "- Patching vendor/lib64/libvpl.so (vplUnload → immediate return)"
    EVAL "python3 \"$PATCH_SCRIPT\" \"$LIBVPL_64\""
fi

LOG_STEP_OUT
