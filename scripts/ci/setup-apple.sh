#!/bin/bash
set -euo pipefail
# Install the reviewed XcodeGen release without executing its installer.
ci_tools="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ammo-ci-tools"
mkdir -p "$ci_tools"
curl --fail --location --retry 2 \
  https://github.com/yonaskolb/XcodeGen/releases/download/2.43.0/xcodegen.zip \
  --output "$ci_tools/xcodegen.zip"
echo "a4847ed77d3341a4d24049bc4424a3babca4c94ff1dcaaee923eaca2b32c678f  $ci_tools/xcodegen.zip" | shasum -a 256 --check
unzip -q -o "$ci_tools/xcodegen.zip" -d "$ci_tools"
echo "$ci_tools/xcodegen/bin" >> "$GITHUB_PATH"
"$ci_tools/xcodegen/bin/xcodegen" --version
xcodebuild -version
swift --version
