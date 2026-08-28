# Gameplay Surface Map

审计快照：2026-08-28。页面/入口来自当前 `src/ui/main.gd`；测试列明确区分本轮实际执行与仅有源码覆盖，focused PASS 不等于完整 UI Journey PASS。

## 全局 Surface 清单

| Surface | 玩家入口与子层级 | 当前内容/动作 | 代码证据 | 测试证据 | 当前判定 |
| --- | --- | --- | --- | --- | --- |
| Top status/header | 始终可见 | 时钟、地点、能源、告警数、项目数、R&D、MEGA；暂停/1×/10×/50×、语言、保存、重开 | `_build_header()`、`_update_header()`、`_request_reset_game()` | zh-CN/English smoke 本轮均实例化 Shell 并退出码 0；没有确认框/布局断言 | Shell focused 启动通过；重开已有取消优先确认，窄屏未验证 |
| Navigation rail | 始终可见，11 个按钮 | System、Location、Industry、Inventory、Logistics、Construction、Research、Ships、Survey、Megastructure、Diagnostics | `_build_navigation_rail()` | `ui_playflow_test.gd` 本轮退出码 0，并按 11 个公开 ID 检查 | `EXECUTED-PASS (FOCUSED)`；不含 Back/breadcrumb/键盘覆盖 |
| Context Inspector | 右栏 | Location 选择、摘要、blocker、Guidance、开发者详情 | `_rebuild_sidebar()`、`_current_blockers()` | 现有 UI 测试未断言 Inspector 选择/解析路径 | 结构与回调存在；runtime 未验证 |
| Alerts/Timeline/Tasks | 底栏 | 单条最近 notice，超长省略 | `_build_shell()`、`_append_log()` | 没有反馈可读性/历史测试 | 名称大于实现；不是完整 timeline/task center |
| System Map | `Navigation_system_map` | 2D 节点、路线、发现/未知图例、系统生产物流摘要 | `_rebuild_system_map()`、`system_map_view.gd` | `location_ui_smoke_test.gd` 点击 Earth；`ui_playflow_test.gd` 查 `SystemMap2D` | 已实现；未知节点可点击语义冲突；无缩放/平移/键盘验证 |
| Location Overview | Map 节点或 `Navigation_location` | 情报、勘测、环境、库存、能源、工业、物流/工程/舰队摘要 | `_rebuild_location()`、`_build_location_overview()` | `location_ui_smoke_test.gd` 本轮退出码 0 | 初始 Earth 与五个 Location 子页为 `EXECUTED-PASS (FOCUSED)`；全 Location/全勘测状态未验证 |
| Location Resources | Location > 资源 | 资源情报、场地状态、开发场地 | `_build_location_resources()` | `location_ui_smoke_test.gd` | 存在；不同 survey state 的真实视觉覆盖未验证 |
| Location Industry | Location > 工业 | 本地约束、产线、优先级、工艺、扩建、容量工程 | `_build_location_industry()` | localization 扫描；action registry 静态追踪 | 高密度控制面；运行 Journey 未验证 |
| Location Logistics | Location > 物流 | 仓储、路线、运输模式、舰船、策略输入 | `_build_location_logistics()` | `location_ui_smoke_test.gd` 只断言策略控件存在 | 核心动作静态可达；拒绝/保存/多地点 Journey 未验证 |
| Location Projects | Location > 工程 | 本地点进行中工程摘要 | `_build_location_projects()` | `location_ui_smoke_test.gd` 检查空态 | 存在；与独立 Construction 页职责重叠 |
| Industry / Production | `Navigation_industry` > 生产配方 | 生产启动/停止、blocker、真实吞吐 | `_rebuild_industry()`、`_build_industry_production()` | `ui_playflow_test.gd` 本轮启动第一配方并制造 blocker，退出码 0 | focused 断言通过，但测试会直接推进/改状态，非完整 UI-only Journey |
| Industry / Facilities | Industry > 设施与工艺 | 设施模块、制造模块、能源优先级 | `_build_facility_management()` | English localization 扫描；action registry 静态追踪 | 入口存在；成功/失败/持久化未由 UI Journey 覆盖 |
| Industry / Construction | Industry > 设施建设 | 工程队列、暂停/继续、优先级、取消、开始建设 | `_build_industry_construction()` | `ui_playflow_test.gd` 启动 Foundry；部分后续用直接 simulation 推进 | 存在；与独立 Construction 页为别名 |
| Industry / Automation | Industry > 经济诊断与规划 | 经济分析、只读 planner、有限 automation | `_build_background_economy_controls()` | English localization 扫描 | 复杂度高；两个 automation action 仍无 UI 入口 |
| Inventory | `Navigation_inventory` | Location 产品搜索、现存/容量、available/reserved、流入/流出/净值、Why | `_rebuild_inventory()` | English localization 只扫描可见 CJK | 信息面存在；reserve/pin 动作无入口；大清单布局未验证 |
| Logistics | `Navigation_logistics` | 复用当前 Location Logistics builder | `_rebuild_logistics()` | English localization 扫描 | 直接入口存在；本质是 Location 子页别名 |
| Construction | `Navigation_construction` | 复用 Industry Construction builder | `_rebuild_construction()` | English localization 扫描 | 直接入口存在；本质是 Industry 子页别名 |
| Diagnostics | `Navigation_diagnostics`、Inventory Why、Inspector blocker | 汇总 mining/industry/construction/shipyard/research/饱和物流 blocker，跳转解析；附 planner | `_rebuild_diagnostics()`、`Game.active_blockers()`、`_navigate_blocker()` | English localization 扫描；无 blocker 路由专项测试 | 来源已扩展；路由仍不保留返回/焦点实体 |
| Research | `Navigation_research` | 活动计划、路线、roadmap、blocker、开始/停止 | `_rebuild_research()` | `ui_playflow_test.gd` 静态制造 blocked research 后检查 Guidance | 核心面存在；不是通过 UI 抵达该 blocked state |
| Ships / Roster | `Navigation_ships` > 舰船 | 舰船生命周期、调配、建设支援、战位、loadout、模块、拆解 | `_rebuild_fleet()`、`_build_fleet_roster()` | UI playflow 本轮验证 `Navigation_ships` 并执行部分调配，退出码 0；action registry 为静态追踪 | 部分 roster 断言 focused PASS；完整生命周期 Journey 未验证 |
| Ships / Readiness | Ships > 战备 | doctrine、撤退、编队、补给目标、自动补给 | `_build_fleet_readiness()` | UI playflow 本轮检查退却布局/三战位，English smoke 扫描页面，均退出码 0 | 指定布局/文本 focused PASS；完整战备 Journey 未验证 |
| Ships / Shipyard | Ships > 造船与改装 | 队列重排/取消、批量建造 | `_build_fleet_shipyard()` | English scan；action registry 静态追踪 | 存在；大队列和多分辨率未验证 |
| Ships / Archive | Ships > 档案 | 改装/维修项目、海军档案 | `_build_fleet_archive()` | English scan | 存在；弱主流程入口 |
| Expedition | Ships > Missions 或 Guidance | 舰队就绪、补给、路线、任务、召回、战斗、报告 | `_rebuild_expedition()` | English smoke 与 UI playflow 本轮都经 `ShipsMissions` 进入并退出码 0 | 间接路径 focused PASS；左栏无入口、完整任务 Journey 未验证 |
| Survey / Frontier | `Navigation_survey` | 永久采集点、开始/停止、网络整合 | `_rebuild_frontier()` | `ui_playflow_test.gd` 本轮验证 `Navigation_survey`，退出码 0 | 入口 focused PASS；完整勘测 Journey 未验证 |
| Megastructure | `Navigation_megastructure` | 工地选择、八阶段、物资/进度、开始/取消；`720x300` 自绘结构按阶段逐层显形；8 个 `✓/◆/○` 阶段 tile、统计卡与普通进度条并存 | `_rebuild_megastructure()`、`megastructure_progress_view.gd` | UI playflow 仅断言阶段定义数量；English smoke 扫描阶段标题，二者本轮退出码 0 | 表面可实例化；分层图的阶段转换、裁切和最终态没有视觉/交互验证；控件虽设置 tooltip，但 `MOUSE_FILTER_IGNORE` 下的可触达性未验证 |
| Overview | 无直接 rail；Guidance 默认/完成态 | 全局目标、库存、设施、运行作业摘要 | `_rebuild_overview()`、`_next_flow_page()` | 当前 UI playflow 不再期待直接 rail ID | 条件可达，发现性弱；无直接导航测试 |

## Navigation 与 Surface 权威关系

| 表面关系 | 现状 | 风险 |
| --- | --- | --- |
| `location.logistics` 与 `logistics` | 共享 `_build_location_logistics()`，依赖同一 `_selected_location_id` | 两个入口容易让玩家误以为存在全局/本地两套语义；标题之外缺少范围提示。 |
| `industry.construction` 与 `construction` | 共享 `_build_industry_construction()` | 工程入口重复，返回路径与当前 Industry section 不一致。 |
| `industry.automation` 与 `diagnostics` | 都调用 `_build_background_economy_controls()` | “诊断”和“规划/自动化”职责混在一起，信息量过大。 |
| `fleet` 与 `expedition` | Fleet 的 Missions 打开隐藏 page | 页面与测试模型已对齐，但左栏不表达该层级，也没有统一返回路径。 |
| `overview` 与 Guidance | 只有 flow 默认路由可进入 | 主流程末尾才可能出现，缺少显式导航与面包屑。 |

## Dead / Orphan / Unsurfaced 清单

### 页面级

| 项目 | 分类 | 证据 | 影响 |
| --- | --- | --- | --- |
| `overview` | 条件可达 / 弱发现 | 页面在 `_build_shell()` 创建；不在 rail；`_next_flow_page()` 最终返回它 | 玩家无法稳定返回全局概览；当前测试不再把它误写成直接入口。 |
| `expedition` | 间接可达 | 页面存在；Ships `ShipsMissions` 与特定 Guidance 可进入；不在 rail | 任务面被藏在舰船页，首次发现依赖文案或 Guide。 |
| `logistics` / `construction` | 重复别名，不是 dead | 独立 rail page 复用子页 builder | 信息架构重复，未来可能出现状态/标题/返回分叉。 |

### 控件、helper 与 Domain action

`data/player_action_registry.json` 当前声明 72 个动作、56 个 core action，顶层 `uiJourneyCoverage = UNVERIFIED`。它仍把 6 个非 core 动作标为无实际 UI entry point；但当前 UI 已新增 Industrial Template apply/clear 控件，所以 registry 与 UI 对这两项的静态结论已经不同步：

| Action | 当前静态事实 | 分类 |
| --- | --- | --- |
| `SET_INVENTORY_RESERVE` | `Game.set_inventory_reserve()` 存在；Inventory 仅展示 reserved 值 | unsurfaced |
| `APPLY_INDUSTRIAL_TEMPLATE` | `ApplyIndustrialTemplate` 控件已调用 `_apply_selected_industrial_template()` -> Domain command | 已 surfacing；registry stale |
| `CLEAR_INDUSTRIAL_TEMPLATE` | `ClearIndustrialTemplate` 已直接绑定 Domain command | 已 surfacing；registry stale |
| `PIN_PRODUCT` | Domain 命令存在，UI 无引用 | dead/unsurfaced preference |
| `AUTHORIZE_ROUTE_AUTOMATION` | Domain 支持 action type，UI 无创建入口 | partial automation surface |
| `AUTHORIZE_PROJECT_PRIORITY_AUTOMATION` | Domain 支持 action type，UI 无创建入口 | partial automation surface |

仍未 surfacing 的 4 项不是 core action 缺失的证明，但 Inventory reserve/pin 与两类 automation 授权仍会削弱例外管理能力。Industrial Template apply/clear 已形成可点击入口，是 anti-Excel 方向的正向变化；对应 registry 需要在其负责阶段重新生成或校正，本任务按要求不修改 registry。

### 当前测试边界

UI Shell 新增的 preferences 与 Inspector 回调目前都有定义，未发现同类本地私有调用缺失。`tests/ui_playflow_test.gd` 已按 `Navigation_ships`、`Navigation_survey` 和 `ShipsMissions` 与当前导航树对齐，并在本轮当前工作树退出码 0。测试本身仍直接修改部分 `Game.state`，所以只能记为 focused/mixed playflow PASS，不能升级为完整 UI-only Journey。另有 player action registry、UI state registry、zh-CN、English 与 Location smoke 同样退出码 0；六个进程退出时都报告 ObjectDB/resource still in use 警告，属于尚未清理的生命周期债务。

## Discoverability 结论

正向模式：锁定导航仍保持可见，并附加“Locked”与条件 tooltip；Guidance 提供单个 Next CTA；Inventory 提供搜索与 Why；Diagnostics 提供根因方向跳转。

当前风险：

- 锁定导航只改 caption/tooltip，不禁用按钮，玩家能进入“Locked”页面，需依赖页面内控件自行解释。
- System Map 文案和图例称 UNKNOWN/LOCKED、未知地点不可操作，但 `SystemMapView.configure()` 对所有节点设置 `button.disabled = false`；`_open_location()` 只检查 Location 是否存在，而 `SpaceGameState.initialize_locations()` 会为内容中的所有 Location 建状态。因此未知节点仍可点击进入，视觉语义与交互语义不一致。
- `overview`、`expedition` 缺少 rail 入口，Shell 也没有 breadcrumb、Back 或最近访问历史。
- `NextStepCTA` 的按钮正文只写“下一步”，目标主要藏在 Guidance 文本/tooltip；跳转后除 Location 与 Industry section 外没有通用 focus entity 定位。
- 大量 disabled action 只有灰态，没有统一 blocker reason 或解析按钮。
- Diagnostics 跳转是按 reason 分类的 page-level 路由，不携带选择实体、返回位置和滚动锚点。

## Excel 化风险

“Excel 化”是指 UI 退化为逐 SKU、逐设施、逐舰船、逐参数的长表/长表单，玩家必须理解内部数据结构才能完成目标。当前风险为高：

- Location Industry 为每个设施、产线和可用配方创建成组按钮；Inventory 展开全部 economy products；Logistics 为单个物品显示多个固定宽度 SpinBox；Fleet 为每艘船展开生命周期、调配、战位、loadout 和模块动作。
- 主要呈现单元是重复卡片和标签，没有摘要/详情层、排序、过滤、批量选择、虚拟化或固定列比较；Inventory 只有文本搜索。
- Logistics 的标签 150 px + 输入 180 px、顶栏 620 px 状态区等硬尺寸在窄窗口会放大表单感和横向压力。
- Industrial Template 已提供 apply/clear 与 managed expansion pause/resume，是“模板作为默认”的第一步；但逐 SKU 例外、模板差异预览、影响确认和批量回滚尚未形成。
- Context Inspector 目前只减少了全局库存/设施堆叠，但仍不能承接产品、项目、舰船等详情，中央页仍必须一次展开大量字段。

建议的迁移边界不是删掉复杂度，而是将复杂度分层：列表只显示身份、状态、关键流量和 blocker；选择后由 Inspector 承接 Why/输入输出/动作；批量默认交给模板；只有比较任务使用表格，并让高级参数渐进展开。
