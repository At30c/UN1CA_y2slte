LOG_STEP_IN "- Adding One UI 8.5 cgroup configuration"

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

LOG "  - Added cgroup configuration and libcgrouprc.so"

ADD_TO_WORK_DIR "e2sxxx" "system" "system/etc/init/cgroupmem.rc" \
    0 0 644 "u:object_r:system_file:s0" || return 1
if [ ! -f "$WORK_DIR/system/system/etc/init/cgroupmem.rc" ]; then
    ABORT "cgroupmem.rc was not added"
    return 1
fi

LOG "  - Added cgroup memory controller configuration"

ADD_TO_WORK_DIR "e2sxxx" "system" "system/lib64/libchrome.so" \
    0 0 644 "u:object_r:system_lib_file:s0" || return 1
if [ ! -f "$WORK_DIR/system/system/lib64/libchrome.so" ]; then
    ABORT "One UI 8.5 libchrome.so was not added"
    return 1
fi

LOG "  - Added One UI 8.5 system libchrome.so"

ADD_TO_WORK_DIR "e2sxxx" "vendor" "lib64/libchrome.so" \
    0 2000 644 "u:object_r:vendor_file:s0" || return 1
if [ ! -f "$WORK_DIR/vendor/lib64/libchrome.so" ]; then
    ABORT "One UI 8.5 vendor libchrome.so was not added"
    return 1
fi

LOG "  - Added One UI 8.5 vendor libchrome.so"

LOG_STEP_OUT
