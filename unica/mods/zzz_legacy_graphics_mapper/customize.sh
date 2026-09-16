# Android 16+ Samsung libui keeps the Gralloc 3/2 implementations in the
# binary, but refuses to try them when android_get_device_api_level() is newer
# than 35.  Legacy vendors such as Exynos 990 expose mapper 2.1, so that gate
# makes GraphicBufferMapper abort even though a compatible fallback is present.
if [ "$SOURCE_PLATFORM_SDK_VERSION" -le 35 ] || \
        [ "$TARGET_PLATFORM_SDK_VERSION" -gt 30 ]; then
    return 0
fi

LIBUI="$WORK_DIR/system/system/lib64/libui.so"

# GraphicBufferMapper and GraphicBuffer each construct their own mapper
# fallback chain. Samsung guards both chains with an API-level check, so both
# branches must be removed for a vendor that still exposes Mapper 2.1.
MAPPER_ORIGINAL="8fbc00941f8c0071ac03005400028052"
MAPPER_PATCHED="8fbc00941f8c00711f2003d500028052"
BUFFER_ORIGINAL="fdb800941f8c0071ac05005400028052"
BUFFER_PATCHED="fdb800941f8c00711f2003d500028052"

if [ ! -f "$LIBUI" ]; then
    LOGE "Missing /system/system/lib64/libui.so"
    return 1
fi

for GATE in MAPPER BUFFER; do
    eval "ORIGINAL=\${${GATE}_ORIGINAL}"
    eval "PATCHED=\${${GATE}_PATCHED}"

    if xxd -p -c 0 "$LIBUI" | grep -q "$PATCHED"; then
        LOG "- Legacy graphics $GATE fallback is already enabled"
    elif xxd -p -c 0 "$LIBUI" | grep -q "$ORIGINAL"; then
        HEX_PATCH "$LIBUI" "$ORIGINAL" "$PATCHED" || return 1
    else
        LOGE "Unsupported libui.so: legacy graphics $GATE API-level gate was not found"
        return 1
    fi
done

# Fail the build rather than shipping a libui that would put SurfaceFlinger in
# a native-crash loop before boot completion.
for PATCHED in "$MAPPER_PATCHED" "$BUFFER_PATCHED"; do
    if ! xxd -p -c 0 "$LIBUI" | grep -q "$PATCHED"; then
        LOGE "Failed to enable every legacy graphics mapper fallback"
        return 1
    fi
done

unset LIBUI GATE ORIGINAL PATCHED
unset MAPPER_ORIGINAL MAPPER_PATCHED BUFFER_ORIGINAL BUFFER_PATCHED
