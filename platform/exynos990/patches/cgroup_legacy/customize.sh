# Replace the S24+ donor's cgroup userspace configuration with the One UI 8.5
# (Android 16) variants so the runtime exactly matches what the Exynos 990
# kernel exposes.
#
# The Exynos 990 Linux 4.19 cgroup v2 hierarchy only mounts the freezer
# controller; the memory controller is declared Optional/NeedsActivation and is
# never activated.  Newer donor builds ship libcgrouprc.so and task_profiles.json
# whose descriptors assume a kernel that provides the cgroup v2 memory
# controller.  When a sandboxed zygote child applies the SystemMemoryProcess
# profile during process specialization, that configuration cannot be satisfied
# and the child aborts, stalling the zygote accept loop.  system_server surfaces
# it as the endless "Got error connecting to zygote, retrying. msg= Connection
# refused" spam when opening a Chrome tab.
#
# Keep cgroups.json, task_profiles.json and lib64/libcgrouprc.so aligned with
# the One UI 8.5 release.  The 32-bit sibling (/system/lib/libcgrouprc.so) is
# supplied by the Android 16 r11s donor through zzz_runtime32_compat.

if [[ "$SOURCE_PLATFORM_SDK_VERSION" -lt 36 ]]; then
    LOG "- Source is not Android 16+; skipping One UI 8.5 cgroup compatibility"
    return 0
fi

LOG_STEP_IN "- Adding One UI 8.5 cgroup configuration for Exynos 990"

ADD_TO_WORK_DIR "e2sxxx" "system" "system/etc/cgroups.json" \
    0 0 644 "u:object_r:cgroup_desc_file:s0" || return 1
ADD_TO_WORK_DIR "e2sxxx" "system" "system/etc/task_profiles.json" \
    0 0 644 "u:object_r:task_profiles_file:s0" || return 1
ADD_TO_WORK_DIR "e2sxxx" "system" "system/lib64/libcgrouprc.so" \
    0 0 644 "u:object_r:system_lib_file:s0" || return 1

for f in \
    "$WORK_DIR/system/system/etc/cgroups.json" \
    "$WORK_DIR/system/system/etc/task_profiles.json" \
    "$WORK_DIR/system/system/lib64/libcgrouprc.so"
do
    if [ ! -f "$f" ]; then
        ABORT "One UI 8.5 cgroup file was not added: $f"
        return 1
    fi
done

LOG "  - cgroups.json, task_profiles.json and lib64/libcgrouprc.so aligned with One UI 8.5"

ADD_TO_WORK_DIR "e2sxxx" "system" "system/etc/init/cgroupmem.rc" \
    0 0 644 "u:object_r:system_file:s0" || return 1
if [ ! -f "$WORK_DIR/system/system/etc/init/cgroupmem.rc" ]; then
    ABORT "cgroupmem.rc was not added"
    return 1
fi

LOG "  - /system/etc/init/cgroupmem.rc activando o memory controller no boot"

ADD_TO_WORK_DIR "e2sxxx" "system" "system/lib64/libchrome.so" \
    0 0 644 "u:object_r:system_lib_file:s0" || return 1
if [ ! -f "$WORK_DIR/system/system/lib64/libchrome.so" ]; then
    ABORT "One UI 8.5 libchrome.so was not added"
    return 1
fi

LOG "  - lib64/libchrome.so aligned with the One UI 8.5 S24+ donor"

ADD_TO_WORK_DIR "e2sxxx" "vendor" "lib64/libchrome.so" \
    0 2000 644 "u:object_r:vendor_file:s0" || return 1
if [ ! -f "$WORK_DIR/vendor/lib64/libchrome.so" ]; then
    ABORT "One UI 8.5 vendor libchrome.so was not added"
    return 1
fi

LOG "  - vendor/lib64/libchrome.so aligned with the One UI 8.5 S24+ donor"
LOG_STEP_OUT