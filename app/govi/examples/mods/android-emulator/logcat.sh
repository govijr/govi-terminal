#!/bin/sh
# Finds adb on the PATH or in the default Android SDK folder, then follows the log.
adb=$(command -v adb || true)
[ -n "$adb" ] || adb="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
if [ ! -x "$adb" ]; then
  echo "adb wasn't found. Install the Android SDK platform tools, or set ANDROID_HOME."
  exit 1
fi
exec "$adb" logcat -v color "$@"
