# Core Gameplay Lab UI 架构现状

审计快照：2026-08-28，基于当前未提交工作树。本文只描述实际代码与测试契约，不把“存在测试”写成“当前通过”。

## 证据等级

| 标记 | 含义 |
| --- | --- |
| `STATIC-CONFIRMED` | 已直接读取当前源码、场景或数据文件，可确认结构事实。 |
| `TEST-SOURCE` | 测试源码中存在断言，但本轮没有在当前工作树执行。 |
| `EXECUTED-PASS` | 本轮已在当前工作树运行对应 Godot 测试，进程退出码为 0；只代表该测试实际断言的范围。 |
| `HISTORICAL-LOG` | `.audit-logs/` 中存在较早的 PASS 文本；若其时间早于被测源码，则不能证明当前版本。 |
| `UNVERIFIED` | 尚无与当前源码对应的运行、视觉或输入证据。 |
| `STATIC-BLOCKED` | 当前源码已经存在足以阻止验证继续的静态不一致。 |

## 运行时组成

`src/ui/main.tscn` 只有一个全屏 `Control` 根节点并挂载 `src/ui/main.gd`；所有可见 UI 都在脚本中动态创建。当前主 UI 脚本已超过 3.5k 行、约 220 KiB，绝大多数页面、查询、格式化、导航和命令绑定集中在同一文件。已明确拆出的复杂视图有 `src/ui/components/system_map_view.gd` 与 `src/ui/components/megastructure_progress_view.gd`；主题 token 位于 `src/ui/ui_theme_tokens.gd`。后者是约 `720x300` 的自绘巨构进度图，按完成阶段逐层绘制基座、基础、主框架、能源骨干、收集器、集成、调试和运行层，并设置阶段 tooltip 文本；但控件同时使用 `MOUSE_FILTER_IGNORE`，tooltip 是否能被鼠标触发必须视为未验证。`main.gd:_rebuild_megastructure()` 还同时构造 8 个 `✓/◆/○` 阶段 tile、统计卡和普通进度条。

```text
project.godot -> src/ui/main.tscn -> CoreGameplayLab (Control)
                                      |
                                      +-- Top status/header
                                      |    +-- clock / Location / power / alerts
                                      |    +-- speed / locale / save / restart
                                      |
                                      +-- Workspace (HBox)
                                      |    +-- Navigation rail
                                      |    +-- hidden-tab TabContainer
                                      |    |    +-- 13 page ScrollContainers
                                      |    +-- Context Inspector sidebar
                                      |
                                      +-- AlertsTimelineTasks bottom strip

UI intent -> src/ui/main.gd callback -> Game.* command
Game signals -> dirty flag -> rebuild sidebar + active page
Game/Simulation query -> labels/cards/controls
```

证据：`src/ui/main.gd:_build_shell()`、`_build_header()`、`_build_navigation_rail()`、`_rebuild_active_page()`；`src/ui/main.tscn`；`project.godot:14-19`。状态为 `STATIC-CONFIRMED`。

## 布局与信息层级

当前信息架构采用固定桌面控制台：

1. 顶栏承担全局运行状态与全局命令。
2. 左栏承担固定工作区导航。
3. 中栏是唯一活动页面；`TabContainer.tabs_visible = false`，页面切换完全依赖外部按钮和代码。
4. 右栏先显示 Location 上下文，再显示最多三个 blocker、Guidance 和可选开发者详情。
5. 底栏显示最近一次 notice；其控件名虽为 `AlertsTimelineTasks`，当前只承载单条、可省略号截断的文本。

页面内部通常是 `page title -> section title -> repeated cards -> buttons/inputs`。代码没有使用 Godot `Tree`/`ItemList` 形成真正的表格，也没有统一的虚拟列表；高密度数据主要通过大量 `Label`、`RichTextLabel`、`VBoxContainer` 和卡片重复展开。Inventory 是少数具备搜索框的表面（`src/ui/main.gd:_rebuild_inventory()`）。

### 固定尺寸约束

`project.godot` 的设计视口和窗口覆盖均为 `1440x900`，stretch mode 为 `canvas_items`。`UiThemeTokens` 定义左栏 204 px、Inspector 304 px、底栏 64 px；地图最小为 `760x560`；顶栏状态文本最小宽 620 px；普通按钮最小高 34 px，导航行为 40 px；数字输入最小宽 180 px，字段标签最小宽 150 px。

只计算地图页的硬最小宽度，根左右边距 36 + 左栏 204 + 两个列间距 20 + 中央页内边距 28 + 地图 760 + Inspector 304 = 1352 px。1366 px 窗口只剩约 14 px 余量，尚未计入滚动条和控件主题尺寸。代码中没有主 Shell 的断点、侧栏折叠或窄屏重排逻辑；只有地图在自身 `resized` 时重新排节点。1366×768 与 2560×1440 的视觉结果均为 `UNVERIFIED`。

## 导航图

```text
Navigation rail
  |-- system_map ---- Location_<id> --------------------> location
  |-- location -------- tabs: overview/resources/industry/logistics/projects
  |-- industry -------- sections: production/facilities/construction/automation
  |-- inventory ------- ProductDetails/Why ------------> diagnostics
  |-- logistics ------- alias of selected Location logistics content
  |-- construction ---- alias of Industry construction content
  |-- research
  |-- ships (internal page key: fleet)
  |      +-- roster/readiness/shipyard/archive
  |      +-- Missions ----------------------------------> expedition
  |-- survey (internal page key: frontier)
  |-- megastructure
  `-- diagnostics ----- blocker routing ----------------> inventory/logistics/
                                                        construction/location/industry

Guidance NextStepCTA -----------------------------------> fleet/frontier/industry/
                                                        research/expedition/
                                                        system_map/location/
                                                        megastructure/overview
```

直接导航条共有 11 个条目；实际创建的页面共有 13 个。`overview` 和 `expedition` 不在导航条：

- `expedition` 可由 Ships 页的 `ShipsMissions` 按钮或特定 Guidance（例如科研 field test）进入，因此是“间接可达”，不是完全孤儿。
- `overview` 只会由 Guidance 的默认映射或主流程全部结束时进入，是“条件可达/弱发现”页面。
- `logistics` 和 `construction` 是独立导航入口，但分别复用 Location Logistics 与 Industry Construction builder；这形成两个入口、一个内容权威的别名关系。

`src/ui/main.gd:_build_navigation_rail()` 将内部 `fleet/frontier` 的节点名发布为 `Navigation_ships/Navigation_survey`。当前 `tests/ui_playflow_test.gd:22-26,45,114-117` 已使用 11 个公开 rail ID，并通过 `ShipsMissions` 间接进入 Expedition；测试源码与当前导航树静态对齐。本轮该测试已退出码 0 并输出 `PASS: UI-driven core playflow and product navigation`，故公开 ID 与该混合 playflow 的断言范围为 `EXECUTED-PASS`；测试仍直接推进/修改部分 Domain 状态，不能据此声称完整 UI-only Journey PASS。

## Context Inspector

当前右栏已具备 Location 级 Inspector 雏形（`src/ui/main.gd:_rebuild_sidebar()`）：

- 已发现 Location 下拉选择；
- 当前 Location 的类型、勘测、能源、仓储和物流摘要；
- “打开地点”动作；
- 最多三个 blocker 及解析导航；
- Guidance 文本与 `NextStepCTA`；
- 可选开发者详情。

它还不是选择驱动的通用 Context Inspector：地图节点、产品、设施、项目、舰船和航线没有统一 `selected_entity` 模型；Inspector 内容仍以 `_selected_location_id` 为主，产品详情会跳转 Diagnostics 而不是在侧栏展开。当前也没有多选、Inspector 历史/返回或 Selection 生命周期。

`_current_blockers()` 已委托给 `Game.active_blockers()`；Location selector 与 Developer Details 也有对应回调。当前 Inspector 结构为 `STATIC-CONFIRMED`，但选择切换、blocker 路由和焦点行为仍为 runtime `UNVERIFIED`。

## 状态、刷新与命令边界

### 当前 UI 状态

页面状态分散在 `_active_page_key`、`_selected_location_id`、`_location_section`、`_industry_section`、`_fleet_section`、搜索词和 planner 字段中，没有单一 `UIState` 对象。`Game.state_changed`、`Game.domain_event`、`Game.command_rejected` 和 locale change 设置 dirty；`_process()` 在非文本编辑状态下，以至少 180 ms 的间隔重建侧栏和活动页。

`_clear()` 会移除并 `queue_free()` 当前容器的全部子节点。这使派生数据简单，但带来以下已确认的结构风险：

- 重建会替换焦点拥有者和大部分控件实例；
- ScrollContainer 的内容被重建，未见显式滚动位置恢复；
- OptionButton、SpinBox 等临时交互状态必须依靠外部字段保存，否则重建即丢失；
- 页面和 Inspector 共享一个巨型脚本，任何新状态都继续增加交叉字段和重建分支。

代码已加入 `UI_CONFIG_PATH` 与 `ConfigFile`，并实现 `_load_ui_preferences()` / `_save_ui_preferences()`：保存 active page、Location、Location/Industry/Fleet section 和 Developer Details。旧 `ships/survey` page key 会在加载时迁移到内部 `fleet/frontier`。这是 `STATIC-CONFIRMED`；当前工作树的实际保存/重启恢复仍为 `UNVERIFIED`。

### Domain 命令边界

按钮写操作大多经 `_command(label, callable)` 调用 `Game.*`，并把成功/失败写入底栏事件文本。`data/player_action_registry.json` 声明 72 个动作，其中 56 个 core action 均有静态 UI-to-Domain 映射；但顶层 `uiJourneyCoverage` 明确为 `UNVERIFIED`。该 registry 的 `verified` 只表示静态字符串/调用点追踪，不能升级为运行时交互覆盖。

Location > Industry 已有真实模板命令面：`IndustrialTemplateSelector` 列出内容模板，`ApplyIndustrialTemplate` 经 `_apply_selected_industrial_template()` 调用 `Game.apply_location_industrial_template()`，`ClearIndustrialTemplate` 调用 `Game.clear_location_industrial_template()`；应用模板后同一卡片还提供 managed expansion pause/resume。它们是 `STATIC-CONFIRMED` 的玩家入口，不应再归类为 dead UI。`data/player_action_registry.json` 仍把 apply/clear 两项写成无 UI entry point，属于 registry 落后；其余 reserve、pin 和两类 automation authorization 仍未 surfaced。本轮 action registry test 仍可通过，是因为该门禁只强制 core actions，不能据此认为上述非 core 清单已同步。

## 输入、焦点、弹窗与工具提示

- 鼠标：按钮、滚轮页面、OptionButton、SpinBox 和 LineEdit 均依赖 Godot 默认控件行为。
- 键盘：未发现 `_input` / `_unhandled_input`、快捷键、focus neighbor、Escape/Back 层级或键盘地图导航。
- 焦点：Theme 只设置按钮 focus 字色；未发现显式 focus ring、焦点恢复或弹窗 focus trap。
- 弹窗：顶栏“重开”已使用 exclusive `ConfirmationDialog`，明确说明不可撤销，并在打开时把焦点放到取消按钮；尚未形成可复用的 Modal/Overlay/Back 统一层。
- 危险动作：重开已有确认；取消工程/巨构阶段/造船订单/改装、删除 loadout、拆解舰船等其他不可逆或有损动作仍直接走 `_command()`，只靠按钮文案提示后果。
- 工具提示：当前只在锁定导航、部分 blocker、运输模式和科研路线等少数位置设置 `tooltip_text`。大量 disabled gameplay button 没有统一“为什么不可用”的提示。
- 触达面积：普通按钮最小高 34 px、导航行 40 px；是否满足目标平台可访问性要求尚未验证。

## 当前架构结论

| 领域 | 状态 | 结论 |
| --- | --- | --- |
| Shell 结构 | `STATIC-CONFIRMED` | 顶栏/左导航/中央工作区/右 Inspector/底 notice 五区已形成。 |
| UI 启动完整性 | `EXECUTED-PASS (FOCUSED)` | UI playflow、Location、zh-CN 与 English smoke 均成功实例化当前 MainScene；未证明全状态、全输入或长时运行。 |
| Navigation graph | `EXECUTED-PASS (FOCUSED)` | 11 个直接入口、2 个间接/条件页面；UI playflow 已验证公开 ID 与 `ShipsMissions` 间接路径。 |
| Domain 命令边界 | `EXECUTED-PASS (STATIC CONTRACT ONLY)` | player action registry test 验证 56 个 core action 的静态 UI-to-Domain contract；运行 Journey 仍未验证。 |
| UI 状态 registry | `EXECUTED-PASS (CONTRACT ONLY)` | 44 个状态的结构测试已通过；数据仍明确标注 runtime `UNVERIFIED`。 |
| 响应式 | `UNVERIFIED` | 固定桌面尺寸、无断点；未见当前源码对应截图矩阵。 |
| 键盘/手柄/焦点 | `UNVERIFIED` | 只依赖默认控件，没有专项测试证据。 |
| 弹窗/危险操作 | `STATIC-CONFIRMED` | 重开已有取消优先的确认框；其他有损动作和统一 Back/Modal contract 仍缺失。 |
| 本地化 | `MIXED` | zh-CN/English smoke 本轮均 `EXECUTED-PASS`；但 stable-key 工作树门禁仍报告 891 errors / 820 warnings 并退出 1，不能合并成总体 PASS。 |

上述 6 个 focused tests 均退出码 0，但 Godot 退出时共同报告 `ObjectDB instances leaked` 与 `8 resources still in use`；这是待清理的测试/生命周期债务，不改写各测试断言的 PASS，也不能忽略为已验证的 clean shutdown。
