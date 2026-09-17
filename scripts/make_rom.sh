#!/usr/bin/env bash
# Copyright (c) 2025 Salvo Giangreco
# SPDX-License-Identifier: GPL-3.0-or-later

# Run from an immutable snapshot. A build can take hours, and changing this
# file while Bash is still reading it can otherwise corrupt the command being
# parsed at the current file offset.
if [ -z "${UNICA_MAKE_ROM_SNAPSHOT:-}" ]; then
    UNICA_MAKE_ROM_SNAPSHOT_PATH="$(mktemp "${TMPDIR:-/tmp}/unica-make-rom.XXXXXX")" || exit 1
    cp -a "${BASH_SOURCE[0]}" "$UNICA_MAKE_ROM_SNAPSHOT_PATH" || {
        rm -f -- "$UNICA_MAKE_ROM_SNAPSHOT_PATH"
        exit 1
    }
    export UNICA_MAKE_ROM_SNAPSHOT=1
    export UNICA_MAKE_ROM_SNAPSHOT_PATH
    trap 'rm -f -- "$UNICA_MAKE_ROM_SNAPSHOT_PATH"' EXIT
    exec bash "$UNICA_MAKE_ROM_SNAPSHOT_PATH" "$@"
fi

# [
source "$SRC_DIR/scripts/utils/firmware_utils.sh" || exit 1

FORCE=false
USE_APK_CACHE=false
BUILD_ROM=false
BUILD_ZIP=true
BUILD_INCREMENTAL=false
SKIP_DEBUG_INSTALL=false

START_TIME="$(date +%s)"

SOURCE_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$SOURCE_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$SOURCE_FIRMWARE")"
TARGET_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"
APK_CACHE_DIR="$OUT_DIR/target/$TARGET_CODENAME/apk_cache"
APK_DECODE_CACHE_DIR="$OUT_DIR/target/$TARGET_CODENAME/apk_decode_cache"
APK_BUILD_LIST="$OUT_DIR/target/$TARGET_CODENAME/tmp/apk-cache-build.list"
APK_CACHE_FORMAT="unica-apk-cache-v2"
INCREMENTAL_DIR="$OUT_DIR/target/$TARGET_CODENAME/incremental"
INCREMENTAL_BASE="$INCREMENTAL_DIR/base-target-files.zip"
INCREMENTAL_TARGET="$INCREMENTAL_DIR/target-files.zip"

GET_PATCHED_APK_HASH()
{
    local DECODED_PATH="$1"
    local RELATIVE_PATH="$2"
    local CERT_PREFIX="aosp"

    [ -d "$DECODED_PATH" ] || return 1
    $ROM_IS_OFFICIAL && CERT_PREFIX="unica"

    {
        printf '%s\n' "$APK_CACHE_FORMAT" "$RELATIVE_PATH"
        find "$DECODED_PATH" -type f \
            ! -path "$DECODED_PATH/build/*" \
            ! -path "$DECODED_PATH/dist/*" \
            -print0 | sort -z | xargs -0 sha256sum
        sha256sum "$SRC_DIR/scripts/apktool.sh"
        if [[ "$RELATIVE_PATH" == *.apk ]]; then
            sha256sum "$SRC_DIR/security/${CERT_PREFIX}_platform.x509.pem" \
                "$SRC_DIR/security/${CERT_PREFIX}_platform.pk8"
        fi
    } | sha256sum | cut -d " " -f 1
}

GET_BUILT_APK_PATH()
{
    local RELATIVE_PATH="$1"
    local PARTITION
    local FILE

    PARTITION="$(cut -d "/" -f 1 -s <<< "$RELATIVE_PATH")"
    FILE="$(cut -d "/" -f 2- -s <<< "$RELATIVE_PATH")"

    case "$PARTITION" in
        "system")
            echo "$WORK_DIR/system/system/$FILE"
            ;;
        "system_ext")
            if $TARGET_OS_BUILD_SYSTEM_EXT_PARTITION; then
                echo "$WORK_DIR/system_ext/$FILE"
            else
                echo "$WORK_DIR/system/system/system_ext/$FILE"
            fi
            ;;
        *)
            echo "$WORK_DIR/$PARTITION/$FILE"
            ;;
    esac
}

RESTORE_APK_CACHE()
{
    local CACHE_HASH
    local CURRENT_HASH
    local DECODED_PATH
    local RELATIVE_PATH
    local OUTPUT_FILE
    local HIT_COUNT="0"
    local MISS_COUNT="0"

    mkdir -p "$(dirname "$APK_BUILD_LIST")"
    : > "$APK_BUILD_LIST"

    while IFS= read -r -d '' f; do
        DECODED_PATH="$f"
        RELATIVE_PATH="${f/$APKTOOL_DIR\//}"
        OUTPUT_FILE="$(GET_BUILT_APK_PATH "$RELATIVE_PATH")"
        CURRENT_HASH="$(GET_PATCHED_APK_HASH "$DECODED_PATH" "$RELATIVE_PATH")" || return 1
        CACHE_HASH="$(cat "$APK_CACHE_DIR/hashes/$RELATIVE_PATH" 2> /dev/null || true)"

        if [ "$CACHE_HASH" = "$CURRENT_HASH" ] && \
                [ -f "$APK_CACHE_DIR/files/$RELATIVE_PATH" ]; then
            mkdir -p "$(dirname "$OUTPUT_FILE")"
            cp -a --reflink=auto "$APK_CACHE_DIR/files/$RELATIVE_PATH" "$OUTPUT_FILE"
            HIT_COUNT=$((HIT_COUNT + 1))
        else
            printf '%s\0' "$DECODED_PATH" >> "$APK_BUILD_LIST"
            MISS_COUNT=$((MISS_COUNT + 1))
        fi
    done < <(find "$APKTOOL_DIR" -type d \( -name "*.apk" -o -name "*.jar" \) -print0)

    LOG "- APK/JAR incremental cache: $HIT_COUNT reused, $MISS_COUNT to build"
    return 0
}

UPDATE_APK_CACHE()
{
    local CACHE_TMP
    local DECODED_PATH
    local FILE_HASH
    local RELATIVE_PATH
    local OUTPUT_FILE

    [ -d "$APKTOOL_DIR" ] || return 0
    CACHE_TMP="$APK_CACHE_DIR.tmp.$$"
    rm -rf "$CACHE_TMP"
    mkdir -p "$CACHE_TMP/files" "$CACHE_TMP/hashes"

    while IFS= read -r -d '' f; do
        DECODED_PATH="$f"
        RELATIVE_PATH="${f/$APKTOOL_DIR\//}"
        OUTPUT_FILE="$(GET_BUILT_APK_PATH "$RELATIVE_PATH")"
        [ -f "$OUTPUT_FILE" ] || return 1
        FILE_HASH="$(GET_PATCHED_APK_HASH "$DECODED_PATH" "$RELATIVE_PATH")" || return 1
        mkdir -p "$CACHE_TMP/files/$(dirname "$RELATIVE_PATH")" \
            "$CACHE_TMP/hashes/$(dirname "$RELATIVE_PATH")"
        cp -a --reflink=auto "$OUTPUT_FILE" "$CACHE_TMP/files/$RELATIVE_PATH"
        printf '%s' "$FILE_HASH" > "$CACHE_TMP/hashes/$RELATIVE_PATH"
    done < <(find "$APKTOOL_DIR" -type d \( -name "*.apk" -o -name "*.jar" \) -print0)

    printf '%s' "$APK_CACHE_FORMAT" > "$CACHE_TMP/.format"
    rm -rf "$APK_CACHE_DIR"
    mv "$CACHE_TMP" "$APK_CACHE_DIR"
    LOG "- Updated per-file APK/JAR cache"
}

BUILD_APKS()
{
    local BUILD_LIST="${1:-}"
    local MAX_JOBS
    MAX_JOBS="$(nproc)"
    [ "$MAX_JOBS" -gt "8" ] && MAX_JOBS="8"

    if [ -d "$APKTOOL_DIR" ]; then
        if [ -n "$BUILD_LIST" ] && [ ! -s "$BUILD_LIST" ]; then
            LOG "- All APKs/JARs were restored from incremental cache"
            return 0
        fi

        LOG_STEP_IN true "Building APKs/JARs"

        # shellcheck disable=SC2016
        if [ -n "$BUILD_LIST" ]; then
            cat "$BUILD_LIST"
        else
            find "$APKTOOL_DIR" -type d \( -name "*.apk" -o -name "*.jar" \) -print0
        fi | xargs -0 -r -I "{}" -P "$MAX_JOBS" \
            bash -c '
                FILE="${1/$APKTOOL_DIR\//}"
                PARTITION="$(cut -d "/" -f 1 -s <<< "$FILE")"
                [[ "$PARTITION" != "system" ]] && FILE="$(cut -d "/" -f 2- -s <<< "$FILE")"
                "$SRC_DIR/scripts/apktool.sh" b -j "$2" "$PARTITION" "$FILE"
            ' "bash" "{}" "$MAX_JOBS" || exit 1

        LOG_STEP_OUT
    fi
}

GET_WORK_DIR_HASH()
{
    if [ "${TARGET_PLATFORM//none/}" ] && [ -d "$SRC_DIR/platform/$TARGET_PLATFORM" ]; then
        find -H "$SRC_DIR/scripts" "$SRC_DIR/unica" "$SRC_DIR/platform/$TARGET_PLATFORM" \
            "$SRC_DIR/target/$TARGET_CODENAME" -type f -print0 | \
            sort -z | xargs -0 sha1sum | sha1sum | cut -d " " -f 1
    else
        find -H "$SRC_DIR/scripts" "$SRC_DIR/unica" "$SRC_DIR/target/$TARGET_CODENAME" \
            -type f -print0 | \
            sort -z | xargs -0 sha1sum | sha1sum | cut -d " " -f 1
    fi
}

PREPARE_SCRIPT()
{
    while [[ "$#" != 0 ]]; do
        if [[ "$1" == "--force" ]] || [[ "$1" == "-f" ]]; then
            FORCE=true
        elif [[ "$1" == "--use-apk-cache" ]] || [[ "$1" == "-c" ]]; then
            USE_APK_CACHE=true
        elif [[ "$1" == "--no-rom-zip" ]] || [[ "$1" == "-z" ]]; then
            BUILD_ZIP=false
        elif [[ "$1" == "--incremental" ]] || [[ "$1" == "-i" ]]; then
            BUILD_INCREMENTAL=true
        else
            if [[ "$1" == "-"* ]]; then
                LOGE "Unknown option: $1"
            fi
            PRINT_USAGE
            exit 1
        fi

        shift
    done
}

# shellcheck disable=SC2317,SC2329
PRINT_BUILD_OUTCOME()
{
    local EXIT_CODE="$?"
    local END_TIME
    local ESTIMATED

    [ -n "${UNICA_MAKE_ROM_SNAPSHOT_PATH:-}" ] && \
        rm -f -- "$UNICA_MAKE_ROM_SNAPSHOT_PATH"

    END_TIME="$(date +%s)"
    ESTIMATED="$((END_TIME - START_TIME))"

    if [[ "$EXIT_CODE" != "0" ]]; then
        echo -n -e '\n\033[1;31m'"Build failed "
    else
        echo -n -e '\n\033[1;32m'"Build completed "
    fi
    echo -e "in $((ESTIMATED / 3600))hrs $(((ESTIMATED / 60) % 60))min $((ESTIMATED % 60))sec."'\033[0m\n'
}

PRINT_USAGE()
{
    echo "Usage: make_rom [options]" >&2
    echo " -f, --force : Force ROM build" >&2
    echo " -c, --use-apk-cache : Incrementally rebuild only changed APKs/JARs" >&2
    echo " -i, --incremental : Build a block-level update from the previous target-files snapshot" >&2
    echo " --no-rom-zip : Do not build ROM zip" >&2
}
# ]

PREPARE_SCRIPT "$@"

# apktool.sh is also invoked indirectly by patch modules. Exporting the cache
# policy here lets every decode participate without changing module scripts.
export APK_DECODE_CACHE_DIR
if $USE_APK_CACHE; then
    export APK_DECODE_CACHE_MODE="reuse"
else
    export APK_DECODE_CACHE_MODE="refresh"
    rm -rf "$APK_DECODE_CACHE_DIR"
fi

# Every make_rom invocation starts from a pristine filesystem tree, regardless
# of the selected options. APK/JAR caches are stored outside WORK_DIR and remain
# available when -c/--use-apk-cache is used.
if [ -d "$WORK_DIR" ]; then
    LOG "- Cleaning previous work dir"
    rm -rf "${WORK_DIR:?}"
fi

if $FORCE || ! $USE_APK_CACHE; then
    # A regular invocation intentionally performs a clean ROM rebuild and
    # refreshes the APK/JAR cache. Cache reuse is opt-in with -c.
    BUILD_ROM=true
else
    if [ -f "$WORK_DIR/.completed" ]; then
        if [[ "$(cat "$WORK_DIR/.completed")" == "$(GET_WORK_DIR_HASH)" ]]; then
            LOGW "No changes have been detected in the build environment"
            BUILD_ROM=false
        else
            LOGW "Changes detected in the build environment"
            BUILD_ROM=true
        fi
    else
        BUILD_ROM=true
    fi
fi

trap 'PRINT_BUILD_OUTCOME' EXIT
trap 'echo' INT

if $BUILD_ROM; then
    [ -d "$APKTOOL_DIR" ] && rm -rf "$APKTOOL_DIR"

    if [ ! -f "$FW_DIR/$SOURCE_FIRMWARE_PATH/.extracted" ] || [ ! -f "$FW_DIR/$TARGET_FIRMWARE_PATH/.extracted" ]; then
        if ! ODIN_FIRMWARE_IS_COMPLETE "$ODIN_DIR/$SOURCE_FIRMWARE_PATH" || \
                ! ODIN_FIRMWARE_IS_COMPLETE "$ODIN_DIR/$TARGET_FIRMWARE_PATH"; then
            LOG_STEP_IN true "Downloading required firmwares"
            "$SRC_DIR/scripts/download_fw.sh" || exit 1
            LOG_STEP_OUT
        fi
        LOG_STEP_IN true "Extracting required firmwares"
        "$SRC_DIR/scripts/extract_fw.sh" || exit 1
        LOG_STEP_OUT
    fi

    LOG_STEP_IN true "Creating work dir"
    "$SRC_DIR/scripts/internal/create_work_dir.sh" || exit 1
    LOG_STEP_OUT

    if [ -d "$SRC_DIR/platform/$TARGET_PLATFORM/patches" ]; then
        LOG_STEP_IN true "Applying platform patches"
        "$SRC_DIR/scripts/internal/apply_modules.sh" "$SRC_DIR/platform/$TARGET_PLATFORM/patches" || exit 1
        LOG_STEP_OUT
    fi
    if [ -d "$SRC_DIR/target/$TARGET_CODENAME/patches" ]; then
        LOG_STEP_IN true "Applying device patches"
        "$SRC_DIR/scripts/internal/apply_modules.sh" "$SRC_DIR/target/$TARGET_CODENAME/patches" || exit 1
        LOG_STEP_OUT
    fi
    if [ -d "$SRC_DIR/unica/patches" ]; then
        LOG_STEP_IN true "Applying ROM patches"
        "$SRC_DIR/scripts/internal/apply_modules.sh" "$SRC_DIR/unica/patches" || exit 1
        LOG_STEP_OUT
    fi

    if [ -d "$SRC_DIR/unica/mods" ]; then
        LOG_STEP_IN true "Applying ROM mods"
        "$SRC_DIR/scripts/internal/apply_modules.sh" "$SRC_DIR/unica/mods" || exit 1
        LOG_STEP_OUT
    fi

    if $USE_APK_CACHE; then
        RESTORE_APK_CACHE || exit 1
        BUILD_APKS "$APK_BUILD_LIST"
    else
        BUILD_APKS
    fi
    UPDATE_APK_CACHE || exit 1

    echo -n "$(GET_WORK_DIR_HASH)" > "$WORK_DIR/.completed"
fi

if $BUILD_ZIP; then
    if $BUILD_INCREMENTAL; then
        mkdir -p "$INCREMENTAL_DIR"
        rm -f "$INCREMENTAL_TARGET"

        LOG_STEP_IN true "Creating incremental target-files"
        "$SRC_DIR/scripts/internal/create_target_files_zip.sh" "$INCREMENTAL_TARGET" || exit 1
        LOG_STEP_OUT

        LOG_STEP_IN true "Creating incremental ROM zip"
        if [ -f "$INCREMENTAL_BASE" ]; then
            "$SRC_DIR/scripts/build_flashable_zip.sh" \
                --incremental "$INCREMENTAL_BASE" "$INCREMENTAL_TARGET" || exit 1
        else
            LOGW "No incremental base exists; creating a full ZIP and establishing the baseline"
            "$SRC_DIR/scripts/build_flashable_zip.sh" "$INCREMENTAL_TARGET" || exit 1
        fi
        LOG_STEP_OUT

        # Promote the target only after the ZIP was generated successfully. A
        # failed build must never destroy the last known installable baseline.
        mv -f "$INCREMENTAL_TARGET" "$INCREMENTAL_BASE"
        LOG "- Updated incremental baseline: ${INCREMENTAL_BASE//$SRC_DIR\//}"
    else
        LOG_STEP_IN true "Creating zip"
        "$SRC_DIR/scripts/internal/build_flashable_zip.sh" || exit 1
        LOG_STEP_OUT
    fi
fi

exit 0
