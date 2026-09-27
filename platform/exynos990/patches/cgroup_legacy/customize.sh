LOG_STEP_IN "- Applying source-compatible cgroup configuration"

# The system partition comes from the S24+ source firmware, while vendor comes
# from the Exynos 990 target. The target's native cgroups.json is not suitable
# here: it uses /acct and omits profiles (SystemServiceCapacityHigh, for
# example) referenced by the S24+ system init files. The e2sxxx descriptor set
# is the Android 16 compatibility variant of those S24+ profiles: it keeps
# /dev/acct and the memory-v2 layout, but maps foreground-boost to the cpuset
# group that exists on the Exynos 990 target and drops unsupported profile
# entries such as cpu_mid.
ADD_TO_WORK_DIR "e2sxxx" "system" "system/etc/cgroups.json" || return 1
ADD_TO_WORK_DIR "e2sxxx" "system" "system/etc/task_profiles.json" || return 1

# The donor descriptor intentionally omits CgroupKill because older kernels
# lacked the v2 interface. The ExtremeKRNL patch below provides that
# interface, so add the source Android 17 attribute to the copied descriptor
# without changing the shared prebuilts asset.
CGROUP_TASK_PROFILES="$WORK_DIR/system/system/etc/task_profiles.json"
if ! grep -q '"Name": "CgroupKill"' "$CGROUP_TASK_PROFILES"; then
    CGROUP_TASK_PROFILES_TMP="$CGROUP_TASK_PROFILES.tmp"
    awk '
        /^    \{$/ { pending = $0; next }
        pending != "" && /^      "Name": "CgroupProcs"/ {
            print "    {"
            print "      \"Name\": \"CgroupKill\"" ","
            print "      \"Controller\": \"cgroup2\"" ","
            print "      \"File\": \"cgroup.kill\""
            print "    },"
            print pending
            pending = ""
        }
        pending != "" { print pending; pending = "" }
        { print }
        END { if (pending != "") print pending }
    ' "$CGROUP_TASK_PROFILES" > "$CGROUP_TASK_PROFILES_TMP" && \
        mv "$CGROUP_TASK_PROFILES_TMP" "$CGROUP_TASK_PROFILES" || return 1
fi
if ! grep -q '"Name": "CgroupKill"' "$CGROUP_TASK_PROFILES"; then
    ABORT "Could not add CgroupKill to task_profiles.json"
    return 1
fi

# The source Android 17 libcgrouprc has the same exported ABI and only the
# standard bionic/libbase dependencies. Keep the source binary paired with
# the source system image instead of replacing it with an older donor binary.
CGROUP_SOURCE_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$SOURCE_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$SOURCE_FIRMWARE")"
CGROUP_SOURCE_DIR="$FW_DIR/$CGROUP_SOURCE_FIRMWARE_PATH"
if [ ! -f "$CGROUP_SOURCE_DIR/system/system/lib64/libcgrouprc.so" ]; then
    ABORT "Source firmware libcgrouprc.so was not found: $CGROUP_SOURCE_DIR"
    return 1
fi
ADD_TO_WORK_DIR "$CGROUP_SOURCE_DIR" "system" "system/lib64/libcgrouprc.so" || return 1

# The VNDK namespace used by the target's 32-bit vendor services resolves
# libprocessgroup.so against the 32-bit cgroup client as well.  The S24+
# source is 64-bit-only, so provide a coherent ARM32 client/dependency set
# from the same r11s Android 17 donor as the imported system-side libraries.
# Mixing the target Android 33 libc++ with r11s liblog/libbase causes missing
# libc++ symbols at process startup. Bionic itself is installed by the
# source_apex runtime compatibility path.
ADD_TO_WORK_DIR "r11sxxx" "system" "system/lib/libcgrouprc.so" \
    0 0 644 "u:object_r:system_lib_file:s0" || return 1
ADD_TO_WORK_DIR "r11sxxx" "system" "system/lib/libbase.so" \
    0 0 644 "u:object_r:system_lib_file:s0" || return 1
ADD_TO_WORK_DIR "r11sxxx" "system" "system/lib/libc++.so" \
    0 0 644 "u:object_r:system_lib_file:s0" || return 1

# The memory controller is available in the 4.19 kernel and
# memory_recursiveprot is enabled. Keep the boot activation helper.
ADD_TO_WORK_DIR "e2sxxx" "system" "system/etc/init/cgroupmem.rc" \
    0 0 644 "u:object_r:system_file:s0" || return 1

# The source already carries libchrome.so in its own system image, so only the
# vendor copy has to be provided here. The target's own vendor library used to
# be dropped at this point, but the p3sxxx UWB and secure element services link
# against libchrome.so: with it missing the dynamic linker aborts both with
# "library libchrome.so not found" and the UWB HAL never starts.
#
# Every exynos990 target ships a vendor libchrome.so built together with the
# rest of its vendor binaries, so that one is kept whenever it is present and
# the source copy is only a fallback. Failing to find either is not fatal: this
# patch must not break targets that legitimately have no vendor libchrome.
CGROUP_VENDOR_LIBCHROME=false
if [ -f "$WORK_DIR/vendor/lib64/libchrome.so" ]; then
    LOG "  - Kept target vendor/lib64/libchrome.so"
elif [ -f "$CGROUP_SOURCE_DIR/vendor/lib64/libchrome.so" ]; then
    ADD_TO_WORK_DIR "$CGROUP_SOURCE_DIR" "vendor" "lib64/libchrome.so" || return 1
    CGROUP_VENDOR_LIBCHROME=true
    LOG "  - Imported source vendor/lib64/libchrome.so"
else
    LOG "  - No vendor/lib64/libchrome.so in the target or the source"
fi

for f in \
    "$WORK_DIR/system/system/etc/cgroups.json" \
    "$WORK_DIR/system/system/etc/task_profiles.json" \
    "$WORK_DIR/system/system/lib64/libcgrouprc.so" \
    "$WORK_DIR/system/system/lib/libcgrouprc.so" \
    "$WORK_DIR/system/system/lib/libbase.so" \
    "$WORK_DIR/system/system/lib/libc++.so" \
    "$WORK_DIR/system/system/etc/init/cgroupmem.rc"
do
    if [ ! -f "$f" ]; then
        ABORT "Source-compatible cgroup file was not installed: $f"
        return 1
    fi
done

if [ "$CGROUP_VENDOR_LIBCHROME" = true ] && \
        [ ! -f "$WORK_DIR/vendor/lib64/libchrome.so" ]; then
    ABORT "Source-compatible cgroup file was not installed: vendor/lib64/libchrome.so"
    return 1
fi

LOG "  - Installed e2sxxx-compatible cgroups.json/task_profiles.json"
LOG "  - Kept source $CGROUP_SOURCE_FIRMWARE_PATH libcgrouprc.so"

LOG_STEP_OUT
