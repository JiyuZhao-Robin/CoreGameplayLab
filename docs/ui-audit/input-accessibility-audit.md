# UI-H Input / Accessibility / Persistence Audit

审计日期：2026-08-28。范围是当前 Godot Core UI 的 keyboard、mouse、focus、scroll、tooltip、disabled reason、Escape/Back、modal confirm/cancel、基础 accessibility，以及 Save/Load UI 和时间/离线刷新证据。本报告不对整体 `CORE UI VERIFIED` 作结论。

## 证据边界

结论严格区分三种证据：

- `EXECUTED`：本轮 focused test 实际驱动 Godot UI 后观察到。
- `STATIC`：从当前源码可以确认，但尚未由真实输入或跨进程运行验证。
- `UNVERIFIED`：现有测试/日志不足，不能从实现存在推导为通过。

本轮新增：

- `tests/ui_input_accessibility_test.gd` / `.tscn`：真实 GUI focus/action、页面 Back、state-refresh focus、滚轮、disabled reason、Reset modal、`1×/2×/5×/10×/100×/Pause` 与 header refresh。
- `tests/ui_persistence_audit_test.gd` / `.tscn`：两进程 writer/reader；通过玩家可见 UI 创建状态并按 Save，第二进程验证自动 Load、UI preference、offline settlement 与 sidebar offline report。
- `tools/run_ui_persistence_audit.ps1`：把 `APPDATA` 与 `LOCALAPPDATA` 重定向到唯一临时目录，确保 `user://` 不读取、覆盖或删除玩家真实存档；完成后只删除已验证位于系统临时目录且具有专用前缀的目录。

Godot `--help` 不提供独立的 user-data-directory 参数，因此跨进程持久化测试必须使用上述环境隔离 runner，不能直接运行 persistence scene。

本轮执行证据：

- Focus/input 最终回归：`.audit-logs/ui-input-accessibility-scroll-postfix.log` 与 `artifacts/test-results/ui-input-accessibility.json`，22/22 observations PASS。
- Persistence writer：`.audit-logs/ui-persistence-writer.log`，`UI_PERSISTENCE_WRITE_PASS`。
- Persistence reader：`.audit-logs/ui-persistence-reader.log`，`UI_PERSISTENCE_READ_PASS`。
- 汇总 artifact：`artifacts/test-results/ui-persistence-audit.json`，`passed=true`。
- runner 结束检查：Godot 残留进程 `0`，专用临时目录残留 `0`。

## 已确认能力

| 能力 | 结果 | 证据 |
| --- | --- | --- |
| 键盘焦点 | PASS (focused) | `EXECUTED`：没有 Control 拥有焦点时，第一次 Tab/ui_focus_next 进入 active Navigation；后续从 System 前进到 Location。 |
| 键盘激活 | PASS (focused) | `EXECUTED`：焦点位于 System 时，`ui_accept` 打开 System 页面。 |
| 速度控制 | PASS (focused) | `EXECUTED`：`Speed1/2/5/10` 分别把 `Engine.time_scale` 设置为 1/2/5/10，`SpeedPause` 归零；100× 跨过一分钟后 `HeaderStatus` 改变。 |
| 页面滚动 | PASS (focused) | `EXECUTED`：加载由正常 Domain commands/simulation 生成的 `megastructure_phase_5` 场景后，Location 页真实 overflow（max 1439 / page 1234）；wheel 将 `scroll_vertical` 从 0 推到 205。 |
| 鼠标入口 | PASS (focused navigation) | `EXECUTED`：OS/root Viewport 左键事件打开 Inventory。全部核心命令入口仍由原生 `Button.pressed` 构建。 |
| Restart 防误操作 | PASS (focused) | `EXECUTED`：Dialog exclusive；子窗口 focus owner 是 Cancel，root 仍记录 invoking Restart；Escape 取消且不改变 save id，关闭后 focus 回到 Restart，Confirm 通过正常 reset transaction 生成新 save id。 |
| 自动保存 | IMPLEMENTED | `STATIC`：应用每 15 秒保存，窗口关闭和应用暂停也保存。 |
| UI 显式保存 | PASS (isolated cross-process) | `EXECUTED`：玩家可见 `SaveButton` 写入隔离 LocalSaveRepository 并增加 revision；旧 action-coverage 的 Domain-only 边界没有被冒充为此证据。 |
| 启动 Load / offline | PASS (isolated cross-process) | `EXECUTED`：第二进程恢复 save identity/revision、UI 创建的 Mining assignment 和 Inventory active page；共享 orchestrator 结算 >1 秒离线时间，sidebar 显示 offline report，Ships 页显示恢复后的 assignment。 |

## Findings

### RESOLVED P1 — keyboard entry focus

首次 focused run 在 fresh shell 无 focus owner 时，第一次 `ui_focus_next` 后 focus owner 仍为空。修复在首轮 rebuild 后 deferred 聚焦 active Navigation，并在 `_unhandled_input` 捕获无 owner 的 `ui_focus_next`。最终 `EXECUTED PASS`：第一次 Tab 进入 shell，后续 Tab 和 Enter/ui_accept 正常。

仍建议未来覆盖窗口失焦/重新聚焦及手柄首个导航事件，但本轮 core entry blocker 已关闭。

### RESOLVED P1 — state-driven rebuild focus/scroll

首次 `EXECUTED FAIL`：在 Ships 页面聚焦 `AssignMining_SHIP-001` 并由该可见按钮提交正常 Domain command 后，state-driven rebuild 删除原控件，focus owner 为空。

修复现在在 `_rebuild_active_page()` 前捕获 stable control name 与 active ScrollContainer 位置，重建后 deferred 恢复同名 visible/enabled control；目标不存在或变为 disabled 时回退 active Navigation。最终 `EXECUTED PASS`：正常 assignment command 后逻辑焦点仍是 `AssignMining_SHIP-001`；合法 overflow 页 wheel 到 205 后，由可见 Speed2 产生的正常 dirty rebuild 保持同一 scroll position。

### RESOLVED P1 — gameplay-disabled reason

首次 fresh-save `EXECUTED FAIL` 扫描到 13 个具稳定 gameplay action name 的 visible disabled Button 没有 reason，包括 Integrate Mining、8 个 Construction Start 与 5 个 Research Start。修复将已有 authoritative eligibility / construction reason / research requirements 绑定到相应 disabled control，并保留卡片内可见 requirement 文本。最终同一 13-action scan 为 `EXECUTED PASS`。

tooltip 不是键盘/触摸的唯一信息面；相邻 Requirements/Unavailable 文本仍是必须保留的等价信息。更完整的 screen-reader semantics 留在 P2。

### P2 — irreversible ship/configuration actions lack confirmation

`STATIC`。当前只有 Restart 创建 `ConfirmationDialog`。以下玩家可见操作直接执行 Domain command：

- Delete saved loadout。
- Scrap ship。
- Cancel refit；玩家文案明确说明材料不退款。
- Cancel ship build。
- Cancel construction / megastructure phase；Domain 可能产生 consumed/lost material。

正常退款规则仍由 Domain 决定，这一点正确；问题是 UI 没有确认层，误触会造成不可逆资产损失。建议建立单一 confirmation helper，默认焦点 Cancel，Escape 取消，关闭后恢复 invoking control；Dialog 只提交现有 Domain command，不在 UI 计算退款。

### RESOLVED P2 — page-level Escape/Back contract

首次 `EXECUTED FAIL`：从 Location 发送 `ui_cancel` 后仍留在 Location。修复加入 capped Navigation history 与 `_unhandled_input(ui_cancel)`；history 无有效来源时回退 System，modal 的 Window 仍优先消费 Escape。最终 `EXECUTED PASS`：Location Back 返回 System，Reset modal Escape 只关闭 modal、不改变 Domain state，并把焦点归还 Restart。

后续若增加多层 detail/modal，应继续遵守 modal > detail/source > workspace history 的优先级。

### P2 — focus order and focus appearance are implicit

`STATIC + EXECUTED`。core entry、Tab/Enter 与 rebuild focus 已通过；但没有 `focus_neighbor_*` 或分区级顺序策略。Theme 定义 `font_focus_color`，未定义项目语义化 Button focus style/token；实际 focus ring 仍依赖 Godot fallback theme。复杂动态卡片中的完整逻辑顺序尚无全页手工验证。

建议至少为 Navigation、Workspace、Inspector、Bottom bar 定义分区顺序，页面打开时聚焦标题/主要 action，使用 token 化且不只依赖颜色的 focus outline。

### RESOLVED P2 — scroll position during live rebuild

最终 `EXECUTED PASS` 同时证明实际 overflow wheel 和 dirty rebuild 后 position 保留。测试场景来自正常 Domain commands/simulation 的 `megastructure_phase_5` Golden snapshot，不直接写伪造 UI 状态。

### P2 — accessible semantics are mostly inferred from visible text

`STATIC`。大部分 action 是带文字的原生 Button，这给平台 accessibility bridge 提供了合理默认名称；但没有显式 accessible name/description、状态变化 announcement、Alert live-region、tooltip keyboard equivalent 或自绘 Megastructure progress 的文本语义 contract。`MegastructureProgressView` 设置 tooltip 同时使用 `MOUSE_FILTER_IGNORE`，该 tooltip 的鼠标可触达性不能视为通过；页面的阶段文字和 ProgressBar 是当前可见替代信息。

### P3 — target size and pointer-state evidence incomplete

`STATIC/UNVERIFIED`。通用按钮最低高 34 px，Navigation row 40 px；未建立目标平台最低点击面积、DPI、hover/pressed/disabled/focus 状态截图矩阵。桌面鼠标可用性没有发现 P0，但不应标为 accessibility 完成。

## Save / Load / Offline / Time Matrix

| 项目 | 当前判定 | 说明 |
| --- | --- | --- |
| Domain schema migration | PASS（其他审计执行证据） | schema 34 -> 35、资产/运输 round-trip、offline debt 已有 core tests；不等于 UI persistence。 |
| SaveButton | PASS | 隔离 writer 经 Restart Confirm、Ships assignment、Inventory navigation 后实际按 Save；save 文件存在且 revision 增加。 |
| Auto Load | PASS | 隔离 reader 恢复同一 save identity、revision 与 UI 创建的舰队 assignment。 |
| selected page / Location / sections / developer mode | PARTIAL PASS | active Inventory page 已跨进程恢复；ConfigFile 另保存 Location、Location/Industry/Fleet section 和 developer details，但本 harness 未逐字段切换断言。 |
| offline settlement | PASS | reader 实际运行 shared orchestrator，`simulated_ms > 1000`；Main sidebar 显示 offline report，Ships 页从恢复的 Domain state 派生正确 assignment。 |
| 1× / 2× / 5× / 10× / Pause | PASS (focused) | 本轮实际按可见控件并验证 `Engine.time_scale`。 |
| 100× online header refresh | PASS (focused) | 实际跨过 >60 秒模拟时间并观察 Header 文本更新。 |
| shipment / construction / research / storage / megastructure boundary UI refresh | PARTIAL | state coverage 创建真实 Domain states 并验证 UI；尚无本 focused test 对每类在线 boundary 的 before/after DOM snapshot。完整 UI-only journey 仍是最终权威证据。 |

## Remaining backlog

1. P2：对 Scrap ship、Delete loadout、Cancel refit 及所有可能损失已投入资产的取消动作使用统一 safe-default confirmation；Escape 取消并归还焦点。
2. P2：建立显式 focus outline token、复杂页面 focus-neighbor/分区策略和 accessibility name/description/live-region contract。
3. P3：补 hover/pressed/disabled/focus 的 DPI 与 pointer-state screenshot matrix。
4. 回归：保留 focused input test 与隔离 persistence writer/reader；当前两者均 PASS。

## 当前结论

没有发现输入层直接修改 Domain 或资源复制的 P0。此前可重复的 keyboard entry、page Back、rebuild focus/scroll 与 disabled reason P1/P2 已修复并由最终 focused run 全部关闭。鼠标导航、实际 overflow wheel、Reset modal safe focus/Escape/Confirm、Tab/Enter、完整速度按钮，以及隔离跨进程 Save/Load/offline UI 均实际通过。UI-H 对本次 core input/persistence 范围给出 `PASS`，保留上列 P2/P3；这不是对整体 `CORE UI VERIFIED` 的独立授权。
