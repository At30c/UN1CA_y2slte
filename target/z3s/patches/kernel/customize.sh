KERNEL_ZIP="$MODPATH/kernel.zip"
LOG "- Extracting Artisan kernel"

if [ -f "$WORK_DIR/kernel/boot.img" ]; then
    EVAL "rm -f \"$WORK_DIR/kernel/boot.img\""
fi
if [ -f "$WORK_DIR/kernel/dtbo.img" ]; then
    EVAL "rm -f \"$WORK_DIR/kernel/dtbo.img\""
fi

KERNEL_TMP_DIR="$WORK_DIR/kernel/tmp_extract"
EVAL "rm -rf \"$KERNEL_TMP_DIR\""
EVAL "mkdir -p \"$KERNEL_TMP_DIR\""

EVAL "unzip -o \"$KERNEL_ZIP\" -d \"$KERNEL_TMP_DIR\""

LOG "- Injecting kernel binaries"

EVAL "find \"$KERNEL_TMP_DIR\" -iname 'boot.img' -exec cp {} \"$WORK_DIR/kernel/boot.img\" \;"
EVAL "find \"$KERNEL_TMP_DIR\" -iname 'dtbo.img' -exec cp {} \"$WORK_DIR/kernel/dtbo.img\" \;"

EVAL "rm -rf \"$KERNEL_TMP_DIR\""

unset KERNEL_ZIP KERNEL_TMP_DIR
