# Gameplay Surface Map

静态快照：2026-08-31。Surface 事实来自 `src/ui/main.gd`、UI components、`data/player_action_registry.json` 与当前测试源码。最终 Journey、分辨率和视觉 PASS 留给最终 strict RunId 与截图矩阵。

## 全局 Shell

| Surface | 玩家入口 | 当前玩家可见内容 | 权威来源 / 写入路径 | 验证入口 |
| --- | --- | --- | --- | --- |
| Top Status Bar | 始终可见 | 时间、Location、总能源、告警数、工程数、R&D、Megastructure；暂停/1/2/5/10/100×、语言、Save、New Game | `_build_header()` / `_update_header()`；`Game.save_game()`；`Game.reset_game()` | `ui_input_accessibility_test.gd`、`ui_persistence_audit_test.gd` |
| Navigation Rail | 始终可见 | 11 个公开入口；锁定项保留可见并显示条件 | `_build_navigation_rail()`；`Game.ui_navigation_availability()` | `ui_input_accessibility_test.gd`、`full_gameplay_ui_test.gd` |
| Context Inspector | 右栏 | 已发现 Location selector、地点摘要、活动 blocker、Guidance、Developer Details | `_rebuild_sidebar()`；`Game.active_blockers()`；`Game.guidance_snapshot()` | `ui_state_coverage_test.gd`、`full_gameplay_ui_test.gd` |
| Alerts / Task / Timeline | 底栏 | 当前 alert 数、Suggested Task、最近 timeline event | `_refresh_alerts()` / `_update_bottom_bar()`；Domain events / command rejection | `ui_state_coverage_test.gd`、`ui_action_coverage_test.gd` |

## 主页面与玩家问题

| 页面 / 子页 | 主要回答的问题 | 主要玩家动作 | 代码入口 | 关键验证 |
| --- | --- | --- | --- | --- |
| System Map | 地点、survey visibility、路线、舰队任务、巨构在哪里？ | 选择已发现 Location | `_rebuild_system_map()`、`SystemMapView.configure()` | UNKNOWN 节点 disabled+tooltip；Location 跳转；Fresh screenshots |
| Location / Overview | 这个地点的 Power、Storage、Cargo、Industry、Maintenance 与 Projects 状态如何？ | 打开五个 Location tabs | `_rebuild_location()`、`_build_location_overview()` | Location smoke、State coverage、Fresh journey |
| Location / Resources | 已知资源和 survey 精度是什么？能否开发 Site？ | Assign Survey、Develop Site | `_build_location_resources()` | Survey states、Action coverage |
| Location / Industry | 本地生产线、设备、工艺与容量是什么？ | Start/Stop、Method、Priority、Add Line、Expand、Template | `_build_location_industry()` | Production action/state coverage |
| Location / Logistics | 哪些货物在运输，路线为何饱和/停运？ | Route pause/resume、mode、ship、priority、policy | `_build_location_logistics()` | Logistics action/state coverage、root-cause route focus |
| Location / Projects | 此地点正在建设什么？ | 打开项目/查看状态 | `_build_location_projects()` | Construction state coverage |
| Industry / Production | 全局工业在生产什么，何处 blocked？ | Start/Stop、control、method、priority | `_rebuild_industry()` | 生产 9 states、四象限 actions |
| Industry / Facilities | 设施和制造模块如何配置？ | Install/Uninstall manufacturing module、Power priority | `_build_facility_management()` | Action coverage |
| Industry / Construction | 统一物资工程队列如何竞争 capacity？ | Start、Pause、Resume、Priority、Cancel | `_build_industry_construction()` | Construction 6 states、Action coverage |
| Industry / Automation + Planner | 当前经济的主瓶颈和目标产量需求是什么？ | Read-only product/ship planner；有限 automation 管理 | `_build_background_economy_controls()` | planner/domain contract、UI performance contract |
| Inventory | 每个商品的 Stock/Capacity/Available/Reserved/Flow/Net 与上下游是什么？ | Search、Product Details、Why | `_rebuild_inventory()` | blocker/navigation、localization、screenshots |
| Logistics | 当前选中 Location 的物流控制面 | 与 Location / Logistics 相同 | `_rebuild_logistics()` 复用 `_build_location_logistics()` | 同上 |
| Construction | 统一工程队列 | 与 Industry / Construction 相同 | `_rebuild_construction()` 复用 `_build_industry_construction()` | 同上 |
| Research | 当前 Program、stage、工业投入、prototype、field test 和 roadmap 是什么？ | Start/Pause、Select route、解决 blocker | `_rebuild_research()` | Research 9 states、Action coverage、Fresh journey |
| Ships / Readiness | Fleet doctrine、formation、supply 是否就绪？ | Doctrine、retreat、zone、supply target、resupply | `_build_fleet_readiness()` | Action coverage |
| Ships / Roster | 舰船在哪里、在做什么、是否可用？ | Assign、maintenance lifecycle、construction support、loadout/refit/scrap | `_build_fleet_roster()` | Action coverage、refit focused probes、Fresh journey |
| Ships / Shipyard | 造船 BOM、队列、commissioning 进度是什么？ | Build、reorder、cancel | `_build_fleet_shipyard()` | Action coverage、Outer Titan commission probe |
| Ships / Archive | 已完成/取消的 refit 和舰队记录是什么？ | Cancel active refit、inspect history | `_build_fleet_archive()` | Action coverage、refit probe |
| Expedition | Fleet 是否能执行 field test / expedition？ | Configure route、launch、recall、repeat combat | `_rebuild_expedition()` | Action coverage、Fresh Research/Ship journeys |
| Survey / Frontier | Site discovery、永久 extraction 与 network integration 如何推进？ | Start/Stop extraction、Integrate site | `_rebuild_frontier()` | Survey states、Action coverage、Fresh journey |
| Megastructure | 唯一巨构的 site、阶段、真实 BOM、施工与物流 blocker 是什么？ | Select site、Start phase、Cancel、Open worksite | `_rebuild_megastructure()`、`megastructure_progress_view.gd` | Megastructure 8 states、Action coverage、Fresh completion |
| Diagnostics | 什么坏了、为什么、根因在哪里、能做什么？ | Why、Open upstream、Open resolution、Planner | `_rebuild_diagnostics()`、`_navigate_blocker()` | `ui_state_coverage_test.gd` 的 root-cause chain |

## 导航图

```text
Navigation_system_map -> Location_<id> -> location
Navigation_location -> overview | resources | industry | logistics | projects
Navigation_industry -> production | facilities | construction | automation
Navigation_inventory -> ProductDetails / Why -> diagnostics or upstream target
Navigation_logistics -> selected Location logistics
Navigation_construction -> unified construction queue
Navigation_research
Navigation_ships -> readiness | roster | shipyard | archive -> ShipsMissions -> expedition
Navigation_survey -> frontier extraction/network
Navigation_megastructure -> worksite -> location.projects
Navigation_diagnostics -> blocker -> inventory/logistics/construction/location/industry/research/ships

Context Guidance -> authoritative page/section/location target
ui_cancel -> previous page -> system_map fallback
```

System Map 未发现节点当前为 disabled，并提供完成前置 survey route 的 tooltip；它们不会再触发 Location navigation。Diagnostics 的 upstream action 会保留 `_logistics_route_focus_id`，因此 route saturation 的 `Problem -> Why -> Root Cause -> Route Card` 不是只跳到泛化页面。

## Action Surface 对账

机器 registry 当前包含 73 个动作，其中 57 个 `coreGameplay=true`；全部 57 个 core action 有具体 UI entry point。非 core 不自动等于应删除：它们包括 Shell 操作、maintenance lifecycle、saved loadout、scrap 与 automation administration。

当前明确未 surfaced 的非 core Domain actions：

| Action | 静态事实 | 处理原则 |
| --- | --- | --- |
| `SET_INVENTORY_RESERVE` | Inventory 展示 reserved，但没有玩家 reserve 编辑入口 | 非 core policy；不计为核心 Surface 缺失 |
| `PIN_PRODUCT` | Domain command 存在，当前 UI 无入口 | 非 core preference |
| `AUTHORIZE_ROUTE_AUTOMATION` | Domain 支持，UI 无创建入口 | 非 core future automation |
| `AUTHORIZE_PROJECT_PRIORITY_AUTOMATION` | Domain 支持，UI 无创建入口 | 非 core future automation |

`APPLY_INDUSTRIAL_TEMPLATE` 与 `CLEAR_INDUSTRIAL_TEMPLATE` 已由 Industry / Industrial Policy Templates 实际接通；旧文档中“registry stale / 无 UI entry”结论已经失效。

## State / Blocker / Guidance Surface

`data/ui_state_registry.json` 定义 43 个 core state。每个 state 的 runtime harness 要求同时证明：真实 Domain state、可见状态、解释、可用下一步。Blocker UI 消费标准化字段并提供：

```text
code / severity / source_entity / missing_requirement /
upstream_cause / navigation_target
```

Sidebar、Diagnostics、具体 Factory/Route/Project card 共享 Domain blocker；Guidance 消费 `Game.guidance_snapshot()` 的 `step_id/reason/page/section/location_id/focus_entity_id`。UI 不持有 progression milestone 规则。

## Discoverability 与信息架构风险

- `expedition` 是唯一没有 rail 的实际页面，但有 Ships > Missions 与 contextual Guidance 两条入口；它是子流程页面，不是 orphan。
- Logistics 与 Construction 各有全局 rail 入口，同时复用 Location/Industry builder。它们共享一个规则和渲染权威，但“全局入口/当前 Location scope”的标题语义仍可进一步强化。
- Context Inspector 以 Location 为中心；Product、Route、Ship、Project 没有统一 selected-entity inspector 与 breadcrumb。
- Inventory、Logistics policy、Fleet supply 仍是最高密度的数字输入区域。自动化/默认策略已经减少逐 SKU 管理，但最终“防 Excel”结论仍需玩家 Journey 与截图审查。
- Bottom bar 是聚合摘要，不是可滚动完整 event history；历史保存在 `_event_log`，但玩家当前只看最近项。

## 可复现测试

```powershell
& 'D:\Godot\godot.exe' --headless --path 'D:\Projects\standalone\core_gameplay_lab' res://tests/player_action_registry_test.tscn -- --no-persistence
& 'D:\Godot\godot.exe' --headless --path 'D:\Projects\standalone\core_gameplay_lab' res://tests/ui_action_coverage_test.tscn -- --no-persistence --locale=en
& 'D:\Godot\godot.exe' --headless --path 'D:\Projects\standalone\core_gameplay_lab' res://tests/ui_state_coverage_test.tscn -- --no-persistence --locale=en
& 'D:\Godot\godot.exe' --headless --path 'D:\Projects\standalone\core_gameplay_lab' res://tests/ui_input_accessibility_test.tscn -- --no-persistence --locale=en
& .\tools\run_full_gameplay_ui.ps1 -RunId '<unique-run-id>' -TimeoutSeconds 28800 -CleanEvidence
```

静态 Surface 对账完成不等于 Journey PASS。最终仍需引用同一提交上的 strict suite、Fresh Save 10-Journey artifact、双语 screenshot matrix 与独立 Visual QA。
