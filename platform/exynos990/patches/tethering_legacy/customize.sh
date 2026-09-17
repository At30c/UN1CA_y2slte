SKIPUNZIP=1

CAPEX="$WORK_DIR/system/system/apex/com.google.android.tethering_compressed.apex"
PATCH_TMP="$TMP_DIR/tethering_legacy"
DECODED="$PATCH_TMP/decoded"
PAYLOAD="$DECODED/unknown/apex_payload"

if [ ! -f "$CAPEX" ]; then
    LOGE "Tethering CAPEX not found: ${CAPEX//$WORK_DIR/}"
    return 1
fi

if ! sudo -n -v &> /dev/null; then
    LOG "\033[0;33m! Root permissions are required to unpack the Tethering APEX\033[0m"
    if ! sudo -v 2> /dev/null; then
        LOGE "Root permissions are required to unpack the Tethering APEX"
        return 1
    fi
fi

# A terminated build may leave the read-only payload mounted below PATCH_TMP.
# Unmount it before removing the previous temporary tree.
if mountpoint -q "$PATCH_TMP/mnt"; then
    LOGW "Unmounting stale Tethering APEX payload from a previous build"
    if ! sudo umount "$PATCH_TMP/mnt"; then
        LOGE "Failed to unmount stale Tethering APEX payload: ${PATCH_TMP//$SRC_DIR/}/mnt"
        return 1
    fi
fi

rm -rf "$PATCH_TMP"
mkdir -p "$PATCH_TMP"

LOG "- Extracting original Tethering APEX"
if unzip -l "$CAPEX" original_apex 2> /dev/null | grep -q "original_apex"; then
    unzip -p "$CAPEX" original_apex > "$PATCH_TMP/original.apex"
else
    # Incremental builds already contain the uncompressed APEX produced by this
    # module, even though the work-dir filename retains the _compressed suffix.
    cp -a "$CAPEX" "$PATCH_TMP/original.apex"
fi
if [ ! -s "$PATCH_TMP/original.apex" ]; then
    LOGE "Failed to extract original_apex from ${CAPEX//$WORK_DIR/}"
    return 1
fi

LOG "- Decoding original Tethering APEX"
EVAL "apktool d -j \"$(nproc)\" -o \"$DECODED\" -r \"$PATCH_TMP/original.apex\""

LOG "- Extracting apex_payload.img"
mkdir -p "$PAYLOAD" "$PATCH_TMP/mnt"
if ! sudo mount -o ro "$DECODED/unknown/apex_payload.img" "$PATCH_TMP/mnt"; then
    LOGE "Failed to mount Tethering APEX payload"
    return 1
fi
if ! sudo cp -a -T "$PATCH_TMP/mnt" "$PAYLOAD"; then
    LOGE "Failed to copy Tethering APEX payload"
    sudo umount "$PATCH_TMP/mnt" || true
    return 1
fi
if ! sudo chown -hR "$(whoami):$(whoami)" "$PAYLOAD"; then
    LOGE "Failed to change ownership of the extracted Tethering APEX payload"
    sudo umount "$PATCH_TMP/mnt" || true
    return 1
fi
rm -rf "$PAYLOAD/lost+found"

LOG "- Recording Tethering APEX filesystem metadata"
if ! sudo find "$PATCH_TMP/mnt" \
        -exec stat -c "%n %u %g %a capabilities=0x0" "{}" \; \
        > "$PATCH_TMP/fs_config"; then
    LOGE "Failed to record Tethering APEX fs_config metadata"
    sudo umount "$PATCH_TMP/mnt" || true
    return 1
fi
if ! sudo find "$PATCH_TMP/mnt" -exec sh -c '
        for path do
            label="$(getfattr -n security.selinux --only-values -h --absolute-names "$path")" || exit 1
            printf "%s %s\n" "$path" "$label"
        done
    ' sh "{}" + > "$PATCH_TMP/file_contexts"; then
    LOGE "Failed to record Tethering APEX SELinux contexts"
    sudo umount "$PATCH_TMP/mnt" || true
    return 1
fi
if ! sudo umount "$PATCH_TMP/mnt"; then
    LOGE "Failed to unmount Tethering APEX payload"
    return 1
fi
rm -rf "$PATCH_TMP/mnt" "$DECODED/unknown/apex_payload.img"

sort -o "$PATCH_TMP/file_contexts" "$PATCH_TMP/file_contexts"
sort -o "$PATCH_TMP/fs_config" "$PATCH_TMP/fs_config"
sed -i -e "s|$PATCH_TMP/mnt |/ |g" -e "s|$PATCH_TMP/mnt||g" "$PATCH_TMP/file_contexts"
sed -i -e 's|\.|\\.|g' -e 's|+|\\+|g' -e 's|\[|\\[|g' \
    -e 's|\]|\\]|g' -e 's|\*|\\*|g' "$PATCH_TMP/file_contexts"
sed -i -e "s|$PATCH_TMP/mnt | |g" -e "s|$PATCH_TMP/mnt/||g" "$PATCH_TMP/fs_config"

# The Android 16 connectivity service starts two optional native BPF event
# consumers when their metrics flags are enabled.  Both ring buffers are
# unavailable on the Exynos 990's Linux 4.19 kernel, and the native consumers
# abort system_server when their maps are missing.  Disable both call sites in
# the APEX jar before rebuilding the payload.
SERVICE_CONNECTIVITY="$PAYLOAD/javalib/service-connectivity.jar"
SERVICE_CONNECTIVITY_WORK="$WORK_DIR/system/system/framework/service-connectivity.jar"
SERVICE_CONNECTIVITY_PATCH="$MODPATH/patches/service-connectivity.jar/0001-disable-local-net-event-listener-on-legacy-bpf.patch"
SERVICE_CONNECTIVITY_LOOPBACK_PATCH="$MODPATH/patches/service-connectivity.jar/0002-disable-loopback-event-consumer-on-legacy-bpf.patch"

if [ ! -f "$SERVICE_CONNECTIVITY" ]; then
    LOGE "Tethering service-connectivity.jar not found in apex_payload"
    return 1
elif [ ! -f "$SERVICE_CONNECTIVITY_PATCH" ]; then
    LOGE "Missing service-connectivity legacy-kernel patch"
    return 1
elif [ ! -f "$SERVICE_CONNECTIVITY_LOOPBACK_PATCH" ]; then
    LOGE "Missing service-connectivity loopback legacy-kernel patch"
    return 1
fi

LOG "- Decoding apex_payload/javalib/service-connectivity.jar"
mkdir -p "$(dirname "$SERVICE_CONNECTIVITY_WORK")"
mv -f "$SERVICE_CONNECTIVITY" "$SERVICE_CONNECTIVITY_WORK"
DECODE_APK "system" "system/framework/service-connectivity.jar"

LOG "- Disabling connectivity BPF event consumers on the legacy kernel"
APPLY_PATCH "system" "system/framework/service-connectivity.jar" \
    "$SERVICE_CONNECTIVITY_PATCH" || return 1
APPLY_PATCH "system" "system/framework/service-connectivity.jar" \
    "$SERVICE_CONNECTIVITY_LOOPBACK_PATCH" || return 1

EVAL "\"$SRC_DIR/scripts/apktool.sh\" b \"system\" \"system/framework/service-connectivity.jar\"" || return 1
mv -f "$SERVICE_CONNECTIVITY_WORK" "$SERVICE_CONNECTIVITY"
rm -rf "$APKTOOL_DIR/system/framework/service-connectivity.jar"

NETBPFLOAD="$PAYLOAD/bin/netbpfload"
EXPECTED_SHA256="cad99f3ef16dfb940e2a29b0a5061d0c8d21063604ace33877023bc78a27ad13"
PATCHED_SHA256="b4458f3107e66cff08e01de87586d2659578a4f16f09b13f846f047920eb0e61"
EXPECTED_85_SHA256="7b77a7ac01d01b6787544f2a01a77f4fd929ec6da0625c6f413764e8622ff2a2"
BROKEN_PATCHED_85_SHA256="d7b634fad672b400656f2dced2504b25090e54992d189133b3eaf1dab7c54813"
Q2_ONLY_PATCHED_85_SHA256="8ee75c6fc3eaf73cd6d93cfd9d96b253e4297706921bd57bedf224a5df16468a"
PATCHED_85_SHA256="13e9fedd343f603445b7094aa6d44266614bbd7e1962c10f56b87f445b219ad0"
EXPECTED_9_SHA256="775d705134ac47146a536d31e76af3d439d0e29d48087bc6c64d04c102c4bed6"
PATCHED_9_SHA256="25f3b42b7889d097994f576a63402025cd988b24f401894340b70f1da7219e6d"
ACTUAL_SHA256="$(sha256sum "$NETBPFLOAD" | cut -d ' ' -f 1)"

if [ "$ACTUAL_SHA256" = "$EXPECTED_SHA256" ]; then
    # NetBpfLoad v0.47 aborts API 36 on kernels older than 5.4. Exynos 990 uses
    # Linux 4.19 with the required BPF functionality backported, so skip only
    # this hard version gate while preserving the real kernel version for BPF
    # program selection.
    #
    # Before: tbnz w0, #0, <Android 25Q2 requires kernel 5.4 error path>
    # After:  nop
    LOG "- Disabling NetBpfLoad Android 25Q2 kernel 5.4 version gate"
    HEX_PATCH "$NETBPFLOAD" \
        "1c070094c0160036680800f0" \
        "1c0700941f2003d5680800f0" > /dev/null
    FINAL_SHA256="$PATCHED_SHA256"
elif [ "$ACTUAL_SHA256" = "$PATCHED_SHA256" ]; then
    LOG "- NetBpfLoad Android 25Q2 kernel gate is already disabled"
    FINAL_SHA256="$PATCHED_SHA256"
elif [ "$ACTUAL_SHA256" = "$EXPECTED_85_SHA256" ]; then
    # One UI 8.5 reaches the error block by falling through when the 25Q2
    # compatibility flag is set. Jump over that block unconditionally while
    # preserving the real kernel version for BPF program selection.
    #
    # Before: tbz w10, #0, <after Android 25Q2 kernel 5.4 error block>
    # After:  b <after Android 25Q2 kernel 5.4 error block>
    LOG "- Disabling NetBpfLoad One UI 8.5 kernel 5.4/5.10 version gates"
    HEX_PATCH "$NETBPFLOAD" \
        "5f01057168010054ea5244392a010036a1fffff0" \
        "5f01057168010054ea52443909000014a1fffff0" > /dev/null
    HEX_PATCH "$NETBPFLOAD" \
        "1f110a71280200546808009008614439c8010036a1fffff0" \
        "1f110a712802005468080090086144390e000014a1fffff0" > /dev/null
    FINAL_SHA256="$PATCHED_85_SHA256"
elif [ "$ACTUAL_SHA256" = "$BROKEN_PATCHED_85_SHA256" ]; then
    LOG "- Repairing cached NetBpfLoad One UI 8.5 kernel gate patch"
    HEX_PATCH "$NETBPFLOAD" \
        "5f01057168010054ea5244391f2003d5a1fffff0" \
        "5f01057168010054ea52443909000014a1fffff0" > /dev/null
    HEX_PATCH "$NETBPFLOAD" \
        "1f110a71280200546808009008614439c8010036a1fffff0" \
        "1f110a712802005468080090086144390e000014a1fffff0" > /dev/null
    FINAL_SHA256="$PATCHED_85_SHA256"
elif [ "$ACTUAL_SHA256" = "$Q2_ONLY_PATCHED_85_SHA256" ]; then
    LOG "- Disabling cached NetBpfLoad One UI 8.5 kernel 5.10 gate"
    HEX_PATCH "$NETBPFLOAD" \
        "1f110a71280200546808009008614439c8010036a1fffff0" \
        "1f110a712802005468080090086144390e000014a1fffff0" > /dev/null
    FINAL_SHA256="$PATCHED_85_SHA256"
elif [ "$ACTUAL_SHA256" = "$PATCHED_85_SHA256" ]; then
    LOG "- NetBpfLoad One UI 8.5 kernel gate is already disabled"
    FINAL_SHA256="$PATCHED_85_SHA256"
elif [ "$ACTUAL_SHA256" = "$EXPECTED_9_SHA256" ]; then
    # Android 17 keeps separate 5.4 and 5.10 feature gates. The two TBZ
    # instructions enter their error blocks when the corresponding platform
    # flags are enabled; branch directly to each normal continuation instead.
    LOG "- Disabling NetBpfLoad One UI 9 kernel 5.4/5.10 version gates"
    HEX_PATCH "$NETBPFLOAD" \
        "cb7e1253730800d07f010571680100546b8244392b010036c1ffffb0" \
        "cb7e1253730800d07f010571680100546b82443909000014c1ffffb0" > /dev/null
    HEX_PATCH "$NETBPFLOAD" \
        "5f110a71280100546a0800d04a914439ca000036c1ffffb0" \
        "5f110a71280100546a0800d04a91443906000014c1ffffb0" > /dev/null
    FINAL_SHA256="$PATCHED_9_SHA256"
elif [ "$ACTUAL_SHA256" = "$PATCHED_9_SHA256" ]; then
    LOG "- NetBpfLoad One UI 9 kernel gates are already disabled"
    FINAL_SHA256="$PATCHED_9_SHA256"
else
    LOGE "Unsupported netbpfload build: $ACTUAL_SHA256"
    LOGE "Expected a supported One UI 8.0/8.5/9 original or patched build"
    return 1
fi

if [ "$(sha256sum "$NETBPFLOAD" | cut -d ' ' -f 1)" != "$FINAL_SHA256" ]; then
    LOGE "netbpfload patch validation failed"
    return 1
fi

NETD_UPDATABLE="$PAYLOAD/lib64/libnetd_updatable.so"
EXPECTED_NETD_SHA256="eda006b2bc421bb2581b2193c10444b7ee158bf728034e1e57ba8425e82a6386"
PATCHED_NETD_SHA256="3ebd27e5f3a6f6c4efe04672c6b835701c8cf6cec584792e907e75d140bee67f"
EXPECTED_NETD_85_SHA256="b15352158c8633d3a3b743331ce149daa29c6b7d656eed014392da082cf187cc"
BROKEN_PATCHED_NETD_85_SHA256="4a6ba0362a869ee8e91b8317b57614cbd9d77872416543c413262e4c52b10aa2"
PATCHED_NETD_85_SHA256="d62c8a9d351296e992f965e396c52cddc0db435ebd89b02d3c6834ade7b0c0d3"
EXPECTED_NETD_9_SHA256="b201bb4871e76bf68f096892e1358efb51dac1008f42d3b3d4d7637a284817f9"
BROKEN_PATCHED_NETD_9_SHA256="9f424b3d59957f25975260ad9267af6598ae94905988935b397495e8c71f630e"
PATCHED_NETD_9_SHA256="ff780803b29a3fb993c841ca8da6166dcb32c8eb65f216cdab10b3066713ca32"
ACTUAL_NETD_SHA256="$(sha256sum "$NETD_UPDATABLE" | cut -d ' ' -f 1)"

if [ "$ACTUAL_NETD_SHA256" = "$EXPECTED_NETD_SHA256" ]; then
    # libnetd_updatable performs the same API 36/kernel 5.4 check when netd
    # starts. Keeping this gate makes netd abort after NetBpfLoad successfully
    # loaded the kernel-4.19 variants of its maps and programs.
    #
    # Before: b.ls <25Q2+ kernel version unsupported error path>
    # After:  nop
    LOG "- Disabling netd Android 25Q2 kernel 5.4 version gate"
    HEX_PATCH "$NETD_UPDATABLE" \
        "1f01096be9430054e00301aa" \
        "1f01096b1f2003d5e00301aa" > /dev/null
    FINAL_NETD_SHA256="$PATCHED_NETD_SHA256"
elif [ "$ACTUAL_NETD_SHA256" = "$PATCHED_NETD_SHA256" ]; then
    LOG "- netd Android 25Q2 kernel gate is already disabled"
    FINAL_NETD_SHA256="$PATCHED_NETD_SHA256"
elif [ "$ACTUAL_NETD_SHA256" = "$EXPECTED_NETD_85_SHA256" ]; then
    # Like NetBpfLoad above, this TBZ skips the unsupported-kernel error
    # object. Replacing it with NOP would fall through into the error; branch
    # unconditionally to the normal continuation instead.
    LOG "- Disabling netd One UI 8.5 kernel 5.4 version gate"
    HEX_PATCH "$NETD_UPDATABLE" \
        "1f010571c805005448a341398805003600088052" \
        "1f010571c805005448a341392c00001400088052" > /dev/null
    FINAL_NETD_SHA256="$PATCHED_NETD_85_SHA256"
elif [ "$ACTUAL_NETD_SHA256" = "$BROKEN_PATCHED_NETD_85_SHA256" ]; then
    LOG "- Repairing cached netd One UI 8.5 kernel gate patch"
    HEX_PATCH "$NETD_UPDATABLE" \
        "1f010571c805005448a341391f2003d500088052" \
        "1f010571c805005448a341392c00001400088052" > /dev/null
    FINAL_NETD_SHA256="$PATCHED_NETD_85_SHA256"
elif [ "$ACTUAL_NETD_SHA256" = "$PATCHED_NETD_85_SHA256" ]; then
    LOG "- netd One UI 8.5 kernel gate is already disabled"
    FINAL_NETD_SHA256="$PATCHED_NETD_85_SHA256"
elif [ "$ACTUAL_NETD_SHA256" = "$EXPECTED_NETD_9_SHA256" ]; then
    # Android 17 moved the 25Q2 test. Turn its conditional jump into the same
    # unconditional jump to the supported-kernel continuation.
    LOG "- Disabling netd One UI 9 kernel 5.4 version gate"
    HEX_PATCH "$NETD_UPDATABLE" \
        "687e12531f010571e81c0054680000f008714039881c0036" \
        "687e12531f010571e7000014680000f008714039881c0036" > /dev/null
    FINAL_NETD_SHA256="$PATCHED_NETD_9_SHA256"
elif [ "$ACTUAL_NETD_SHA256" = "$BROKEN_PATCHED_NETD_9_SHA256" ]; then
    # The first Android 17 patch jumped to 0x9678, in the middle of the
    # expected<T> result writeback path, before its destination pointer was
    # initialized. netd consequently wrote through x11=0x12800c and crashed.
    # Branch to 0x9684, the normal continuation used by the original gate.
    LOG "- Repairing cached netd One UI 9 kernel gate branch target"
    HEX_PATCH "$NETD_UPDATABLE" \
        "687e12531f010571e4000014680000f008714039881c0036" \
        "687e12531f010571e7000014680000f008714039881c0036" > /dev/null
    FINAL_NETD_SHA256="$PATCHED_NETD_9_SHA256"
elif [ "$ACTUAL_NETD_SHA256" = "$PATCHED_NETD_9_SHA256" ]; then
    LOG "- netd One UI 9 kernel gate is already disabled"
    FINAL_NETD_SHA256="$PATCHED_NETD_9_SHA256"
else
    LOGE "Unsupported libnetd_updatable build: $ACTUAL_NETD_SHA256"
    LOGE "Expected a supported One UI 8.0/8.5/9 original or patched build"
    return 1
fi

if [ "$(sha256sum "$NETD_UPDATABLE" | cut -d ' ' -f 1)" != "$FINAL_NETD_SHA256" ]; then
    LOGE "libnetd_updatable patch validation failed"
    return 1
fi

# Android 17's netd.o still carries dedicated Android T implementations for
# Linux 4.19, but their program metadata caps the platform API at 36.  On API
# 37 NetBpfLoad therefore skips both ingress_stats_4_19_t and
# egress_stats_4_19_t, and netd aborts because their pinned programs do not
# exist.  Extend only these two 4.19 variants to future platform APIs; their
# kernel range remains [4.19, 5.4), so no newer implementation is affected.
NETD_BPF="$PAYLOAD/etc/bpf/mainline/netd.o"
EXPECTED_NETD_BPF_9_SHA256="4418d9cca4dca5ca4ea8cfc2a61cee247946e6fa0d0ec111ed6b10954a9a2e5a"
PATCHED_NETD_BPF_9_SHA256="05cc78cebc8b6fe0b5203096f4cd0246a9bb9eeb2ee3c72cdf2d0dad8d865b24"
ACTUAL_NETD_BPF_SHA256="$(sha256sum "$NETD_BPF" | cut -d ' ' -f 1)"

if [ "$ACTUAL_NETD_BPF_SHA256" = "$EXPECTED_NETD_BPF_9_SHA256" ]; then
    LOG "- Extending netd Android 4.19 ingress/egress programs to API 37"
    # android_prog_def: min_kver=4.19, max_kver=5.4, min_api=3300,
    # max_api=3600 -> max_api=65536. The pattern occurs exactly twice, for
    # ingress_stats_4_19_t and egress_stats_4_19_t.
    HEX_PATCH "$NETD_BPF" \
        "000013040000040500000000e40c0000100e0000" \
        "000013040000040500000000e40c000000000100" > /dev/null || return 1
    HEX_PATCH "$NETD_BPF" \
        "000013040000040500000000e40c0000100e0000" \
        "000013040000040500000000e40c000000000100" > /dev/null || return 1
elif [ "$ACTUAL_NETD_BPF_SHA256" = "$PATCHED_NETD_BPF_9_SHA256" ]; then
    LOG "- netd Android 4.19 programs already support API 37"
else
    LOGE "Unsupported Android 17 netd.o build: $ACTUAL_NETD_BPF_SHA256"
    return 1
fi

if [ "$(sha256sum "$NETD_BPF" | cut -d ' ' -f 1)" != \
        "$PATCHED_NETD_BPF_9_SHA256" ]; then
    LOGE "netd.o Android 4.19 API-range patch validation failed"
    return 1
fi

LOG "- Rebuilding apex_payload.img"
"$SRC_DIR/scripts/build_fs_image.sh" "ext4" --no-avb \
    -o "$DECODED/unknown/apex_payload.img" -p "system" \
    "$PAYLOAD" "$PATCH_TMP/file_contexts" "$PATCH_TMP/fs_config" > /dev/null

rm -rf "$PAYLOAD" "$PATCH_TMP/file_contexts" "$PATCH_TMP/fs_config"

LOG "- Signing Tethering APEX payload"
SALT="$(sha256sum "$DECODED/unknown/apex_manifest.pb" | cut -d ' ' -f 1)"
EVAL "avbtool add_hashtree_footer --do_not_generate_fec --algorithm \"SHA256_RSA4096\" --hash_algorithm \"sha256\" --key \"$SRC_DIR/security/avb/testkey_rsa4096.pem\" --prop \"apex.key:com.android.tethering\" --salt \"$SALT\" --image \"$DECODED/unknown/apex_payload.img\""
EVAL "avbtool extract_public_key --key \"$SRC_DIR/security/avb/testkey_rsa4096.pem\" --output \"$DECODED/unknown/apex_pubkey\""

LOG "- Rebuilding uncompressed Tethering APEX"
mkdir -p "$DECODED/build/apk"
cp -a "$DECODED/original/META-INF" "$DECODED/build/apk/META-INF"
EVAL "apktool b -j \"$(nproc)\" \"$DECODED\""

BUILT_APEX="$DECODED/dist/original.apex"
if [ ! -f "$BUILT_APEX" ]; then
    LOGE "Rebuilt Tethering APEX not found"
    return 1
fi

CERT_PREFIX="aosp"
if $ROM_IS_OFFICIAL; then
    CERT_PREFIX="unica"
fi

LOG "- Signing Tethering APEX container"
EVAL "signapk -a 4096 --align-file-size \"$SRC_DIR/security/${CERT_PREFIX}_platform.x509.pem\" \"$SRC_DIR/security/${CERT_PREFIX}_platform.pk8\" \"$BUILT_APEX\" \"$BUILT_APEX.signed\""

# APEXd accepts an uncompressed APEX in place of its CAPEX. Keeping the original
# path also avoids stale filesystem metadata entries during incremental builds.
mv -f "$BUILT_APEX.signed" "$CAPEX"
rm -rf "$PATCH_TMP"

unset CAPEX PATCH_TMP DECODED PAYLOAD NETBPFLOAD EXPECTED_SHA256 PATCHED_SHA256 \
    EXPECTED_85_SHA256 BROKEN_PATCHED_85_SHA256 \
    Q2_ONLY_PATCHED_85_SHA256 PATCHED_85_SHA256 EXPECTED_9_SHA256 \
    PATCHED_9_SHA256 ACTUAL_SHA256 FINAL_SHA256 \
    SERVICE_CONNECTIVITY SERVICE_CONNECTIVITY_WORK SERVICE_CONNECTIVITY_PATCH \
    SERVICE_CONNECTIVITY_LOOPBACK_PATCH \
    NETD_UPDATABLE EXPECTED_NETD_SHA256 PATCHED_NETD_SHA256 \
    EXPECTED_NETD_85_SHA256 BROKEN_PATCHED_NETD_85_SHA256 \
    PATCHED_NETD_85_SHA256 EXPECTED_NETD_9_SHA256 \
    BROKEN_PATCHED_NETD_9_SHA256 PATCHED_NETD_9_SHA256 \
    ACTUAL_NETD_SHA256 FINAL_NETD_SHA256 SALT \
    NETD_BPF EXPECTED_NETD_BPF_9_SHA256 PATCHED_NETD_BPF_9_SHA256 \
    ACTUAL_NETD_BPF_SHA256 \
    BUILT_APEX CERT_PREFIX
