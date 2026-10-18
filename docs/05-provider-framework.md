# 05 · Provider 适配层

## 5.1 三件事必须分开

`ProviderDefinition` 声明名称、能力与认证方式；`ProviderAdapter` 从授权来源读取原始响应；`Normalizer` 将原始语义转为 `QuotaWindow`。UI 不按 providerId 写一串 if/else 推断字段，Worker 也不维护 Provider 解析器。

能力至少包括：quota windows、remaining ratio、absolute counts、reset time、usage history、balance、multiple accounts、models/shared pools、source method、experimental。能力缺失不是异常，更不是 0。

## 5.2 凭据与来源策略

Codex 通过校验过的签名 `codex app-server` 在每个 UUID 专属目录中登录及读取，强制文件凭据后端并隔离 HOME、CODEX_HOME、TMPDIR。其余服务只使用该实例保存于本机钥匙串的 API 令牌、Cookie 或 OAuth；创建全新的显式来源上下文，不读取外部账号配置、全局环境或浏览器。Grok 的本机历史与 CLI 补充读取、Copilot 的浏览器预算补充读取均关闭；仅当 Grok 本机登录令牌过期时，才启动一次 CLI 让其在自身进程内完成令牌刷新（x.ai 每次兑换都会轮换 refresh token，App 不得代为兑换），随后重读凭据文件。

连接探测必须先返回有效窗口，再保存不含凭据的连接记录并固定账户身份。后续身份变化进入 `authRequired`，该账号退出常规计划、按 30 分钟低频探测，登录恢复后自动跟进；重新连接仍是立即恢复并刷新固定身份的路径。版本 5 保留旧记录及历史，未绑定独立授权的旧连接保持暂停。凭据草稿和移除操作均有持久化清理记录；Antigravity 需 access token 与 project ID，过期后重新连接，不自动刷新或 onboarding。

## 5.3 当前 Provider 路线

| Provider | 数据路径 | 限制 |
|---|---|---|
| Codex | 独立目录内的签名 app-server | 用户在浏览器中为每个实例单独登录 |
| OpenCode Go、Droid | API 或手工 Cookie | 明确选择来源，不回退至其他账号 |
| Amp | API、CLI 或手工 Cookie | 明确选择来源，不回退至其他账号。credits 余额（Individual credits）输出为货币余额窗口；2026 起 Amp Free 每日余量并入该行文本，不再提供独立百分比窗口 |
| Copilot、z.ai、OpenRouter | API 令牌 | z.ai 保留区域、团队和项目范围 |
| Manus | 手工 Cookie | 会话过期后重新连接 |
| Grok | CLI 计费代理（OAuth）或网页会话 Cookie | 禁止本机历史 / CLI 补充读取；令牌过期仅委托 CLI 原生自刷新。Cookie 通道读取 grok.com `rest/rate-limits` 的 bot 限时窗口（auto/fast/heavy 滚动配额） |
| DeepSeek | API 或平台访问令牌 | 保留实际币种余额 |
| Antigravity | OAuth JSON | 需 access token 与 project ID；不自动刷新 |

产品入口只展示以上 11 项。内嵌参考库的更多实现不构成支持清单；本地测试不等同于所有服务和套餐的真实账号验收。

## 5.4 Codex 适配契约

官方 app-server 文档提供 `account/rateLimits/read`、`account/rateLimits/updated`，返回中可包含 `rateLimitsByLimitId`，窗口有 `usedPercent`、`windowDurationMins` 和 Unix 秒 `resetsAt`。[S9]

读取流程：定位经用户认可的可执行文件 → 记录版本 → 启动有超时/资源限制的子进程 → 初始化协议 → 读取账户与 limits → 解析并关闭。定期采集只请求查询方法。用户主动连接时使用 `account/login/start`，等待服务器的 `account/login/completed` 通知，再验证账户及额度；取消时终止该登录进程。

正规化规则：`remainingBps = 10000 - round(usedPercent * 100)`，先验证上游数值有效；`windowDurationMins * 60` 存为 durationSeconds；不要硬编码所有账户都是 5h/7d；优先多桶视图，legacy 单桶仅作兼容且不能重复计入。缺失 secondary 就只显示已有窗口；上游没有绝对值时 amount/limit 为 null。

若需要历史统计，`account/usage/read` 的可用性和统计范围单独探测；其 tokens 不能直接等同当前 quota 桶的额度消耗。[S9] 上游版本降级、字段新增或未知枚举要保留可诊断的能力差异，不触发 UI 崩溃。

## 5.5 Adapter 返回与错误

结果包含稳定账户 ID、窗口、来源方法、成功观测时间、可选历史，以及本次 fetchOutcome。错误分类：auth_required、rate_limited、network、timeout、parse_changed、unsupported、permission_denied、cancelled。每类错误有 retryAfter/建议动作；任何失败不覆盖最近成功数据为 0。

部分成功允许发布：例如 Codex 正常而 Claude 失败。窗口保留各自的 observedAt；整包 fetchedAt 不能冒充每个窗口的采集时间。Provider 被禁用即取消任务并删除下一次调度；旧历史可保留，但当前列表显示禁用或隐藏，不自动恢复采集。

## 5.6 扩展边界

v0.1 原生 adapter 随版本编译；自定义 HTTP 连接只允许明确配置的 HTTPS 域名、只读方法和声明式 JSON 映射。重定向重新验证主机，不将 Authorization 发送给跳转目标；本地/私网 URL 需用户独立授权。禁止远程任意 JS、shell 命令或“自动发现后执行”。

贡献一个 Provider 必须提交：Definition、认证说明、脱敏输入 fixture、期望标准输出、未知/401/429/畸形响应测试、超时与清理测试、依赖许可证和资源测量。没有这些材料只可标 experimental。
