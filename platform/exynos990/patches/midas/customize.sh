# Keep Photo Remaster and MIDAS on one coherent S24+ source-firmware stack.
# This module intentionally does not accept a donor override: mixing the S24+
# engine with p3sxxx MIDAS caused a native crash in midas_proc/SetEnhSequence.
MIDAS_SOURCE="$SOURCE_FIRMWARE"

if [ -z "$MIDAS_SOURCE" ]; then
    ABORT "SOURCE_FIRMWARE is not configured for the source MIDAS stack."
    return 1
fi

LOG_STEP_IN "- Restoring source-firmware (S24+) MIDAS"
DELETE_FROM_WORK_DIR "vendor" "etc/midas"
DELETE_FROM_WORK_DIR "vendor" "etc/VslMesDetector"
ADD_TO_WORK_DIR "$MIDAS_SOURCE" "vendor" "etc/midas"
ADD_TO_WORK_DIR "$MIDAS_SOURCE" "vendor" "etc/VslMesDetector"
LOG_STEP_OUT

# The source-firmware config has no Exynos 990 model entry. Without an
# explicit fallback, the DNN interface selects its generic Adreno/TFLite
# branch and requests models that are not shipped by the S24+ firmware. Keep
# the S24+ engine/config, but provide the generic Lite model assets used by
# the existing Samsung MIDAS implementation and mark them for this SoC.
LOG_STEP_IN "- Adding Exynos 990 MIDAS Lite fallback models"
for MIDAS_MODEL in \
    "SRIBMidas_aiUPSCALER_2X_LITE_V100_INT8.tflite" \
    "SRIBMidas_aiUPSCALER_3X_LITE_V100_INT8.tflite" \
    "SRIBMidas_aiUPSCALER_4X_LITE_V100_INT8.tflite"; do
    ADD_TO_WORK_DIR "p3sxxx" "vendor" "etc/midas/$MIDAS_MODEL" \
        0 0 644 "u:object_r:vendor_configs_file:s0"
done
EVAL "python3 \"$SRC_DIR/platform/exynos990/patches/midas/patch_midas_config.py\" \"$WORK_DIR/vendor/etc/midas/midas_config.json\""
LOG_STEP_OUT

LOG_STEP_IN "- Restoring source-firmware (S24+) Photo Remaster Service"
DELETE_FROM_WORK_DIR "system" "system/priv-app/PhotoRemasterService/oat"
ADD_TO_WORK_DIR "$MIDAS_SOURCE" "system" "system/priv-app/PhotoRemasterService/PhotoRemasterService.apk"
LOG_STEP_OUT

LOG_STEP_IN "- Restoring source-firmware (S24+) MIDAS libraries"
ADD_TO_WORK_DIR "$MIDAS_SOURCE" "system" "system/lib64/libmidas_core.camera.samsung.so"
ADD_TO_WORK_DIR "$MIDAS_SOURCE" "system" "system/lib64/libmidas_DNNInterface.camera.samsung.so"
LOG_STEP_OUT

unset MIDAS_SOURCE
