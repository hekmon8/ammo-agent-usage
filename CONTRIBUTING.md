# Contributing

Use a branch and a focused pull request. Describe the user-visible change and
its validation. Use synthetic accounts and fixtures; never attach credentials,
real quota captures, pairing QR codes or private deployment logs to an issue.

## Checks

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" swift test --disable-sandbox
.venv/bin/python scripts/test_contracts.py
python3 scripts/check_l10n.py
npm run test:contracts
npm --prefix workers/lite run check
npm --prefix workers/lite run test:push
npm --prefix workers/lite run test:http
python3 -m unittest discover -s tests/release -p 'test_*.py'
node --test tests/release/*.mjs
```

Run `xcodegen generate` followed by `sh scripts/check_apple.sh` for Swift tests,
iOS simulator libraries, the iPhone app and the native Mac app. No real account,
Cloudflare deployment or Apple upload is required for unit/integration tests.
Keep zh-Hans and English strings in sync. Preserve unknown/unavailable states;
never invent a quota value from a missing or failed provider response.

For credential, authorization and sync changes, test denial, stale requests,
concurrent requests, revocation, retry and crash recovery. Reviewers must check
that secrets never follow redirects and one account's data never enriches another.

## Dependencies and licensing

Use pinned dependencies and update lock files together. Run `npm audit` in both
Node package directories; review development-tool findings as well as runtime
findings. Scan public exports with Gitleaks and review its findings without
printing secret values. Do not add broad scanner exclusions for tests.
Worker tooling is pinned to Wrangler 4.145.0, whose Miniflare dependency uses
Undici 7.29.1. Keep the Worker audit gate enabled when updating this toolchain;
older pins can reintroduce high-severity transport advisories.
Retain upstream notices and update THIRD_PARTY_NOTICES.md when dependencies change.
Only contribute code and assets you have the right to distribute under the
project's license. Brand marks do not imply provider endorsement.

## Releases

PR checks have read-only repository permissions and no deployment secrets.
Signed publishing is a separate maintainer operation from an immutable, verified
release tag. Do not deploy fork PR code with trusted credentials. See
`docs/open-source-release.md` for source-export and binary-release gates.
