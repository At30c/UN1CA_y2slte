# shellcheck disable=SC2034
SKIPUNZIP=1

if [ ! "$(GET_PROP "system" "ro.unica.codename")" ]; then
    LOG "- Patching /system/system/etc/selinux/plat_property_contexts"
    EVAL "echo \"ro.unica.codename u:object_r:build_prop:s0 exact string\" >> \"$WORK_DIR/system/system/etc/selinux/plat_property_contexts\""
    SET_PROP "system" "ro.unica.codename" "$ROM_CODENAME"
fi

# 2025 Audio Pack
LOG_STEP_IN "- Fixing audio pack for Android 17"
SET_PROP "vendor" "ro.config.ringtone" "ACH_Galaxy_Bells.ogg"
SET_PROP "vendor" "ro.config.notification_sound" "ACH_Spaceline.ogg"
SET_PROP "vendor" "ro.config.alarm_alert" "ACH_Homecoming.ogg"
SET_PROP "vendor" "ro.config.media_sound" "Media_preview_Over_the_horizon.ogg"
SET_PROP "vendor" "ro.config.ringtone_2" "ACH_Atomic_Bell.ogg"
SET_PROP "vendor" "ro.config.notification_sound_2" "ACH_Signal.ogg"

# Game Booster
LOG "- Downloading latest Game Booster app"
GAME_TOOLS_APK="$WORK_DIR/system/system/priv-app/GameTools_Dream/GameTools_Dream.apk"
GAME_TOOLS_URL="$(GET_GALAXY_STORE_DOWNLOAD_URL "com.samsung.android.game.gametools")" || true
if [ "$GAME_TOOLS_URL" ]; then
    DOWNLOAD_FILE "$GAME_TOOLS_URL" "$GAME_TOOLS_APK"
elif [ -f "$GAME_TOOLS_APK" ]; then
    LOG "- Galaxy Store download is unavailable; keeping Game Booster from the source firmware"
else
    LOGE "Game Booster is unavailable from both Galaxy Store and source firmware"
    return 1
fi
unset GAME_TOOLS_APK GAME_TOOLS_URL
