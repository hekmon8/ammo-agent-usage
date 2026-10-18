# 16 · 多语言与本地化（zh-Hans / en）

Quota Island 的全部用户可见文案集中在一张共享语言表里，由 `QuotaCore` 的 `L10n` 在运行时解析。当前随包发布 **简体中文（开发语言）** 与 **English** 两套；新增语言只需增加一个 `.lproj` 表并注册到 `L10n` 的可用语言列表。

## 架构

- `packages/QuotaCore/Sources/QuotaCore/L10n.swift`
  - `L("key")` / `L("key", args…)`：printf 风格（`%@`、`%lld`、`%.1f`）的即时查表；结果是普通 `String`。
  - `L10n.resource("key")`：给 AppIntents/WidgetKit 等要求 `LocalizedStringResource` 的 API 使用，携带创建时的生效语言。
  - `LocalizedStatus("key", args…)`：跨事件保存的状态行（如 Mac 的 `model.message`、连接行 `status`）。只存键和参数，读取 `.text` 时才按当前语言渲染，语言切换后历史状态随之重渲染，不会滞留旧语言。
  - 语言解析顺序：应用内覆盖（`UserDefaults` 键 `quota.island.language`）→ 系统 `Bundle.preferredLocalizations`（在 `zh-Hans`/`en` 中匹配）→ `zh-Hans`。
  - `L10n.install(additionalDefaults:)`：注册 App Group 套件，让 iPhone App 与 Widget 扩展跨进程共享同一覆盖。
  - `L10n.setLanguage(_:)`：持久化覆盖、失效缓存、递增 `revision` 并在主线程发 `L10n.languageDidChange`。
- 语言表：`packages/QuotaCore/Sources/QuotaCore/Resources/{zh-Hans,en}.lproj/Localizable.strings`（SPM 资源包，Mac/iOS/Widget 共用）。
- 各界面只在 body/函数调用处取值，**不得**把 `L()` 结果缓存进 `let`/`static let`/`lazy`（语言切换后会过期）。

## 语言切换

- iPhone：设置页“语言”卡片；切换后通过 `WidgetCenter.reloadAllTimelines()` 让小组件立即跟进。
- Mac：同步工作区“语言”卡片；岛与仪表盘包在 `LanguageSensitiveView` 里，收到通知后整树重建。
- “跟随系统”（默认）按系统首选语言显示；iOS 的“每 App 语言设置”依赖 `CFBundleLocalizations: [zh-Hans, en]`（见 `project.yml` 与各 target Info 属性）。

## 校验

```bash
python3 scripts/check_l10n.py
```

校验内容：两套表键集一致、占位符类型一致（忽略位置重排）、代码中 `L(…)`/`L10n.resource(…)`/`LocalizedStatus(…)` 引用的键都在表内、重复键检测；`tests/contracts/L10nTests.swift` 覆盖运行时行为（双语言解析、缺键回退、revision 通知、App Group 共享、`LocalizedStatus` 切语言后重渲染）。`scripts/check_apple.sh` 与发布门禁请一并运行。

## 约定

- 键名小写点分英文，按界面域分组：`island.*`（Mac 岛/面板）、`settings.*`（Mac 设置）、`mac.*`（Mac 模型状态/错误）、`phone.*`（iOS）、`widget.*`（小组件/实时活动）、`quota.*`（核心额度文案）、`catalog.*`（Provider 接入说明）、`design.*`（QuotaDesign 组件）、`icloud.*`（iCloud 错误提示）、`language.*`。
- 新增文案：先在两个表同批添加，再在代码中引用；提交前跑 `check_l10n.py`。
- 品牌词（Codex、Claude、GLM、Grok、MCP 等）不翻译；枚举 raw value、UserDefaults 键、fixture 名等数据字符串保持原样。
