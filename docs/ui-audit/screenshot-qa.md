# Screenshot Matrix 与 Visual QA

审查日期：2026-08-28  
Reviewer：UI-F Visual QA  
基线截图：`artifacts/ui/inspection/megastructure_en_1920x1080.png`（文件实际为 **1728×1080**）

## 结论

最新 post-fix quick 批次 `artifacts/ui/matrix/ui-f-quick-postfix-20260828` 的 8 张图为 **TARGETED PASS / overall CONDITIONAL PASS**：此前 System Map 卡片重叠、1366 pillarbox/不可读缩放、中文 `R&D` / `MEGA` / `Phase` / task-ID 泄漏均已关闭，巨构阶段也已改为稳定的 4×2 网格。本轮在 System/Megastructure × 1920/1366 × en/zh_CN 中没有残留 P1。

整体仍保留 P2：1366 没有折叠三栏，次级字号、按钮高度和 Inspector 密度偏紧；巨构详情仍需要纵向滚动。Full 的其余九页、2560×1440 和交互态仍为 `UNVERIFIED`，不能由本次 targeted PASS 外推为全 UI 认证。

旧 `artifacts/ui/inspection/megastructure_en_1920x1080.png` 只能作为 **1728×1080 viewport crop 的历史布局样本**：其文件名错误，且底栏泄漏技术 ID，因此历史认证仍为 `FAIL / P1`，不得替代 post-fix 证据。

## 自动截图矩阵

脚本：`tools/capture_ui_matrix.ps1`

```powershell
# 8 张：System + Megastructure × 1920×1080 / 1366×768 × en / zh_CN
& 'D:\Projects\standalone\core_gameplay_lab\tools\capture_ui_matrix.ps1' -Mode quick

# 66 张：11 个公开核心页 × 3 个分辨率 × en / zh_CN
& 'D:\Projects\standalone\core_gameplay_lab\tools\capture_ui_matrix.ps1' -Mode full
```

可用 `-RunId ui-f-quick` 指定稳定且不含空格的批次名；为保留证据，脚本拒绝覆盖已有批次。每次运行输出到：

```text
artifacts/ui/matrix/<RunId>/<locale>/<resolution>/<page>.png
```

脚本固定使用 `D:\Godot\godot.exe` 和绝对 `--path D:\Projects\standalone\core_gameplay_lab`，以普通 windowed 模式启动；不使用 `--headless`。它在 Windows DPI 下强制精确 client area，保存 Godot 的真实最终 viewport，不缩放内容，再按引擎保持比例的位置补齐完整 client 边缘。每张图均等待 Godot 到达最终渲染探针并自行退出，检查退出码、`SCRIPT ERROR` / autoload 错误、黑帧颜色采样、文件存在性与 PNG 像素尺寸。`--no-persistence` 防止截图批次写入游戏存档。

项目基准 viewport 为 1440×900（16:10）。旧工作树保持比例时，Godot 的 `get_viewport().get_texture()` 在 1920×1080 窗口内只产生 1728×1080 内容图；这正是旧截图名为 1920×1080、实际却为 1728×1080 的原因。当前 `window/stretch/aspect="expand"` 已使 post-fix 批次的 viewport 与 1920×1080、1366×768 client 精确一致；矩阵仍保留 client 尺寸和 inset 检查，避免回归。

### 覆盖集合

| 维度 | Full | Quick |
| --- | --- | --- |
| 页面 | `system_map`, `location`, `industry`, `inventory`, `logistics`, `construction`, `research`, `fleet`, `frontier`, `megastructure`, `diagnostics` | `system_map`, `megastructure` |
| 分辨率 | 1920×1080, 2560×1440, 1366×768 | 1920×1080, 1366×768 |
| 语言 | `en`, `zh_CN` | `en`, `zh_CN` |
| 数量 | 66 | 8 |

`fleet` 对应公开导航 Ships，`frontier` 对应公开导航 Survey。Expedition 与 Overview 是间接页面，不属于当前 11 个公开核心导航页；若它们提升为核心导航，应同步扩展矩阵。

## 基线截图审查（实际 1728×1080）

### 信息层级 — P2 / 条件通过

- 顶栏 -> 左侧 Operations -> 中央 Megastructure -> 右侧 Context Inspector -> 底部状态条的五区结构明确。
- 白色页面标题、青色活动项/主要值、黄色 Locked、绿色 Guidance 构成可理解的视觉语义。
- 三张摘要卡先给状态、队列、阶段，再进入图形和阶段细节，阅读顺序正确。
- 风险：右侧 Inspector 的全高边框、青色大标题与 CTA 和中央主任务区接近同等权重；Locked 页仍展示大量阶段控制信息，主行动“先完成研究”没有成为唯一视觉焦点。

### 溢出与布局 — P2 / 未发现横向破坏

- 1728×1080 viewport crop 未见横向裁切、重叠或越界；顶栏动作和三栏均完整。它没有包含 1920×1080 client 的全部像素，因此不代表完整窗口通过。
- 中央 ScrollContainer 的滚动条清晰可见，底部 Phase 0 卡片只露出上缘。它属于可滚动内容而非直接覆盖，但首屏信息量已经超过一屏。
- 八阶段标签被强制铺在单行，较长英文被折成两行且列间距很小；在更窄窗口上属于高风险区。
- 单张截图无法证明滚动末端、tooltip、弹窗和长动态内容不溢出，故不标记为全面 PASS。

### 密度 — P2

- 左侧 11 项导航在 1080 高度内尚有余量，选择态明显。
- 中央同时出现锁定说明、三张统计、巨构图、八阶段刻度和阶段卡，信息重复度偏高；`Phase 0 / 0 of 8 / 0 / 8` 在同一首屏多次出现。
- 阶段标签约为正文次级字号，八列连续阅读成本高。建议在未解锁时收起详细阶段卡，或改为可聚焦的单阶段摘要 + 横向进度。

### 可读性与视觉品质 — P2

- 主标题、正文和状态值在深色背景上总体清楚；边框与背景层次克制，没有装饰资产干扰功能。
- 顶栏第二行、页面说明、图内标注和底部状态条使用低对比灰蓝；在缩放、低亮度屏幕和 1366×768 下可能不足。
- 巨构图中心、轨道与十字线过细且对比低，初始 0/8 状态可理解，但视觉信息承载有限。
- 字体与间距整体一致；英文字段大小写风格基本统一。无 hover/focus/disabled 对比截图，因此交互态保持 `UNVERIFIED`。

## 人工判定规则

每张图按以下等级记录：

- `PASS`：无裁切/重叠；主要任务、状态与 CTA 可在 3 秒内定位；正文和次级文本可读。
- `CONDITIONAL PASS`：核心操作可用，但存在密度、对比、折行或首屏层级问题，应记 P2。
- `PASS / P3`：核心视觉门禁通过，只剩不阻碍任务的对比、节奏或精修问题。
- `FAIL`：任何主要操作不可见/不可达、文本或控件互相覆盖、横向裁切、语言泄漏，或关键信息只靠颜色表达，应记 P1。
- `UNVERIFIED`：截图未覆盖的滚动末端、弹窗、hover、focus、键盘、tooltip、动态极值和 OS/DPI 行为。

Full 批次应逐图检查：顶栏动作是否完整；导航标签是否裁切；主栏是否出现横向滚动；表单/卡片是否超出可视宽度；Inspector CTA 是否可见；底栏是否只做省略而未遮挡；中英文是否泄漏；数字、单位和长 blocker 是否产生异常折行。

## Pre-fix Quick 运行记录（历史）

有效批次：`artifacts/ui/matrix/ui-f-quick-clean-20260828-v2`  
执行结果：`UI_MATRIX_PASS mode=quick ... captured=8`。8 张 PNG 均通过启动错误门禁、最终帧探针、颜色采样和精确尺寸检查。Godot 退出仍打印 `8 resources still in use`，属于当前退出清理警告；本批无 `SCRIPT ERROR` 或 autoload 错误。

渲染证据同时确认项目仍按 1440×900 的 16:10 比例适配：

- 1920×1080 client 内实际 viewport 为 1728×1080，左右各 96 px 未使用区。
- 1366×768 client 内实际 viewport 为 1228×768，左右各 69 px 未使用区。
- 因此 UI 没有利用 16:9 的全部宽度；1366 下又把三栏、字体和点击目标整体缩到约 71%，不是响应式重排。

| 证据 | 等级 | 主要发现 |
| --- | --- | --- |
| `en/1920x1080/system_map.png` | `FAIL / P1` | Lunar Space 与 Asteroid Belt 卡片/命中区重叠；底栏暴露 `assign_starter_miner`；左右 96 px 浪费。 |
| `zh_CN/1920x1080/system_map.png` | `FAIL / P1` | 同一地图卡片碰撞；顶栏泄漏 `R&D` / `MEGA`，底栏泄漏技术 ID；左右 96 px 浪费。 |
| `en/1920x1080/megastructure.png` | `CONDITIONAL PASS / P2` | 主层级清楚且无横向裁切；八阶段标签密集、弱文本偏暗、首屏内容需滚动；底栏仍有技术 ID。 |
| `zh_CN/1920x1080/megastructure.png` | `FAIL / P1` | `Phase 0`、`R&D`、`MEGA` 和任务 ID 混入中文；阶段密度与低对比问题同英文。 |
| `en/1366x768/system_map.png` | `FAIL / P1` | 地图卡片仍重叠；整体等比缩小导致正文、图例、Inspector 与导航字号过小，没有窄屏重排。 |
| `zh_CN/1366x768/system_map.png` | `FAIL / P1` | 重叠、技术词泄漏与过小文字同时存在；三栏仍固定并排。 |
| `en/1366x768/megastructure.png` | `FAIL / P1` | 八阶段文字接近不可读，详情卡首屏只露一部分；固定三栏和整体缩放压低可读性。 |
| `zh_CN/1366x768/megastructure.png` | `FAIL / P1` | 阶段标签过小、`Phase 0` 混语、详情下折并被首屏截断；无响应式替代布局。 |

### Pre-fix 跨图结论

- **层级**：1920 下 Shell、主页面和 Inspector 的主次成立；1366 下仍完整保留三栏，视觉结构没散，但所有层级一起缩小，信息优先级退化。
- **溢出**：未发现顶栏按钮、导航、Inspector 或主栏的横向裁切；中央页通过滚动容纳纵向内容。System Map 的节点卡片发生真实重叠，是当前最明确的布局 P1。
- **密度**：Megastructure 首屏重复显示 Locked、0/8、阶段 0 与完整阶段轴；1366 下八列标签密度不可接受。
- **可读性**：1920 主文本可读，弱化文本与细轨道对比仍偏低；1366 因统一缩放出现普遍小字，不能标记为通过。
- **本地化**：英文 quick 未出现 CJK，但可见原始 task ID；中文可见 `R&D`、`MEGA`、`Phase 0` 和 task ID。截图层面的中文门禁失败。
- **未验证**：Full 的其余九页、2560×1440、滚动末端、hover/focus、tooltip、Modal 和动态极值仍保持 `UNVERIFIED`。

## Post-fix Quick 复核（当前）

有效批次：`artifacts/ui/matrix/ui-f-quick-postfix-20260828`  
执行结果：`UI_MATRIX_PASS mode=quick run=ui-f-quick-postfix-20260828 captured=8`。8 张图均通过 Godot 退出码、`SCRIPT ERROR` / autoload、最终帧探针、黑帧颜色采样和精确像素尺寸门禁。Godot 仍打印已知的 `8 resources still in use` 退出清理信息，本批没有脚本或运行时错误。

最新输出的 viewport 与 client 均为精确的 1920×1080 或 1366×768，`inset=0,0`；此前左右 96/69 px pillarbox 已关闭。

| 新截图证据 | 等级 | 独立复核 |
| --- | --- | --- |
| `artifacts/ui/matrix/ui-f-quick-postfix-20260828/en/1920x1080/system_map.png` | `PASS / P3` | Lunar Space 与 Asteroid Belt 卡片间已有清晰空隙；所有节点卡无重叠。弱化节点与轨道对比仍可精修。 |
| `artifacts/ui/matrix/ui-f-quick-postfix-20260828/zh_CN/1920x1080/system_map.png` | `PASS / P3` | 卡片无重叠；顶栏已使用“科研/巨构”，底栏为完整中文任务句，不再出现 task ID。 |
| `artifacts/ui/matrix/ui-f-quick-postfix-20260828/en/1920x1080/megastructure.png` | `PASS / P3` | 阶段 0–3 / 4–7 组成清晰 4×2 网格，无挤压或覆盖；Locked、0/8、阶段 0 信息略重复。 |
| `artifacts/ui/matrix/ui-f-quick-postfix-20260828/zh_CN/1920x1080/megastructure.png` | `PASS / P3` | “阶段 0”已完全中文化；4×2 网格与标题、图形和详情卡层级稳定。 |
| `artifacts/ui/matrix/ui-f-quick-postfix-20260828/en/1366x768/system_map.png` | `CONDITIONAL PASS / P2` | viewport 使用全部宽度，地图节点不重叠，Header/Inspector/CTA 均完整；三栏仍固定，次级文字和按钮高度偏紧。 |
| `artifacts/ui/matrix/ui-f-quick-postfix-20260828/zh_CN/1366x768/system_map.png` | `CONDITIONAL PASS / P2` | 中文无技术词泄漏且卡片无碰撞；小字号 Legend、底栏和 Inspector 正文仍需要可读性余量。 |
| `artifacts/ui/matrix/ui-f-quick-postfix-20260828/en/1366x768/megastructure.png` | `CONDITIONAL PASS / P2` | 4×2 阶段网格完整可辨，优于旧八列；详情卡落在首屏下方，需要滚动，阶段次级字号偏小。 |
| `artifacts/ui/matrix/ui-f-quick-postfix-20260828/zh_CN/1366x768/megastructure.png` | `CONDITIONAL PASS / P2` | “阶段 0”与全部八阶段中文标签完整，无横向裁切；固定三栏下主栏纵向密度仍高。 |

### 指定 P1 关闭状态

| 复核项 | 当前状态 | 证据结论 |
| --- | --- | --- |
| System Map 卡片重叠 | `PASS` | 四张 System Map 中 Lunar/Asteroid 及其他节点卡均有可见间距，命中区不再相交。 |
| 1366 响应式布局 | `P1 CLOSED / P2 REMAINS` | viewport 已扩展到 1366×768，无 pillarbox、横向裁切或卡片碰撞；固定三栏、小字号/小目标仍需后续 breakpoint 或尺寸优化。 |
| zh_CN `R&D` / `MEGA` / `Phase` / task ID | `PASS` | 新中文截图分别显示“科研”“巨构”“阶段 0”和完整任务句；只保留合理的语言切换标签 `EN / 中文`。 |
| 巨构 4×2 阶段网格 | `PASS` | 双语、双分辨率均为第一行 0–3、第二行 4–7；无文字或卡片互相覆盖。 |

### 当前分级汇总

- **P1：0（在 quick 覆盖内）**。
- **P2：1366 固定三栏、次级字号/按钮尺寸偏紧；巨构详情首屏下折，需要滚动。**
- **P3：弱化文本与细轨道对比偏低；Locked / 0 of 8 / stage 0 的信息重复；英文顶栏长状态偶有换行。**
- **PASS：地图卡片碰撞、16:9 viewport、中文技术词/task-ID 泄漏、巨构 4×2 阶段网格。**
- **UNVERIFIED：其余九个核心页、2560×1440、滚动末端、hover/focus/tooltip/Modal、长动态极值与 OS/DPI 组合。**
