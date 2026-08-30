# UI → Domain 完整性独立审查（UI-E）

静态复核：2026-08-31。范围为 `src/ui/**/*.gd`、`src/application/game.gd`、`tests/ui_domain_integrity_test.gd` 与 Fresh Save harness 源码。本文只给源码契约结论；最终严格运行结果留给最终认证。

## 当前结论

**未发现生产 UI 直接修改核心状态或直接推进 Simulation 的 P0。先前记录的 UI/Domain P1 已在当前源码中关闭；最终 PASS 仍需在 certified commit 上重跑静态守卫和完整 Journey。**

当前边界为：

```text
UI query
  <- Game / Simulation snapshot / availability / blocker / guidance

Player intent
  -> visible Control callback
  -> _command(label, Game.*)
  -> bool command result
  -> GameStateTransaction / Simulation
  -> state_changed / domain_event / command_rejected
  -> UI rebuild
```

## P0 扫描结果

`tests/ui_domain_integrity_test.gd` 对四个生产 UI source 扫描以下危险模式：

- `Game.state.* =`、算术赋值和容器 mutator；
- 通过 `Game.state` 别名进行嵌套赋值或容器修改；
- `Game.state.add_item/remove_item/...` 等 mutable state API；
- `Game.simulation.advance/tick/process_boundary/...`；
- localized/display text 反查或绑定 Domain identity；
- 启用状态但 callback 为无效 `Callable()` 的按钮；
- `_command()` 调用不返回 `bool` 的 `Game.*` 方法。

当前源码未发现这些 P0 模式。System Map 在 `configure()` 中对 Location/Route snapshots 执行 `duplicate(true)`；舰装候选对已安装 module definitions 使用 `.duplicate()` 后再构造 prospective loadout，避免 UI 对 Domain Array 的别名写入。

## 已关闭的 P1

### 原子 automation 命令

`_authorize_storage_guard()` 只调用 `Game.authorize_storage_guard()`。应用层在一个 `GameStateTransaction.working_state` 内校验、写入 production control 与 automation rules，最后只 commit 一次；不存在“前一半已提交、后一半失败”的 UI 编排路径。

### Guidance 单一权威

`_next_flow_step()` 和 `_next_flow_page()` 只消费 `Game.guidance_snapshot()`。UI 不读取 `completed_activities`、facilities 或 costs 来重建 progression milestone。`guidance_snapshot()` 返回 message/page/section/location/focus/acquisition 等 navigation data，UI 只展示、记录 telemetry 并跳转。

### 舰装 availability 与真实 BOM

`Game.ship_loadout_availability()` 当前统一处理：

- Ship 是否 operational+docked；
- module definition / technology 可用性；
- canonical full-loadout structure；
- unique equipment 物理库存；
- `loadout_fabrication_costs()`；
- 每项 `required/available/missing` 与玩家可见 reason。

`begin_ship_refit()` 使用相同结构与完整 BOM 语义执行真实 transaction。Fleet renderer 保留结构合法的 install option，并用 authoritative availability 决定 disabled state 与 tooltip，不再把资源不足误表现成“模块不存在”。连续 Remove → Install 的 focused probe 位于 `tests/ui_endgame_scenario_test.gd --outer-titan-exotic-refit-probe`。

### Fresh Save harness 不再是 hybrid playflow

旧 `ui_playflow_test.gd` 仍可作为 bounded/hybrid smoke，但它不再承担最终 Journey 认证。`tests/full_gameplay_ui_test.gd` 是单独的严格 harness；静态 guard 禁止其：

- 写 `Game.state` 或 state container；
- 调用 mutable `SpaceGameState` API；
- 直接推进 Simulation；
- 直接调用 gameplay `Game.*` 命令（只允许只读查询白名单）。

关键操作必须由真实 MainScene Control 触发；时间加速必须点击正常 speed control。是否完整跑到终局由 Fresh Save runtime artifact 判定，不能由本段源码检查提前确认。

### 地图锁定语义

`SystemMapView.configure()` 当前设置 `button.disabled = not discovered`，并为未知节点提供 survey prerequisite tooltip。UI 文案和交互不再出现“未知地点不可操作但节点仍可点击”的冲突。

## Single Source of Truth 复核

| 数据/规则 | UI 使用方式 | 权威来源 |
| --- | --- | --- |
| Production status / rate / blocker | 渲染 runtime 和 normalized blocker | `SimulationEngine` queries |
| Inventory available/reserved/flow | 渲染 location snapshots | `SpaceGameState` / Simulation snapshots |
| Logistics utilization / blocker | 渲染 service snapshot；command 改 policy/mode/ship | Logistics Simulation + `Game.*` |
| Construction eligibility / queue | availability + command | `Game.can_start_construction_project()` / Construction runtime |
| Research eligibility / stage blocker | availability + command | `Game` / Research Simulation |
| Ship fitting / BOM | availability + refit command | `Game.ship_loadout_availability()` / `begin_ship_refit()` |
| Guidance | 只读 snapshot | `Game.guidance_snapshot()` |
| Diagnostics | 只读 normalized blockers | `Game.active_blockers()` / `Game.blocker_info()` |
| Megastructure state / BOM | read model + normal Construction command | Simulation / Content / `Game.start_megastructure_phase()` |

## 保留的 P2 架构风险

### P2-DI-1：进度比例仍在 UI 解释原始 runtime 字段

`src/ui/main.gd:_operation_progress()` 在 UI 内区分 construction 与其他 operation，再从 `completed_work/cycle_progress` 或 `stage_progress_ms/progress_ms/...` 计算 ratio。它不写 Domain，也没有形成 P0/P1，但 runtime schema 演进可能让显示与 Simulation 漂移。建议由 read model 返回统一 `progress_ratio`、`progress_caption_key`。

### P2-DI-2：替换模块的发现性仍可与 availability 分离

`_installable_loadout_modules()` 会保留结构合法但因 BOM/ship state 暂不可执行的选项，再用 authoritative reason 禁用；`_compatible_loadout_modules()` 目前只保留 `ship_loadout_availability().allowed=true` 的 replacement。后者可能在资源短缺时把合法替换完全隐藏。Domain 安全性不受影响，但玩家可能看不到需要补什么资源。建议 replacement 与 install 使用同一“结构可见、availability 决定 disabled/reason”呈现策略。

### P2-DI-3：应用/表现集中在单一 UI 脚本

`main.gd` 超过 3.7k 行。虽然静态 guard 能阻止直接 state mutation，页面 builder、query formatting 与 callback 数量继续增长会提高漏检和 review 成本。应在不复制 gameplay rules 的前提下，按 Surface 拆 presenter/view builder，并保持 `Game.*`/Simulation read model 为唯一规则源。

## Stable identity

- Location OptionButton 绑定平行 `location_ids`，不使用显示文本反查。
- Logistics selectors 分别保留 `item_ids/source_ids/route_ids`。
- Ship UI 显示 `name`，命令绑定 `instance_id`。
- Saved Loadout 显示 `name`，命令绑定 `loadout_id`。
- 未发现 `get_item_text()`、`find_key()` 或把 `_content_name()/I18n` 结果传入 `Game.*.bind(...)`。

## 失败反馈与 Developer Details

`_command()` 读取命令返回值；`false` 时使用 `Game.last_notice`，若没有新 structured notice 则显示本地化通用失败文本。成功与失败都写入 Timeline 和 `PlayerAction` telemetry。普通玩家不看到 stack/exception；Developer Details 可显示内部 ID/state code 等审计信息。

## 可复现验证

静态 Domain guard：

```powershell
& 'D:\Godot\godot.exe' --headless --path 'D:\Projects\standalone\core_gameplay_lab' res://tests/ui_domain_integrity_test.tscn -- --no-persistence
```

相关 runtime contracts：

```powershell
& 'D:\Godot\godot.exe' --headless --path 'D:\Projects\standalone\core_gameplay_lab' res://tests/ui_action_coverage_test.tscn -- --no-persistence --locale=en
& 'D:\Godot\godot.exe' --headless --path 'D:\Projects\standalone\core_gameplay_lab' res://tests/ui_state_coverage_test.tscn -- --no-persistence --locale=en
& 'D:\Godot\godot.exe' --headless --path 'D:\Projects\standalone\core_gameplay_lab' res://tests/ui_endgame_scenario_test.tscn -- --no-persistence --locale=en --scenario=open_deep --outer-titan-exotic-refit-probe
& .\tools\run_full_gameplay_ui.ps1 -RunId '<unique-run-id>' -TimeoutSeconds 28800 -CleanEvidence
```

最终认证需要把以上结果绑定到同一提交与 final strict RunId，并同时通过 Fresh Save、Save/Load、Offline、Localization 和 screenshot gates；本文不单独发布 `CORE UI VERIFIED`。
