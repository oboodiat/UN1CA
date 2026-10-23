# Disable app compaction
# Guard the patch as the source firmware might have this already disabled
LOG "- Applying \"Disable app compaction\" to /system/system/framework/services.jar"
APPLY_PATCH "system" "system/framework/services.jar" \
    "$MODPATH/appcompactor/services.jar/0001-Disable-app-compaction.patch" &> /dev/null || true

# Disable FM Radio country restrictions
if [[ "$(GET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_FMRADIO_CONFIG_CHIP_VENDOR")" != "0" ]]; then
    SET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_FMRADIO_CONFIG_AVOID_REGION" --delete

    SMALI_PATCH "system" "system/framework/samsungfmradiolib.jar" \
        "smali/com/samsung/frameworks/fmradio/FMRadioImpl.smali" "return" \
        'isRadioNotSupportedInRegion()Z' \
        'false'
fi

# Rebalance the shade blur (window vs. content)
# The radius constants are rescaled starting from the values found in the firmware,
# so no stock value has to be known. 100 leaves a constant untouched.
# NOTE: Blur Intensity Scale (SecQpBlurController) still multiplies the result at runtime
SHADE_WINDOW_BLUR_PCT=100
SHADE_CONTENT_BLUR_PCT=200

DECODE_APK "system_ext" "priv-app/SystemUI/SystemUI.apk"

SYSTEMUI_RES="$APKTOOL_DIR/system_ext/priv-app/SystemUI/SystemUI.apk/res"

for ENTRY in "max_shade_window_blur_radius:$SHADE_WINDOW_BLUR_PCT" \
        "max_shade_content_blur_radius:$SHADE_CONTENT_BLUR_PCT"; do
    DIMEN_NAME="${ENTRY%%:*}"
    DIMEN_PCT="${ENTRY##*:}"

    if [[ "$DIMEN_PCT" == "100" ]]; then
        continue
    fi

    DIMEN_FILES="$(find "$SYSTEMUI_RES" -path "*/values*/*.xml" ! -name "public.xml" \
        -exec grep -l "name=\"$DIMEN_NAME\"" {} + 2> /dev/null || true)"

    if [ -z "$DIMEN_FILES" ]; then
        LOGW "Dimen \"$DIMEN_NAME\" not found in SystemUI.apk, skipping"
        continue
    fi

    while IFS= read -r f; do
        DIMEN_FILE="${f#"$SYSTEMUI_RES"/}"

        # Current value of the dimen in this file, e.g. "120.0dip" or "@dimen/other"
        DIMEN_ORIG="$(grep -hoE "name=\"$DIMEN_NAME\">[^<]*<" "$f" 2> /dev/null | head -n 1 \
            | sed -e 's/^[^>]*>//' -e 's/<$//' || true)"
        DIMEN_VALUE="$DIMEN_ORIG"

        # Follow references (@dimen/...) down to a plain number, so a dimen that only
        # points to another one gets its own scaled value without touching the target
        DIMEN_DEPTH=0
        while [[ "$DIMEN_VALUE" == "@dimen/"* ]] && [ "$DIMEN_DEPTH" -lt 5 ]; do
            DIMEN_REF="${DIMEN_VALUE#@dimen/}"
            DIMEN_VALUE="$(find "$SYSTEMUI_RES" -path "*/values/*.xml" ! -name "public.xml" \
                -exec grep -hoE "name=\"$DIMEN_REF\">[^<]*<" {} + 2> /dev/null | head -n 1 \
                | sed -e 's/^[^>]*>//' -e 's/<$//' || true)"
            DIMEN_DEPTH=$((DIMEN_DEPTH + 1))
        done

        if [[ ! "$DIMEN_VALUE" =~ ^(-?[0-9]*\.?[0-9]+)([a-zA-Z]*)$ ]]; then
            LOGW "\"$DIMEN_NAME\" in \"$DIMEN_FILE\" is \"$DIMEN_ORIG\" and cannot be resolved to a number, left untouched"
            continue
        fi

        DIMEN_NEW="$(awk -v v="${BASH_REMATCH[1]}" -v p="$DIMEN_PCT" -v u="${BASH_REMATCH[2]}" \
            'BEGIN { printf "%.1f%s", v * p / 100, u }')"

        LOG "- Scaling \"$DIMEN_NAME\" in \"$DIMEN_FILE\": $DIMEN_ORIG -> $DIMEN_NEW ($DIMEN_PCT%)"
        awk -v NAME="$DIMEN_NAME" -v NEW="$DIMEN_NEW" '
            index($0, "name=\"" NAME "\"") && match($0, />[^<]*</) {
                sub(/>[^<]*</, ">" NEW "<")
            }
            { print }
        ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    done <<< "$DIMEN_FILES"
done

unset SHADE_WINDOW_BLUR_PCT SHADE_CONTENT_BLUR_PCT SYSTEMUI_RES ENTRY DIMEN_NAME DIMEN_PCT DIMEN_FILES \
    DIMEN_FILE DIMEN_ORIG DIMEN_VALUE DIMEN_DEPTH DIMEN_REF DIMEN_NEW
    