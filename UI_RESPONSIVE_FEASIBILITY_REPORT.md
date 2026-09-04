# UI Responsive Feasibility Report

分析日期：2026-09-04

> 快照说明：项目在分析开始前已经存在未提交修改，且分析期间另有外部进程继续更新部分 UI 与测试文件。本报告采用分析结束时可见的生产代码快照。分析阶段没有修改项目文件；本 Markdown 报告是用户后续明确要求新增的唯一文件。

## 1. Executive Summary

| 项目 | 结论 |
|---|---|
| 当前系统状态 | 原生窗口像素布局；已有统一的运行时 Theme/Token 和手动 UI Scale，但响应式布局只覆盖少数场景。整体是“Container 驱动 + 大量像素约束”的混合架构 |
| 自动 UI Scale 可行性 | **MEDIUM** |
| Responsive Layout 可行性 | **MEDIUM** |
| 舰船名册增量改造 | **MEDIUM**（节点结构修改本身是 LOW；业务语义确认使整体变为 MEDIUM） |
| 是否需要大修 | **NO** |
| 推荐 | **GO WITH CONDITIONS** |

核心判断：

- 当前手动 UI Scale 不是伪缩放：字体、控件、间距确实会重新构建，并非简单拉伸画面。
- 当前尚无 AUTO Scale，也没有根据可用 logical space 选择布局档位的机制。
- 4K/超宽屏空白主要不是字体缩放失效，而是 **Responsive Layout + Content Density + Container Sizing** 的组合问题。
- 舰船名册右侧现有结构已经分成 Upper、Lower、Footer，适合继续增加“编队与部署”“补给与载荷”，不需要重做上半部分。
- 编队、位置、条令、撤退和舰队补给数据均可复用现有业务状态；“作战角色”和真正的“单舰补给量”目前不存在，不能仅靠 UI 补出来。
- 最低风险入口是：保留现有美术、Theme 和主结构，先补齐 AUTO/Manual 状态模型与布局 Profile，再以舰船名册为唯一试点。

## 2. Current Rendering & Scaling Architecture

### Godot 版本

- 项目声明版本：Godot 4.7，见 `project.godot:17`。
- 实际运行版本：`4.7.2.stable.official.ed1daf0bf`。
- 主场景：`src/ui/main.tscn`。

### Project Settings

| 文件 | Setting key | 当前值 |
|---|---|---:|
| `project.godot:26` | `display/window/size/viewport_width` | `1440` |
| `project.godot:27` | `display/window/size/viewport_height` | `900` |
| `project.godot:28` | `display/window/size/window_width_override` | `1440` |
| `project.godot:29` | `display/window/size/window_height_override` | `900` |
| `project.godot` | `display/window/stretch/mode` | **未设置** |
| `project.godot` | `display/window/stretch/aspect` | **未设置** |
| `project.godot` | `display/window/stretch/scale` / content scale | **未设置** |
| `project.godot` | `display/window/dpi/allow_hidpi` | **未设置** |
| `project.godot` | `display/window/size/mode` | **未设置；正常启动表现为 Windowed** |
| `project.godot` | `display/window/size/resizable` | **未设置** |
| `project.godot` | `display/window/size/borderless` | **未设置** |
| `project.godot:37` | `gui/theme/default_font_multichannel_signed_distance_field` | `true` |
| `project.godot:41` | `renderer/rendering_method` | `gl_compatibility` |

虽然定义了 1440×900 viewport，但实际运行与测试显示：

- 根 Control 跟随实际窗口/Viewport 尺寸。
- 根节点 `scale == Vector2.ONE`。
- `Window.content_scale_factor == 1.0`。
- 不存在固定 1440×900 画布再整体 stretch 到窗口的效果。

生产代码另设窗口最小尺寸：

- `MIN_PRODUCTION_VIEWPORT_SIZE = Vector2i(1280, 720)`
- `_ready()` 中赋给 `get_window().min_size`
- 位置：`src/ui/main.gd:172-179`

### 当前 UI Scale 完整调用链

```text
main.gd::_build_header()
  → 创建 UIScaleSelector
  → UiThemeTokens.SUPPORTED_UI_SCALES
  → main.gd::_on_ui_scale_selected()
  → UiThemeTokens.sanitize_ui_scale()
  → UiThemeTokens.ui_scale_supported_for_viewport()
  → 写入 root session meta
  → main.gd::_save_ui_preferences()
  → main.gd::_reload_ui_for_scale()
  → SceneTree.reload_current_scene()
  → main.gd::_ready()
  → main.gd::_load_ui_preferences()
  → main.gd::_build_theme()
  → UiThemeTokens.build_theme()
  → 所有动态 UI 按新 token 重建
```

具体位置：

- Dropdown 创建：`src/ui/main.gd::_build_header()`，约第 435 行
- 节点名：`UIScaleSelector`
- 选项定义：`src/ui/ui_theme_tokens.gd:83`
- 默认值：`src/ui/ui_theme_tokens.gd:84`
- 选择回调：`src/ui/main.gd::_on_ui_scale_selected()`，约第 6674 行
- 重载函数：`src/ui/main.gd::_reload_ui_for_scale()`，约第 6698 行
- Theme 构建：`src/ui/main.gd::_build_theme()`，约第 286 行
- 偏好加载/保存：`src/ui/main.gd::_load_ui_preferences()`、`_save_ui_preferences()`

当前选项实际是：

```text
75%, 100%, 125%, 150%, 175%, 200%
```

默认值为 **125%**。

各档位当前最低允许窗口：

| UI Scale | 最低 Viewport |
|---:|---:|
| 75% | 1280×720 |
| 100% | 1280×720 |
| 125% | 1280×720 |
| 150% | 1600×900 |
| 175% | 1920×1080 |
| 200% | 2560×1440 |

定义见 `src/ui/ui_theme_tokens.gd:89-96`。

### 它实际修改什么

不是以下机制：

- 不修改 `content_scale_factor`
- 不修改根 `Control.scale`
- 不修改 Viewport 尺寸
- 不用整体 Canvas/stretch 缩放
- 不使用平台 DPI 作为 multiplier

实际机制是：

1. 重建根 Theme。
2. 字体通过 `UiTokens.font_size()` 按完整 `_ui_scale` 缩放。
3. 普通 shell 尺寸通过 `layout_scale = lerp(1.0, ui_scale, 0.5)` 进行缓和后的缩放。
4. 舰船名册使用 `_fleet_roster_px()`，按当前 UI Scale 对 Golden Reference 尺寸进行完整换算。
5. 本场景所有动态创建的 Control 被重新创建。

因此它是：

- 全局于当前主 UI scene
- 对所有页面保持
- 切换页面保持
- 场景 reload 保持
- 重启后在 `Game.persistence_enabled` 时保存至 `user://core_gameplay_ui.cfg`
- 测试使用 `--no-persistence` 时不写配置

当前没有：

- AUTO 选项
- 自动推荐
- DPI 驱动逻辑
- monitor-change 重新计算
- resize 后改变有效 scale

Resize 时只会重新禁用不适合当前尺寸的选项；如果当前已经是 200%，再把窗口缩到 1280×720，代码不会自动降档。

本机 Retina 环境诊断得到 OS display scale `2.0`，但它只在截图诊断代码中记录；生产缩放逻辑没有使用它。

## 3. Current UI Architecture

### Theme 结论

最接近：

> **B. 部分统一 Theme + 大量局部 override**  
> 同时具有明显的 C 类特征，即许多页面自行定义基础像素尺寸。

证据：

- 项目中没有 `.tres` 或 `.theme` Theme resource。
- 没有发现生产代码使用 `ThemeDB`。
- 统一入口是运行时模块 `src/ui/ui_theme_tokens.gd`。
- `UiThemeTokens.build_theme()` 统一设置默认字体、Button、LineEdit、OptionButton、Panel、ProgressBar 等样式。
- CJK 字体 fallback 包含 `Noto Sans CJK SC`、`Microsoft YaHei UI`、`PingFang SC` 等。
- 页面仍大量使用局部 `add_theme_*_override()` 和 `custom_minimum_size`。

当前快照近似统计：

| 项目 | 数量 |
|---|---:|
| `custom_minimum_size` 引用 | 约 160 |
| `main.gd` 中带数值字号的 `_label(...)` 调用 | 约 189 |
| `add_theme_font_size_override()` | 60 |
| `add_theme_constant_override()` | 210 |
| `add_theme_stylebox_override()` | 103 |
| Size Flag 设置 | 158 |
| Stretch ratio 设置 | 8 |
| 直接 `position=` | 14 |
| 直接 `size=` | 15 |
| 直接 offset 赋值 | 8 |

189 个字号调用多数是“硬编码基础字号”，最终仍会经过 Token 缩放；它们不是完全不可缩放，但说明 Typography 尚未抽象为少量语义字号。

### Container 使用

| Container | 构造数量 |
|---|---:|
| `HBoxContainer` | 50 |
| `VBoxContainer` | 51 |
| `GridContainer` | 2 |
| `HFlowContainer` | 23 |
| `VFlowContainer` | 0 |
| `MarginContainer` | 10 个直接构造；另有大量 `_margin()` helper 调用 |
| `PanelContainer` | 16 |
| `ScrollContainer` | 8 |
| `TabContainer` | 2 |
| `SplitContainer` | 0 |
| `CenterContainer` | 5 |
| `AspectRatioContainer` | 0 |

结论：

> 当前布局是 **Container-driven，但带有强烈 Pixel-authored constraints**。

它不是传统 absolute positioning UI。绝对坐标主要集中在：

- System Map
- 舰船模块/船体绘制
- Blueprint canvas
- Popup 定位
- 自定义图形和视觉层

舰船名册等普通页面主要依赖 Container，不依赖绝对坐标。

### 主要页面

| 页面 | 当前布局方式 | 响应式现状 |
|---|---|---|
| 顶部全局导航 | `HBoxContainer` + Workspace `HFlowContainer` | Workspace 导航可换行；Scale >125% 时隐藏 Header Status 并加高导航。顶部工具栏自身仍是固定 HBox |
| 舰船主页面 | `_rebuild_fleet()` 动态创建 VBox/HFlow/HBox | 编队选择可换行；四张统计卡和部分区域仍是固定 HBox |
| 舰船名册 | 固定 master/detail HBox，比例约 34.1%/63.9% | 低高度依赖 Inspector 内滚动；无 profile、无最大内容宽度 |
| 编队与补给 | HFlow 条令/撤退按钮，固定三列阵位 HBox，纵向补给项 | 按钮可换行；三阵位列不会根据空间主动改列 |
| 造船与改装 | 三栏编辑器，左右有最小宽度，中间 expand | 比一般页面更复杂；缩放较大时依赖最小尺寸和外层滚动 |
| 维修与档案 | VBox + 卡片 + 页面 ScrollContainer | 最容易自然适配 |
| 任务页面 | VBox + 卡片 + HFlow actions | 主要靠纵向滚动和按钮换行，可适配性较好 |

公共 Shell 位于 `src/ui/components/game_shell.gd::build()`。它由顶部栏、Workspace HBox、左右栏、中心区和底栏组成；舰船名册与造船页面会调用 `set_blueprint_workspace(true)` 隐藏全局左右栏及底栏，让舰船工作区使用完整宽度。

## 4. Ship Registry Analysis

### 当前节点结构

舰船名册几乎完全在 `src/ui/main.gd::_build_fleet_roster()` 动态构造，简化后的运行时树为：

```text
CoreGameplayLab
└── GameShell
    └── ShellRows (VBoxContainer)
        ├── TopStatusBar
        │   └── TopStatusBarControls (HBoxContainer)
        └── WorkspaceGrid (HBoxContainer)
            └── CentralWorkspace (VBoxContainer)
                ├── WorkspaceNavigationBar
                │   └── WorkspaceNavigationFlow (HFlowContainer)
                └── TabContainer
                    └── fleet (ScrollContainer)
                        └── MarginContainer
                            └── FleetPageContent (VBoxContainer)
                                ├── FleetSectionTabs (HFlowContainer)
                                ├── FleetRosterHeader (HBoxContainer)
                                ├── FleetRosterFilters (HBoxContainer)
                                │   └── FleetRosterQueryControls (HBoxContainer)
                                └── FleetRosterBodyMargin
                                    └── FleetRosterMasterDetail (HBoxContainer)
                                        ├── FleetRosterListSurface
                                        │   └── FleetRosterBrowser (VBoxContainer)
                                        │       ├── FleetRosterBrowserHeader
                                        │       ├── FleetRosterListScroll
                                        │       │   └── FleetRosterShipList
                                        │       └── FleetRosterBrowserFooter
                                        └── FleetRosterInspectorSurface
                                            └── FleetRosterInspectorHost
                                                └── FleetRosterInspectorMargin
                                                    └── FleetRosterDetail (VBoxContainer)
                                                        ├── FleetRosterInspectorIdentityHeader
                                                        ├── FleetRosterInspectorUpperContent
                                                        │   ├── FleetRosterShipVisualPanel
                                                        │   └── FleetRosterOperationalStatusPanel
                                                        ├── FleetRosterLowerInfoInset
                                                        │   └── FleetRosterLowerInfoRow
                                                        │       ├── BasicInformation
                                                        │       ├── ConfigurationSummary
                                                        │       └── Readiness
                                                        └── FleetRosterFooterActions
```

`FleetRosterInspectorHost` 是单独的 `ScrollContainer` 组件，明确返回零 minimum size，使富内容只在低高度时进行内部滚动，见 `src/ui/components/ship_registry_inspector_host.gd`。

### LEFT 舰船列表

- 宽度由 `FleetRosterMasterDetail` 的剩余宽度和 `size_flags_stretch_ratio = 0.341` 决定。
- 没有显式 max width。
- 列表 Surface 没有直接声明统一 min width；子控件、搜索工具栏、行内容共同形成隐式 minimum。
- 水平和垂直均为 `SIZE_EXPAND_FILL`。
- 列表内已经存在 `FleetRosterListScroll`。
- 舰船很少时，Browser 和 list margin 仍然 fill vertical，因此舰船行以下是空的列表区域，Footer 被推到最下方。
- 4K 下列表达到 1300px 左右，是因为 34.1% 比例持续参与分配且没有 max width，不是舰船行需要这么宽。

### RIGHT 舰船详情

外层与内层的 size flag 正好解释了空白：

- `FleetRosterInspectorSurface`：横向、纵向 `EXPAND_FILL`
- `FleetRosterInspectorHost`：横向、纵向 `EXPAND_FILL`
- `FleetRosterInspectorMargin`：纵向 `SHRINK_BEGIN`
- `FleetRosterDetail`：纵向 `SHRINK_BEGIN`

因此：

1. 右侧背景 Surface 必须填满整个剩余高度。
2. 真正的内容 VBox 只保持自己的 minimum/content height，并贴在顶部。
3. 其后没有 expand 的 Workspace，也没有能消费剩余高度的内容。
4. 结果就是右侧背景延伸到底部，而内容停在顶部。

主要固定高度以 150% Golden Reference 为基准：

| 区域 | 100% | 150% | 200% |
|---|---:|---:|---:|
| Upper Content | 约 141px | 211px | 281px |
| Lower Info | 约 177px | 266px | 355px |
| 完整 Inspector 内容 | 约 410–420px | 约 630px | 约 840px |

这套结构非常适合增量增加：

```text
现有 Overview/Upper
+
现有 Basic / Configuration / Readiness
+
Formation & Deployment
+
Supply & Loadout
+
Footer Actions
```

上半部分不需要重做。可以在 `FleetRosterDetail` 中继续加入新的独立区域，低高度由现有 Inspector ScrollContainer 兜底。

### 增量改造难度

> **整体：MEDIUM**  
> **纯节点/布局插入：LOW**

原因：

- 有明确的 `Upper`、`Lower`、`Footer` builder 边界。
- 页面本来就通过 builder 动态重建，新增一两个信息区符合现有结构。
- Inspector 已有独立滚动。
- 不需要动舰船 Preview、现有上半信息或美术框架。
- 但“作战角色”和“单舰补给”的数据语义尚未存在，需要产品/模型层决定；若错误地把舰队共享补给标成单舰库存，会造成业务误导。

## 5. Fleet & Supply Analysis

### 现有功能与数据源

编队与补给页面实现于 `src/ui/main.gd::_build_fleet_readiness()`。

| 信息 | 当前是否存在 | 数据源 |
|---|---|---|
| 所属编队 | 是 | `SpaceGameState.fleet_formations[].ship_ids`；查询 `ship_formation_id()` |
| 编队位置 | 是 | `fleet_logistics[formation].formation.ship_zones[ship_id]` |
| 前列/中列/后列 | 是 | `FRONT / MID / REAR`；未设置但已入编队时按 `FRONT` 显示 |
| 作战角色 | **否** | Ship entity 没有 canonical role/duty；名册明确显示 `—` |
| 作战条令 | 是 | `formation.doctrine` |
| 撤退规则 | 是 | `formation.retreat_policy` |
| 动能弹药目标 | 是 | `supply_plan.kinetic_munitions` |
| 化学推进剂目标 | 是 | `supply_plan.chemical_propellant` |
| 维修补给目标 | 是 | `supply_plan.repair_supplies` |
| 当前舰队补给 | 是 | `fleet_logistics[formation].supplies` |
| 自动补给 | 是，但为一次性命令 | `Game.auto_resupply_fleet()`，不是可开关设置 |
| 舰队管理 | 是 | 创建/删除编队、舰船分配、阵位、条令、撤退策略 |

核心状态位于 `src/core/game_state.gd`：

```text
fleet_formations
fleet_logistics[formation_id]
├── supplies
├── supply_plan
├── policies
└── formation
    ├── doctrine
    ├── ship_zones
    └── retreat_policy
```

业务写操作集中在 `src/application/game.gd`：

- `set_ship_formation_assignment()`
- `set_fleet_supply_plan()`
- `set_ship_combat_zone()`
- `set_fleet_doctrine()`
- `set_fleet_retreat_policy()`
- `auto_resupply_fleet()`

Combat 也直接消费同一份条令、阵位、撤退规则，见 `src/core/combat_resolver.gd`。

### 能否在舰船名册复用

可以复用，而且不应复制 Fleet-level business logic。

以当前选中舰船 ID 为入口，可只读派生：

```text
ship_id
→ ship_formation_id()
→ formation_runtime()
→ fleet_logistics[formation_id]
→ 阵位、条令、撤退、当前补给、补给目标
```

复用程度：**HIGH**。

当前没有发现两个 UI 各自维护一份舰队业务状态。名册本地状态主要是当前选中舰船、批量选择、搜索、过滤和排序；这些是 presentation state，不是业务状态副本。

低风险注意点：

- `ship["assignment"]` 同时镜像 formation membership，但通过 `Game.set_ship_formation_assignment()` 的同一事务维护。
- `fleet_logistics_runtime()` 在缺项时会惰性创建默认字典；只读投影最好避免无意触发初始化，但这不构成 UI 业务状态重复。

### 补给数据分类

#### 已经存在的数据

- 舰队共享的 CURRENT：
  - `supplies.kinetic_munitions`
  - `supplies.chemical_propellant`
  - `supplies.repair_supplies`
- 舰队共享的 TARGET：
  - `supply_plan.kinetic_munitions`
  - `supply_plan.chemical_propellant`
  - `supply_plan.repair_supplies`
- 默认目标：`60 / 20 / 10`
- 默认当前 supplies 是空字典，查询结果相当于 0。
- 返回策略：`ammunition_empty`、`repair_empty`、`cargo_full`

#### 可以派生的数据

- “当前舰船所属编队的补给：42 / 60”
- 当前条令和撤退规则
- 当前舰船阵位
- 当前补给是否低于目标
- 自动补给行为当前是“从可用库存填到目标，受舰队货舱容量限制”

#### 当前不存在的数据

- 单舰独立的动能弹药库存
- 单舰独立的推进剂库存
- 单舰独立的维修补给库存
- 单舰独立补给目标
- Canonical 作战角色
- 可配置的补给来源
- 补给物资来源 provenance
- 可开关的“自动补给 enabled”状态
- 可选择的补给优先策略

`_auto_resupply_state()` 没有传入来源地点时使用默认主基地位置；这是当前算法行为，不是持久化的“补给来源”字段。

#### 纯概念/Mock 数据

示例中的 `42/60`、`18/20`、`4/10`：目标 60/20/10 与默认数据吻合，但当前值 42/18/4 不是代码中的固定状态。更重要的是，它们只能诚实地表示“舰船所属编队的共享补给”，不能表示“该舰本身携带量”。

## 6. Resolution Test Matrix

使用当前项目已有截图/诊断入口，以中文 UI 检查舰船名册。`L/R/P/B` 分别表示左栏宽度、右 Inspector 宽度、Preview 面板尺寸、右侧内容之后的近似空白高度。

当前菜单会禁用不符合最低 viewport 的缩放组合。表中“强制诊断”仅通过已有命令行 UI Scale 参数验证失败形态，没有实现 AUTO 或绕过生产逻辑。

| Resolution | Scale | Result | Primary Problems |
|---|---:|---|---|
| 1280×720 | 100% | 通过 | 可读但偏小；无 overlap/clipping；L/R≈422/792，P≈420×141，空白较少 |
| 1280×720 | 150% | 非支持；强制诊断可滚动 | 无明显水平裁切；Inspector 需要纵向滚动，Footer 在下方 |
| 1280×720 | 200% | 非支持；失败形态明显 | Master/detail minimum≈1533px，出现水平裁切和过窄列；P≈494×281 |
| 1600×900 | 100% | 通过 | L/R≈533/1001，P≈536×141，B≈261；密度开始偏低 |
| 1600×900 | 150% | 通过/内滚动 | 字体舒适；Inspector 轻微滚动，Footer 可达；无横向溢出 |
| 1600×900 | 200% | 非支持；强制诊断滚动 | Inspector 内容明显高于可用高度，控件密度过大 |
| 1920×1080 | 100% | 通过 | L/R≈645/1209，P≈651×141，B≈441；字体相对小、横向较空 |
| 1920×1080 | 150% | 通过 | 比例稳定，字体舒适；B≈149 |
| 1920×1080 | 200% | 非支持；强制诊断滚动 | 无主要水平裁切，但 Inspector 需要纵向滚动 |
| 2560×1440 | 100% | 通过 | L/R≈867/1627，P≈883×141，B≈801；信息密度明显不足 |
| 2560×1440 | 150% | 通过 | L/R≈862/1618，P≈869×211，B≈509；仍有大量下方空白 |
| 2560×1440 | 200% | 通过 | 字体清晰；P≈854×281，B≈216；没有解决宽度过宽问题 |
| 3440×1440 | 100% | 通过但布局失衡 | L/R≈1174/2200，P≈1201×141，B≈801；列极宽、横向空白显著 |
| 3440×1440 | 150% | 通过但布局失衡 | L/R≈1169/2191，P≈1187×211，B≈509 |
| 3440×1440 | 200% | 通过 | L/R≈1164/2182，P≈1172×281，B≈216；字体好但内容仍被拉得过宽 |
| 3840×2160 | 100% | 通过但极低密度 | L/R≈1313/2461，P≈1346×141，B≈1521；字体视觉很小 |
| 3840×2160 | 150% | 通过但大量空白 | L/R≈1308/2452，P≈1332×211，B≈1229 |
| 3840×2160 | 200% | 通过但仍大量空白 | L/R≈1303/2443，P≈1317×281，B≈936；200% 只改善可读性 |

共同结果：

- 所有当前“支持”的组合均未发现不可达的 overlap、clipping 或横向 overflow。
- 不支持的低分辨率高缩放组合会产生内部滚动，1280×720@200% 出现实质横向裁切。
- 左/右比例一直基本保持 34%/64%，不会因超宽屏改变。
- Preview 使用 `STRETCH_KEEP_ASPECT_CENTERED`，图像本身不变形，但面板会成为极宽、固定高度的横条。
- 右侧空白主要随“窗口高度 − 固定内容高度”增长。
- 英文 1280×720@100% 和 1600×900@150% 没有不可达裁切；150% 时 Configuration 文本出现更多换行，并使 Inspector Footer 下移到滚动区域。

现有测试运行结果：

- `tests/ui_scale_contract_test.tscn`：PASS
- `tests/ship_assembly_ui_test.tscn`：PASS
- `tests/ship_registry_step12_test.tscn`：PASS

`ship_registry_step12_test.gd` 已验证 native transform、`content_scale_factor=1`、支持档位下的边界、滚动可达性、resize 状态和弹窗位置，但不验证“空白是否有意义”或“信息密度是否合理”。

## 7. Root Cause Analysis

200% 问题属于：

> **E. 多个问题混合**  
> 主因排序：**B Responsive Layout → C Content Density → D Container Sizing**。  
> A UI Scale 不是主要故障。

技术因果链：

```text
窗口扩大
→ 根 Control 使用完整原生窗口尺寸
→ FleetRosterBody 纵横 EXPAND_FILL
→ Master/detail 按固定 0.341 / 0.639 比例分配全部宽度
→ 左右两栏没有最大宽度或内容宽度约束
→ Inspector Surface 填满全部剩余高度
→ 内层 FleetRosterDetail 使用 SHRINK_BEGIN
→ Upper/Lower 高度只按 UI Scale 扩大
→ 没有新增区域、profile 切换或可消费剩余高度的 Workspace
→ 面板继续铺满，内容停在顶部
→ 产生下方和横向大面积空白
```

为什么低分辨率正常：

- 可用画布与现有 Golden Reference 固定内容高度接近。
- 空白少。
- ScrollContainer 能在高 Scale、低高度时兜底。
- 34/64 分栏在 1280–1920 区间尚合理。

为什么高分辨率出现空白：

- 容器正确地扩张了，但内容结构没有变。
- `custom_minimum_size` 是下限，不是有意义的最大宽度/最大高度。
- 系统没有 Expanded profile 来增加列、显示额外内容或限制阅读宽度。

为什么 200% 不能解决：

- 200% 改变字体、控件和固定模块的尺寸。
- 它不改变分栏比例。
- 它不增加信息。
- 它不改变 Overview/Lower 的层级关系。
- 它不设置最大内容宽度。
- 它不把下方空白转换成新 Workspace。

4K@200% 的实测中，右 Inspector 可用高度约 1776px，而内容约 840px，因此仍剩约 936px。这是布局/内容密度问题，不是继续增加 font scale 能解决的问题。

## 8. AUTO UI Scale Feasibility

### 难度

> **MEDIUM**

不需要重写当前 Scale system，可以在现有机制上增量增加。

现有可复用基础：

- 单一支持档位列表
- Scale sanitize
- Theme 构建
- 字体和布局 Token
- Scale scene reload
- session meta
- 配置持久化
- Scale-specific minimum viewport
- Scale contract 测试

需要增加的概念：

1. 偏好模式：`AUTO` / `MANUAL`
2. 保留玩家最后一次 manual scale
3. 单独维护 recommended scale 和 effective scale
4. 窗口/显示器变化后的 recommendation 更新
5. debounce/hysteresis，避免 resize 时在两个档位间抖动或反复 reload
6. AUTO 只推荐并应用允许档位，不覆盖玩家 manual 选择
7. 增加目标档位 `90/100/110/125/150/175/200`

当前档位有 75%，但没有 90% 和 110%；需要迁移/兼容旧配置值。

侵入点主要是：

- `UiThemeTokens`
- `main.gd` 顶部 selector、偏好加载/保存、resize
- UI Scale 测试
- 本地化文案

主要技术注意点：

- 普通 Shell 使用 moderated `layout_scale()`，名册使用 full scale，目前不存在一个对所有控件完全统一的 logical-size 基准。
- 保存的 200% 在较小窗口恢复时不会自动降档。
- AUTO 必须根据宽和高共同决定；3440×1440 不应仅因宽度很大就选与 4K 相同的配置。
- DPI 可以作为推荐 scale 的输入，但不能直接替代实际可用页面尺寸。

## 9. Responsive Layout Feasibility

### 难度

> **MEDIUM**

### 当前是否已有公共 manager

没有真正的 Responsive UI Manager。

- Autoload 只有 `Game` 和 `I18n`。
- `UiNavigationState` 负责导航、折叠状态等，不适合承载 DPI/布局策略。
- `UiThemeTokens` 是静态 Token/Theme 模块，没有 profile signal。
- `Main` 和 `GameShell` 是目前最合适的统一协调入口。

### 推荐接入方式

试点阶段不建议把响应式逻辑放进 `Game` Autoload，也不必立即建立全局 Autoload。

更符合当前结构的做法：

- 一个纯 UI policy/resolver 负责计算 effective scale 和 profile。
- `Main` 持有当前 profile，并发布 `layout_profile_changed`。
- `GameShell` 提供实际中心工作区/活动页面可用 rect。
- 页面 builder 根据 profile 调整结构。
- 等出现多个独立 UI root 后，再决定是否提升为 Autoload。

### Profile 应根据什么决定

不使用：

```text
if screen_width >= 3840: EXPANDED
```

应使用：

```text
玩家偏好
+ 当前窗口可用尺寸
+ Shell/导航占用空间
+ Effective UI Scale
→ 当前页面实际 usable rect
→ logical usable width AND height
→ COMPACT / STANDARD / EXPANDED
```

因为普通 Shell 与名册当前使用不同的布局缩放曲线，初期应以活动页面实际 rect 为准；舰船名册自身使用完整 scale，适合作为第一个统一 logical-space 试点。

### Profile 可以改变什么

不必重建所有 scene。可以只改变：

- 可见性
- 列数
- stretch ratio
- max/min content width
- 卡片排列
- HBox/VBox 选择
- 是否显示扩展信息
- Preview 高度档位
- Inspector 下方 Workspace 的列数

建议行为：

| Profile | 舰船名册可能行为 |
|---|---|
| COMPACT | 上下堆叠部分信息；Lower cards 单列/两列；隐藏次要装饰；依靠 Inspector scroll |
| STANDARD | 基本保持当前 master/detail 与三张 Lower cards |
| EXPANDED | 保留当前上半结构；限制阅读列最大宽度；下方增加 Formation/Deployment 与 Supply/Loadout 工作区 |

### 是否需要每个页面重建 scene

不需要。

- 对简单变化只改 visibility、columns、size flags。
- Box 方向需要变化时，重建活动页面或局部 body。
- 不需要 reload 整个主 scene。
- Godot 支持 runtime reparent，但不建议把它作为主方案，因为容易影响 focus、选择、弹窗和滚动状态。

### Resize 现状

根节点 resize 回调 `src/ui/main.gd::_on_root_resized()` 目前只负责：

- 重新定位名册 Popup
- 更新 Scale 选项 disabled 状态
- 窄窗口时折叠右侧栏

它不会：

- 自动改变 UI Scale
- 选择布局 Profile
- 在窗口重新变宽时自动展开被折叠栏
- 调整名册列数
- 调整内容密度
- 响应 DPI/显示器变化

Godot Container 已足以自动处理：

- Expand/fill
- 锚点
- 常规 VBox/HBox 排列
- ScrollContainer
- HFlow 换行
- Preview 居中
- 自定义视觉的 resize redraw

需要主动 reflow 的部分：

- 固定三列阵位卡
- 名册 Lower 三列
- Shipyard 三栏
- Header 极窄状态
- Expanded 信息区
- 最大内容宽度
- 根据高度决定是否显示额外区块
- System Map 当前仅在构建时依据窗口高度选择 430/560 minimum，resize 后不会立即重算

## 10. Incremental Migration Feasibility

该路线现实，且符合最低风险目标。

### Phase 1：Scaling 与 Responsive 基础

- 将 AUTO 与 MANUAL 偏好分离。
- 保留玩家最后 manual 选择。
- 定义 effective scale 和实际 page usable rect。
- 引入 COMPACT/STANDARD/EXPANDED profile 与迟滞规则。
- 完善 resize、重启、切屏和多语言测试。
- 不改变视觉资产和页面业务。

### Phase 2：舰船名册试点

- 保持顶部导航、左侧列表、现有 Preview 和 Operational Status。
- 保持现有 Basic/Configuration/Readiness。
- 在右侧下方增加编队与部署、补给与载荷。
- COMPACT 时堆叠/滚动。
- STANDARD 时接近现状。
- EXPANDED 时利用下方和横向空间。
- 只读复用舰队业务状态，不复制写操作。
- “作战角色”和“单舰补给”在模型语义明确前显示缺省或明确标注为舰队共享数据。

### Phase 3：逐页接入

按风险由低到高：

1. 维修与档案、任务页面
2. 编队与补给
3. 顶部导航和普通舰船页
4. 造船与改装
5. System Map/复杂 Canvas 页面

Canvas zoom 必须继续与 UI Scale 分离。

真正的阻碍不是 UI 美术，也不是 Container 不够，而是：

- `main.gd` 集中承载过多页面
- 大量局部基础像素
- Shell 与名册存在两种缩放曲线
- 尚无 profile/usable-space 概念
- 单舰角色和单舰补给语义缺失

这些都可以逐步处理，不构成全套 UI 重写理由。

## 11. Risk Matrix

| Issue | Current Risk | Migration Risk | Notes |
|---|---|---|---|
| Theme fragmentation | MEDIUM | MEDIUM | 有统一 Token/Theme，但局部 override 数量很大 |
| Hardcoded pixel values | HIGH | MEDIUM | 约 160 个 minimum-size 引用、189 个基础字号调用、210 个 constant override |
| Absolute positioning | LOW | LOW | 主要集中在 Canvas、视觉层和 Popup；普通页面是 Container |
| Container nesting | MEDIUM | MEDIUM | Page Scroll + List Scroll + Inspector Scroll，兜底有效但要注意滚轮/焦点 |
| Localization | MEDIUM | MEDIUM | 已有中英文系统和 CJK fallback，但布局并非全部按文本自然尺寸设计 |
| Chinese / English text length | MEDIUM | MEDIUM | 英文在 1600×900@150% 已出现更多换行和 Footer 下移 |
| UI scale persistence | LOW | MEDIUM | 当前持久化有效；AUTO 后需区分 mode/manual/recommended/effective |
| Window resize | MEDIUM | MEDIUM | Containers 自动布局有效，但没有 profile reflow，Scale 不重算 |
| Ultrawide | HIGH | MEDIUM | 固定 34/64 比例、无 max width，造成超宽空洞 |
| 4K | HIGH | MEDIUM | 字体可通过 200% 改善，但高度和内容密度仍严重失衡 |
| Minimum supported resolution | MEDIUM | LOW–MEDIUM | 代码已明确 1280×720，并限制高 Scale；旧持久化 Scale 仍可能不合当前窗口 |
| ScrollContainers | MEDIUM | LOW | 能保证可达性；但需避免不必要嵌套和 Footer 长期藏在折叠下方 |
| Business state duplication | LOW | LOW | UI 基本读取 canonical state；没有独立舰队状态副本 |
| Scene coupling | HIGH | MEDIUM | `main.gd` 约 6900 行并动态创建多数页面，改动需严格限制范围 |
| Runtime reflow | MEDIUM | MEDIUM | 有少量 resize/redraw 和 sidebar collapse，无统一 profile |
| Test coverage | MEDIUM | MEDIUM | 名册几何测试较强，但其他页面、高密度语义和视觉空白未覆盖 |
| Platform DPI | HIGH | MEDIUM | 生产代码不使用 DPI；多显示器行为尚未验证 |

## 12. Estimated Change Surface

不包含工时估算。

### 仅完成 AUTO + Profile 基础 + 舰船名册试点

预计涉及：

- 生产 UI 文件：约 **4–8 个**
- Localization：**2 个 catalog**
- 测试文件：约 **3–6 个**
- 生产 Scene：**0–1 个**
- 测试 Scene：约 **1–3 个**
- 公共 UI policy/component：约 **1–3 个**

判断：

> **中等范围 UI 修改**，不是跨项目重写。

### 后续逐页接入

预计会触及：

- `main.gd` 中约 5–8 个页面 builder 区域
- `GameShell`
- `UiThemeTokens`
- 若干 Shipyard/Canvas 组件
- 对应测试

仍然不需要修改核心业务系统，除非要求新增：

- Canonical 作战角色
- 单舰补给分配
- 可配置补给来源/策略

这些属于独立的 Domain change surface，不应偷偷混入 UI 响应式改造。

## 13. Recommended Architecture

建议的数据流：

```text
窗口/活动页面实际 usable rect
+ 平台 DPI/显示器提示
+ 玩家 AUTO 或 MANUAL 偏好
            │
            ▼
Recommended Scale
            │
      Manual 可覆盖
            ▼
Effective UI Scale
            │
            ▼
Theme / Design Tokens
            │
            ▼
实际中心工作区尺寸
            │
            ▼
Logical Usable Width + Height
            │
            ▼
COMPACT / STANDARD / EXPANDED
            │
            ▼
页面 visibility / columns / arrangement / size flags
```

### AUTO Scale

- 输出推荐 Scale。
- 同时考虑宽、高、DPI 和最小可操作面积。
- 不直接决定页面布局。
- 窗口连续 resize 时使用迟滞和 debounce。

### Manual Override

- 玩家可以选择 `90/100/110/125/150/175/200%`。
- Manual 状态下不被 resize 自动覆盖。
- 应保留最后一次手动值，切回 AUTO 后仍可再次恢复。

### Logical Usable Size

- 采用活动页面在 Shell、导航和缩放生效后的实际内容 rect。
- 同时考虑 width 和 height。
- 不读取纯物理屏幕分辨率来判断布局。
- 由于当前 Shell 与名册缩放曲线不同，初期应以实测 page rect 为权威，随后逐步统一 token 语义。

### Layout Profile

- 玩家不可直接选择。
- 是纯 presentation state。
- Profile change 不得改变 Game domain state。
- 页面可以按需局部重建，不必 reload 整个场景。

### Design Tokens

在现有 `UiThemeTokens` 上逐步增加语义 Token，而不是更换美术：

- Typography roles，而不是大量散落的 13/14/15/17
- Compact/Standard/Expanded spacing
- 最小操作控件尺寸
- 最大可读内容宽度
- Master/detail 推荐比例及上下限
- Preview 高度档位
- Lower workspace 列数与间距

颜色、深色工业风、青绿色强调色、边框和现有 Panel 样式均可保持。

## 14. Go / No-Go Recommendation

结论：

> **GO WITH CONDITIONS**

当前项目适合继续做：

```text
自动 UI Scale
+
自动 Responsive Layout
+
舰船名册集成编队/补给信息
```

理由：

- 已有可用的手动 Scale、Theme 重建、偏好持久化和档位约束。
- 主要页面是 Container 驱动，不需要把 absolute UI 全部推倒。
- 舰船名册 Inspector 已经模块化为 Upper/Lower/Footer。
- 编队和舰队补给状态有清晰 canonical source。
- ScrollContainer 已覆盖低高度兜底。
- 当前视觉风格集中在 Token/StyleBox 和现有资产中，布局变化不要求换皮。

最低风险实施入口是：

1. 先明确 AUTO/MANUAL/effective scale 状态模型。
2. 以实际舰船名册内容 rect 计算第一个 Layout Profile。
3. 只让舰船名册响应 profile。
4. 在现有 `FleetRosterDetail` 下方增加只读的编队与舰队共享补给信息。
5. 不在这一阶段新增作战角色或单舰补给业务模型。
6. 用 1280×720、1600×900、2560×1440、3440×1440、3840×2160 和中英文回归。
7. 试点稳定后再逐页接入。

不建议：

- 先创建一个管理所有 UI 行为的重型全局 Autoload。
- 用 `screen_width >= 3840` 决定 Expanded。
- 用更大的 UI Scale 掩盖信息密度问题。
- 为了填空白复制 Fleet-level state 到舰船 UI。
- 因为 `main.gd` 较大就提前做全项目 UI 重构。

## 15. Questions / Unknowns

以下问题无法仅从代码确定，需要产品语义决定：

1. “当前舰船补给”应表示舰船所属编队的共享补给池，还是未来新增的单舰实际装载量？
2. “作战角色”是否要成为新的 canonical Ship/Formation assignment 字段？当前代码明确没有该属性，也不再接受从 Loadout 猜测角色。
3. AUTO Scale 的跨平台推荐标准主要基于窗口 logical size，还是还要保证特定物理字号/DPI？当前只在 macOS Retina 环境观察到 display scale；Windows 多显示器和 DPI 切换仍需目标平台验证。

---

本报告仅包含分析结论，不包含实现。
