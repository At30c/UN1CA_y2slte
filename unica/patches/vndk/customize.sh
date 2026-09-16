TARGET_VNDK_VERSION="$TARGET_BOARD_API_LEVEL"
TARGET_FW_SOURCE="$(cut -d "/" -f 1,2 <<< "$TARGET_FIRMWARE")"

if $TARGET_OS_BUILD_SYSTEM_EXT_PARTITION; then
    SYS_EXT_DIR="$WORK_DIR/system_ext"
else
    SYS_EXT_DIR="$WORK_DIR/system/system/system_ext"
fi

VNDK_APEX_REL="apex/com.android.vndk.v$TARGET_VNDK_VERSION.apex"
VNDK_APEX="$SYS_EXT_DIR/$VNDK_APEX_REL"
VINTF_MANIFEST="$SYS_EXT_DIR/etc/vintf/manifest.xml"

# [
ADD_TARGET_VNDK_APEX() {
    local STOCK_APEX
    STOCK_APEX="$FW_DIR/$(tr "/" "_" <<< "$TARGET_FW_SOURCE")/system/system/system_ext/$VNDK_APEX_REL"

    # Prefer the target stock firmware so the snapshot, signing lineage and
    # vendor ABI all come from the same Samsung release family.
    if [ -f "$STOCK_APEX" ]; then
        ADD_TO_WORK_DIR "$TARGET_FW_SOURCE" "system_ext" "$VNDK_APEX_REL" \
            0 0 644 "u:object_r:system_file:s0"
        return $?
    fi

    # Fallbacks for targets whose extracted stock system is unavailable.
    case "$TARGET_VNDK_VERSION" in
        "30") ADD_TO_WORK_DIR "a73xqxx" "system_ext" "$VNDK_APEX_REL" 0 0 644 "u:object_r:system_file:s0" ;;
        "31") ADD_TO_WORK_DIR "b0qxxx" "system_ext" "$VNDK_APEX_REL" 0 0 644 "u:object_r:system_file:s0" ;;
        "32") ADD_TO_WORK_DIR "b4qxxx" "system_ext" "$VNDK_APEX_REL" 0 0 644 "u:object_r:system_file:s0" ;;
        "33") ADD_TO_WORK_DIR "dm1qxxx" "system_ext" "$VNDK_APEX_REL" 0 0 644 "u:object_r:system_file:s0" ;;
        "34") ADD_TO_WORK_DIR "gta9pxxx" "system_ext" "$VNDK_APEX_REL" 0 0 644 "u:object_r:system_file:s0" ;;
        *) ABORT "No APEX blob available for VNDK $TARGET_VNDK_VERSION" ;;
    esac
}

PATCH_VNDK_MANIFEST() {
    if [ ! -f "$VINTF_MANIFEST" ]; then
        ABORT "Framework VINTF manifest not found: ${VINTF_MANIFEST//$WORK_DIR/}"
        return 1
    fi

    LOG "- Registering VNDK $TARGET_VNDK_VERSION in ${VINTF_MANIFEST//$WORK_DIR/}"
    if grep -q '<vendor-ndk>' "$VINTF_MANIFEST"; then
        EVAL "sed -i '/<vendor-ndk>/,/<\\/vendor-ndk>/ s|<version>[^<]*</version>|<version>$TARGET_VNDK_VERSION</version>|' '$VINTF_MANIFEST'" || return 1
    else
        EVAL "sed -i '/<\\/manifest>/i\\    <vendor-ndk>\\n        <version>$TARGET_VNDK_VERSION</version>\\n    </vendor-ndk>' '$VINTF_MANIFEST'" || return 1
    fi
}

VALIDATE_LEGACY_VNDK() {
    local APEX_SIZE VENDOR_SDK VNDK_COUNT

    if [ ! -f "$VNDK_APEX" ]; then
        ABORT "VNDK $TARGET_VNDK_VERSION APEX was not installed"
        return 1
    fi

    APEX_SIZE="$(wc -c < "$VNDK_APEX")"
    if [ "$APEX_SIZE" -lt 1048576 ]; then
        ABORT "VNDK APEX is unexpectedly small ($APEX_SIZE bytes)"
        return 1
    fi

    if command -v unzip > /dev/null 2>&1 && ! unzip -tq "$VNDK_APEX" > /dev/null; then
        ABORT "VNDK APEX container validation failed"
        return 1
    fi

    VNDK_COUNT="$(grep -c '<vendor-ndk>' "$VINTF_MANIFEST")"
    if [ "$VNDK_COUNT" -ne 1 ] || ! grep -q "<version>$TARGET_VNDK_VERSION</version>" "$VINTF_MANIFEST"; then
        ABORT "Framework VINTF does not contain exactly one VNDK $TARGET_VNDK_VERSION declaration"
        return 1
    fi

    if [[ "$(GET_PROP vendor ro.vndk.version)" != "$TARGET_VNDK_VERSION" ]]; then
        ABORT "ro.vndk.version does not match target VNDK $TARGET_VNDK_VERSION"
        return 1
    fi

    VENDOR_SDK="$(GET_PROP vendor ro.vendor.build.version.sdk)"
    if [ -n "$VENDOR_SDK" ] && [ "$VENDOR_SDK" -ne "$TARGET_PLATFORM_SDK_VERSION" ]; then
        ABORT "Vendor SDK $VENDOR_SDK does not match target platform SDK $TARGET_PLATFORM_SDK_VERSION"
        return 1
    fi

    LOG "  - Legacy VNDK $TARGET_VNDK_VERSION compatibility validated ($APEX_SIZE bytes)"
}
# ]

if [ "$TARGET_VNDK_VERSION" -le 34 ]; then
    if [ ! -f "$VNDK_APEX" ] || [ "$SOURCE_BOARD_API_LEVEL" != "$TARGET_VNDK_VERSION" ]; then
        if [ "$SOURCE_BOARD_API_LEVEL" -le 34 ] && \
                [ -f "$SYS_EXT_DIR/apex/com.android.vndk.v$SOURCE_BOARD_API_LEVEL.apex" ]; then
            DELETE_FROM_WORK_DIR "system_ext" "apex/com.android.vndk.v$SOURCE_BOARD_API_LEVEL.apex"
        fi
        ADD_TARGET_VNDK_APEX || return 1
    fi

    PATCH_VNDK_MANIFEST || return 1

    # Android 16+ linkerconfig still probes this target-specific allowlist for
    # legacy vendors. Restore the stock file instead of leaving the namespace
    # configuration incomplete.
    TARGET_CORE_VARIANT="$FW_DIR/$(tr "/" "_" <<< "$TARGET_FW_SOURCE")/system/system/etc/vndkcorevariant.libraries.txt"
    if [ -f "$TARGET_CORE_VARIANT" ]; then
        ADD_TO_WORK_DIR "$TARGET_FW_SOURCE" "system" "system/etc/vndkcorevariant.libraries.txt" \
            0 0 644 "u:object_r:system_file:s0" || return 1
    else
        LOG "\033[0;33m! Target vndkcorevariant.libraries.txt is unavailable\033[0m"
    fi

    # Preserve the old vendor ABI level even when the framework donor no
    # longer ships a current-version VNDK APEX.
    SET_PROP "vendor" "ro.vndk.version" "$TARGET_VNDK_VERSION" || return 1
    VALIDATE_LEGACY_VNDK || return 1
elif [ "$SOURCE_BOARD_API_LEVEL" -le 34 ]; then
    if [ -f "$SYS_EXT_DIR/apex/com.android.vndk.v$SOURCE_BOARD_API_LEVEL.apex" ]; then
        DELETE_FROM_WORK_DIR "system_ext" "apex/com.android.vndk.v$SOURCE_BOARD_API_LEVEL.apex"
    fi
    if [ -f "$VINTF_MANIFEST" ]; then
        EVAL "sed -i '/<vendor-ndk>/,/<\\/vendor-ndk>/d' '$VINTF_MANIFEST'" || return 1
    fi
fi

unset TARGET_CORE_VARIANT TARGET_FW_SOURCE TARGET_VNDK_VERSION
unset SYS_EXT_DIR VINTF_MANIFEST VNDK_APEX VNDK_APEX_REL
unset -f ADD_TARGET_VNDK_APEX PATCH_VNDK_MANIFEST VALIDATE_LEGACY_VNDK
