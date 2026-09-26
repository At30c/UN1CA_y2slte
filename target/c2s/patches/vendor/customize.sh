LOG_STEP_IN "- Updating UWB HAL"

DELETE_FROM_WORK_DIR "vendor" "etc/init/nxp-uwb-service.rc"

BLOBS_LIST="
bin/hw/vendor.samsung.hardware.uwb@1.0-service
etc/libuwb-countrycode.conf
etc/libuwb-feature.conf
etc/libuwb-nxp.conf
etc/libuwb-uci.conf
etc/init/init.vendor.uwb.rc
etc/init/vendor.samsung.hardware.uwb@1.0-service.rc
firmware/uwb
lib64/uwb_uci.hal.so
lib64/libmemunreachable.so
"
for blob in $BLOBS_LIST
do
    ADD_TO_WORK_DIR "p3sxxx" "vendor" "$blob"
done

# apply_modules.sh imports this module's whole vendor/ tree with
# ADD_TO_WORK_DIR "<module>" "vendor" ".", so the canned file_context-vendor
# next to this script is what labels the blobs it ships. Files the stock
# firmware does not already label would otherwise get an empty context and
# mkfs.erofs would refuse the vendor image with "line N is missing fields".
INCOMPLETE_CONTEXTS="$(awk 'NF < 2 { print }' "$WORK_DIR/configs/file_context-vendor")"
if [ -n "$INCOMPLETE_CONTEXTS" ]; then
    LOGE "Incomplete file_context entries in /vendor: $INCOMPLETE_CONTEXTS"
    return 1
fi

SET_PROP "vendor" "ro.vendor.uwb.feature.chipname" "sr100"
LOG_STEP_OUT

unset INCOMPLETE_CONTEXTS
