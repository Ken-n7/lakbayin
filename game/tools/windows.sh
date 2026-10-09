#!/usr/bin/env bash
# The teacher's Windows build, ready to hand over: one zip with the game and
# cloudflared beside it.
#
#   tools/windows.sh           release build -> ../build/NumXventure-Windows.zip
#   tools/windows.sh --debug   with the dev panel -> ../build/NumXventure-Windows-debug.zip
#
# Game Controls hosts its class's relay through cloudflared, found beside the
# exe (RelayHost.cloudflared). Without it the class silently falls back to the
# home relay or the hub, so it ships in the same zip and nobody has to install
# anything. Pinned and checked: a download that doesn't match is refused.
set -eu
cd "$(dirname "$0")/.." || exit 1          # the `game` directory
CF_VERSION="2026.10.0"
CF_SHA256="86aee4017b26625cee8484c113558f48effa4cd47f7aa05fcf425604e5d2b23c"
CF_CACHE="../build/cache/cloudflared-$CF_VERSION.exe"

mode=release; zip_name=NumXventure-Windows.zip; out=../build/windows
if [ "${1:-}" = --debug ]; then
	mode=debug; zip_name=NumXventure-Windows-debug.zip; out=../build/windows-debug
fi

if [ ! -f "$CF_CACHE" ] || [ "$(sha256sum "$CF_CACHE" | cut -c1-64)" != "$CF_SHA256" ]; then
	mkdir -p "$(dirname "$CF_CACHE")"
	curl -sSL --fail -o "$CF_CACHE.part" \
		"https://github.com/cloudflare/cloudflared/releases/download/$CF_VERSION/cloudflared-windows-amd64.exe"
	if [ "$(sha256sum "$CF_CACHE.part" | cut -c1-64)" != "$CF_SHA256" ]; then
		rm -f "$CF_CACHE.part"; echo "cloudflared download does not match its checksum: refused"; exit 1
	fi
	mv "$CF_CACHE.part" "$CF_CACHE"
fi

mkdir -p "$out"
godot --headless --path . --export-$mode "Windows Desktop" "$out/NumXventure.exe" | tail -1
cp "$CF_CACHE" "$out/cloudflared.exe"
rm -f "../build/$zip_name"
(cd "$out" && zip -q -9 "../$zip_name" NumXventure.exe cloudflared.exe)
echo "../build/$zip_name ($(du -h "../build/$zip_name" | cut -f1)): NumXventure.exe + cloudflared $CF_VERSION"
