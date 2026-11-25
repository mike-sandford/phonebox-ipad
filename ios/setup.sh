#!/bin/sh
# Generates PhoneBox.xcodeproj from project.yml. Run on the Mac from anywhere: ios/setup.sh
set -eu
cd "$(dirname "$0")"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen is missing: brew install xcodegen" >&2
  exit 1
fi
if [ ! -f Signing.xcconfig ]; then
  cp Signing.xcconfig.example Signing.xcconfig
  echo "Created ios/Signing.xcconfig: put your Team ID and bundle identifier in it, then run this again." >&2
  exit 1
fi
xcodegen generate
echo "Open ios/PhoneBox.xcodeproj in Xcode, pick your iPad as the run destination and press Run."
