# Core Gameplay Lab UI 架构

静态快照：2026-09-01。本文描述当前源码与测试契约，不替代正在进行的 Fresh Save 通关、最终严格审计或截图认证。

## 证据口径

- `STATIC-CONFIRMED`：直接读取当前源码、场景或机器注册表得到的结构事实。
- `TEST-CONTRACT`：测试源码存在对应断言；最终认证仍须运行测试并核对产物。
- `RUNTIME-ARTIFACT`：工作区存在由测试生成的结构化结果；最终严格 RunId 仍由认证文档记录。
- `FINAL-PENDING`：必须等待最终严格套件或截图矩阵，本文不提前写 PASS。

## 运行时组成

`project.godot` 将 `src/ui/main.tscn` 设为 Main Scene，并把 `I18n` 与 `Game` 注册为 autoload。Scene 只有一个全屏 `Control` 根节点；`src/ui/main.gd` 在运行时构造 Shell 与全部页面。

```text
project.godot
  -> src/ui/main.tscn
     -> src/ui/main.gd
        -> src/ui/ui_theme_tokens.gd
        -> src/ui/ui_navigation_state.gd
        -> src/ui/components/game_shell.gd
        -> src/ui/components/system_map_view.gd
        -> src/ui/components/megastructure_progress_view.gd

Player Control
  -> main.gd callback
  -> Game.* command / availability query
  -> GameStateTransaction / Simulation
  -> state_changed | domain_event | command_rejected
  -> dirty active-page rebuild
```

`main.gd` 当前约 3,900 行，仍同时承担页面组装、格式化、命令绑定、告警、Guidance 与 telemetry。五区桌面骨架已拆到 `GameShell`；设备本地的工作区、选择、历史和侧栏折叠状态由 `UiNavigationState` 表达；System Map 和巨构分层图也是独立组件，Theme/token 集中在 `ui_theme_tokens.gd`。这是第一批可运行的 UI 重构边界，但各 Workspace 和通用 Inspector projection 尚待继续拆分，主脚本规模仍是明确风险。

## Shell 与页面

`_build_shell()` 创建五区桌面布局：

1. Top Status Bar：品牌、时间、地点、能源、告警、工程、研发、巨构状态；暂停、1×、2×、5×、10×、100×、语言、保存和 New Game。
2. 左侧 Resource Rail：当前地点、仓储占用、主要库存、当前 Guidance 和作用域；可独立折叠。
3. 中央 Workspace：横向 11 个公开入口 + 12 个隐藏-tab 实际页面。
4. 右侧 Context Inspector：Location、摘要、Blocker、Guidance、Developer Details；可独立折叠。
5. 底部 Command Dock：当前工作区、Back、Suggested Next Step 与 Alerts / Task / Timeline 摘要。

12 个内部页面 key 为：

```text
system_map, location, industry, inventory, logistics, construction,
research, fleet, frontier, expedition, megastructure, diagnostics
```

`fleet/frontier` 对外分别发布为 `Navigation_ships` 与 `Navigation_survey`。`expedition` 不在工作区导航，由 Ships > Missions 或 Guidance 进入。旧 UI 配置中的 `overview/ships/survey` 会在 `_load_ui_preferences()` 中迁移到 `system_map/fleet/frontier`；当前代码不再创建独立 `overview` 页面。公开 `Navigation_*` 节点名保持不变，因此既有自动化和玩家路径不因布局移动而失效。

## 导航与上下文

`UiNavigationState` 维护 active workspace、selected context、左右侧栏折叠状态和最多 32 项的页面历史；它是设备本地呈现状态，不进入玩法 Save。`_unhandled_input()` 与 Command Dock 的 Back 使用同一历史，历史为空时回到 System Map。`_navigate_blocker()` 消费 Domain `navigation_target`，保留 Location、Product filter 与 Route focus 后跳转到解析页面。`Game.guidance_snapshot()` 是 Suggested Next Step 的唯一规则来源，Resource Rail、Command Dock 和 Inspector 只展示同一 snapshot、记录 telemetry 并执行其 page/section/location 路由。

Context Inspector 仍是 Location-first，而不是任意实体的统一 selection model：它可以切换已发现 Location、打开 Location、显示至多三个活动 blocker、点击解析入口和 Guidance，但没有通用 entity history、多选或面包屑。

## 查询、命令与 Single Source of Truth

生产 UI 的写操作统一经 `_command(label, callable)` 调用返回 `bool` 的 `Game.*` 命令；失败时使用 `Game.last_notice` 写入玩家可见 Timeline 并记录失败 telemetry。静态守卫 `tests/ui_domain_integrity_test.gd` 检查：

- UI 不直接写 `Game.state`，不经别名修改其容器，也不直接推进 Simulation；
- display/localized text 不作为稳定 identity；
- 启用按钮必须有有效 callback；
- `_command` 目标必须返回 `bool`；
- storage guard 的多步写入位于一个应用层事务；
- 舰装候选使用 canonical loadout validator/availability；
- Guidance milestone 不由 UI 重算；
- Fresh Save harness 不直接调用 gameplay command 或修改 Domain 状态。

`Game.ship_loadout_availability()` 当前同时返回完整装配结构校验、特殊装备可用性、`fabrication_costs` 与逐项 `missing_costs`。安装候选在结构合法时保持可见，按钮的 enabled/disabled 与 reason 取自 authoritative availability；UI 不再因为资源短缺把合法选项完全隐藏。

仍存在一个明确的显示层重复公式：`_operation_progress()` 根据 construction/non-construction 原始 runtime 字段计算进度比例。它不修改 Domain，但长期应由 Simulation/read model 提供统一 `progress_ratio`。

## 状态刷新、焦点与持久化

`state_changed`、`domain_event`、`command_rejected` 和 locale change 将页面标记为 dirty。Header 每 200 ms 更新；活动页在未编辑文本且至少间隔 180 ms 时重建。隐藏页面不会随每次 dirty event 全量重建；`_rebuild_active_page()` 只重建 Resource Rail、Context Inspector 与当前页。

动态重建前会保存当前 ScrollContainer 的 `scroll_vertical` 和焦点节点名；`_restore_rebuilt_page_context()` 在新控件树中恢复滚动位置与逻辑焦点，失效或 disabled 时回退到当前 Navigation 按钮。`ui_focus_next` 在无 focus owner 时进入 Shell。

UI preference 使用 `user://core_gameplay_ui.cfg` 保存 active workspace、selected Location、左右侧栏折叠、Location/Industry/Fleet section、Developer Details、Reduced Motion 与 UI scale。Domain Save 由 `Game.save_game()`/`LocalSaveRepository` 负责；二者不是同一份状态文件。

## Design System 与尺寸

`UiThemeTokens` 集中定义深黑绿工业控制台的语义色、spacing、panel padding、row height、控件状态与 UI scale。桌面五区的基准尺寸为：Resource Rail 236 px、Inspector 306 px、折叠边 28 px、Top 68 px、Command Dock 108 px；中央 Workspace 吸收剩余空间。字体按 UI scale 完整缩放，结构尺寸使用 `1 + (UI scale - 1) × 0.5` 的温和比例缩放，因此提高可读性时不会等比例吞掉全部中央工作区。

`project.godot` 设计视口仍为 1440×900，但不使用根 Control 或 viewport 等比拉伸模拟 UI scale；控件以原生窗口像素和 anchor/container 响应。全局顶栏的 `UIScaleSelector` 提供 100%、125%、150%、175%、200% 五档，新安装默认 125%。中央导航使用 `HFlowContainer`，150% 以上预留多行高度并隐藏重复的 Header 状态摘要以优先保留主要操作。若窗口宽度小于“缩放后双侧栏 + 760 px 中央画布 + 安全间距”，Resource Rail 与 Context Inspector 自动成为互斥抽屉，防止高倍率侧栏被挤出窗口；窗口足够宽时仍可同时展开。System Map 在物理窗口高度不超过 800 px 时使用 430 px 最小高，否则使用 560 px，以避免 1366×768 下被 Command Dock 裁切。1366×768 仍是最紧张目标分辨率，最终结论必须由 en/zh-CN screenshot matrix 给出，不能只从源码推断 PASS。

UI scale 只改变字体、控件、间距和 Shell 结构；System Map、Industrial Network、Research Graph、Ship Assembly 以及未来 Planet Surface 的内容坐标不继承根节点缩放，继续使用各自的 canvas zoom/pan。改变 UI scale 会重建 Main Scene 以统一应用 token，但 `Game` autoload 中的 Domain/Simulation 状态保持存活；这不是重新开局。

普通按钮最小高 34 px、工作区导航高 48 px。左右折叠按钮具有本地化 tooltip 和 accessibility name；折叠后恢复控件继续可见。`_button()` 为所有 disabled 控件提供本地化通用原因，关键游戏动作会用 authoritative availability reason 覆盖。New Game 使用 exclusive `ConfirmationDialog`，初始焦点在 Cancel。其他有损操作是否都需要确认仍是产品层 P2/P3 决策，不属于 Domain 绕过。

## 机器注册表与验证入口

- `data/player_action_registry.json`：73 个登记动作，其中 57 个 core；57 个 core 均有 UI entry point。静态文件顶层 `uiJourneyCoverage` 保持 `UNVERIFIED`，避免把 registry 自证当作运行证据。
- `data/ui_state_registry.json`：43 个 core state，静态文件顶层 `runtimeCoverage` 保持 `UNVERIFIED`；运行证据由独立测试产物提供。
- `tests/ui_action_coverage_test.gd`：每个 core action 的 Success / Failure / Consequence / Persistence 四象限。
- `tests/ui_state_coverage_test.gd`：真实 Domain state、可见状态、解释、可用下一步四项门禁。
- `tests/ui_input_accessibility_test.gd`：五区 Shell、双侧栏折叠/恢复、鼠标、键盘 focus、Back、refresh focus、disabled reason、New Game modal 与 speed controls。
- `tests/ui_scale_contract_test.gd`：五档缩放、默认 125%、字体与结构尺寸、200% 导航可达性及 canvas 独立缩放边界。
- `tests/ui_persistence_audit_test.gd`：隔离用户目录下的真实保存/加载与 UI 派生状态。
- `tests/full_gameplay_ui_test.gd`：单一 Fresh Save、UI-only、10 Journey、巨构完成及 Journey/Action telemetry。

可复现命令：

```powershell
& 'D:\Godot\godot.exe' --headless --path 'D:\Projects\standalone\core_gameplay_lab' res://tests/ui_domain_integrity_test.tscn -- --no-persistence
& 'D:\Godot\godot.exe' --headless --path 'D:\Projects\standalone\core_gameplay_lab' res://tests/player_action_registry_test.tscn -- --no-persistence
& 'D:\Godot\godot.exe' --headless --path 'D:\Projects\standalone\core_gameplay_lab' res://tests/ui_state_registry_test.tscn -- --no-persistence
& 'D:\Godot\godot.exe' --headless --path 'D:\Projects\standalone\core_gameplay_lab' res://tests/ui_input_accessibility_test.tscn -- --no-persistence --locale=en
```

## 静态结论与最终待证

| 领域 | 当前静态结论 | 最终仍需填充 |
| --- | --- | --- |
| Shell / 12 pages / 11 rail entries | `STATIC-CONFIRMED` | 最终 strict RunId |
| UI → Domain command boundary | 守卫与源码契约已建立 | 最终 guard 重跑结果 |
| Action / State registries | 57 core actions、43 core states | 最终 action/state artifacts |
| Back / focus / disabled reason | 代码与专项测试契约存在 | 最终 accessibility artifact |
| Save / Load UI | 独立 persistence harness 存在 | 最终 writer/reader artifact |
| Fresh Save end-to-end | UI-only harness 已实现 | 当前 Fresh run 与最终 strict run |
| 分辨率与双语视觉 | capture tool 已存在 | 66 张最终矩阵与独立 Visual QA |

本文不写 `CORE UI VERIFIED`。该标记只允许出现在最终认证中，并且必须由最终严格套件、Fresh Save 证据和截图审查共同支撑。
