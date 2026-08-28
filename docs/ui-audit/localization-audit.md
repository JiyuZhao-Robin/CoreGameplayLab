# UI 本地化审计

审计日期：2026-08-28  
审计范围：`src/ui` 场景与脚本、`src/application` 玩家通知/引导、`src/core` 可能进入诊断界面的文本，以及 `data/localization_en.json` / `data/localization_zh_CN.json`。

## 当前结论

| 门禁 | 结果 | 证据 |
| --- | --- | --- |
| 生产代码实际引用的稳定 key 双语覆盖 | **PASS** | 929 个唯一稳定 key，英文缺失 0，中文缺失 0 |
| 占位符签名与英文 CJK 检查 | **PASS** | `errors=0`；中英文 `%s/%d/%f` 签名一致 |
| English 核心页面 smoke | **PASS** | 所有主页面和子页无可见 CJK；巨构八阶段英文均显示 |
| zh-CN 核心页面 smoke | **PASS** | 中文状态、阻塞和导航显示；语言切换保持页面、地点和子页 |
| Application 玩家通知 / Guidance / structured error key 化 | **PASS** | `HARD_CODED_APPLICATION_TEXT=0`；6 个内部诊断、fallback 与哨兵单独保留为 REVIEW |
| 完整 UI 文案 key 化 | **PASS** | `HARD_CODED_UI_TEXT=0`，`HARD_CODED_APPLICATION_TEXT=0`，`INLINE_NOT_STABLE_KEY=0` |
| 历史目录双语对称 | **REVIEW** | 682 个当前未被稳定 API 引用的中文历史目录条目没有英文对应项 |

因此，本轮已证明当前玩家 UI 与 application 玩家通知均通过稳定双语 key；严格门禁没有运行时缺键、硬编码玩家文本、inline 桥或术语 warning。未重新接入运行时的历史目录差异仍单独保留为 REVIEW，不伪装成玩家表面的运行时失败。

## 严格审计快照

命令：

```powershell
& 'D:\Godot\godot.exe' --headless --path 'D:\Projects\standalone\core_gameplay_lab' --log-file 'D:\Projects\standalone\core_gameplay_lab\.audit-logs\localization-ui-strict-final.log' --script res://tools/ui_localization_audit.gd -- --strict --no-persistence
```

当前输出：

```text
UI_LOCALIZATION_AUDIT files=21 scenes=1 scripts=20 stable_refs=1074 stable_keys=929 inline=0 hardcoded=0 terminology=0 runtime_missing=0 catalog_debt=682 errors=0 warnings=0 review=1071
UI_LOCALIZATION_AUDIT_CODES APPLICATION_INTERNAL_TEXT_REVIEW=6,CATALOG_LEGACY_ONLY_ZH=682,CORE_PLAYER_TEXT_REVIEW=361,DYNAMIC_LOCALIZATION_KEY=14,UI_INTERNAL_CAPTURE_MARKER_REVIEW=2,UI_INTERNAL_FONT_IDENTIFIER_REVIEW=6
```

审计退出码为 `0`。这里的 PASS 只覆盖会使当前运行时文案缺失、空白、占位符崩坏或英文含 CJK 的 ERROR 级目录问题；WARN/REVIEW 不会被藏进 PASS。

## 统计边界

- `I18n.core("literal.key")` 对应 `core_ui`；`I18n.t("literal.key")` 对应 `ui`。只有字面量首参数进入稳定 key 清单。
- 实际生产代码引用缺失、空值、英文含 CJK 或双语格式签名不一致仍为 `ERROR`，并使工具退出码为 `1`。
- `goal_steps` 与 `megastructure_stages` 是运行时动态枚举目录；即使没有静态字面量调用，也强制双语对称。
- `ui` / `core_ui` 中未被生产代码引用的单语历史条目不会再伪装成运行时缺键，单独记为 `CATALOG_LEGACY_ONLY_* / REVIEW`。如果未来重新引用，立即升级为真正的 `CATALOG_MISSING_*` 和 `STABLE_KEY_MISSING_* / ERROR`。
- `I18n.inline(text)` 只是遗留文本替换桥，不算稳定覆盖。
- 动态 key 无法仅靠静态扫描证明，记录为 `DYNAMIC_LOCALIZATION_KEY / REVIEW`，需要有限枚举契约。
- 硬编码检测偏向高召回率，但只对两类精确内部标识豁免 WARN：6 个平台字体族与 2 个截图 harness 协议标记；它们仍以独立 REVIEW 留痕。相邻玩家文本的合成测试证明不会被该规则隐藏。

## 本轮修复

- 为 `src/application/game.gd` 实际引用的 100 个英文通知/舰船 key 和 26 个中文通知/条件 key 建立了真实目录项。
- 将 `game.gd` 中 97 组维护、拆解、勘测、生产线、自动化、建设、船厂、物流、工业模板、装配与时间格式迁移为双语稳定 key；玩家可见的 application 硬编码 finding 从 107 降至 0。
- `Content validation` 日志、翻译 fallback 与 `slot limit` 内部哨兵没有伪装成玩家文案；6 处以 `APPLICATION_INTERNAL_TEXT_REVIEW` 保留审查证据。
- 校验所有新增通知的格式占位符与调用点一致，未依赖英文 fallback 代替目录覆盖。
- 中文 `header.research` / `header.megastructure`、巨构阶段标签和核心状态目录已使用本地化文案；产品搜索统一使用“产品”，不再混用“商品”。
- 将历史单语目录差异从 `runtime_missing` 拆出为 `catalog_debt`，并添加合成测试，证明实际引用一旦缺语言仍然保持 ERROR。
- 将 `src/ui/main.gd` 与巨构进度组件中的 664 个玩家文本候选迁移为语义稳定 key，并移除全部 6 个 `I18n.inline` 桥；生产 UI 不再以中文 fallback 充当 identity。
- 统一了生产、物流、建设、研发、舰船、勘测、诊断、Planner、自动化和巨构的标题、阶段、状态、阻塞与格式文案；活动/路线/项目列表改为显示 Content Database 的本地化名称，而不是 raw ID。
- 为研发路线及制造模块安装/拆卸按钮保留与语言无关的稳定节点名，UI Journey 不再依赖本地化按钮文字定位。
- 增量复核建设历史、运输批次阻塞与巨构工程状态；补齐动态 `status.LOCKED` / `status.BUILDING` 双语契约，并统一 `Reserved / 预留`、`In Transit / 在途`、`Project state / 工程状态` 用语。

## 测试证据

| 测试 | 结果 | 日志 |
| --- | --- | --- |
| 严格审计（无持久化） | PASS | `.audit-logs/localization-ui-strict-final.log` |
| 审计工具合成 + application 双语命令测试（无持久化） | PASS | `.audit-logs/localization-audit-unit-final.log` |
| English 全核心页面 smoke（无持久化） | PASS | `.audit-logs/localization-en-final.log` |
| zh-CN + 状态保持语言切换 smoke（无持久化） | PASS | `.audit-logs/localization-zh-final.log` |
| UI → Domain 静态完整性回归（无持久化） | PASS | `.audit-logs/localization-domain-final.log` |
| 核心 UI Playflow（无持久化） | PASS | `.audit-logs/localization-playflow-final.log` |
| Full Gameplay UI harness（无持久化） | PASS | `.audit-logs/localization-full-gameplay-ui-final.log` |
| 建设历史 / 运输 / 巨构增量严格审计（无持久化） | PASS | `.audit-logs/localization-incremental-strict-final.log` |
| 增量 English UI smoke（无持久化） | PASS | `.audit-logs/localization-incremental-en-final.log` |
| 增量 zh-CN UI smoke（无持久化） | PASS | `.audit-logs/localization-incremental-zh-final.log` |
| 增量双语 catalog 对齐（无持久化） | PASS | `.audit-logs/localization-incremental-catalog-final.log` |

增量检查同时确认运输与巨构动态状态目录覆盖：`BLOCKED_DESTINATION`、`IN_TRANSIT`、`LOCKED`、`BUILDING`、`SITE_PREPARATION`、`WAITING_MATERIAL`、`INTEGRATION`、`COMMISSIONING`、`COMPLETED` 在英文与中文 `core_ui.status.*` 中均有非空值。严格工具继续验证新增建设历史、运输和巨构格式字符串的中英文占位符签名一致。

航线暂停/恢复与研究状态的第二次增量复核日志为 `.audit-logs/localization-routes-research-strict.log`、`localization-routes-research-en.log`、`localization-routes-research-zh.log`、`localization-routes-research-catalog.log`，四项均 PASS。研究动态状态契约 9/9 双语覆盖：`PAUSED`、`ACTIVE`、`IDLE`、`COMPLETED`、`WAITING_MATERIAL`、`WAITING_FACILITY`、`WAITING_KNOWLEDGE`、`WAITING_FIELD_TEST`、`WAITING_PROTOTYPE`；共享 `ACTIVE` 中文采用跨领域可用的“运行中”，不再把舰船专用“现役”泄漏到研发项目状态。

中文 smoke 退出时仍有项目已有的 `8 resources still in use` 引擎清理信息；测试在其前已打印 PASS，且没有 `SCRIPT ERROR`。这不是本地化断言失败，但资源释放应由 UI 生命周期审计继续处理。

## 剩余债务与优先级

1. **P2 — 682 个历史中文目录条目。** 当前未被生产稳定 API 引用；应按 Dead UI / 复用功能判定删除或补英文，而不是自动复制中文到英文。
2. **REVIEW — 14 个动态 key、361 个 core 玩家文本候选、6 个 application 内部文本。** 动态 key 应建立有限枚举；core 文本只有确认进入玩家诊断后才迁移；内部 application 文本不得误迁移为玩家文案。
3. **REVIEW — 8 个 UI 内部标识。** 2 个截图 harness 协议标记和 6 个系统字体族不是玩家文案，保持精确分类与审查证据。

玩家 UI 本地化结论：**VERIFIED**。`zh-CN`、`English`、运行时稳定 key、UI/application 玩家文本与格式签名均通过；历史未引用 catalog 与 core 候选仍作为非运行时 REVIEW 债务保留，不能被解释为已完成历史目录清理。
