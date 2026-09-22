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
            libc.so|libdl.so|libdl_android.so|libm.so|libandroidicu.so)
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
    WFD_RUNTIME_ROOT WFD_IMPORTED ARM32_WFD_VALIDATED
unset -f ADD_R11S_WFD_LIB VALIDATE_ARM32_WFD_ELF

LOG_STEP_OUT
