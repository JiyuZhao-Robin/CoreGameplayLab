# Core Gameplay Lab UI 审计报告

审计日期：2026-08-28  
范围：当前未提交工作树的 UI 源码、场景、UI contract 数据、UI 测试源码与现存审计日志。  
结论：**当前 UI 审计不通过，不能声明 runtime UI coverage，也不能声明 READY FOR ART PRODUCTION。**

## 执行摘要

当前 UI 已经形成清晰的工业控制台骨架：顶栏、固定工作区导航、中央页面、Location 级 Context Inspector、底部反馈区；Inventory、Diagnostics、锁定条件 tooltip、Guidance 和语义 theme token 都是有价值的方向。56 个 core player action 也有静态 UI-to-Domain 映射。

当前导航公开 ID 已与 `ui_playflow_test.gd` 对齐，Restart 也已有取消优先确认，Industrial Template 已出现真实 apply/clear 入口，Megastructure 已有逐层显形的自绘进度视图和 8 阶段 tile。本轮当前工作树的 player action registry、UI playflow、UI state registry、English、zh-CN 与 Location 六个 focused tests 均退出码 0；但 `overview` / `expedition` 仍是条件/间接页面，缺少统一 Back/breadcrumb，这些测试也不覆盖完整 UI-only Journey、分辨率矩阵或键盘/焦点。

除此以外，响应式、键盘/手柄、焦点、危险操作确认覆盖、截图矩阵、全状态呈现和纯 UI fresh-save Journey 均没有当前运行证据。`data/ui_state_registry.json` 自身明确标注 `CONTRACT_ONLY / UNVERIFIED`，`data/player_action_registry.json` 也明确标注 `uiJourneyCoverage = UNVERIFIED`。

## 审计方法与证据边界

本轮执行了源码/数据/测试/日志检查，并以 `--no-persistence` 运行 6 个 focused Godot 测试；没有修改代码、数据或测试，四份文档是唯一写入范围。

本轮当前工作树实际结果为：`player_action_registry_test`、`ui_playflow_test`、`ui_state_registry_test`、`ui_english_localization_smoke_test`、`ui_chinese_localization_smoke_test`、`location_ui_smoke_test` 均输出各自 PASS 且退出码 0。每个进程退出时也都报告 `ObjectDB instances leaked` 和 `8 resources still in use`，所以应同时记录 focused 断言通过与 lifecycle cleanup 债务。registry test 只证明静态 contract，localization smoke 不替代 stable-key 门禁，mixed playflow 不替代 UI-only Journey。

## Findings

### P1 — 间接页面与返回模型仍然弱

当前 rail 使用稳定的 11 个公开 ID；`ui_playflow_test.gd` 也已改为 `Navigation_ships`、`Navigation_survey` 和 `ShipsMissions`。`expedition` 因而是经 Ships 可达的间接页面，`overview` 是 Guidance 条件可达页面。问题已从“测试 contract 冲突”降为信息架构风险：Shell 没有 breadcrumb、Back 或最近访问历史，玩家无法稳定判断当前位置或返回来源。

### P1 — 状态 contract 与 runtime 覆盖之间仍有完整缺口

UI state registry 定义 44 个生产、建设、科研、物流、勘测和巨构状态，但每项 `runtimeCoverage` 都是 `UNVERIFIED`。现有 UI tests 只覆盖少数初始状态、一个工业 input blocker 和人工构造的 research blocker，不能证明：

- 每个状态由合法模拟路径产生；
- 所有 affected screens 显示相同语义；
- Why 显示实际/需要/在途/预留等关键数值；
- Suggested Action 可到达正确 Location/entity 并真正解析状态。

### P1 — Discoverability 与导航语义不一致

- `overview` 只有条件 Guidance 可达，`expedition` 只有 Ships Missions/特定 Guidance 可达；二者无 breadcrumb/Back。
- 锁定 rail 项显示 Locked 和 tooltip，但按钮仍可进入页面；页面需要承担完整的 unlock explanation，目前没有统一门槛卡。
- 地图图例写 UNKNOWN/LOCKED、页面文案写未知地点不可操作，但地图为所有节点创建 enabled Button；所有内容 Location 又都存在于 state，故未知节点可进入 Location。
- `NextStepCTA` 正文不显示目标，且没有通用 entity focus/return stack。
- 大量 disabled gameplay action 没有统一 reason tooltip 或 Why 控件。

### P1 — Context Inspector 只有 Location 级投影

当前 Inspector 的信息顺序合理：上下文摘要 -> blockers -> Guidance -> developer details，且 `Game.active_blockers()` 已聚合 mining、industry、construction、shipyard、research 和饱和物流路线。但没有统一 selection model，不能根据产品、设施、产线、项目、舰船、航线或巨构阶段切换；没有多选、历史和焦点实体。Diagnostics 因而仍主要靠 page-level 分类跳转，而不是把玩家带到具体问题对象。

### P1 — 响应式/分辨率没有实现或证据

当前项目固定 1440×900，Shell 无 breakpoint/侧栏折叠/窄屏重排。地图页硬最小宽约 1352 px；1366 px 仅余约 14 px，顶栏还有 620 px 状态区、四个速度按钮和三个全局动作。地图最小高 560 px，加上顶栏/底栏/边距后在 768 px 高度需要滚动。

`docs/ui-audit/dsponline-reference.md` 要求 1920×1080、2560×1440、1366×768 矩阵，但当前仓库没有截图资产，也没有 resolution test。三种分辨率均为 `UNVERIFIED`。

### P1 — Excel 化风险高，模板已落地但信息分层仍不足

中央页面大量逐 SKU/逐设施/逐舰船展开字段与按钮。Location Logistics 使用每项目标库存/保留量/优先级/阈值 SpinBox；Industry 为每设施和配方创建动作；Fleet 为每舰船展开全部生命周期、编队、loadout 和模块控制。除 Inventory 搜索外，缺少过滤、排序、分组、批量、虚拟化和摘要/详情分层。

Industrial Template 现已提供 selector、apply、clear 与 managed expansion pause/resume，是 anti-Excel 的实质进展。但模板差异预览、影响确认、逐 SKU 例外层和批量回滚仍未形成；大量详细控制仍默认展开。另外，`data/player_action_registry.json` 仍把 apply/clear 标为不可达，已经落后于当前 UI，需由 registry 负责阶段校正。

### P1 — 危险操作确认覆盖与反馈层级不一致

Restart 已使用 exclusive `ConfirmationDialog`，明确说明不可撤销，并默认聚焦取消按钮，这是正确的局部修复。但取消工程/巨构阶段/造船订单/改装、删除 loadout、拆解舰船等有损动作仍直接执行；代码也没有统一 Modal/Overlay、Escape/Back 和关闭后焦点恢复 contract。成功和失败大多写入底栏单行 notice，超长文本会省略；持久 Alert、阻断 Dialog 与普通 Notice 没有明确分层。

### P2 — 动态重建会破坏焦点、滚动与局部交互

`_rebuild_active_page()` 会重建 Inspector 与当前页；`_clear()` 删除所有子控件。虽然文本输入聚焦时会暂缓 dirty rebuild，但没有 scroll restore、focus restore 或 stable list item identity。任何状态 signal 都可能让键盘用户丢失位置，长清单也会产生不必要的创建/释放开销。

### P2 — UI 单体文件继续承担过多职责

`src/ui/main.gd` 同时负责 Shell、13 页面、格式化、Guidance、blocker 路由、planner、命令反馈、偏好和本地状态。Context Inspector、preferences、Inventory、Diagnostics 与 navigation availability 都继续并入同一脚本，集成面和回归半径持续扩大。`system_map_view.gd`、`megastructure_progress_view.gd` 与 `ui_theme_tokens.gd` 的拆分方向正确，但还没有形成 Workspace/Inspector/ViewModel/CommandGateway 边界。

### P2 — 巨构分层视觉已实现，但状态与分辨率验证缺失

`src/ui/components/megastructure_progress_view.gd` 是约 `720x300` 的自绘视图：结构从基座、基础、主框架、能源骨干、收集器、集成、调试到运行层随完成阶段逐层显形，并设置阶段 tooltip 文本；`_rebuild_megastructure()` 同时构造 8 个 `✓/◆/○` 阶段 tile、统计卡和普通进度条。该实现比单一百分比更能表达终局推进，但当前测试只浅查阶段定义/标题，没有逐阶段截图、取消/恢复、最终态或 1366×768 裁切证据；固定 `720x300` 会继续占用窄屏中央区，且视图的 `MOUSE_FILTER_IGNORE` 使 tooltip 可触达性尤其需要实测。

### P2 — 键鼠、焦点与可访问性无专项验证

未发现快捷键、显式 Tab 顺序、focus neighbor、focus ring 应用、Escape/Back、手柄导航或地图键盘操作。普通按钮最小高 34 px，导航行 40 px；是否满足目标平台点击面积未验证。tooltip 覆盖零散，且 tooltip 自身没有键盘/触摸等价路径证据。

### P1 — Stable-key 本地化门禁当前失败

`docs/ui-audit/localization-audit.md` 的工作树快照真实报告 `891 errors / 820 warnings`：主要是英文目录缺失、UI/Application 硬编码、stable key 缺失、动态 key 复核、inline 桥和术语混用。该审计门禁退出码为 1；精确数量会随并行修改变化，但在重跑清零前必须保持失败。

English smoke 主要扫描可见 CJK 字符，不能识别生硬翻译、fallback key、tooltip 泄漏或文本裁切。当前 `main.gd` 仍包含大量直接中文拼接和 `I18n.inline()` 桥。Locale 切换的状态保留测试意图良好，但不能覆盖 stable-key 门禁，也不能被用来关闭当前失败。

## 正向资产

- 语义颜色与尺寸已集中到 `ui_theme_tokens.gd`，比页面自定义颜色更容易审计。
- Shell 的五区层级清楚，Context -> blocker -> Guidance 的侧栏顺序符合任务优先级。
- Guidance snapshot 已包含 page、section、Location、focus entity、reason 和 acquisition path 等结构字段。
- Inventory 已有搜索和 Why，Diagnostics 已有 root-cause 分类路由。
- 锁定导航保持可见并显示条件，方向上优于完全隐藏功能。
- Restart 已具备明确、取消优先的确认弹窗。
- Industrial Template 已提供 apply/clear 与托管扩建授权入口。
- Megastructure 已提供与八阶段同步的分层自绘结构、阶段状态 tile、统计卡和进度条，而不是仅显示单一百分比。
- 56 个 core action 有静态 UI-to-Domain 映射，且写操作主要经 `Game.*`，没有发现 UI 直接写库存/工程/科研等权威状态的常规按钮路径。
- System Map 使用真实 Location/route 数据而不是图片热点；Location 有五个清晰子页。

## 验证矩阵

| Gate | 当前状态 | 证据/原因 |
| --- | --- | --- |
| UI script 可加载并启动 | `EXECUTED-PASS (FOCUSED)` | UI playflow、Location、English 与 zh-CN smoke 均实例化当前 MainScene 并退出码 0；不覆盖长时运行。 |
| Navigation contract | `EXECUTED-PASS (FOCUSED)` | UI playflow 本轮验证 11 个公开 ID 与 `ShipsMissions` 间接路径，退出码 0。 |
| Player action static contract | `EXECUTED-PASS (STATIC CONTRACT ONLY)` | registry test 本轮验证 56 core action，退出码 0；不证明控件 Journey。 |
| Player action UI Journey | `UNVERIFIED` | registry 顶层明确如此。 |
| UI state registry structure | `EXECUTED-PASS (CONTRACT ONLY)` | 本轮结构测试退出码 0；runtime coverage 仍明确 UNVERIFIED。 |
| 全 44 状态 runtime UI | `UNVERIFIED` | 无真实状态矩阵测试。 |
| zh-CN UI | `EXECUTED-PASS (FOCUSED)` | locale/选择状态 smoke 本轮退出码 0；无视觉溢出矩阵。 |
| English UI | `EXECUTED-PASS (FOCUSED)` | 可见 CJK 泄漏 smoke 本轮退出码 0；不检查文案质量、tooltip 与裁切。 |
| Stable-key localization audit | `FAIL` | 快照报告 891 errors / 820 warnings，门禁退出码 1。 |
| 1920×1080 | `UNVERIFIED` | 无当前截图/裁切检查。 |
| 2560×1440 | `UNVERIFIED` | 无当前截图/裁切检查。 |
| 1366×768 | `UNVERIFIED / HIGH RISK` | 固定最小宽接近窗口上限，无断点。 |
| 鼠标完整操作 | `UNVERIFIED` | 部分 button smoke，不是全 Journey。 |
| 键盘/焦点/Escape | `UNVERIFIED` | 无实现契约与测试。 |
| 危险操作确认 | `PARTIAL / UNVERIFIED` | Restart 已实现确认；其他有损动作未统一，弹窗交互未运行。 |
| UI-only fresh-save -> endgame | `UNVERIFIED` | Domain golden path 不等于 UI path。 |

## 建议修复顺序

1. 将本轮 focused 测试固化为与源码版本关联的可复现日志，修复退出时 ObjectDB/resource still in use 警告，并补跨进程偏好恢复。
2. 保持当前 navigation public ID 稳定，并为 `overview` / `expedition` 补足 breadcrumb/Back/当前位置语义。
3. 让 UNKNOWN map node 的可点击性与图例/文案一致，并为 Locked workspace 提供可见门槛卡。
4. 建立单一 `UIState`（active workspace、selection、overlay、back stack）与稳定 Context Inspector 投影。
5. 在现有 Industrial Template 入口上补差异预览、影响确认和例外层；逐 SKU 控件降为高级展开。
6. 扩展现有 `BlockerInfo -> Why -> NavigationTarget`，加入稳定 entity/section/focus/return，并用 registry 44 状态验证。
7. 把 Restart 的取消优先模式扩展为统一 modal/back/focus contract，并覆盖其他有损动作；区分 Notice、Alert、Dialog。
8. 拆出 Shell、Workspace、Inspector、页面 view model 和 command feedback；避免每次状态变化清空整页。
9. 在 1920×1080、2560×1440、1366×768 × zh-CN/en 运行截图矩阵，再做键盘、焦点、滚动和 tooltip 等价路径检查。
10. 最后运行不写 `Game.state` 的 UI-only fresh-save Journey，并把结果记录到独立 final certification；在此之前保持 UI runtime coverage 为 `UNVERIFIED`。
