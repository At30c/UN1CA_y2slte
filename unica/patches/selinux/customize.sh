# UN1CA SELinux entries removal list
# - Append new type entries to the ENTRIES list
# - Add the EXACT type entry, DO NOT just add a common pattern (eg. "fabriccrypto", "fabriccrypto_exec" and NOT just "fabriccrypto")
# - DO NOT add the API version at the end of the entry (eg. "fabriccrypto" and NOT "fabriccrypto_30_0")
# - DO NOT add any parenthesis or statements (eg. "fabriccrypto" and NOT "expanttypeattribute ... (fabriccrypto)")
# - DO NOT add unnecessary types or remove the existing ones unless they aren't necessary anymore for all devices

# One UI 8.0 additions
ENTRIES+="
heatmap_default
heatmap_default_exec
"

DUPLICATES+="
init.svc.vendor.wvkprov_server_hal
"

# One UI 7.0 additions
ENTRIES+="
attiqi_app
attiqi_app_data_file
ker_app
kpp_app
kpp_data_file
"

# One UI 6.1.1 additions
ENTRIES+="
hal_dsms_default
hal_dsms_default_exec
proc_compaction_proactiveness
sbauth
sbauth_exec
"

# One UI 5.1.1 additions
ENTRIES+="
audiomirroring
audiomirroring_exec
audiomirroring_service
fabriccrypto
fabriccrypto_exec
fabriccrypto_data_file
hal_dsms_service
uwb_regulation_skip_prop
"

# [
GET_SYSTEM_EXT()
{
    if $TARGET_OS_BUILD_SYSTEM_EXT_PARTITION; then
        echo "system_ext"
    else
        echo "system/system/system_ext"
    fi
}

CIL_NAME="$(head -n 1 "$WORK_DIR/vendor/etc/selinux/plat_sepolicy_vers.txt")"
PATCHED=false
SYSTEM_EXT_SELINUX="$WORK_DIR/$(GET_SYSTEM_EXT)/etc/selinux"

# Android 17 sources no longer ship the Android 10/11 compatibility mappings
# required by the Exynos 990 vendor policy. They must exist in system_ext
# before the removal pass below reads the target vendor's CIL version.
for LEGACY_MAPPING in 29.0.cil 29.0.compat.cil 30.0.cil 30.0.compat.cil; do
    if [ ! -f "$SYSTEM_EXT_SELINUX/mapping/$LEGACY_MAPPING" ]; then
        ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system_ext" \
            "etc/selinux/mapping/$LEGACY_MAPPING" \
            0 0 644 "u:object_r:system_file:s0" || return 1
        PATCHED=true
    fi
done

CIL_FILE="$SYSTEM_EXT_SELINUX/mapping/$CIL_NAME.cil"
if [ ! -f "$CIL_FILE" ]; then
    ABORT "Missing system_ext SELinux mapping for target vendor policy $CIL_NAME"
fi

VENDOR_API_LIST="$(find "$SYSTEM_EXT_SELINUX/mapping" -type f -printf "%f\n" | \
                    sed '/.compat./d' | sed 's/.cil//' | sed 's/\./_/' | sort)"
# ]

for e in $ENTRIES; do
    if grep -q -F "($e)" "$CIL_FILE" || \
         grep -q -F "${e}_${CIL_NAME//./_}" "$CIL_FILE"; then
        # the problematic entry is currently present in system_ext, check if we need to remove it
        if ! grep -q -F "(type $e)" "$WORK_DIR/vendor/etc/selinux/plat_pub_versioned.cil"; then
            PATCHED=true
            # the problematic entry is not supported by the target device
            LOG "- \"$e\" SELinux entry not supported. Removing"
            sed -i "/($e)/d" "$CIL_FILE"
            for a in $VENDOR_API_LIST; do
                sed -i "/${e}_${a}/d" "$CIL_FILE"
            done
            if grep -q "genfscon.*$e" "$SYSTEM_EXT_SELINUX/system_ext_sepolicy.cil"; then
                sed -i "/genfscon.*$e/d" "$SYSTEM_EXT_SELINUX/system_ext_sepolicy.cil"
            fi
            if grep -q "genfscon.*$e" "$WORK_DIR/system/system/etc/selinux/plat_sepolicy.cil"; then
                sed -i "/genfscon.*$e/d" "$WORK_DIR/system/system/etc/selinux/plat_sepolicy.cil"
            fi
        fi
    fi
done

for e in $DUPLICATES; do
    if grep -q "^$e.*" "$SYSTEM_EXT_SELINUX/system_ext_property_contexts"; then
        # the problematic entry is currently present in system_ext, check if we need to remove it
        if grep -q "^$e.*" "$WORK_DIR/vendor/etc/selinux/vendor_property_contexts"; then
            PATCHED=true
            # the problematic entry is found in target vendor
            LOG "- \"$e\" SELinux duplicate entry found. Removing"
            sed -i "s/^$e/#SEC_DUPLICATE: $e/g" "$WORK_DIR/vendor/etc/selinux/vendor_property_contexts"
        fi
    fi
done

# New source releases may omit the legacy platform mappings. Import only
# missing files from the target firmware, retaining the source's own mappings.
for LEGACY_MAPPING in 29.0.cil 29.0.compat.cil 30.0.cil 30.0.compat.cil; do
    if [ ! -f "$WORK_DIR/system/system/etc/selinux/mapping/$LEGACY_MAPPING" ]; then
        ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" \
            "system/etc/selinux/mapping/$LEGACY_MAPPING" \
            0 0 644 "u:object_r:system_file:s0" || return 1
        PATCHED=true
    fi
done

if ! $PATCHED; then
    LOG "\033[0;33m! Nothing to do\033[0m"
fi

unset ENTRIES DUPLICATES CIL_NAME CIL_FILE PATCHED SYSTEM_EXT_SELINUX VENDOR_API_LIST LEGACY_MAPPING
unset -f GET_SYSTEM_EXT
