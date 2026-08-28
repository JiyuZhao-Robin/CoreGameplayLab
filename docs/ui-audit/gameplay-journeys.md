# Gameplay Journeys：当前实现与验证边界

审计快照：2026-08-28。本文区分“代码中可推导的路径”“测试源码覆盖”和“当前运行验证”。除 focused Godot 测试外，本轮新增并实际执行了严格的 fresh-save UI-only 早期工业 Journey；只有各测试实际断言可标记为 `EXECUTED-PASS`，不把混合测试、静态 contract 或 MainScene 可实例化升级为完整 Journey PASS。

## Journey 覆盖定义

一个 Journey 只有同时满足以下条件，才能标为 runtime verified：

1. 实例化真实 `src/ui/main.tscn`；
2. 从玩家可见入口按正常导航到达控件；
3. 通过控件触发 `Game.*`，不直接调用 Domain 命令替代点击；
4. 观察成功结果与至少一个合法失败原因；
5. 对持久化动作执行保存/读取并重新从 UI 派生结果；
6. 对目标分辨率和语言检查裁切、焦点、滚动与可读性。

`tests/player_action_registry_test.gd` 只做静态源追踪；`tests/ui_state_registry_test.gd` 明确只做 contract 结构检查；二者都不能证明 Journey。

## J0：启动与恢复工作区

```text
Launch -> load UI preferences -> build theme/shell -> connect Game signals
       -> rebuild all pages -> restore active page / Location / section
```

| 项目 | 证据 | 状态 |
| --- | --- | --- |
| Main scene 指向真实 UI | `project.godot:run/main_scene`、`src/ui/main.tscn` | `STATIC-CONFIRMED` |
| 页面与选择偏好字段存在 | `_active_page_key`、`_selected_location_id`、section fields、`ConfigFile` | `STATIC-CONFIRMED` |
| 读写偏好可执行 | `_load_ui_preferences()` / `_save_ui_preferences()` 保存 page、Location、三个 section 和 Developer Details | `STATIC-CONFIRMED` |
| MainScene focused 启动 | UI playflow、Location、zh-CN 与 English smoke 均实例化当前 UI 并退出码 0 | `EXECUTED-PASS (FOCUSED)` |
| 实际保存/重启恢复 | 没有通过关闭进程再启动验证 page/Location/section | `UNVERIFIED` |

启动链已有当前源码对应的 focused 运行证据；保存、关闭进程、重启和恢复选择仍无 Journey 证据。所有 6 个 focused tests 退出时均报告 `ObjectDB instances leaked` 与 `8 resources still in use`，因此 clean shutdown 也尚未验证。

## J1：新存档 -> 第一条永久采集 -> 第一条工业生产

当前设计路径：

```text
Guidance -> Ships/Roster -> 初始舰调入采矿
         -> Survey/Frontier -> 启动近地采集
         -> 等待/加速 -> 获得 mixed_raw_ore
         -> Industry/Production -> 分离/精炼/装配结构框架
```

静态证据：`_next_flow_step()`、`_next_flow_page()`、`_rebuild_fleet()`、`_rebuild_frontier()`、`_build_industry_production()`。

`tests/ui_playflow_test.gd` 确实点击舰船调配、采矿和第一工业配方，并检查真实库存与 structured blocker。但是它：

- 当前已按 `Navigation_ships` / `Navigation_survey` 查找，与公开控件名静态一致；
- 中途直接调用 `Game.simulation.advance()`；
- 直接修改 mining operation、extraction network、完成活动和库存；
- 因此虽与当前导航树一致，也不是严格的 UI-only fresh-save Journey。

新增 `tests/full_gameplay_ui_test.gd` / `.tscn` 从顶部 Restart 按钮和玩家可见确认框建立新存档，之后仅触发可见、enabled 的 `Button.pressed`：Ships 调配、Survey、顶部速度、Industry、Construction、Research、Shipyard、Expedition 与 Location 子页。它不调用 `Game.reset_game()`、任何 `Game` Gameplay Command、`Game.simulation.advance()`，也不写 `Game.state`；Content、State 与 Query 只用于规划合法 BOM 和观察结果，时间只在点击正常速度控件后由真实 `_process` 推进。

最新 fresh-save 运行把原 15 个里程碑继续推进到 24 个有序里程碑：

```text
NEW_GAME -> FIRST_FLEET_ASSIGNMENT -> FIRST_EXTRACTION_STARTED
-> FIRST_EXTRACTION -> FIRST_PRODUCTION_STARTED -> FIRST_PROCESSED_MATERIAL
-> FIRST_REFINED_IRON -> FIRST_REFINED_COPPER -> FIRST_STRUCTURAL_FRAME
-> FIRST_FACILITY_CONSTRUCTION_STARTED -> FIRST_FACILITY_COMPLETED
-> ESTABLISH_INDUSTRY_COMPLETED -> FIRST_RESEARCH_PROGRAM
-> FIRST_CAPITAL_GOOD -> FIRST_FACILITY_UPGRADE
-> EARTH_EXTRACTION_AUTOMATED -> FIRST_ROUTE_COMPLETED
-> FIRST_PROTOTYPE -> FIRST_FIELD_TEST -> ADVANCED_PROPULSION_COMPLETED
-> FIRST_COMMISSIONED_SHIP -> ASTEROID_BELT_REACHED
-> FIRST_REMOTE_SURVEY -> FIRST_REMOTE_EXTRACTION
```

新增的 UI-only 实证包括：选择 Advanced Propulsion 路线、制造实体 prototype、用 starter ship 完成 field test、研发与按完整 BOM 建造 Lunar Pathfinder、以 Pathfinder 开放小行星带、从 DETECTED 执行材料支持的 SURVEYED 勘测、安装真实制造/舰船模块，以及在远端场地开始守恒采矿。所有长等待只使用玩家可见 100×，返回后立即经可见 10× 控件 settle；短 bootstrap 仍真实覆盖 10×。完整有序 Control trace 和里程碑写入 `artifacts/test-results/full-gameplay-ui.json`，运行日志为 `.audit-logs/full-gameplay-ui-offworld-stage2-available.log`。

当前最高判定是 `FIRST_REMOTE_EXTRACTION: EXECUTED-PASS (FRESH-SAVE UI-ONLY)`。`FIRST_STEEL` 仍为 `UNVERIFIED`，且没有用 checkpoint/scenario 或状态伪造替代：下一步必须在小行星带为 `mixed_raw_ore` 建立 `SUPPLY`、在 Earth 建立对应 `DEMAND`，让远端守恒库存进入正常 freight，随后才能加工 silicate/cobalt、安装 `advanced_alloy_cell` 并执行 `refine_steel`。当前 Advanced Logistics 编辑器的 Add Supply/Demand/Storage 按钮虽然可见，但没有稳定 `Control.name`；严格 Journey 无法寻址玩家意图 `AddLogisticsPolicy_asteroid_belt_mixed_raw_ore_SUPPLY`。该缺口分类为 `P0_MISSING_GAMEPLAY_SURFACE / SET_LOCATION_LOGISTICS_POLICY`，并在证据 JSON 的 `blockingUiSurface` 中保留精确 location/item/mode、期望控件名和 Domain consequence。完整终局 UI-only Journey 也仍为 `UNVERIFIED`。

## J2：System Map -> Location -> 情报递进 -> 场地开发

```text
System Map -> 选择已知 Location -> Overview
           -> 执行 UNKNOWN/DETECTED/SURVEYED 的下一阶段勘测
           -> Resources -> 查看分级披露的资源情报
           -> Develop Site -> Construction-backed 场地开发
```

`tests/location_ui_smoke_test.gd` 从 Earth 节点进入 Location，并遍历 overview/resources/industry/logistics/projects；它验证初始库存、资源空/有状态、物流策略控件和工程空态。它没有走完整勘测递进、未覆盖未知节点，也未检查未知节点是否应禁用。

当前 `SystemMapView` 对未知节点仍创建 enabled Button，而 Location state 对所有内容 Location 都存在；因此“UNKNOWN/LOCKED”图例与可点击行为不一致。当前判定：Location smoke 本轮退出码 0，已知 Earth 与五个子页为 `EXECUTED-PASS (FOCUSED)`；完整 Journey `UNVERIFIED`。

## J3：库存异常 -> Why -> Diagnostics -> 根因解决

```text
Inventory search -> ProductDetails / Why -> Diagnostics
                 -> blocker card -> route by reason
                 -> Logistics / Construction / Location / Inventory / Industry
                 -> resolve -> return and observe recovery
```

静态实现：`_rebuild_inventory()`、`_open_product_diagnostics()`、`_rebuild_diagnostics()`、`_navigate_blocker()`。

已确认的限制：

- `Game.active_blockers()` 已聚合 mining、industry、construction、shipyard、research 和路线饱和；Survey、维修、Expedition、Megastructure 的状态仍未形成同等的 active blocker 聚合。
- 路由只保存产品搜索词，没有通用 `focus_entity_id`、scroll anchor 或返回栈。
- 没有测试点击 Why、验证目标页、执行修复并返回确认状态恢复。

当前判定：`STATIC-CONFIRMED` 路径，runtime `UNVERIFIED`。

## J4：Location Logistics 策略与运输资源配置

```text
Location/Logistics or global Logistics
  -> 查看仓储/枢纽/路线/在途
  -> 选择 transport mode / source / route / ships
  -> 编辑 reserve/target/priority/threshold
  -> 保存或清除 policy
  -> 观察 shipment、利用率和 blocker
```

`data/player_action_registry.json` 对 SET/CLEAR policy、CHANGE mode、ASSIGN ship、CHANGE route priority 有静态 UI-to-Domain 映射。`tests/location_ui_smoke_test.gd` 只确认策略控件存在；没有输入、保存、拒绝、在途变化、跨 Location 或 save/load 的真实 Journey。

当前判定：核心动作 `STATIC-CONFIRMED`，交互链 `UNVERIFIED`。

### J4b：Industrial Template 默认策略与例外管理

```text
Location/Industry -> IndustrialTemplateSelector
                  -> ApplyIndustrialTemplate / ClearIndustrialTemplate
                  -> managed expansion pause/resume
                  -> inspect per-facility / per-recipe exceptions
```

当前 `ApplyIndustrialTemplate` 经 `_apply_selected_industrial_template()` 调用 `Game.apply_location_industrial_template()`，`ClearIndustrialTemplate` 直接绑定 `Game.clear_location_industrial_template()`，所以 apply/clear 已是 `STATIC-CONFIRMED` 的真实 UI 入口；`data/player_action_registry.json` 对这两项的“无入口”记录已经 stale。本轮没有点击模板、确认设施/配方变化、清除回滚或 save/load 的专项断言；模板差异预览、影响确认与逐 SKU 例外层也尚未形成。当前判定：入口已实现，Template Journey `UNVERIFIED`。

## J5：Guidance 驱动建设与科研 Field Test

```text
完成首个框架 -> Guidance 指出 Foundry 精确材料缺口
             -> NextStepCTA -> Industry/Construction
             -> 建造 Foundry/电子设施/研究中心
             -> Research program blocked at prototype/field test
             -> Guidance -> Industry 或 Expedition
```

`tests/ui_playflow_test.gd` 检查精确缺口文案、Next CTA 切换 construction section，以及 research blocker 到 Industry/Expedition 的页级路由。但测试直接制造研究 blocked Dictionary、直接写库存/设施/完成活动并直接推进 simulation。它验证的是若干 UI 输出契约，不是玩家从新存档自然走到 field test 的完整 Journey。

当前判定：相关输出断言随 UI playflow 本轮退出码 0，为 `EXECUTED-PASS (FOCUSED/MIXED)`；runtime UI-only 全链仍为 `UNVERIFIED`。

## J6：Ships -> Expedition -> 任务/战斗/报告

```text
Ships/Roster -> 调配 expedition 舰队
Ships/Readiness -> doctrine / retreat / formation / supply
Ships/Missions -> Expedition
               -> route readiness -> start/recall
               -> optional combat action -> report/archive
```

English localization 与 `ui_playflow_test.gd` 当前都通过 `ShipsMissions` 到达 Expedition，间接入口 contract 已对齐。仍没有一个测试用正常 UI 完成调配、补给、发射、战斗/召回、结果和持久化全链。

当前判定：English smoke 与 UI playflow 本轮都成功经 `ShipsMissions` 进入页面，间接导航为 `EXECUTED-PASS (FOCUSED)`；完整 Journey `UNVERIFIED`。

## J7：Megastructure 八阶段终局

```text
Research unlock -> Megastructure
                -> 深度勘测候选地 -> 选择工地
                -> 八阶段逐阶段准备/建设/集成/调试
                -> 完成状态
```

Domain `golden_path_test` 的历史日志显示无作弊路径能完成 11 个目标和八阶段，但它不是 UI Journey。UI 测试只断言存在一个八阶段定义并扫描英文阶段名，没有通过 UI 执行各阶段开始/取消、材料 blocker 和最终完成。

当前 UI 不是纯文本进度：`src/ui/components/megastructure_progress_view.gd` 提供约 `720x300` 的自绘结构，将基座、基础、主框架、能源骨干、收集器、集成、调试、运行层按完成阶段逐层显形，并设置阶段 tooltip 文本；`_rebuild_megastructure()` 还呈现 8 个 `✓/◆/○` 阶段 tile、当前阶段统计卡和进度条。该分层视觉为 `STATIC-CONFIRMED`，但没有截图、分辨率矩阵或逐阶段状态转换断言；视图使用 `MOUSE_FILTER_IGNORE`，tooltip 可触达性也未验证。

当前判定：Domain 行为有历史证据；UI Journey `UNVERIFIED`。

## J8：语言切换、保存与危险重开

| 子 Journey | 测试源码 | 缺口 | 当前状态 |
| --- | --- | --- | --- |
| zh-CN -> en -> zh-CN | `ui_chinese_localization_smoke_test.gd` 保存 page/location/subpage 并切换；本轮退出码 0 | 无视觉溢出、tooltip 与全动态状态检查 | `EXECUTED-PASS (FOCUSED)` |
| English 全页扫描 | `ui_english_localization_smoke_test.gd` 遍历多数页面与 sub-sections，检测 visible CJK；本轮退出码 0 | 只查 CJK，不查 natural language、stable key、tooltip、裁切或 fallback key | `EXECUTED-PASS (FOCUSED)` |
| Stable-key 审计 | `tools/ui_localization_audit.gd` 扫描 stable key、inline、硬编码、术语和目录 | 快照为 891 errors / 820 warnings；精确数量需在 UI 稳定后重跑 | `FAIL (AUDIT SNAPSHOT)` |
| Save | action registry 有静态映射 | 无通过 UI 保存、重启、恢复 selection/page 的 Journey | `UNVERIFIED` |
| Restart | 顶栏打开 exclusive `ConfirmationDialog`，文案说明不可撤销，默认焦点置于取消 | 无打开/取消/确认/关闭后焦点的 runtime 测试 | 实现 `STATIC-CONFIRMED`，交互 `UNVERIFIED` |

## 测试能力地图

| Test | 实际证明范围 | 明确不能证明 |
| --- | --- | --- |
| `player_action_registry_test.gd` | 本轮 PASS：registry 结构、56 core action 有源码字符串引用、Domain symbol 存在 | 控件可达/可用、点击结果、视觉、失败反馈、持久化 |
| `ui_state_registry_test.gd` | 本轮 PASS：44 个状态 contract 字段与唯一性 | 状态可由真实模拟产生、所有受影响屏幕呈现、动作能解析根因 |
| `location_ui_smoke_test.gd` | 本轮 PASS：初始 Earth 地点与五个子页的若干控件/文本 | 全 Location、全 survey state、响应式、输入与焦点 |
| `ui_chinese_localization_smoke_test.gd` | 本轮 PASS：locale 切换与选择状态保持断言 | 全动态文本、视觉溢出、stable-key 完整性 |
| `ui_english_localization_smoke_test.gd` | 本轮 PASS：多页面 visible text 的 CJK 泄漏扫描 | 文案质量、不可见/tooltip 文本、布局、stable-key 完整性 |
| `full_gameplay_ui_test.gd` | 本轮 PASS：仅通过可见控件和正常 10×/100×，从玩家确认的新存档到第一采集、第一加工品、三设施、第一次研究、第一资本品与第一次扩建；含 71 个 PlayerAction、15 个 Journey 里程碑与 Domain event log | 第一钢、Pathfinder、实际 Survey、远端工业和巨构终局尚未走通 |
| `ui_playflow_test.gd` | 本轮 PASS：若干真实按钮、公开导航 ID 和真实 Domain 结果的混合测试 | 纯 UI fresh-save 全链；它仍直接修改状态 |
| `golden_path_test.gd` | Domain 无作弊可完成路径 | 玩家能从 UI 发现并执行同一路径 |

## 必须补齐的 Journey 门槛

1. 保留当前 focused 启动/公开 navigation ID 回归，并修复退出时 ObjectDB/resource still in use 警告；另加跨进程偏好恢复验证。
2. 在已经 UI-only 通过的基础工业、第一次研究、第一资本品与第一次扩建基础上继续走到第一钢、Pathfinder、Survey、科研 field test、远征和巨构完成；不得用 scenario 或直接状态写入替代 fresh-save 验收。
3. 对每个 core blocker 验证 `状态 -> Why -> 目标页/实体 -> 可执行修复 -> 状态恢复`。
4. 对持久化动作验证 UI save/load 后的 page、Location、section、实体和 Domain 状态。
5. 在 1920×1080、2560×1440、1366×768，zh-CN/en 下生成可追溯截图；当前没有截图资产。
6. 增加键盘 Tab 顺序、可见焦点、Escape/Back、滚动位置恢复、disabled reason 和危险操作确认测试。
