# Provider marks and original placeholders

## Attributed provider marks

Except for the six original placeholders below, the transparent marks under
`packages/QuotaDesign/Sources/QuotaDesign/Resources/ProviderMarks` are rasterized at
192 px from CodexBar v0.56.4, commit `fb9d295304af2873803b317ac1e3adb07b414083`,
`Sources/CodexBar/Resources/ProviderIcon-*.svg`.

Source: https://github.com/steipete/CodexBar/tree/fb9d295304af2873803b317ac1e3adb07b414083/Sources/CodexBar/Resources

The upstream MIT license is retained in `CodexBar-LICENSE.txt`. Conversion used
macOS AppKit NSImage with aspect-preserving transparent 192 × 192 output. These
marks identify providers; provider names and trademarks remain their owners'
property and do not imply endorsement or blanket trademark permission.

## Original letter placeholders

Copyright 2026 Ammo contributors. Licensed under this project's Apache-2.0 license.

| Resource | Visible label |
| --- | --- |
| ProviderIcon-workbuddy.png | WB |
| ProviderIcon-zcode.png | ZC |
| ProviderIcon-fal.png | F |
| ProviderIcon-cloudflare.png | CF |
| ProviderIcon-vercel.png | V |
| ProviderIcon-replit.png | R |

These six images are generic hand-authored letter strokes, not official provider
logos. `scripts/ci/generate-provider-placeholders.py` generates them using only
Python's standard library. No external font, downloaded image, or third-party
brand geometry is used. Rebuild with the script; `--check` verifies committed output.

`codebuddy` retains its existing `workbuddy` resource alias. Provider text labels
and behavior are unchanged. Ammo's own App icon is separate and is not replaced.
