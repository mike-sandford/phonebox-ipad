#!/usr/bin/env bash
# Builds the PhoneBox agent from this repository and installs it in place of the released one on this Mac, so the
# iPad gets what only this fork's agent has (standby for the iPad, the iPad page templates). Run it from anywhere in
# the repo after `git pull`. Undo: run the upstream setup.sh again, which installs the latest release.
#
# Needs the .NET SDK (brew install --cask dotnet-sdk). Turn off Settings › General › Updates › "Install new releases
# automatically" on the Mac, or the agent replaces this build with the next upstream release.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
app="$HOME/Library/Application Support/PhoneBox/app"
plist="$HOME/Library/LaunchAgents/net.oxog.phonebox.agent.plist"
label="gui/$(id -u)/net.oxog.phonebox.agent"
rid="osx-$(uname -m | sed 's/x86_64/x64/')"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

[ "$(uname)" = Darwin ] || { echo "This is for macOS."; exit 1; }
command -v dotnet >/dev/null || { echo "Install the .NET SDK first: brew install --cask dotnet-sdk"; exit 1; }
[ -f "$plist" ] || { echo "No PhoneBox login item ($plist). Install the release once with setup.sh --no-phone first."; exit 1; }

echo "Building the agent ($rid)…"
dotnet publish "$repo/agent/PhoneBox.Agent" -c Release -f net10.0 -r "$rid" --self-contained true \
  -p:PublishSingleFile=true -o "$out" --nologo

echo "Stopping the running agent…"
launchctl bootout "$label" 2>/dev/null || true
pkill -f "$app/PhoneBoxAgent" 2>/dev/null || true
sleep 1

echo "Installing into $app"
mkdir -p "$app"
cp -R "$out"/. "$app"/
chmod +x "$app/PhoneBoxAgent"
codesign --force --sign - "$app/PhoneBoxAgent" >/dev/null 2>&1 || true

echo "Starting it…"
launchctl bootstrap "gui/$(id -u)" "$plist"
launchctl kickstart -k "$label"
sleep 3
if lsof -nP -iTCP:8765 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Done: the agent from this repo is running (http://127.0.0.1:8765)."
else
  echo "The agent did not start. If System Settings › General › Login Items & Extensions lists PhoneBoxAgent under"
  echo "\"Allow in the Background\", turn it on, then run: launchctl kickstart -k $label"
  exit 1
fi
