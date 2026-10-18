#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift test --disable-sandbox
QI_IOS_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
for QI_TARGET in QuotaPhone QuotaWidgets; do
    swift build --disable-sandbox --scratch-path .build/ios \
        --triple arm64-apple-ios17.0-simulator --sdk "$QI_IOS_SDK" --target "$QI_TARGET"
done
# Build native hosts too: SPM library checks do not typecheck PhoneHost or the
# checked-in desktop target's source membership. No signing/upload is performed.
xcodebuild -project Ammo.xcodeproj -scheme AmmoPhone -configuration Debug \
    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath .build/native-ios CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Ammo.xcodeproj -scheme AmmoDesktop -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath .build/native-mac \
    CODE_SIGNING_ALLOWED=NO build
