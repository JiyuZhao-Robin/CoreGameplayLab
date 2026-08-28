# UI→Domain 完整性独立审查（UI-E）

初审日期：2026-08-28  
修复复核日期：2026-08-28  
审查范围：`src/ui/**/*.gd`、`src/application/game.gd` 与现有 UI 测试；生产源码仅只读复核。  
结论口径：源码追踪与静态守卫，不等同于真实鼠标/键盘 UI Journey。

## 复核结论

**生产 UI→Domain 静态边界：PASS。综合验证完整性：仍未关闭（0 个 P0、1 个 P1、4 个 P2）。**

初审的三个生产边界 P1 已关闭：仓储自动化授权改为单一原子应用命令，舰装替换/安装候选统一查询应用层 availability，next-flow 的里程碑规则全部移入 `Game.guidance_snapshot()`。独立重跑 `tests/ui_domain_integrity_test.tscn` 得到 Exit 0 与：

```text
PASS: UI Domain integrity static guard (source contracts only; no UI Journey claim)
```

这项 PASS 只证明静态源码契约。现有 playflow 仍依靠直接推进模拟、写入状态和调用私有 helper，因此不能把项目整体标记为 UI Journey verified。

## P0

未发现 P0。生产 UI 未发现 `Game.state.foo = ...`、状态容器 `merge/append/remove_at(...)`、`Game.state.add_item/remove_item(...)` 或 `Game.simulation.advance(...)`。

## 未关闭 P1

### P1-1：现有 playflow 是 hybrid integration，不是端到端 UI Journey

- `tests/ui_playflow_test.gd:60-71` 直接调用 `Game.simulation.advance`，直接修改 operation 与 extraction network 字典。
- `tests/ui_playflow_test.gd:81-100` 直接移除/添加库存并写 `completed_activities`；`tests/ui_playflow_test.gd:124-142` 直接写 facilities/research，并调用 UI 私有 next-flow wrapper。
- 这些写入适合构造跨阶段测试夹具，但绕过真实控件、应用事务和玩家可见失败反馈，不能由末尾的 playflow PASS 外推成所有核心动作的真实 UI Journey 覆盖。
- 关闭标准：保留并明确标注 hybrid test；另建只通过控件输入、等待真实应用/模拟边界，并同时断言成功与失败反馈的 journey suite。

## 已关闭的初审 P1

### 已关闭：有限自动化授权的部分提交风险

- UI `src/ui/main.gd:1758-1759` 的 `_authorize_storage_guard()` 现在只调用一次 `Game.authorize_storage_guard(...)`。
- 应用层 `src/application/game.gd:648-662` 在同一个 `GameStateTransaction.working_state` 上校验生产线、修改 control、添加 pause/resume 两条规则，最后只有一次 `_commit_transaction(transaction)`。
- 结论：第二/第三个独立提交失败导致“授权一半”的路径已消失，原 P1 关闭。

### 已关闭：替换舰装候选的结构校验双规则源

- 替换候选 `src/ui/main.gd:2653-2675` 构造完整 prospective loadout 后调用 `Game.ship_loadout_availability(...)`；安装候选 `2678-2696` 使用同一查询。
- 应用层查询 `src/application/game.gd:1806-1828` 统一校验舰船可改装状态、模块/特殊装备/设计可用性，并复用 `_validate_loadout_modules(...)`。
- 结论：UI 仅按 slot 自行推导、Domain 再拒绝结构非法装配的问题已关闭。完整 BOM 可执行性仍有一个 P2，见下文。

### 已关闭：next-flow 双权威

- 应用层 `src/application/game.gd:1906-1948` 的 `guidance_snapshot()` 统一返回 `message/page/section/location_id/focus_entity_id/requirement/acquisition_path`；bootstrap 里程碑集中在 `1951+`。
- UI `src/ui/main.gd:2603-2629` 只读取 snapshot，负责 telemetry、导航状态与展示，不再读取 `completed_activities/facilities/costs` 推导下一步。
- 结论：新增里程碑或 requirement routing 不再需要同步修改 UI 规则，原 P1 关闭。

## P2

### P2-1：舰装 availability 尚未覆盖 full-loadout BOM

- `Game.ship_loadout_availability()`（`src/application/game.gd:1806-1828`）覆盖状态、设计、特殊装备与装配结构，但未计算/检查 `loadout_fabrication_costs`。
- 真正命令 `begin_ship_refit()` 在 `src/application/game.gd:1690-1695` 仍会因 full-loadout fabrication resources 不足拒绝。
- 因此一个结构合法候选可能显示为可用，点击后才报告资源不足。建议 availability 返回 BOM、逐项缺口和与命令一致的 `allowed`，或将当前字段明确命名为 `structurally_allowed`。

### P2-2：进度公式仍由 UI 解释原始 runtime 字段

- `src/ui/main.gd:2864-2877` 在 UI 内区分 construction/non-construction，并重算 `completed_work + cycle_progress` 或 `elapsed / duration`。
- 这不是状态写入，但字段语义演进时可能造成显示漂移。建议 Domain/read model 返回统一的 `progress_ratio` 与 `progress_caption_key`。

### P2-3：禁用 Button 被用作纯状态文本

- `src/ui/main.gd:579` 用 `Callable(), true` 创建 “No eligible Survey Vessel”。它不是 dead enabled control，但视觉语义仍像不可用操作。
- 建议改为 warning Label/empty-state card。

### P2-4：地图文案与交互语义不一致

- `src/ui/main.gd:445` 声称“未知地点不可操作”；`src/ui/components/system_map_view.gd:42-61` 却让 discovered/undiscovered 节点都 `disabled = false` 并发送稳定的 `location_id`。
- `_open_location()` 在 `src/ui/main.gd:510-517` 只检查 location 是否存在。若产品意图是允许查看并发起勘测，应把文案改为“可查看、工业操作未解锁”；否则应真正禁用节点。

## 已通过的边界检查

### 无直接状态/资源/进度写入

- 扫描 `src/ui/**/*.gd` 未发现 `Game.state` 直接/别名写入、状态容器 mutator、资源可变 API 或直接 simulation advance。
- `SystemMapView.configure()` 在 `src/ui/components/system_map_view.gd:30-33` 对输入执行 `duplicate(true)`，组件不会持有 Domain snapshot 的可变别名。

### 命令成功/失败契约一致

- `src/ui/main.gd:3067+` 的 `_command()` 以 `bool false` 记录失败和失败 telemetry。
- 静态枚举的所有 `_command(... Game.*)` 目标均在 `src/application/game.gd` 声明 `-> bool`；守卫会阻止 void/Dictionary 命令被误记为“已执行”。

### display name 没有充当 identity

- 地点 selector 在 `src/ui/main.gd:371-383` 绑定 `location_ids`，回调在 `3248+` 由 index 取稳定 ID。
- 物流 item/source/route selectors 在 `src/ui/main.gd:914-1042` 分别保留 `item_ids`、`source_ids`、`route_ids`。
- 舰船 UI 展示 `ship.name`，命令绑定 `instance_id`；saved loadout 展示 `name`，命令绑定 `loadout_id`。
- 未发现 `get_item_text()`、`find_key()` 或将 `_content_name()/I18n` 结果传给 `Game.*.bind(...)`。

### Dead UI 扫描

- 除 Godot 生命周期回调和对测试暴露的只读 `telemetry_snapshot()` 外，`main.gd` 本地 helper 均有调用点或 signal/callback 引用。
- 工业模板应用 helper 已由 `ApplyIndustrialTemplate` 接通（`src/ui/main.gd:687-688,805+`）。
- 未发现启用状态下 callback 为无效 `Callable()` 的 `_button`；P2-3 是禁用 empty-state 控件，不是假命令。

## 静态守卫

`tests/ui_domain_integrity_test.tscn` 独立读取 UI 与应用层源码，不依赖 `player_action_registry.json`。它检查：

1. `Game.state` 直接/别名写入、容器 mutator、资源 API 和直接 simulation advance；
2. display name 反查/绑定 identity；
3. 无回调的启用按钮与未引用私有 UI helper；
4. `_command` 目标必须为 `Game.* -> bool`；
5. storage guard 不得在 UI 编排多个可部分提交的写命令；
6. 舰装候选必须走 canonical availability；
7. next-flow UI 不得拥有 progression milestone 规则。

复核命令：

```powershell
& 'D:\Godot\godot.exe' --headless --path 'D:\Projects\standalone\core_gameplay_lab' res://tests/ui_domain_integrity_test.tscn -- --no-persistence
```

复核结果：**PASS，Exit 0**。该结果是静态架构守卫结论，不宣称运行时 UI Journey 覆盖；P1-1 仍需单独关闭。
