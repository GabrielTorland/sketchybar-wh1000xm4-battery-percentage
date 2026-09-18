#!/usr/bin/env bash
#
# sketchybar plugin: battery level of the Sony headphones you are listening
# through. Collapses to nothing when you are not wearing them.
#
# The battery is read by the launchd agent that `make install` sets up, not
# here: Bluetooth is not available to processes sketchybar spawns, which fail
# without ever getting a reply. The agent leaves its answer in a file and this
# script only ever reads that file.
#
# Wire it up in your sketchybarrc — see sketchybarrc.example.

CACHE="${HEADPHONE_BATTERY_CACHE:-$HOME/.cache/headphone-battery.json}"
AGENT="${HEADPHONE_BATTERY_AGENT:-io.github.gabrieltorland.headphone-battery}"

LOW=${HEADPHONE_BATTERY_LOW:-20}
WARN=${HEADPHONE_BATTERY_WARN:-35}

COLOR_NORMAL=${HEADPHONE_BATTERY_COLOR:-0xff7f8490}
COLOR_WARN=${HEADPHONE_BATTERY_COLOR_WARN:-0xfff39660}
COLOR_LOW=${HEADPHONE_BATTERY_COLOR_LOW:-0xfffc5d7c}
COLOR_CHARGING=${HEADPHONE_BATTERY_COLOR_CHARGING:-0xff9ed072}

# Switching output device is the moment the answer changes, and waiting out the
# agent's own interval to find out would be a long time to look wrong.
if [ "$SENDER" = "volume_change" ] || [ "$SENDER" = "system_woke" ]; then
  launchctl kickstart -k "gui/$(id -u)/$AGENT" >/dev/null 2>&1
  sleep 3
fi

# Collapsing to zero width rather than turning drawing off is deliberate:
# sketchybar stops running the update script of an item whose drawing is off,
# so an item hidden that way would never notice the headphones coming back.
collapse() {
  sketchybar --set "$NAME" width=0 \
                           icon.drawing=off \
                           label.drawing=off \
                           background.drawing=off
  exit 0
}

READING=$(cat "$CACHE" 2>/dev/null)
[ -n "$READING" ] || collapse

PERCENT=${READING#*\"percent\":}
PERCENT=${PERCENT%%,*}
case $PERCENT in
  ''|*[!0-9]*) collapse ;;
esac

COLOR=$COLOR_NORMAL
if [[ $READING == *'"charging":true'* ]]; then
  COLOR=$COLOR_CHARGING
elif [ "$PERCENT" -le "$LOW" ]; then
  COLOR=$COLOR_LOW
elif [ "$PERCENT" -le "$WARN" ]; then
  COLOR=$COLOR_WARN
fi

sketchybar --set "$NAME" width=dynamic \
                         icon.drawing=on \
                         icon.color="$COLOR" \
                         label.drawing=on \
                         label="${PERCENT}%" \
                         label.color="$COLOR" \
                         background.drawing=on
