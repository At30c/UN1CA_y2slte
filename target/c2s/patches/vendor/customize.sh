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

# The stock c2s firmware ships the UWB VINTF fragment without its
# security.selinux xattr, so extract_fw.sh reproduces it in
# file_context-vendor as a line holding a single field. mkfs.erofs then
# refuses the whole vendor image with "line N is missing fields". Every other
# vendor VINTF manifest is a vendor_configs_file, so fill the gap in.
VENDOR_FILE_CONTEXT="$WORK_DIR/configs/file_context-vendor"
UWB_MANIFEST="/vendor/etc/vintf/manifest/android\\.hardware\\.uwb\\.xml"

if [ -f "$VENDOR_FILE_CONTEXT" ]; then
    if awk -v entry="$UWB_MANIFEST" \
            'NF < 2 && $1 == entry { print $1 " u:object_r:vendor_configs_file:s0"; next } { print }' \
            "$VENDOR_FILE_CONTEXT" > "$VENDOR_FILE_CONTEXT.tmp" &&
            ! cmp -s "$VENDOR_FILE_CONTEXT" "$VENDOR_FILE_CONTEXT.tmp"; then
        LOG "- Filling the missing SELinux context in $UWB_MANIFEST"
        mv -f "$VENDOR_FILE_CONTEXT.tmp" "$VENDOR_FILE_CONTEXT"
    else
        rm -f "$VENDOR_FILE_CONTEXT.tmp"
    fi

    # Catch any other incomplete entry here: mkfs.erofs only reports the
    # line number, twelve minutes into the build.
    INCOMPLETE_CONTEXTS="$(awk 'NF < 2 { print }' "$VENDOR_FILE_CONTEXT")"
    if [ -n "$INCOMPLETE_CONTEXTS" ]; then
        LOGE "Incomplete file_context entries in /vendor: $INCOMPLETE_CONTEXTS"
        return 1
    fi
fi

SET_PROP "vendor" "ro.vendor.uwb.feature.chipname" "sr100"
LOG_STEP_OUT

unset VENDOR_FILE_CONTEXT UWB_MANIFEST INCOMPLETE_CONTEXTS
