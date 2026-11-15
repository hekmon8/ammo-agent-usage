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
    # Empty team and dropped entitlements let a certificate-less machine build;
    # Xcode then ad-hoc signs so the artifact stays launchable on Apple
    # Silicon, where a fully unsigned binary is killed by the kernel.
    # iCloud sync degrades gracefully in the CI artifact and is restored by
    # any signed local build.
    xcodebuild -project Ammo.xcodeproj -scheme AmmoDesktop -configuration Release \
      -destination 'platform=macOS' -derivedDataPath .build/native-mac \
      DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS= build
    codesign --verify --strict .build/native-mac/Build/Products/Release/Ammo.app
    ditto -c -k --keepParent .build/native-mac/Build/Products/Release/Ammo.app \
      .build/ci/Ammo-macOS.zip
    shasum -a 256 .build/ci/Ammo-macOS.zip > .build/ci/Ammo-macOS.zip.sha256
    ;;
  *) echo 'Choose ios or macos.' >&2; exit 2 ;;
esac
