#!/usr/bin/env bash
# Copyright (c) 2026 At30c
# SPDX-License-Identifier: GPL-3.0-or-later

SKIPUNZIP=1

if [[ "$SOURCE_PLATFORM_SDK_VERSION" -lt 36 ]]; then
    LOG "- Source is not Android 16; skipping Exynos 990 WFD compatibility"
    return 0
fi

LOG_STEP_IN "- Adding Android 16 ARM32 wireless DeX/Smart View stack"

# Exynos 990 retains a 32-bit OMX service. R9s supplies an Android 16 ARM32
# RemoteDisplay stack that uses the same metadata ABI as the legacy encoder.
ADD_TO_WORK_DIR "r9sxxx" "system" "system/bin/insthk" \
    0 2000 755 "u:object_r:insthk_exec:s0" || return 1
ADD_TO_WORK_DIR "r9sxxx" "system" "system/bin/remotedisplay" \
    0 2000 755 "u:object_r:remotedisplay_exec:s0" || return 1

R9S_WFD_LIBS="
android.hardware.graphics.common-V6-ndk.so
android.hardware.graphics.composer3-V4-ndk.so
android.hardware.graphics.extension.composer3-V1-ndk.so
libhdcp2.so
libhdcp_client_aidl.so
libremotedisplay.so
libremotedisplay_wfd.so
libremotedisplayservice.so
librepeater.so
libsecuibc.so
libstagefright_hdcp.so
libtsmux.so
vendor.samsung.hardware.security.hdcp.wifidisplay-V2-ndk.so
vendor.samsung_slsi.hardware.ExynosHWCServiceTW@1.0.so
vendor.samsung_slsi.hardware.graphics.extension.composer3-V4-ndk.so
wfd_log.so
"
while IFS= read -r R9S_WFD_LIB; do
    [ "$R9S_WFD_LIB" ] || continue
    ADD_TO_WORK_DIR "r9sxxx" "system" "system/lib/$R9S_WFD_LIB" \
        0 0 644 "u:object_r:system_lib_file:s0" || return 1
done <<< "$R9S_WFD_LIBS"

# The ARM32 RemoteDisplay stack links against the ARM32 libmedia, and that
# libmedia needs the ARM32 libandroidicu shim. The source i18n APEX only ships
# the ARM64 variant, because the S24+ has no ARM32 media stack at all, so the
# ARM32 closure has to be imported from a donor that does provide one.
#
# Without it the linker rejects /system/bin/remotedisplay with
# `library "libandroidicu.so" not found: needed by /system/lib/libmedia.so`,
# remotedisplay is restarted every five seconds, and DeX never comes up.
WFD_I18N_DONOR=""
for WFD_I18N_CANDIDATE in r11sxxx r9sxxx; do
    if [ -f "$SRC_DIR/prebuilts/samsung/$WFD_I18N_CANDIDATE/system/apex/com.android.i18n.apex" ]; then
        WFD_I18N_DONOR="$WFD_I18N_CANDIDATE"
        break
    fi
done

if [ -z "$WFD_I18N_DONOR" ]; then
    LOGE "No donor provides an i18n APEX for the ARM32 WFD stack"
    return 1
fi

WFD_I18N_APEX="$SRC_DIR/prebuilts/samsung/$WFD_I18N_DONOR/system/apex/com.android.i18n.apex"
WFD_I18N_TMP="$TMP_DIR/wfd_i18n"
WFD_I18N_LIBS="libandroidicu.so libicuuc.so libicui18n.so libicu.so"

rm -rf "$WFD_I18N_TMP"
mkdir -p "$WFD_I18N_TMP/apex" "$WFD_I18N_TMP/mnt" "$WFD_I18N_TMP/system/lib"

if unzip -l "$WFD_I18N_APEX" original_apex 2> /dev/null | grep -q "original_apex"; then
    unzip -p "$WFD_I18N_APEX" original_apex > "$WFD_I18N_TMP/original.apex" || return 1
    unzip -o -q "$WFD_I18N_TMP/original.apex" apex_payload.img -d "$WFD_I18N_TMP/apex" || return 1
else
    unzip -o -q "$WFD_I18N_APEX" apex_payload.img -d "$WFD_I18N_TMP/apex" || return 1
fi

WFD_I18N_PAYLOAD="$WFD_I18N_TMP/apex/apex_payload.img"
if [ ! -f "$WFD_I18N_PAYLOAD" ]; then
    LOGE "Donor $WFD_I18N_DONOR i18n APEX has no apex_payload.img"
    return 1
fi

WFD_I18N_MOUNTED=false
if command -v debugfs > /dev/null 2>&1; then
    WFD_I18N_READ() {
        debugfs -R "dump $1 $2" "$WFD_I18N_PAYLOAD" > /dev/null 2>&1
    }
elif sudo -n mount -o ro "$WFD_I18N_PAYLOAD" "$WFD_I18N_TMP/mnt" 2> /dev/null; then
    # e2fsprogs is not guaranteed on the build host, so fall back to mounting
    # the payload the way the tethering APEX patch already does.
    WFD_I18N_MOUNTED=true
    WFD_I18N_READ() {
        cp -a -f "$WFD_I18N_TMP/mnt$1" "$2"
    }
else
    ABORT "Neither debugfs nor a usable sudo mount is available to read the i18n APEX"
    return 1
fi

for WFD_I18N_LIB in $WFD_I18N_LIBS; do
    WFD_I18N_READ "/lib/$WFD_I18N_LIB" "$WFD_I18N_TMP/system/lib/$WFD_I18N_LIB"

    if [ ! -f "$WFD_I18N_TMP/system/lib/$WFD_I18N_LIB" ]; then
        ABORT "Donor $WFD_I18N_DONOR i18n APEX has no ARM32 /lib/$WFD_I18N_LIB"
        return 1
    fi

    if ! LC_ALL=C readelf -h "$WFD_I18N_TMP/system/lib/$WFD_I18N_LIB" 2> /dev/null | grep -q 'ELF32'; then
        ABORT "Donor $WFD_I18N_DONOR i18n /lib/$WFD_I18N_LIB is not ELF32"
        return 1
    fi

    ADD_TO_WORK_DIR "$WFD_I18N_TMP" "system" "system/lib/$WFD_I18N_LIB" \
        0 0 644 "u:object_r:system_lib_file:s0" || return 1
done

if $WFD_I18N_MOUNTED; then
    sudo umount "$WFD_I18N_TMP/mnt" || true
fi
rm -rf "$WFD_I18N_TMP"
unset -f WFD_I18N_READ

# R9s advertises WFD R2/HEVC, while the target encoder uses the legacy native
# metadata layout. Skip the R2 capability fields in sendM3().
HEX_PATCH "$WORK_DIR/system/system/lib/libremotedisplay_wfd.so" \
    "94f81d0318b994f8241301290ed1" \
    "00f00fb818b994f8241301290ed1" || return 1

# Fix the ARM32 __fread_chk overflow observed when RemoteDisplay configures
# the legacy encoder. ACodec::reconfigEncoder4OtherApps reads 512 bytes into a
# 255-byte stack buffer and immediately aborts under FORTIFY. Limit the read
# to 254 bytes so the following NUL terminator remains inside the buffer.
# Android 37 changed register allocation and the call-site encoding.
WFD_STAGEFRIGHT_HEX="$(xxd -p -c 0 "$WORK_DIR/system/system/lib/libstagefright.so")"
if grep -q "01214ff4007230462b460097" <<< "$WFD_STAGEFRIGHT_HEX"; then
    HEX_PATCH "$WORK_DIR/system/system/lib/libstagefright.so" \
        "01214ff4007230462b460097" \
        "01214ff0fe0230462b460097" || return 1
elif grep -q "01214ff4007238463346009428f1e2eb" <<< "$WFD_STAGEFRIGHT_HEX"; then
    HEX_PATCH "$WORK_DIR/system/system/lib/libstagefright.so" \
        "01214ff4007238463346009428f1e2eb" \
        "01214ff0fe0238463346009428f1e2eb" || return 1
elif grep -q -e "01214ff0fe0230462b460097" \
        -e "01214ff0fe0238463346009428f1e2eb" <<< "$WFD_STAGEFRIGHT_HEX"; then
    LOG "- ARM32 libstagefright fread bound is already patched"
else
    ABORT "Unsupported ARM32 libstagefright fread call site"
    return 1
fi
unset WFD_STAGEFRIGHT_HEX

# Do not leave an alternative ARM64 graph that can be selected by stale
# processes in preference to the matching ARM32 stack.
R9S_WFD_64_REMOVE="
android.hardware.graphics.extension.composer3-V1-ndk.so
libhdcp2.so
libhdcp_client_aidl.so
libremotedisplay_wfd.so
libremotedisplayservice.so
librepeater.so
libsecuibc.so
libstagefright_hdcp.so
libtsmux.so
vendor.samsung.hardware.security.hdcp.wifidisplay-V2-ndk.so
wfd_log.so
"
while IFS= read -r R9S_WFD_64_LIB; do
    [ "$R9S_WFD_64_LIB" ] || continue
    DELETE_FROM_WORK_DIR "system" "system/lib64/$R9S_WFD_64_LIB"
done <<< "$R9S_WFD_64_REMOVE"

# Resolve the framework-side WFD roots recursively from the Android 16 donors.
# Libraries already supplied by another WFD donor are reused, while missing
# dependencies can fall back between r9s and r11s.
declare -A WFD_IMPORTED=()

ADD_R11S_WFD_LIB()
{
    local LIB_NAME="$1"
    local RESOLVE_EXISTING="${2:-false}"
    local PREFERRED_DONOR="${3:-r11sxxx}"
    local DONOR="$PREFERRED_DONOR"
    local DONOR_LIB
    local NEEDED_LIB

    if [ "${WFD_IMPORTED[$LIB_NAME]+set}" ]; then
        # A previous traversal may have seen a cyclic dependency before the
        # file was installed. Do not let that stale mark hide a missing ELF.
        [ -e "$WORK_DIR/system/system/lib/$LIB_NAME" ] && return 0
        unset 'WFD_IMPORTED[$LIB_NAME]'
    fi
    WFD_IMPORTED["$LIB_NAME"]=1
    DONOR_LIB="$SRC_DIR/prebuilts/samsung/$DONOR/system/lib/$LIB_NAME"
    if [ ! -f "$DONOR_LIB" ]; then
        for DONOR in r11sxxx r9sxxx; do
            DONOR_LIB="$SRC_DIR/prebuilts/samsung/$DONOR/system/lib/$LIB_NAME"
            [ -f "$DONOR_LIB" ] && break
        done
    fi
    if [ -e "$WORK_DIR/system/system/lib/$LIB_NAME" ] && \
            [ "$RESOLVE_EXISTING" != "true" ]; then
        return 0
    fi

    if [ ! -f "$DONOR_LIB" ]; then
        ABORT "Missing ARM32 WFD dependency in r9s/r11s donors: system/lib/$LIB_NAME"
        return 1
    fi
    if [ ! -e "$WORK_DIR/system/system/lib/$LIB_NAME" ]; then
        ADD_TO_WORK_DIR "$DONOR" "system" "system/lib/$LIB_NAME" \
            0 0 644 "u:object_r:system_lib_file:s0" || return 1
    fi

    while read -r NEEDED_LIB; do
        case "$NEEDED_LIB" in
            libc.so|libdl.so|libdl_android.so|libm.so|libandroidicu.so)
                continue
                ;;
        esac
        ADD_R11S_WFD_LIB "$NEEDED_LIB" || return 1
    done < <(readelf -d "$DONOR_LIB" 2>/dev/null | \
        sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p')
}

# Resolve dependencies of every explicitly imported r9s WFD library. This
# catches cross-donor requirements such as r9s libhdcp2 -> r11s libion before
# the strict ELF validation stage.
if [[ "${EXYNOS990_RUNTIME32_APEX_MODE:-merged}" == "source_apex" ]]; then
    while IFS= read -r R9S_WFD_LIB; do
        [ "$R9S_WFD_LIB" ] || continue
        ADD_R11S_WFD_LIB "$R9S_WFD_LIB" true r9sxxx || return 1
    done <<< "$R9S_WFD_LIBS"
fi

# source_apex keeps only a targeted stagefright input from r11s. Resolve its
# non-Bionic DT_NEEDED closure as well, otherwise the strict graph validation
# below reports the first missing dependency one library at a time.
if [[ "${EXYNOS990_RUNTIME32_APEX_MODE:-merged}" == "source_apex" ]]; then
    ADD_R11S_WFD_LIB "libstagefright.so" true || return 1
fi

for WFD_RUNTIME_ROOT in libsfextcp.so libinput.so libmemunreachable.so; do
    ADD_R11S_WFD_LIB "$WFD_RUNTIME_ROOT" || return 1
done

# The r9s ARM32 WFD stack was built against the Android 16 audio client, which
# still exports the 16-argument AudioTrack constructor. Android 17 removed that
# overload, so ld.so rejects libremotedisplay_wfd.so and DeX never starts. R0sxxx
# is still Android 16 and its ARM32 audio client closure is three libraries.
#
# A private LD_LIBRARY_PATH directory does not work here: init-launched native
# services do not pick up the variable, so ld.so resolved the DT_NEEDED
# libaudioclient.so from the default path and the import stayed unresolved.
#
# Instead, give the donor libraries private SONAMEs inside /system/lib, which is
# already on the default search path, and repoint libremotedisplay_wfd.so at
# them. The target's own libaudioclient.so and its V5 audio types library stay
# untouched for every other process, which is the same isolation trick the
# target suspend bridge uses in patches/miscs.
WFD_AUDIO_LIBS="
libaudioclient_wfd_compat.so
libnblog_wfd_compat.so
android.media.audio.common.types-V4-cpp-wfd_compat.so
"
WFD_AUDIO_DONOR="$SRC_DIR/prebuilts/samsung/r0sxxx"
for WFD_AUDIO_LIB in $WFD_AUDIO_LIBS; do
    WFD_AUDIO_SRC="$WFD_AUDIO_DONOR/system/lib/$WFD_AUDIO_LIB"
    if [ ! -f "$WFD_AUDIO_SRC" ]; then
        ABORT "Missing ARM32 audio client donor lib: system/lib/$WFD_AUDIO_LIB"
        return 1
    fi
    if ! LC_ALL=C readelf -h "$WFD_AUDIO_SRC" 2>/dev/null | grep -q 'ELF32'; then
        ABORT "ARM32 audio client donor lib is not ELF32: $WFD_AUDIO_LIB"
        return 1
    fi
    ADD_TO_WORK_DIR "r0sxxx" "system" "system/lib/$WFD_AUDIO_LIB" || return 1
done

WFD_AUDIO_COMPAT="$WORK_DIR/system/system/lib/libaudioclient_wfd_compat.so"
WFD_AUDIO_TYPES_COMPAT="$WORK_DIR/system/system/lib/android.media.audio.common.types-V4-cpp-wfd_compat.so"
WFD_AUDIO_NBLOG_COMPAT="$WORK_DIR/system/system/lib/libnblog_wfd_compat.so"
WFD_AUDIO_WFD_LIB="$WORK_DIR/system/system/lib/libremotedisplay_wfd.so"

if ! command -v patchelf > /dev/null 2>&1; then
    ABORT "patchelf is required for the ARM32 WFD audio client"
    return 1
fi
if [ ! -f "$WFD_AUDIO_WFD_LIB" ]; then
    ABORT "Missing libremotedisplay_wfd.so, cannot redirect its audio client"
    return 1
fi

# The graph validation below only walks DT_NEEDED, which is why a donor whose
# audio client had already dropped the old overload shipped as a working build
# that could not start. Check the symbol the WFD library actually imports.
WFD_AUDIO_TRACK_SYMBOL="_ZN7android10AudioTrackC1E19audio_stream_type_tj14audio_format_t20audio_channel_mask_tj20audio_output_flags_tRKNS_2wpINS0_19IAudioTrackCallbackEEEi15audio_session_tNS0_13transfer_typeEPK20audio_offload_info_tRKNS_7content22AttributionSourceStateEPK18audio_attributes_tbfi"
if ! readelf --dyn-syms -W "$WFD_AUDIO_COMPAT" 2>/dev/null | \
        awk '{ print $NF }' | grep -qxF "$WFD_AUDIO_TRACK_SYMBOL"; then
    ABORT "r0sxxx libaudioclient_wfd_compat.so does not export the 16-argument AudioTrack constructor"
    return 1
fi

patchelf --set-soname "libaudioclient_wfd_compat.so" \
    "$WFD_AUDIO_COMPAT" || return 1
patchelf --set-soname "android.media.audio.common.types-V4-cpp-wfd_compat.so" \
    "$WFD_AUDIO_TYPES_COMPAT" || return 1
patchelf --set-soname "libnblog_wfd_compat.so" \
    "$WFD_AUDIO_NBLOG_COMPAT" || return 1

# The donor closure wants the V4 audio types library and libnblog, and the target
# ships V5 plus no ARM32 libnblog at all. Redirect both to the private copies.
if readelf -d "$WFD_AUDIO_COMPAT" 2>/dev/null | \
        grep -q "NEEDED.*android.media.audio.common.types-V4-cpp.so"; then
    patchelf --replace-needed "android.media.audio.common.types-V4-cpp.so" \
        "android.media.audio.common.types-V4-cpp-wfd_compat.so" \
        "$WFD_AUDIO_COMPAT" || return 1
fi
if readelf -d "$WFD_AUDIO_COMPAT" 2>/dev/null | grep -q "NEEDED.*libnblog.so"; then
    patchelf --replace-needed "libnblog.so" "libnblog_wfd_compat.so" \
        "$WFD_AUDIO_COMPAT" || return 1
fi

# Redirect the only importer of the old AudioTrack constructor. libremotedisplay
# _wfd is the single WFD library that needs it, so no other DT_NEEDED changes.
if readelf -d "$WFD_AUDIO_WFD_LIB" 2>/dev/null | \
        grep -q "NEEDED.*\[libaudioclient.so\]"; then
    patchelf --replace-needed "libaudioclient.so" \
        "libaudioclient_wfd_compat.so" "$WFD_AUDIO_WFD_LIB" || return 1
elif ! readelf -d "$WFD_AUDIO_WFD_LIB" 2>/dev/null | \
        grep -q "NEEDED.*\[libaudioclient_wfd_compat.so\]"; then
    ABORT "libremotedisplay_wfd.so does not link against the ARM32 audio client"
    return 1
fi

if ! readelf --dyn-syms -W "$WFD_AUDIO_WFD_LIB" 2>/dev/null | \
        grep -q "UND $WFD_AUDIO_TRACK_SYMBOL"; then
    ABORT "libremotedisplay_wfd.so no longer imports the 16-argument AudioTrack constructor"
    return 1
fi
LOG "  - libremotedisplay_wfd.so redirected to libaudioclient_wfd_compat.so"

# The audio closure links, the WFD handshake completes, and remotedisplay then
# dies at its first video buffer allocation:
#
#   Gralloc4: mapper 4.x is not supported
#   GraphicBufferMapper: gralloc-mapper is missing
#   Fatal signal 6 (SIGABRT) in tid 24394 (binder:24157_3), pid 24157
#
# The first line is informational and shows up in ten other processes that keep
# running. The second is level F and appears only in the two remotedisplay PIDs,
# both of which abort, so it is the actual cause.
#
# The string lives in the ARM32 /system/lib/libui.so, but what it loads is a
# vendor graphics mapper. libui walks the HIDL passthrough stubs in order and
# reports each version it cannot use, so `mapper 4.x is not supported` means the
# 4.0 path was selected and its vendor implementation could not be loaded. The
# target has no ARM32 gralloc at all: /vendor/lib and /system/system/lib hold
# zero ARM32 .so files, libgralloctypes.so and android.hardware.graphics.mapper
# @4.0.so exist only under lib64, and the sole 32-bit vendor mapper is the old
# HIDL android.hardware.graphics.mapper@2.0-impl-2.1.so. That is why the audio
# donors alone were not enough: the video path needs a mapper the Exynos 2400
# never shipped in 32-bit.
#
# The S22 Exynos (s5e9925) firmware does ship the ARM32 mapper, in the same
# -impl-sgr form the target uses for its own ARM64 mapper, and its vendor
# manifest declares mapper 4.0 as <transport arch="32+64">passthrough, which is
# what the ARM32 libui requires. Its 32-bit libgralloctypes/libhidlbase/libbase
# dependencies are not needed from this donor because the target's /system/lib
# already resolves them through the r9s/r11s WFD closure.
#
# Only three files are missing from the target. libion_exynos.so is deliberately
# not donated: the target already ships an ARM32 build whose exported symbols are
# a superset of the S22 one, so replacing it would only add risk.
WFD_GRALLOC_LIBS="
lib/hw/android.hardware.graphics.mapper@4.0-impl-sgr.so
lib/hw/gralloc.default.so
lib/libeis_utils.so
"
WFD_GRALLOC_DONOR="$SRC_DIR/prebuilts/samsung/r0sxxx"
for WFD_GRALLOC_LIB in $WFD_GRALLOC_LIBS; do
    WFD_GRALLOC_SRC="$WFD_GRALLOC_DONOR/vendor/$WFD_GRALLOC_LIB"
    if [ ! -f "$WFD_GRALLOC_SRC" ]; then
        ABORT "Missing ARM32 gralloc donor lib: vendor/$WFD_GRALLOC_LIB"
        return 1
    fi
    if ! LC_ALL=C readelf -h "$WFD_GRALLOC_SRC" 2>/dev/null | grep -q 'ELF32'; then
        ABORT "ARM32 gralloc donor lib is not ELF32: $WFD_GRALLOC_LIB"
        return 1
    fi
    ADD_TO_WORK_DIR "r0sxxx" "vendor" "$WFD_GRALLOC_LIB" \
        0 2000 644 "u:object_r:same_process_hal_file:s0" || return 1
done

# libion_exynos.so is not donated because the target already ships a 32-bit
# build of it in vendor/lib whose exported symbols cover the S22 one. That file
# comes from the vendor partition of the same firmware payload the build
# extracts, so it is present in a fresh build, but assert it rather than assume:
# the mapper is dlopen'ed by the passthrough and would fail later at runtime.
if [ ! -f "$WORK_DIR/vendor/lib/libion_exynos.so" ]; then
    ABORT "Missing ARM32 vendor/lib/libion_exynos.so required by the gralloc mapper"
    return 1
fi

# The graph validation below only walks DT_NEEDED, which cannot see the dlopen
# that the HIDL passthrough performs. Check the symbol the passthrough actually
# resolves, so a donor that stopped exporting it fails the build instead of
# shipping an image that aborts on the first allocation.
WFD_GRALLOC_IMPL="$WORK_DIR/vendor/lib/hw/android.hardware.graphics.mapper@4.0-impl-sgr.so"
WFD_GRALLOC_STUB="$WORK_DIR/system/system/lib/android.hardware.graphics.mapper@4.0.so"

if [ ! -f "$WFD_GRALLOC_IMPL" ]; then
    ABORT "Missing ARM32 graphics mapper implementation, cannot validate passthrough"
    return 1
fi
if [ ! -f "$WFD_GRALLOC_STUB" ]; then
    ABORT "Missing ARM32 android.hardware.graphics.mapper@4.0.so passthrough stub"
    return 1
fi
if ! readelf --dyn-syms -W "$WFD_GRALLOC_IMPL" 2>/dev/null | \
        awk '{ print $NF }' | grep -qxF 'HIDL_FETCH_IMapper'; then
    ABORT "ARM32 graphics mapper donor does not export HIDL_FETCH_IMapper"
    return 1
fi

# Every V4_0::IMapper method the donor imports has to be provided by the target's
# own passthrough stub. The two stubs are different builds, so verify the
# interface instead of assuming the donor matches.
WFD_GRALLOC_MISSING=""
while IFS= read -r WFD_GRALLOC_SYM; do
    [ "$WFD_GRALLOC_SYM" ] || continue
    if ! readelf --dyn-syms -W "$WFD_GRALLOC_STUB" 2>/dev/null | \
            awk '{ print $NF }' | grep -qxF "$WFD_GRALLOC_SYM"; then
        WFD_GRALLOC_MISSING="$WFD_GRALLOC_MISSING$WFD_GRALLOC_SYM "
    fi
done <<< "$(readelf --dyn-syms -W "$WFD_GRALLOC_IMPL" 2>/dev/null | \
    awk '$7 == "UND" { print $NF }' | grep -F 'V4_07IMapper' | sort -u)"

if [ -n "$WFD_GRALLOC_MISSING" ]; then
    ABORT "ARM32 passthrough stub does not provide: $WFD_GRALLOC_MISSING"
    return 1
fi
LOG "  - ARM32 graphics mapper 4.0 passthrough validated against the target stub"

# Staging the mapper is not enough on its own. hwservicemanager answers the
# passthrough lookup straight from VINTF, and it has nothing to return while the
# device manifest only declares mapper 2.1:
#
#   hwservicemanager: getTransport: Cannot find entry
#     android.hardware.graphics.mapper@4.0::IMapper/default in either framework
#     or device VINTF manifest.
#   Gralloc4: mapper 4.x is not supported
#   GraphicBufferMapper: gralloc-mapper is missing
#
# That getTransport failure is what kills remotedisplay, and it happens before
# any dlopen, which is why the donor library is never even attempted. The S22
# ships mapper 4.0 as <transport arch="32+64">passthrough, which is the
# declaration the passthrough resolves.
#
# The target cannot simply adopt the S22 declaration verbatim. Its 64-bit
# vendor stack is Gralloc2: /vendor/lib64/hw only carries the old
# android.hardware.graphics.mapper@2.0-impl-2.1.so, and both the 32-bit and the
# 64-bit libui log "mapper 4.x is not supported" today and fall back to 2.1,
# which is why the rest of the system works. Overwriting 2.1 with 4.0 for both
# architectures would strip the 64-bit fallback and break working graphics.
#
# So the existing 2.1 entry is narrowed to arch="64" and a second 4.0 entry is
# added for arch="32". remotedisplay is a 32-bit PIE, so it is the only consumer
# of the new entry, and the 64-bit path keeps the 2.1 fallback untouched.
WFD_VINTF="$WORK_DIR/vendor/etc/vintf/manifest.xml"
WFD_VINTF_NEW='    <hal format="hidl">
        <name>android.hardware.graphics.mapper</name>
        <transport arch="32">passthrough</transport>
        <version>4.0</version>
        <interface>
            <name>IMapper</name>
            <instance>default</instance>
        </interface>
        <fqname>@4.0::IMapper/default</fqname>
    </hal>'

if [ ! -f "$WFD_VINTF" ]; then
    ABORT "Missing $WFD_VINTF, cannot register the ARM32 mapper 4.0 passthrough"
    return 1
fi

if grep -qF '@4.0::IMapper/default' "$WFD_VINTF"; then
    LOG "  - mapper 4.0 passthrough already declared for ARM32"
else
    if ! grep -qF '@2.1::IMapper/default' "$WFD_VINTF"; then
        ABORT "Unexpected VINTF: no mapper 2.1 entry to narrow to ARM64"
        return 1
    fi

    # Rewrite only the mapper block. awk buffers each <hal>...</hal> pair so the
    # arch rewrite cannot leak onto the renderscript passthrough, which shares
    # the same arch="32+64" passthrough form and must keep both architectures.
    # Count the candidate blocks first. This pass prints nothing but the count,
    # so the value captured below cannot be polluted by the document itself.
    WFD_VINTF_FOUND="$(awk '
        /<hal[ >]/ { inblock = 1; blk = $0 ORS; next }
        inblock {
            blk = blk $0 ORS
            if ($0 ~ /<\/hal>/) {
                if (blk ~ /android\.hardware\.graphics\.mapper/ && blk !~ /@4\.0::IMapper/) {
                    found++
                }
                inblock = 0
                blk = ""
            }
            next
        }
        END { print found + 0 }
    ' "$WFD_VINTF")"

    if [ "$WFD_VINTF_FOUND" != "1" ]; then
        ABORT "Expected exactly one mapper 2.1 hal block in VINTF, found $WFD_VINTF_FOUND"
        return 1
    fi

    WFD_VINTF_TMP="$WFD_VINTF.zzwfd.tmp"
    awk -v add40="$WFD_VINTF_NEW" '
        /<hal[ >]/ { inblock = 1; blk = $0 ORS; next }
        inblock {
            blk = blk $0 ORS
            if ($0 ~ /<\/hal>/) {
                if (blk ~ /android\.hardware\.graphics\.mapper/ && blk !~ /@4\.0::IMapper/) {
                    gsub(/arch="32\+64"/, "arch=\"64\"", blk)
                    printf "%s", blk
                    printf "%s\n", add40
                } else {
                    printf "%s", blk
                }
                inblock = 0
                blk = ""
            }
            next
        }
        { print }
    ' "$WFD_VINTF" > "$WFD_VINTF_TMP" || {
        ABORT "Failed to rewrite the mapper block in VINTF"
        rm -f "$WFD_VINTF_TMP"
        return 1
    }

    if ! grep -qF '@4.0::IMapper/default' "$WFD_VINTF_TMP" || \
            ! grep -qF '<fqname>@2.1::IMapper/default</fqname>' "$WFD_VINTF_TMP"; then
        ABORT "VINTF rewrite did not produce the expected mapper entries"
        rm -f "$WFD_VINTF_TMP"
        return 1
    fi

    # The legacy entry must keep working for ARM64, so the rewrite is only
    # accepted if 2.1 really ended up narrowed instead of duplicated.
    if [ "$(grep -cF '<fqname>@2.1::IMapper/default</fqname>' "$WFD_VINTF_TMP")" != "1" ] || \
            [ "$(grep -cF '<fqname>@4.0::IMapper/default</fqname>' "$WFD_VINTF_TMP")" != "1" ]; then
        ABORT "VINTF rewrite changed the number of mapper entries"
        rm -f "$WFD_VINTF_TMP"
        return 1
    fi

    cat "$WFD_VINTF_TMP" > "$WFD_VINTF" || {
        ABORT "Failed to install the rewritten VINTF"
        rm -f "$WFD_VINTF_TMP"
        return 1
    }
    rm -f "$WFD_VINTF_TMP"
    LOG "  - mapper 2.1 narrowed to ARM64, mapper 4.0 passthrough added for ARM32"
fi

# ---------------------------------------------------------------------------
# android.hardware.graphics.allocator@4.0
# ---------------------------------------------------------------------------
# Gralloc4 is a pair: the mapper and the allocator must be the same version.
# Registering only the mapper moved the failure one step down the stack rather
# than removing it, which the previous build confirmed:
#
#   [HIDL_FETCH_IMapper] android.hardware.graphics.mapper@4.0: Loaded Mapper successfully.
#   Gralloc4: allocator 4.x is not supported
#   GraphicBufferAllocator: Failed to load matching allocator for mapper version 4
#   Fatal signal 6 (SIGABRT) ... pid 25195 (remotedisplay)
#
# "allocator 4.x is not supported" reads like the harmless fallback notice that
# the 64-bit side logs all day for the mapper, and it is worth being explicit
# that it is not: that message only ever reports a failed lookup, and what makes
# it fatal is the absence of any alternative. 64-bit has allocator 2.0 to fall
# back to, so its identical-looking notice costs nothing. The 32-bit
# remotedisplay has no fallback at all, and libui only accepts an allocator
# matching the mapper version, hence the SIGABRT.
#
# Unlike the mapper, the allocator is not a passthrough. The S22 ships it as a
# real hwbinder service, android.hardware.graphics.allocator@4.0-service-sgr,
# running as vendor.gralloc-4-0. That is what makes it usable here despite the
# arch split: the service is aarch64 while remotedisplay is 32-bit, but hwbinder
# is IPC, so the 32-bit client binds the 64-bit service over binder and never
# maps its code. The mapper could not be done this way, which is why it stayed a
# passthrough and needed the 32-bit build of the implementation.
#
# The 2.0 declaration is left untouched. It carries no arch attribute, so it
# keeps serving the 64-bit SurfaceFlinger exactly as before, and the two coexist
# because they are different HAL versions.
WFD_ALLOC_SERVICE="bin/hw/android.hardware.graphics.allocator@4.0-service-sgr"
WFD_ALLOC_RC="etc/init/android.hardware.graphics.allocator@4.0-service-sgr.rc"
WFD_ALLOC_DONOR="$SRC_DIR/prebuilts/samsung/r0sxxx/vendor"

if [ ! -f "$WFD_ALLOC_DONOR/$WFD_ALLOC_SERVICE" ]; then
    ABORT "Missing ARM64 allocator 4.0 donor service: vendor/$WFD_ALLOC_SERVICE"
    return 1
fi
if ! LC_ALL=C readelf -h "$WFD_ALLOC_DONOR/$WFD_ALLOC_SERVICE" 2>/dev/null | grep -q 'ELF64'; then
    ABORT "Allocator 4.0 donor service is not ELF64: $WFD_ALLOC_SERVICE"
    return 1
fi
# How a HIDL implementation publishes itself depends on how it is consumed, and
# getting this backwards is easy because the two mechanisms are different.
#
# The mapper is a passthrough: the 32-bit client dlopen's the library and calls
# HIDL_FETCH_IMapper in it, so that symbol is the one worth checking there.
#
# The allocator is a real hwbinder service binary, so hwservicemanager never
# loads it; it starts, and main() registers the interface itself through
# IAllocator::registerAsService. Looking for HIDL_FETCH in it was simply the
# wrong symbol, and it aborted the build against a perfectly good donor. Check
# the method the service actually calls, plus the interface it registers, so a
# donor that stopped registering still fails here.
if ! strings "$WFD_ALLOC_DONOR/$WFD_ALLOC_SERVICE" 2>/dev/null | LC_ALL=C c++filt 2>/dev/null | \
        grep -q 'IAllocator::registerAsService'; then
    ABORT "Allocator 4.0 donor service does not register IAllocator::registerAsService"
    return 1
fi
if ! strings "$WFD_ALLOC_DONOR/$WFD_ALLOC_SERVICE" 2>/dev/null | \
        grep -q 'android.hardware.graphics.allocator@4.0.so'; then
    ABORT "Allocator 4.0 donor service does not link the allocator 4.0 HIDL library"
    return 1
fi

# The 64-bit libraries the service links against. /system/lib64 already carries
# libbase, libcutils, liblog, libutils and the allocator 4.0 HIDL stub, so those
# are not donated. The remaining four are absent from the target's vendor tree
# even though its own allocator 2.0 service needs the same gralloc types, because
# that service resolves them out of /system/lib64 through the default namespace.
# A service registered with the vendor namespace cannot rely on that, so the
# copies go to /vendor/lib64 where the namespace can actually see them.
#
# libion_exynos.so is not donated even though the service needs it. The target
# already ships a 64-bit build in /vendor/lib64, so donating one would replace a
# working library rather than fill a gap, and that library is shared with
# gralloc.exynos990, libGLES_mali, libOpenCL, libgpudataproducer and the eden
# runtime stub. The S22 build exports the same global set with the same soname
# and every one of those consumers resolves against it, so the swap would very
# likely link, but it would still be putting an Exynos 2400-era ION
# implementation from different firmware underneath the GPU stack for no gain.
# Leaving the target's own copy in place is strictly the lower-risk option.
WFD_ALLOC_LIBS="
lib64/libeis_utils.so
lib64/libgralloctypes.so
lib64/libhardware.so
lib64/libhidlbase.so
"
for WFD_ALLOC_LIB in $WFD_ALLOC_LIBS; do
    WFD_ALLOC_SRC="$WFD_ALLOC_DONOR/$WFD_ALLOC_LIB"
    if [ ! -f "$WFD_ALLOC_SRC" ]; then
        ABORT "Missing ARM64 allocator donor lib: vendor/$WFD_ALLOC_LIB"
        return 1
    fi
    if ! LC_ALL=C readelf -h "$WFD_ALLOC_SRC" 2>/dev/null | grep -q 'ELF64'; then
        ABORT "Allocator donor lib is not ELF64: $WFD_ALLOC_LIB"
        return 1
    fi
    ADD_TO_WORK_DIR "r0sxxx" "vendor" "$WFD_ALLOC_LIB" \
        0 2000 644 "u:object_r:same_process_hal_file:s0" || return 1
done

ADD_TO_WORK_DIR "r0sxxx" "vendor" "$WFD_ALLOC_SERVICE" \
    0 2000 755 "u:object_r:hal_graphics_allocator_default_exec:s0" || return 1
ADD_TO_WORK_DIR "r0sxxx" "vendor" "$WFD_ALLOC_RC" \
    0 0 644 "u:object_r:vendor_file:s0" || return 1

# A vendor service that cannot resolve one of its DT_NEEDED entries will not
# start, and init will silently respawn it. Walk the service's own graph so the
# build fails here instead of shipping a phone whose DeX never allocates.
#
# LC_ALL=C matters on the readelf side: the tool localises its output, and on
# this build it prints "Biblioteca Compartilhada" rather than "Shared library",
# which made the sed below match nothing and turned this loop into a no-op that
# silently approved every donor.
WFD_ALLOC_WORK="$WORK_DIR/vendor/$WFD_ALLOC_SERVICE"
if [ ! -f "$WFD_ALLOC_WORK" ]; then
    ABORT "Allocator 4.0 service was not staged into the work directory"
    return 1
fi
WFD_ALLOC_NEEDED_LIST="$(LC_ALL=C readelf -d "$WFD_ALLOC_WORK" 2>/dev/null | \
    LC_ALL=C sed -n 's/.*Shared library: \[\(.*\)\]/\1/p')"
if [ -z "$WFD_ALLOC_NEEDED_LIST" ]; then
    ABORT "Could not read DT_NEEDED from the allocator 4.0 service, refusing to skip the closure check"
    return 1
fi

while read -r WFD_ALLOC_NEEDED; do
    case "$WFD_ALLOC_NEEDED" in
        libc.so|libdl.so|libdl_android.so|libm.so|libc++.so)
            continue
            ;;
    esac
    if [ -f "$WORK_DIR/vendor/lib64/$WFD_ALLOC_NEEDED" ] || \
            [ -f "$WORK_DIR/system/system/lib64/$WFD_ALLOC_NEEDED" ]; then
        continue
    fi
    ABORT "Allocator 4.0 service needs $WFD_ALLOC_NEEDED, which is in neither /vendor/lib64 nor /system/lib64"
    return 1
done <<EOF
$WFD_ALLOC_NEEDED_LIST
EOF

# The service is a hwbinder HAL, so the declaration is transport-level and
# carries no arch, exactly like the 2.0 entry it sits next to. Selecting the
# 2.0 block by its own <name> keeps the rewrite from touching anything else in
# the manifest.
if ! grep -qF '<fqname>@4.0::IAllocator/default</fqname>' "$WFD_VINTF"; then
    WFD_VINTF_ALLOC='    <hal format="hidl">
        <name>android.hardware.graphics.allocator</name>
        <transport>hwbinder</transport>
        <version>4.0</version>
        <interface>
            <name>IAllocator</name>
            <instance>default</instance>
        </interface>
        <fqname>@4.0::IAllocator/default</fqname>
    </hal>'

    WFD_VINTF_TMP="$WFD_VINTF.zzwfd.tmp"
    awk -v add40="$WFD_VINTF_ALLOC" '
        /<hal[ >]/ { inblock = 1; blk = $0 ORS; next }
        inblock {
            blk = blk $0 ORS
            if ($0 ~ /<\/hal>/) {
                if (blk ~ /<name>android\.hardware\.graphics\.allocator<\/name>/ &&
                        blk !~ /@4\.0::IAllocator/) {
                    printf "%s", blk
                    printf "%s\n", add40
                } else {
                    printf "%s", blk
                }
                inblock = 0
                blk = ""
            }
            next
        }
        { print }
    ' "$WFD_VINTF" > "$WFD_VINTF_TMP" || {
        ABORT "Failed to rewrite the allocator block in VINTF"
        rm -f "$WFD_VINTF_TMP"
        return 1
    }

    # The 2.0 entry must survive untouched for ARM64, and the new 4.0 entry
    # must be the only allocator 4.0 in the file.
    if [ "$(grep -cF '<fqname>@2.0::IAllocator/default</fqname>' "$WFD_VINTF_TMP")" != "1" ] || \
            [ "$(grep -cF '<fqname>@4.0::IAllocator/default</fqname>' "$WFD_VINTF_TMP")" != "1" ]; then
        ABORT "VINTF rewrite did not produce exactly one 2.0 and one 4.0 allocator entry"
        rm -f "$WFD_VINTF_TMP"
        return 1
    fi

    cat "$WFD_VINTF_TMP" > "$WFD_VINTF" || {
        ABORT "Failed to install the rewritten allocator VINTF"
        rm -f "$WFD_VINTF_TMP"
        return 1
    }
    rm -f "$WFD_VINTF_TMP"
    LOG "  - allocator 4.0 hwbinder service declared alongside the existing 2.0"
fi

# Reject incomplete or mixed-architecture dependency graphs during the build.
declare -A ARM32_WFD_VALIDATED=()

VALIDATE_ARM32_WFD_ELF()
{
    local ELF_PATH="$1"
    local ELF_NAME="${ELF_PATH##*/}"
    local NEEDED_LIB
    local NEEDED_PATH

    [ "${ARM32_WFD_VALIDATED[$ELF_NAME]+set}" ] && return 0
    ARM32_WFD_VALIDATED["$ELF_NAME"]=1

    if [ ! -f "$ELF_PATH" ]; then
        ABORT "Missing ARM32 WFD dependency: $ELF_NAME"
        return 1
    fi
    if ! LC_ALL=C readelf -h "$ELF_PATH" 2>/dev/null | grep -q 'ELF32'; then
        ABORT "ARM32 WFD dependency is not ELF32: $ELF_NAME"
        return 1
    fi

    while read -r NEEDED_LIB; do
        case "$NEEDED_LIB" in
            libc.so|libdl.so|libdl_android.so|libm.so)
                continue
                ;;
        esac
        NEEDED_PATH="$WORK_DIR/system/system/lib/$NEEDED_LIB"
        if [ ! -f "$NEEDED_PATH" ]; then
            # Resolve from either donor at the validation boundary as well.
            # This makes the check self-healing and prevents one omitted root
            # from turning a large dependency graph into repeated build/fail
            # cycles.
            ADD_R11S_WFD_LIB "$NEEDED_LIB" true || return 1
        fi
        if [ ! -f "$NEEDED_PATH" ]; then
            ABORT "$ELF_NAME requires missing ARM32 library: $NEEDED_LIB"
            return 1
        fi
        VALIDATE_ARM32_WFD_ELF "$NEEDED_PATH" || return 1
    done < <(readelf -d "$ELF_PATH" 2>/dev/null | \
        sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p')
}

VALIDATE_ARM32_WFD_ELF \
    "$WORK_DIR/system/system/bin/remotedisplay" || return 1
LOG "  - ARM32 RemoteDisplay dependency graph validated"

unset R9S_WFD_LIBS R9S_WFD_LIB R9S_WFD_64_REMOVE R9S_WFD_64_LIB \
    WFD_RUNTIME_ROOT WFD_IMPORTED ARM32_WFD_VALIDATED \
    WFD_I18N_DONOR WFD_I18N_CANDIDATE WFD_I18N_APEX WFD_I18N_TMP \
    WFD_I18N_LIBS WFD_I18N_LIB WFD_I18N_PAYLOAD WFD_I18N_MOUNTED \
    WFD_AUDIO_LIBS WFD_AUDIO_DONOR WFD_AUDIO_LIB WFD_AUDIO_SRC \
    WFD_AUDIO_TRACK_SYMBOL WFD_AUDIO_COMPAT WFD_AUDIO_TYPES_COMPAT \
    WFD_AUDIO_NBLOG_COMPAT WFD_AUDIO_WFD_LIB \
    WFD_GRALLOC_LIBS WFD_GRALLOC_DONOR WFD_GRALLOC_LIB WFD_GRALLOC_SRC \
    WFD_GRALLOC_IMPL WFD_GRALLOC_STUB WFD_GRALLOC_SYM WFD_GRALLOC_MISSING \
    WFD_VINTF WFD_VINTF_NEW WFD_VINTF_TMP WFD_VINTF_FOUND \
    WFD_ALLOC_SERVICE WFD_ALLOC_RC WFD_ALLOC_DONOR WFD_ALLOC_LIBS WFD_ALLOC_LIB \
    WFD_ALLOC_SRC WFD_ALLOC_WORK WFD_ALLOC_NEEDED WFD_VINTF_ALLOC
unset -f ADD_R11S_WFD_LIB VALIDATE_ARM32_WFD_ELF

LOG_STEP_OUT
