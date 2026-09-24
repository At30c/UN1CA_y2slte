# Adapted from the downloaded Exynos 2100 module. The early order makes
# these libraries available to subsequent camera and WFD compatibility fixes.
if [ "$SOURCE_PLATFORM_SDK_VERSION" -lt 36 ]; then
    LOG "- Source does not require the multilib compatibility runtime"
    return 0
fi

EXYNOS990_RUNTIME32_APEX_MODE="${EXYNOS990_RUNTIME32_APEX_MODE:-merged}"
case "$EXYNOS990_RUNTIME32_APEX_MODE" in
    merged|source_apex)
        ;;
    *)
        LOGE "Invalid EXYNOS990_RUNTIME32_APEX_MODE: $EXYNOS990_RUNTIME32_APEX_MODE"
        return 1
        ;;
esac

INSTALL_DESIX_RUNTIME32_STANDALONE()
{
    local DONOR_APEX="$SRC_DIR/prebuilts/samsung/r11sxxx/system/apex/com.android.runtime.apex"
    local RUNTIME_ROOT="$TMP_DIR/desixtification-runtime32-standalone"
    local DECODED="$RUNTIME_ROOT/donor"
    local MOUNT_DIR="$RUNTIME_ROOT/mnt"
    local BIONIC_LIB
    local DEST
    local RUNTIME_LINKER_FOUND=false

    [ -f "$DONOR_APEX" ] || {
        LOGE "Missing r11s Runtime APEX for standalone ARM32 compatibility"
        return 1
    }
    if ! sudo -n -v &> /dev/null && ! sudo -v; then
        LOGE "Root permissions are required to extract the ARM32 Runtime payload"
        return 1
    fi

    sudo rm -rf "$RUNTIME_ROOT"
    mkdir -p "$RUNTIME_ROOT" "$MOUNT_DIR"
    LOG "- Extracting standalone ARM32 linker/Bionic from r11s Runtime"
    EVAL "apktool d -j \"$(nproc)\" -o \"$DECODED\" -r \"$DONOR_APEX\""
    sudo mount -o ro "$DECODED/unknown/apex_payload.img" "$MOUNT_DIR" || return 1

    mkdir -p "$WORK_DIR/system/system/bin" "$WORK_DIR/system/system/lib"
    for DEST in linker linker_asan; do
        if [ -e "$MOUNT_DIR/bin/$DEST" ] || [ -L "$MOUNT_DIR/bin/$DEST" ]; then
            [ "$DEST" = "linker" ] && RUNTIME_LINKER_FOUND=true
            sudo cp -a "$MOUNT_DIR/bin/$DEST" "$WORK_DIR/system/system/bin/$DEST" || {
                sudo umount "$MOUNT_DIR" || true
                return 1
            }
            sudo chown -h "$(id -u):$(id -g)" "$WORK_DIR/system/system/bin/$DEST"
            SET_METADATA "system" "system/bin/$DEST" 0 2000 755 \
                "u:object_r:system_linker_exec:s0" || {
                    sudo umount "$MOUNT_DIR" || true
                    return 1
                }
        fi
    done
    if ! $RUNTIME_LINKER_FOUND; then
        sudo umount "$MOUNT_DIR" || true
        LOGE "r11s Runtime APEX lacks the ARM32 linker"
        return 1
    fi

    for BIONIC_LIB in libc.so libdl.so libdl_android.so libm.so; do
        if [ ! -f "$MOUNT_DIR/lib/bionic/$BIONIC_LIB" ]; then
            sudo umount "$MOUNT_DIR" || true
            LOGE "r11s Runtime APEX lacks ARM32 Bionic $BIONIC_LIB"
            return 1
        fi
        sudo cp -a "$MOUNT_DIR/lib/bionic/$BIONIC_LIB" \
            "$WORK_DIR/system/system/lib/$BIONIC_LIB" || {
                sudo umount "$MOUNT_DIR" || true
                return 1
            }
        sudo chown -h "$(id -u):$(id -g)" "$WORK_DIR/system/system/lib/$BIONIC_LIB"
        SET_METADATA "system" "system/lib/$BIONIC_LIB" 0 0 644 \
            "u:object_r:system_lib_file:s0" || {
                sudo umount "$MOUNT_DIR" || true
                return 1
            }
    done
    sudo umount "$MOUNT_DIR" || return 1
    rm -rf "$RUNTIME_ROOT"
}

if [ "$EXYNOS990_RUNTIME32_APEX_MODE" = "merged" ]; then
LOG_STEP_IN "- Adding S23 FE ARM32 libraries and runtime"

# ADD_TO_WORK_DIR can infer metadata for individual files, but a recursive
# directory import expects every child to already exist in the donor metadata
# files.  The extracted r11s prebuilt intentionally contains only a minimal
# metadata manifest, so register the homogeneous system/lib tree here before
# importing it.  This avoids hundreds of fallback warnings and guarantees the
# permissions/labels used in the rebuilt system image.
DESIX_LIB_ROOT="$SRC_DIR/prebuilts/samsung/r11sxxx/system/lib"
while IFS= read -r -d '' DESIX_LIB_PATH; do
    DESIX_LIB_ENTRY="system/lib/${DESIX_LIB_PATH#"$DESIX_LIB_ROOT"/}"
    if [ -d "$DESIX_LIB_PATH" ]; then
        DESIX_LIB_MODE=755
    else
        DESIX_LIB_MODE=644
    fi

    if ! grep -q -F "$DESIX_LIB_ENTRY " "$WORK_DIR/configs/fs_config-system"; then
        echo "$DESIX_LIB_ENTRY 0 0 $DESIX_LIB_MODE capabilities=0x0" \
            >> "$WORK_DIR/configs/fs_config-system"
    fi

    DESIX_LIB_CONTEXT="/$(_HANDLE_SPECIAL_CHARS "$DESIX_LIB_ENTRY")"
    if ! grep -q -F "$DESIX_LIB_CONTEXT " "$WORK_DIR/configs/file_context-system"; then
        echo "$DESIX_LIB_CONTEXT u:object_r:system_lib_file:s0" \
            >> "$WORK_DIR/configs/file_context-system"
    fi
done < <(find "$DESIX_LIB_ROOT" -mindepth 1 -print0 | sort -z)

ADD_TO_WORK_DIR "r11sxxx" "system" "system/lib" 0 0 755 "u:object_r:system_lib_file:s0" || return 1
SET_METADATA "system" "system/lib" 0 0 755 "u:object_r:system_lib_file:s0" || return 1

# Never replace the complete Runtime/I18n APEX with the Android 16 donor.
# Besides ARM32, those packages also contain Bionic/ICU for ARM64. Mixing that
# ARM64 runtime with the Android 17 framework causes CFI failures (notably
# netd1shot crashing in __cfi_slowpath).  Start from the source APEX and merge
# only the missing ARM32 payload directories from r11s.
MERGE_DESIX_APEX_ARM32()
{
    local APEX_NAME="$1"
    local MERGE_BIN_LINKER="$2"
    local BASE_APEX="$WORK_DIR/system/system/apex/$APEX_NAME.apex"
    local DONOR_APEX="$SRC_DIR/prebuilts/samsung/r11sxxx/system/apex/$APEX_NAME.apex"
    local MERGE_ROOT="$TMP_DIR/desixtification-${APEX_NAME##*.}"
    local BASE_DECODED="$MERGE_ROOT/base"
    local DONOR_DECODED="$MERGE_ROOT/donor"
    local PAYLOAD="$BASE_DECODED/unknown/apex_payload"
    local MOUNT_DIR="$MERGE_ROOT/mnt"
    local FS_CONFIG="$MERGE_ROOT/fs_config"
    local FILE_CONTEXTS="$MERGE_ROOT/file_contexts"
    local SALT CERT_PREFIX BUILT_APEX ARM32_RUNTIME_BIN

    if [ ! -f "$BASE_APEX" ] || [ ! -f "$DONOR_APEX" ]; then
        LOGE "Missing base or donor APEX for $APEX_NAME"
        return 1
    fi
    if ! sudo -n -v &> /dev/null && ! sudo -v; then
        LOGE "Root permissions are required to merge $APEX_NAME"
        return 1
    fi
    if mountpoint -q "$MOUNT_DIR"; then
        sudo umount "$MOUNT_DIR" || return 1
    fi
    sudo rm -rf "$MERGE_ROOT"
    mkdir -p "$MERGE_ROOT" "$MOUNT_DIR"

    LOG "- Decoding source $APEX_NAME"
    EVAL "apktool d -j \"$(nproc)\" -o \"$BASE_DECODED\" -r \"$BASE_APEX\""
    LOG "- Decoding r11s $APEX_NAME"
    EVAL "apktool d -j \"$(nproc)\" -o \"$DONOR_DECODED\" -r \"$DONOR_APEX\""

    mkdir -p "$PAYLOAD"
    sudo mount -o ro "$BASE_DECODED/unknown/apex_payload.img" "$MOUNT_DIR" || return 1
    sudo cp -a -T "$MOUNT_DIR" "$PAYLOAD" || {
        sudo umount "$MOUNT_DIR" || true
        return 1
    }
    sudo umount "$MOUNT_DIR" || return 1

    sudo mount -o ro "$DONOR_DECODED/unknown/apex_payload.img" "$MOUNT_DIR" || return 1
    if [ ! -d "$MOUNT_DIR/lib" ]; then
        LOGE "$APEX_NAME donor has no ARM32 lib directory"
        sudo umount "$MOUNT_DIR" || true
        return 1
    fi
    sudo cp -a "$MOUNT_DIR/lib" "$PAYLOAD/" || {
        sudo umount "$MOUNT_DIR" || true
        return 1
    }
    if [ "$MERGE_BIN_LINKER" = "true" ]; then
        for ARM32_RUNTIME_BIN in linker linker_asan crash_dump32; do
            if [ -e "$MOUNT_DIR/bin/$ARM32_RUNTIME_BIN" ] || \
                    [ -L "$MOUNT_DIR/bin/$ARM32_RUNTIME_BIN" ]; then
                sudo cp -a "$MOUNT_DIR/bin/$ARM32_RUNTIME_BIN" \
                    "$PAYLOAD/bin/$ARM32_RUNTIME_BIN" || {
                        sudo umount "$MOUNT_DIR" || true
                        return 1
                    }
            fi
        done
    fi
    sudo umount "$MOUNT_DIR" || return 1
    sudo rm -rf "$PAYLOAD/lost+found"

    # Generate metadata from the merged tree, retaining labels copied from
    # both payloads. build_fs_image consumes paths relative to payload root.
    sudo find "$PAYLOAD" -exec stat -c '%n %u %g %a capabilities=0x0' '{}' \; > "$FS_CONFIG" || return 1
    sudo find "$PAYLOAD" -exec sh -c '
        for path do
            label="$(getfattr -n security.selinux --only-values -h --absolute-names "$path")" || exit 1
            printf "%s %s\n" "$path" "$label"
        done
    ' sh '{}' + > "$FILE_CONTEXTS" || return 1
    sed -i -e "s|$PAYLOAD | |g" -e "s|$PAYLOAD/||g" "$FS_CONFIG"
    sed -i -e "s|$PAYLOAD |/ |g" -e "s|$PAYLOAD||g" "$FILE_CONTEXTS"
    sed -i -e 's|\.|\\.|g' -e 's|+|\\+|g' -e 's|\[|\\[|g' \
        -e 's|\]|\\]|g' -e 's|\*|\\*|g' "$FILE_CONTEXTS"
    sort -o "$FS_CONFIG" "$FS_CONFIG"
    sort -o "$FILE_CONTEXTS" "$FILE_CONTEXTS"
    sudo chown -hR "$(whoami):$(whoami)" "$MERGE_ROOT"
    rm -f "$BASE_DECODED/unknown/apex_payload.img"

    LOG "- Rebuilding merged $APEX_NAME payload"
    "$SRC_DIR/scripts/build_fs_image.sh" ext4 --no-avb \
        -o "$BASE_DECODED/unknown/apex_payload.img" -p system \
        "$PAYLOAD" "$FILE_CONTEXTS" "$FS_CONFIG" > /dev/null || return 1
    rm -rf "$PAYLOAD" "$FILE_CONTEXTS" "$FS_CONFIG"

    SALT="$(sha256sum "$BASE_DECODED/unknown/apex_manifest.pb" | cut -d ' ' -f 1)"
    EVAL "avbtool add_hashtree_footer --do_not_generate_fec --algorithm SHA256_RSA4096 --hash_algorithm sha256 --key \"$SRC_DIR/security/avb/testkey_rsa4096.pem\" --prop \"apex.key:$APEX_NAME\" --salt \"$SALT\" --image \"$BASE_DECODED/unknown/apex_payload.img\""
    EVAL "avbtool extract_public_key --key \"$SRC_DIR/security/avb/testkey_rsa4096.pem\" --output \"$BASE_DECODED/unknown/apex_pubkey\""
    mkdir -p "$BASE_DECODED/build/apk"
    cp -a "$BASE_DECODED/original/META-INF" "$BASE_DECODED/build/apk/META-INF"
    EVAL "apktool b -j \"$(nproc)\" \"$BASE_DECODED\""
    BUILT_APEX="$BASE_DECODED/dist/$APEX_NAME.apex"
    [ -f "$BUILT_APEX" ] || BUILT_APEX="$BASE_DECODED/dist/$(basename "$BASE_APEX")"
    if [ ! -f "$BUILT_APEX" ]; then
        LOGE "Rebuilt $APEX_NAME was not produced"
        return 1
    fi
    CERT_PREFIX=aosp
    $ROM_IS_OFFICIAL && CERT_PREFIX=unica
    EVAL "signapk -a 4096 --align-file-size \"$SRC_DIR/security/${CERT_PREFIX}_platform.x509.pem\" \"$SRC_DIR/security/${CERT_PREFIX}_platform.pk8\" \"$BUILT_APEX\" \"$BUILT_APEX.signed\""
    mv -f "$BUILT_APEX.signed" "$BASE_APEX"
    rm -rf "$MERGE_ROOT"
}

MERGE_DESIX_APEX_ARM32 "com.android.runtime" true || return 1
MERGE_DESIX_APEX_ARM32 "com.android.i18n" false || return 1
# tzdata6 is byte-identical between the current source and donor; retain the
# source package so future source changes cannot be silently downgraded.
ADD_TO_WORK_DIR "r11sxxx" "system" "system/bin/bootstrap/linker" \
    0 0 755 "u:object_r:system_file:s0" || return 1
SET_METADATA "system" "system/bin/bootstrap/linker" 0 0 755 "u:object_r:system_file:s0" || return 1
# This download has no separate ASan binary. Use its ordinary linker as
# fallback, matching the non-ASan runtime links in the donor module.
ln -sfn linker "$WORK_DIR/system/system/bin/bootstrap/linker_asan" || return 1
SET_METADATA "system" "system/bin/bootstrap/linker_asan" 0 0 755 "u:object_r:system_file:s0" || return 1
for DESIX_LINK in linker linker_asan; do
    ln -sfn /apex/com.android.runtime/bin/linker "$WORK_DIR/system/system/bin/$DESIX_LINK" || return 1
    SET_METADATA "system" "system/bin/$DESIX_LINK" 0 0 755 "u:object_r:system_file:s0" || return 1
done
for DESIX_LINK in libc.so libdl.so libdl_android.so libm.so; do
    ln -sfn "/apex/com.android.runtime/lib/bionic/$DESIX_LINK" "$WORK_DIR/system/system/lib/$DESIX_LINK" || return 1
    SET_METADATA "system" "system/lib/$DESIX_LINK" 0 0 644 "u:object_r:system_lib_file:s0" || return 1
done
LOG_STEP_OUT
else
    # Keep the source S24+ Runtime/I18n/ART APEXes and do not add the donor
    # ARM32 linker or Bionic links.  A small non-Bionic exception is kept for
    # the later WFD compatibility module, which patches this library directly.
    # This is an A/B diagnostic variant for the Chromium/AppZygote crash; all
    # property fixes below remain active so the comparison is limited to the
    # runtime payload rather than an unrelated missing build input.
    LOG "- Source APEX test mode: preserving S24+ Runtime/I18n/ART APEXes"
    INSTALL_DESIX_RUNTIME32_STANDALONE || return 1
    # These target-side 32-bit framework libraries are referenced by vendor
    # sensor/GPU/minijail clients. Keep their ABI paired with the S20+ vendor;
    # libminijail/libcap are only available in the r11s ARM32 donor.
    for DESIX_TARGET_LIB in \
        android.frameworks.sensorservice@1.0.so \
        android.hardware.sensors@1.0.so \
        libGLESv3.so; do
        ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" \
            "system/lib/$DESIX_TARGET_LIB" 0 0 644 \
            "u:object_r:system_lib_file:s0" || return 1
    done
    ADD_TO_WORK_DIR "r11sxxx" "system" "system/lib/libminijail.so" \
        0 0 644 "u:object_r:system_lib_file:s0" || return 1
    ADD_TO_WORK_DIR "r11sxxx" "system" "system/lib/libcap.so" \
        0 0 644 "u:object_r:system_lib_file:s0" || return 1
    ADD_TO_WORK_DIR "r11sxxx" "system" "system/lib/libstagefright.so" \
        0 0 644 "u:object_r:system_lib_file:s0" || return 1
fi

SET_PROP "vendor" "ro.vendor.product.cpu.abilist" "arm64-v8a"
SET_PROP "vendor" "ro.vendor.product.cpu.abilist32" ""
SET_PROP "vendor" "ro.vendor.product.cpu.abilist64" "arm64-v8a"
SET_PROP "odm" "ro.odm.product.cpu.abilist" "arm64-v8a"
SET_PROP "odm" "ro.odm.product.cpu.abilist32" ""
SET_PROP "odm" "ro.odm.product.cpu.abilist64" "arm64-v8a"
SET_PROP "vendor" "ro.zygote" "zygote64"
SET_PROP "vendor" "dalvik.vm.dex2oat64.enabled" "true"
SET_PROP "system" "persist.sys.disable_rescue" "true"
unset DESIX_LINK DESIX_LIB_CONTEXT DESIX_LIB_ENTRY DESIX_LIB_MODE DESIX_LIB_PATH \
    DESIX_LIB_ROOT DESIX_TARGET_LIB
unset -f MERGE_DESIX_APEX_ARM32
unset -f INSTALL_DESIX_RUNTIME32_STANDALONE
