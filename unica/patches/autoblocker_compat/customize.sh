if [[ "$SOURCE_PLATFORM_SDK_VERSION" -ge 36 ]]; then
    LOG_STEP_IN "- Disabling Auto Blocker"

    RAMPART_APK="system/app/Rampart/Rampart.apk"
    DECODE_APK "system" "$RAMPART_APK"

    RAMPART_DECODE_DIR="$APKTOOL_DIR/$RAMPART_APK"
    RAMPART_DEVICE_CONFIG="$(grep -R -l -F 'ro.boot.verifiedbootstate' \
        "$RAMPART_DECODE_DIR"/smali* 2>/dev/null | head -n 1)"

    [ -n "$RAMPART_DEVICE_CONFIG" ] || \
        ABORT "Unable to locate Rampart verified-boot check"

    RAMPART_UNLOCK_METHOD="$(awk '
        /^\.method / { method = $0 }
        /const-string [vp][0-9]*, "ro\.boot\.verifiedbootstate"/ {
            sub(/^.* static /, "", method)
            print method
            exit
        }
    ' "$RAMPART_DEVICE_CONFIG")"

    [ -n "$RAMPART_UNLOCK_METHOD" ] || \
        ABORT "Unable to resolve Rampart unlocked-device method"

    RAMPART_DEVICE_CONFIG="${RAMPART_DEVICE_CONFIG#"$RAMPART_DECODE_DIR/"}"
    SMALI_PATCH "system" "$RAMPART_APK" \
        "$RAMPART_DEVICE_CONFIG" "return" \
        "$RAMPART_UNLOCK_METHOD" \
        "true"

    # Prevent Samsung services and the automatic deadline receiver from
    # enabling Rampart again after the boot-time reset below.
    SMALI_PATCH "system" "$RAMPART_APK" \
        "smali/com/samsung/android/rampart/components/receiver/RampartOnReceiver.smali" \
        "null" \
        "onReceive(Landroid/content/Context;Landroid/content/Intent;)V"
    SMALI_PATCH "system" "$RAMPART_APK" \
        "smali/com/samsung/android/rampart/components/receiver/AutoTurnOnReceiver.smali" \
        "null" \
        "onReceive(Landroid/content/Context;Landroid/content/Intent;)V"

    # Merely reporting an unlocked bootloader is not enough on a dirty flash:
    # Rampart can leave its previously applied policies in SettingsProvider.
    # Reset those policies from Rampart's own direct-boot handler, where the
    # package already has permission to write Secure and Global settings.
    RAMPART_BOOT_HANDLER="$(grep -R -l -F \
        'BootCompleteActionHandler: isRampartNotSupported' \
        "$RAMPART_DECODE_DIR"/smali* 2>/dev/null | head -n 1)"

    [ -n "$RAMPART_BOOT_HANDLER" ] || \
        ABORT "Unable to locate Rampart boot-complete handler"

    RAMPART_BOOT_METHOD="$(awk '
        /^\.method / { method = $0 }
        /BootCompleteActionHandler: isRampartNotSupported/ {
            sub(/^.* (public |private |protected )?(final )?/, "", method)
            print method
            exit
        }
    ' "$RAMPART_BOOT_HANDLER")"

    [ -n "$RAMPART_BOOT_METHOD" ] || \
        ABORT "Unable to resolve Rampart boot-complete method"

    RAMPART_BOOT_HANDLER_REL="${RAMPART_BOOT_HANDLER#"$RAMPART_DECODE_DIR/"}"

    # The reset below is written as raw smali, and smali does not verify that a
    # referenced class, field or method actually exists. A stale obfuscated
    # name therefore builds cleanly and only fails at runtime, which for the
    # boot handler means a NoClassDefFoundError on every broadcast followed by
    # a dumpstate soft reboot. Resolve every reference now, while the stock
    # decode in front of us can still be used to check it.
    RAMPART_SETTINGS_HELPER="smali/m5/a.smali"

    if [ -f "$RAMPART_DECODE_DIR/$RAMPART_SETTINGS_HELPER" ] && \
       grep -q "^\.method public final b(ILjava/lang/String;)V" \
           "$RAMPART_DECODE_DIR/$RAMPART_SETTINGS_HELPER" && \
       grep -q "^\.method public final d(ILjava/lang/String;)V" \
           "$RAMPART_DECODE_DIR/$RAMPART_SETTINGS_HELPER"; then
        RAMPART_SETTINGS_CLASS="Lm5/a;"
    else
        ABORT "Unable to resolve the Rampart settings wrapper used by the persisted-policy reset"
    fi

    # m5.a's putInt helpers only work on a non-null ContentResolver, so the
    # handler's own Context field is needed to build one. It is inherited, so
    # walk the .super chain until the declaration is found.
    RAMPART_CONTEXT_CLASS=""
    RAMPART_WALK="$RAMPART_DECODE_DIR/$RAMPART_BOOT_HANDLER_REL"

    while [ -f "$RAMPART_WALK" ]; do
        if grep -q "^\.field public final d:Landroid/content/Context;" "$RAMPART_WALK"; then
            RAMPART_CONTEXT_CLASS="L$(basename "$RAMPART_WALK" .smali | tr '/' '.')/;"
            break
        fi

        RAMPART_WALK="$(awk '
            /^\.super / {
                print "'"$RAMPART_DECODE_DIR"'/smali/" substr($2, 2) ".smali"
                exit
            }
        ' "$RAMPART_WALK")"
    done

    [ -n "$RAMPART_CONTEXT_CLASS" ] || \
        ABORT "Unable to resolve the Context field of the Rampart boot handler"

    LOG "- Resetting persisted Auto Blocker policies at locked boot"

    awk -v METHOD="$RAMPART_BOOT_METHOD" \
        -v SETTINGS="$RAMPART_SETTINGS_CLASS" \
        -v CONTEXT="$RAMPART_CONTEXT_CLASS" '
        BEGIN { in_method = 0; injected = 0 }

        /^\.method / && index($0, METHOD) {
            in_method = 1
        }

        {
            print
        }

        in_method && !injected && /^[[:space:]]*\.locals [0-9]+/ {
            print ""
            print "    # UN1CA: clear stale Rampart policy after a dirty flash"
            print "    move-object/from16 v0, p0"
            print ""
            print "    iget-object v0, v0, " CONTEXT "->d:Landroid/content/Context;"
            print ""
            print "    new-instance v1, " SETTINGS
            print ""
            print "    invoke-direct {v1, v0}, " SETTINGS "-><init>(Landroid/content/Context;)V"
            print ""
            print "    const/4 v0, 0x0"

            # block_usb_lock is maintained by UsbHostRestrictor outside Rampart,
            # but stale value 1 also forces the gadget back to sec_charging.
            key_count = split("rampart_main_switch_enabled rampart_strict_protection_switch_enabled rampart_auto_enabled_switch_enabled rampart_blocked_unknown_apps rampart_enabled_message_guard rampart_blocked_commands rampart_blocked_auto_download_messages rampart_blocked_link_preview_messages rampart_blocked_location_messages rampart_blocked_device_admin_apps rampart_enabled_device_protection rampart_blocked_usb_data_transfer rampart_blocked_shared_album_gallery rampart_blocked_location_gallery rampart_blocked_2g_network rampart_blocked_unsecure_wifi_autojoin rampart_blocked_adb_cmd rampart_blocked_at_cmd rampart_blocked_keystring block_usb_lock", keys, " ")
            for (i = 1; i <= key_count; i++) {
                print ""
                print "    const-string v2, \"" keys[i] "\""
                print ""
                print "    invoke-virtual {v1, v0, v2}, " SETTINGS "->d(ILjava/lang/String;)V"
            }

            print ""
            print "    const/4 v0, 0x1"
            print ""
            print "    const-string v2, \"adb_enabled\""
            print ""
            print "    invoke-virtual {v1, v0, v2}, " SETTINGS "->b(ILjava/lang/String;)V"
            print ""
            injected = 1
        }

        in_method && /^\.end method/ {
            in_method = 0
        }

        END {
            if (!injected) {
                exit 42
            }
        }
    ' "$RAMPART_BOOT_HANDLER" > "$RAMPART_BOOT_HANDLER.tmp" || \
        ABORT "Unable to inject Rampart persisted-policy reset"

    mv "$RAMPART_BOOT_HANDLER.tmp" "$RAMPART_BOOT_HANDLER"

    unset RAMPART_APK RAMPART_DECODE_DIR RAMPART_DEVICE_CONFIG \
        RAMPART_UNLOCK_METHOD RAMPART_BOOT_HANDLER RAMPART_BOOT_METHOD \
        RAMPART_BOOT_HANDLER_REL RAMPART_SETTINGS_HELPER \
        RAMPART_SETTINGS_CLASS RAMPART_CONTEXT_CLASS RAMPART_WALK
    LOG_STEP_OUT
fi
