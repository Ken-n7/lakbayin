#!/usr/bin/env bash
# Build, install, run and photograph the app on a connected phone.
#
#   tools/device.sh build      export the debug APK
#   tools/device.sh release    export the SIGNED release APK
#   tools/device.sh install    build, then install over USB
#   tools/device.sh shot NAME  screenshot the running app into build/shots/
#   tools/device.sh log        the app's own log lines, live
#   tools/device.sh run        install, launch, wait, shoot "launch"
#
# A phone is the only place several things are real: touch targets at their
# physical size, a soft keyboard over a landscape form, realtime over mobile
# data, and the 20:9 screen this project's 16:9 canvas has to live on.
set -u
# Absolute path to this script before the cd, or re-invoking itself below
# looks for a relative path that no longer exists.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.." || exit 1          # the `game` directory
ADB="${ANDROID_HOME:-$HOME/Android/Sdk}/platform-tools/adb"
APK="../build/NumXventure.apk"
PKG="com.numxventure.game"
SHOTS="../build/shots"

need_device() {
	"$ADB" get-state >/dev/null 2>&1 || { echo "no device: plug in and allow USB debugging"; exit 1; }
}

case "${1:-run}" in
build)
	godot --headless --path . --export-debug "Android" "$APK" | tail -1
	;;
release)
	# Signed, and without the dev tools -- they are gated on
	# OS.is_debug_build(), so a release export drops them by itself.
	#
	# The keystore lives outside the repo and its password comes from the
	# environment, never from export_presets.cfg: that file is committed, and
	# a signing key in git is a signing key everyone has. Losing this key
	# means never updating the app on a phone that already has it.
	KS="${NUMX_KEYSTORE:-$HOME/.local/share/numxventure/release.keystore}"
	PASSFILE="$KS.pass"
	[ -f "$PASSFILE" ] || { echo "no $PASSFILE -- see SPECS §8 Release signing"; exit 1; }
	GODOT_ANDROID_KEYSTORE_RELEASE_PATH="$KS" \
	GODOT_ANDROID_KEYSTORE_RELEASE_USER="$(grep ^alias= "$PASSFILE" | cut -d= -f2)" \
	GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD="$(grep ^password= "$PASSFILE" | cut -d= -f2)" \
	godot --headless --path . --export-release "Android" "../build/NumXventure-release.apk" | tail -1
	;;
install)
	"$SELF" build && need_device && "$ADB" install -r "$APK" | tail -1
	;;
shot)
	need_device
	mkdir -p "$SHOTS"
	name="${2:-shot}"
	# Straight down the pipe: `adb shell screencap -p` mangles newlines on
	# some shells, `exec-out` does not.
	"$ADB" exec-out screencap -p > "$SHOTS/$name.png"
	echo "$(cd "$SHOTS" && pwd)/$name.png"
	;;
log)
	need_device
	"$ADB" logcat -c
	"$ADB" logcat godot:V GodotEngine:V "*:S"
	;;
run)
	"$SELF" install || exit 1
	"$ADB" shell am force-stop "$PKG"
	"$ADB" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
	sleep 8
	"$SELF" shot "launch"
	;;
*)
	echo "usage: $0 {build|release|install|shot NAME|log|run}"; exit 1
	;;
esac
