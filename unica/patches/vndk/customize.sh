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

PATCH_VNDK_CGROUP_RUNTIME() {
    local PATCH_ROOT="$TMP_DIR/vndk-cgroup-runtime"
    local DECODED="$PATCH_ROOT/decoded"
    local MOUNT_DIR="$PATCH_ROOT/mnt"
    local PAYLOAD="$DECODED/unknown/apex_payload"
    local ORIGINAL_APEX="$PATCH_ROOT/original.apex"
    local FS_CONFIG="$PATCH_ROOT/fs_config"
    local FILE_CONTEXTS="$PATCH_ROOT/file_contexts"
    local VERIFY_IMAGE="$PATCH_ROOT/verify.img"
    local TARGET_ROOT="$FW_DIR/$(tr "/" "_" <<< "$TARGET_FW_SOURCE")"
    local DONOR32="$TARGET_ROOT/system/system/lib/libcgrouprc.so"
    local DONOR64="$TARGET_ROOT/system/system/lib64/libcgrouprc.so"
    local SALT CERT_PREFIX BUILT_APEX

    # libprocessgroup.so in the legacy VNDK v30 namespace has a versioned
    # dependency on LIBCGROUPRC_30.  Installing this library in /system/lib*
    # is insufficient: the vndk linker namespace only searches the APEX and
    # therefore still aborts vendor audio, DRM and OMX services.
    if [ ! -f "$DONOR32" ] || [ ! -f "$DONOR64" ]; then
        ABORT "Target VNDK donor is missing ARM32/ARM64 libcgrouprc.so: $TARGET_ROOT"
        return 1
    fi
    if ! readelf -V "$DONOR32" 2>/dev/null | grep -q "LIBCGROUPRC_30" || \
            ! readelf -V "$DONOR64" 2>/dev/null | grep -q "LIBCGROUPRC_30"; then
        ABORT "Target libcgrouprc.so does not export the VNDK v30 ABI"
        return 1
    fi

    if ! sudo -n -v &> /dev/null && ! sudo -v; then
        LOGE "Root permissions are required to rebuild the VNDK APEX"
        return 1
    fi

    if mountpoint -q "$MOUNT_DIR"; then
        sudo umount "$MOUNT_DIR" || return 1
    fi
    sudo rm -rf "$PATCH_ROOT"
    mkdir -p "$PATCH_ROOT" "$MOUNT_DIR"

    LOG "- Extracting VNDK v$TARGET_VNDK_VERSION APEX"
    if unzip -l "$VNDK_APEX" original_apex 2> /dev/null | grep -q "original_apex"; then
        unzip -p "$VNDK_APEX" original_apex > "$ORIGINAL_APEX"
    else
        cp -a "$VNDK_APEX" "$ORIGINAL_APEX"
    fi
    if [ ! -s "$ORIGINAL_APEX" ]; then
        LOGE "Failed to extract the VNDK APEX"
        return 1
    fi

    LOG "- Decoding VNDK v$TARGET_VNDK_VERSION APEX payload"
    EVAL "apktool d -j \"$(nproc)\" -o \"$DECODED\" -r \"$ORIGINAL_APEX\""
    mkdir -p "$PAYLOAD"
    if ! sudo mount -o ro "$DECODED/unknown/apex_payload.img" "$MOUNT_DIR"; then
        LOGE "Failed to mount the VNDK APEX payload"
        return 1
    fi
    if ! sudo cp -a -T "$MOUNT_DIR" "$PAYLOAD"; then
        sudo umount "$MOUNT_DIR" || true
        LOGE "Failed to copy the VNDK APEX payload"
        return 1
    fi

    # An incremental build may already contain this repair.  Avoid rebuilding
    # and resigning a valid APEX a second time.
    if [ -f "$PAYLOAD/lib/libcgrouprc.so" ] && \
            [ -f "$PAYLOAD/lib64/libcgrouprc.so" ]; then
        sudo umount "$MOUNT_DIR" || return 1
        sudo rm -rf "$PATCH_ROOT"
        LOG "  - VNDK v$TARGET_VNDK_VERSION already contains both cgroup clients"
        return 0
    fi

    # Preserve the original payload metadata before adding files that do not
    # carry SELinux xattrs in the host filesystem.
    if ! sudo find "$MOUNT_DIR" \
            -exec stat -c "%n %u %g %a capabilities=0x0" "{}" \; > "$FS_CONFIG"; then
        sudo umount "$MOUNT_DIR" || true
        LOGE "Failed to record VNDK APEX fs_config metadata"
        return 1
    fi
    if ! sudo find "$MOUNT_DIR" -exec sh -c '
            for path do
                label="$(getfattr -n security.selinux --only-values -h --absolute-names "$path")" || exit 1
                printf "%s %s\n" "$path" "$label"
            done
        ' sh "{}" + > "$FILE_CONTEXTS"; then
        sudo umount "$MOUNT_DIR" || true
        LOGE "Failed to record VNDK APEX SELinux contexts"
        return 1
    fi
    sudo umount "$MOUNT_DIR" || return 1

    sed -i -e "s|$MOUNT_DIR |/ |g" -e "s|$MOUNT_DIR||g" "$FILE_CONTEXTS"
    sed -i -e "s|$MOUNT_DIR | |g" -e "s|$MOUNT_DIR/||g" "$FS_CONFIG"
    sed -i -e 's|\.|\\.|g' -e 's|+|\\+|g' -e 's|\[|\\[|g' \
        -e 's|\]|\\]|g' -e 's|\*|\\*|g' "$FILE_CONTEXTS"

    LOG "- Adding target VNDK v30-compatible libcgrouprc.so to both payload ABIs"
    sudo install -o 1000 -g 1000 -m 0644 "$DONOR32" "$PAYLOAD/lib/libcgrouprc.so"
    sudo install -o 1000 -g 1000 -m 0644 "$DONOR64" "$PAYLOAD/lib64/libcgrouprc.so"
    printf 'lib/libcgrouprc.so 1000 1000 644 capabilities=0x0\n' >> "$FS_CONFIG"
    printf 'lib64/libcgrouprc.so 1000 1000 644 capabilities=0x0\n' >> "$FS_CONFIG"
    printf '/lib/libcgrouprc\\.so u:object_r:system_lib_file:s0\n' >> "$FILE_CONTEXTS"
    printf '/lib64/libcgrouprc\\.so u:object_r:system_lib_file:s0\n' >> "$FILE_CONTEXTS"
    sort -u -o "$FS_CONFIG" "$FS_CONFIG"
    sort -u -o "$FILE_CONTEXTS" "$FILE_CONTEXTS"
    sudo chown -hR "$(id -u):$(id -g)" "$PATCH_ROOT"

    rm -f "$DECODED/unknown/apex_payload.img"
    "$SRC_DIR/scripts/build_fs_image.sh" ext4 --no-avb \
        -o "$DECODED/unknown/apex_payload.img" -p system \
        "$PAYLOAD" "$FILE_CONTEXTS" "$FS_CONFIG" > /dev/null || return 1
    rm -rf "$PAYLOAD" "$FILE_CONTEXTS" "$FS_CONFIG"

    SALT="$(sha256sum "$DECODED/unknown/apex_manifest.pb" | cut -d ' ' -f 1)"
    EVAL "avbtool add_hashtree_footer --do_not_generate_fec --algorithm SHA256_RSA4096 --hash_algorithm sha256 --key \"$SRC_DIR/security/avb/testkey_rsa4096.pem\" --prop \"apex.key:com.android.vndk.v$TARGET_VNDK_VERSION\" --salt \"$SALT\" --image \"$DECODED/unknown/apex_payload.img\""
    EVAL "avbtool extract_public_key --key \"$SRC_DIR/security/avb/testkey_rsa4096.pem\" --output \"$DECODED/unknown/apex_pubkey\""
    mkdir -p "$DECODED/build/apk"
    cp -a "$DECODED/original/META-INF" "$DECODED/build/apk/META-INF"
    EVAL "apktool b -j \"$(nproc)\" \"$DECODED\""

    BUILT_APEX="$DECODED/dist/com.android.vndk.v$TARGET_VNDK_VERSION.apex"
    [ -f "$BUILT_APEX" ] || BUILT_APEX="$DECODED/dist/original.apex"
    if [ ! -f "$BUILT_APEX" ]; then
        LOGE "Rebuilt VNDK APEX was not produced"
        return 1
    fi
    CERT_PREFIX=aosp
    $ROM_IS_OFFICIAL && CERT_PREFIX=unica
    EVAL "signapk -a 4096 --align-file-size \"$SRC_DIR/security/${CERT_PREFIX}_platform.x509.pem\" \"$SRC_DIR/security/${CERT_PREFIX}_platform.pk8\" \"$BUILT_APEX\" \"$BUILT_APEX.signed\""
    mv -f "$BUILT_APEX.signed" "$VNDK_APEX"

    # Validate the actual rebuilt payload, rather than only the outer ZIP.
    unzip -p "$VNDK_APEX" apex_payload.img > "$VERIFY_IMAGE"
    for VNDK_LIB in /lib/libcgrouprc.so /lib64/libcgrouprc.so; do
        if ! debugfs -R "stat $VNDK_LIB" "$VERIFY_IMAGE" 2>/dev/null | grep -q "Inode:"; then
            LOGE "Rebuilt VNDK APEX is missing $VNDK_LIB"
            return 1
        fi
    done
    sudo rm -rf "$PATCH_ROOT"
    LOG "  - VNDK v$TARGET_VNDK_VERSION payload now exports both LIBCGROUPRC_30 clients"
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

    # This dependency is specific to the legacy Exynos 990 VNDK v30 vendor;
    # do not inject a v30 symbol set into other targets sharing this module.
    if [ "$TARGET_VNDK_VERSION" = "30" ]; then
        PATCH_VNDK_CGROUP_RUNTIME || return 1
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
unset -f ADD_TARGET_VNDK_APEX PATCH_VNDK_CGROUP_RUNTIME PATCH_VNDK_MANIFEST \
    VALIDATE_LEGACY_VNDK
