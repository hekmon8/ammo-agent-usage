# 契约与合成样例

snapshot.schema.json是业务快照；envelope.schema.json是传输信封；openapi.json是HTTP设计契约。示例非真实账户、非真实部署。schema之外的跨字段不变量由 scripts/test_contracts.py 和各模块测试验证。

ID只允许ASCII字母、数字、下划线与连字符，避免AAD分隔符歧义。数量用十进制字符串，比例用基点。sourceSequence是1..2^53-1安全整数。相同sequence重试必须复用已持久化的同一个envelope，不重新加密产生新nonce/密文。

AES-GCM签名测试向量使用固定公开测试key/nonce，专为重现而设；生产必须用随机独立密钥及新nonce，绝不复用示例。签名输入与contentHash见 packages/QuotaSync/Sources/QuotaSync/Envelope.swift；contentHash为签名消息SHA256，不是可替代签名的安全证明。

OpenAPI中的x-required-role只描述授权规则，框架不会自动执行它；开发者必须实现设备/tenant/writer/epoch检查。GET pairing result是有限次数的受权秘密交付，应采用明确ack再消费的协议：approved可向同一claim能力幂等交付，客户端收到并存储后确认consumed；不得因网络丢包永久丢失token。当前OpenAPI提供result与ack两个操作。

Swift/TypeScript文件为可编译的DTO/接口边界示例，不含真实Provider、App、Worker服务实现。MCP样例路径需替换。首次真机集成前以实际Provider响应补充脱敏golden fixtures。


## DTO 验证命令

```bash
swiftc contracts/Contracts.swift scripts/verify_swift.swift -o /tmp/qi-verify-swift
/tmp/qi-verify-swift contracts/fixtures
tsc --strict --noEmit --target ES2022 --module ES2022 contracts/Contracts.ts
```

Swift 示例显式保留 JSON null，不使用 encodeIfPresent 丢掉必填空字段。上述 Swift 验证在 Linux 工具链运行，只验证 Foundation DTO 序列化，不验证 AppKit、SwiftUI、WidgetKit 或 ActivityKit。

密钥封装采用下方 CryptoKit HPKE 配置；Worker 的 D1 授权、并发写入和重试实现位于 workers/lite/src，HTTP 集成测试使用临时本地数据库。顺序契约测试不能替代并发边界测试。

## Snapshot key wrap v1

`key-wrap.schema.json` defines the decoded object transported as base64url in `wrappedSnapshotKey`.
Use CryptoKit RFC 9180 HPKE X25519/HKDF-SHA256/AES-256-GCM. Context is
`workspaceId|sourceDeviceId|sourceEpoch|keyId|claimId`; its `QI-WRAP|1|` prefix is HPKE info and AAD.
Pinned source Ed25519 signs info + LF + encapsulatedKey bytes + ciphertext bytes. The receiver checks
that signature and the exact expected context before HPKE opening. No raw snapshot key reaches Worker.
`key-wrap-input.TEST-ONLY.json` contains public synthetic input only; each production wrap uses new HPKE randomness.

Native Live Activity content is specified by `live-activity-content.schema.json` and its golden example. Immutable attributes use `sessionID`, `windowID`, and a fixed `endsAt`; content timestamps are epoch seconds. Optional numeric values may be absent or null, and must not become fabricated zeroes.

## Token usage sidecar v1

`token-usage.schema.json` is a distinct, strict business contract; it does not
extend `snapshot.schema.json`. `usage-envelope.schema.json` reuses the exact
transport fields but separates encryption/signing with `QI-USAGE|1|`.
`PUT/GET /v1/usage` uses the existing paired single-source authorization and its
own monotonic sequence, receipt, ETag and encrypted cache. Maximum usage plaintext
is 131072 bytes. The phone replaces a whole aggregate; it never sums two Macs.
Synthetic example: `examples/token-usage.TEST-ONLY.json`.
