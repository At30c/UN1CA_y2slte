#!/usr/bin/env bash
# Copyright (c) 2026 At30c <PabloAtsoc9993@outlook.com>
# SPDX-License-Identifier: GPL-3.0-or-later

# Samsung's imported Android 16 libgui only rewrites a GraphicBuffer's
# generation number in Surface::attachBuffer() while shared-buffer mode is
# enabled.  MediaCodec/ACodec reuses ordinary (non-shared) video buffers when
# Telegram/Discord replace a Surface, so BufferQueueProducer rejects them with
# BAD_VALUE (-22) after the queue receives the new generation.
if [[ "$TARGET_PLATFORM" != "exynos990" ]]; then
    return 0
fi

LIBGUI="$WORK_DIR/system/system/lib64/libgui.so"
if [[ ! -f "$LIBGUI" ]]; then
    LOGE "Missing $LIBGUI"
    return 1
fi

# Surface::attachBuffer() at the S926B donor's stable instruction sequence:
#   cmp w9, #1; b.ne skip_generation_write
# Make the generation write unconditional.  This keeps the producer-side
# buffer metadata synchronized before the compatibility guard below runs.
ATTACH_ORIGINAL="3f05007161000054698a43b909e500b9"
ATTACH_PATCHED="3f0500711f2003d5698a43b909e500b9"

# Surface::setGenerationNumber() normally updates its local generation only
# when the producer call succeeds.  Keep the local value synchronized even on
# a legacy producer return path; the producer-side compatibility guard below
# is limited to this donor's stale generation-0 video-buffer transition.
SETGEN_ORIGINAL="40000035748a03b9"
SETGEN_PATCHED="1f2003d5748a03b9"

# BufferQueueProducer::attachBuffer() compares GraphicBuffer::mGenerationNumber
# (w8) against BufferQueueCore::mGenerationNumber (w9) and branches to the
# BAD_VALUE path on every mismatch.  On this legacy framework/vendor pairing,
# the video buffer arrives as generation 0 immediately after MediaCodec's
# setOutputSurface() assigns the new queue generation.  The log shows the
# producer-side rejection, so synchronizing Surface alone is insufficient.
#
# Keep the comparison instruction for diagnostics, but disable only the
# conditional branch to the -EINVAL path.  This is intentionally narrower than
# changing the whole attachBuffer routine and leaves all other slot, fence, and
# queue validation intact.
GENERATION_GUARD_ORIGINAL="09c841b908e540b91f01096be1190054"
GENERATION_GUARD_PATCHED="09c841b908e540b91f01096b1f2003d5"

for PAIR in ATTACH SETGEN; do
    eval "ORIGINAL=\${${PAIR}_ORIGINAL}"
    eval "PATCHED=\${${PAIR}_PATCHED}"
    if xxd -p -c 0 "$LIBGUI" | grep -q "$PATCHED"; then
        LOG "Surface generation $PAIR synchronization is already enabled"
    elif xxd -p -c 0 "$LIBGUI" | grep -q "$ORIGINAL"; then
        HEX_PATCH "$LIBGUI" "$ORIGINAL" "$PATCHED" || return 1
    else
        LOGE "Unsupported libgui.so: Surface generation $PAIR sequence not found"
        return 1
    fi
done

if xxd -p -c 0 "$LIBGUI" | grep -q "$GENERATION_GUARD_PATCHED"; then
    LOG "BufferQueue generation guard compatibility is already enabled"
elif xxd -p -c 0 "$LIBGUI" | grep -q "$GENERATION_GUARD_ORIGINAL"; then
    HEX_PATCH "$LIBGUI" "$GENERATION_GUARD_ORIGINAL" "$GENERATION_GUARD_PATCHED" || return 1
else
    LOGE "Unsupported libgui.so: BufferQueue generation guard sequence not found"
    return 1
fi

for PATCHED in "$ATTACH_PATCHED" "$SETGEN_PATCHED" "$GENERATION_GUARD_PATCHED"; do
    if ! xxd -p -c 0 "$LIBGUI" | grep -q "$PATCHED"; then
        LOGE "Failed to enable every Surface generation synchronization sequence"
        return 1
    fi
done

unset LIBGUI PAIR ORIGINAL PATCHED
unset ATTACH_ORIGINAL ATTACH_PATCHED SETGEN_ORIGINAL SETGEN_PATCHED
unset GENERATION_GUARD_ORIGINAL GENERATION_GUARD_PATCHED
