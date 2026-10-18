# Third-party notices

These terms apply independently of the project license. Redistribution must retain
applicable copyright and license text, including in binary distributions.

## Swift runtime dependencies

Versions and revisions are locked in Package.resolved. The files below were extracted
from those exact revisions; the MCP SDK contains transitional Apache/MIT terms.

| Dependency | Version | Revision | Terms |
| --- | --- | --- | --- |
| eventsource | 1.5.1 | 86b5096ac59ab46e66bd1f6377c604bc1dab0bc2 | [Notices](third_party/eventsource/) |
| swift-atomics | 1.3.1 | 0442cb5a3f98ab802acb777929fdb446bda11a34 | [Notices](third_party/swift-atomics/) |
| swift-collections | 1.6.0 | a0cb0954ecb21e4e31b0070e6ed5674e8556685a | [Notices](third_party/swift-collections/) |
| swift-log | 1.15.0 | 3ffafb9722d5d918c614feb496c8789a3b59d222 | [Notices](third_party/swift-log/) |
| swift-nio | 2.102.0 | a931f2c1de8dd49381ce3bf2e279d033f68d8865 | [Notices](third_party/swift-nio/) |
| swift-sdk | 0.12.1 | a0ae212ebf6eab5f754c3129608bc5557637e605 | [Notices](third_party/swift-sdk/) |
| swift-system | 1.8.1 | 869129b7bf4ecc57b97d0193ad29690ca2134750 | [Notices](third_party/swift-system/) |

## Fonts and provider marks

- Inter Tight: SIL OFL 1.1; see packages/QuotaDesign/Sources/QuotaDesign/Resources/Fonts/OFL.txt.
- Provider marks: attributed CodexBar assets and six original letter placeholders.
  The CodexBar source revision is fb9d295304af2873803b317ac1e3adb07b414083;
  the original placeholders are Apache-2.0 project code/assets, not official logos.
  see third_party/provider-marks/ProviderBrandAssets-NOTICE.md and third_party/provider-marks/CodexBar-LICENSE.txt.
  Provider trademarks remain with their respective owners; no endorsement is implied.
- Apple frameworks and system SQLite are supplied by the operating system.

## Development tools and research

Node and Python development dependencies are pinned in their lock files; they are not
bundled in the app. Run the dependency audits described in CONTRIBUTING.md.
Research templates, private QA records and design boards are not distributed.

SwiftNIO atomics include the MIT-licensed uSHET `cpp_magic.h`; the exact upstream license is retained in [third_party/swift-nio/uSHET-LICENSE.txt](third_party/swift-nio/uSHET-LICENSE.txt), from revision `c09e0acafd86720efe42dc15c63e0cc228244c32`.
