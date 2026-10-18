#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
platform="${1:?Choose ios or macos}"
mkdir -p .build/ci
xcodegen generate
case "$platform" in
  ios)
    xcodebuild -project Ammo.xcodeproj -scheme AmmoPhone -configuration Debug \
      -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath .build/native-ios CODE_SIGNING_ALLOWED=NO build
    ditto -c -k --keepParent .build/native-ios/Build/Products/Debug-iphonesimulator/AmmoPhone.app \
      .build/ci/Ammo-iOS-Simulator.zip
    ;;
  macos)
    swift test --disable-sandbox
    xcodebuild -project Ammo.xcodeproj -scheme AmmoDesktop -configuration Debug \
      -destination 'platform=macOS' -derivedDataPath .build/native-mac \
      CODE_SIGNING_ALLOWED=NO build
    ditto -c -k --keepParent .build/native-mac/Build/Products/Debug/Ammo.app \
      .build/ci/Ammo-macOS-unsigned.zip
    ;;
  *) echo 'Choose ios or macos.' >&2; exit 2 ;;
esac
