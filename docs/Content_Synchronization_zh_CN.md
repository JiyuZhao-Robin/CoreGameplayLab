# 内容同步状态与权威边界

> 更新：2026-09-11。本文是当前文档入口的索引，不替代代码、内容数据或一次实际测试运行。

## 如何判断一项说法

| 标签 | 含义 | 可作为什么依据 |
| --- | --- | --- |
| **已批准** | 用户已确认的产品边界 | 后续设计与实现范围 |
| **已实现** | 当前代码与内容中存在的行为 | 玩家路径与集成判断 |
| **已验证** | 主 agent 在指定时间实际运行过的聚焦检查 | 仅覆盖该检查所述场景 |
| **待设计** | 需要产品决定后才能实现 | 不是已批准的待办 |
| **历史** | 旧架构或迁移背景 | 不得作为当前功能、测试或待办依据 |

当前运行事实以 `src/`、`data/` 和被实际重跑的聚焦测试为准。历史 PASS 记录不能自动覆盖后续内容、规则或测试变更。

## 当前已批准的 Factory 契约

- 普通星球工业使用道路承载本地电力和货物；玩家不再拖拽本地 CARGO/POWER 端口，不引入铁路、区间库存或手动仓库导入导出。
- 每个 Location 持有唯一的星球库存；每种物品独立容量。仓库是道路接入和装卸点，不复制库存；机器缓存和道路在途货物另有明确保管域。
- 普通建筑先作为成品制造，再从库存部署。缺货保留幽灵；没有现场 BOM 拨料或普通建筑施工进度条。
- 新游戏由玩家选择位置部署一件星球开发核心。核心接入共享库存、提供 400 kW，并且只发放一次两矿机、两锻炉和一台自动制造机；不预放工业建筑或太阳能阵列。
- 行星画布有有限逻辑边界。Earth 为 1024×640，较大世界最高 4096×2560；地形和不规则矿区以稀疏、确定性描述生成，视口只渲染需要的区块。
- 当前矿区按持续开采速率运行。有限矿量不是已批准实现项，见下方待设计项。
- DSPONLINE 的适配仅覆盖已记录的工厂内容、道路工业和生成美术；不导入上游账号、商城、完整世界系统或完整戴森球壳几何。

Factory 的详细规则、数据契约和已记录的定向验证见[星球共享库存与道路工业](./Planetary_Industry_Roads_Design_zh_CN.md)。

## 当前范围与非范围

| 主题 | 当前结论 |
| --- | --- |
| 星系范围 | 当前产品只运行单一 `sol` 恒星系；文案中的“星际航运”指现有跨地点航运。第二恒星系/跨恒星殖民尚未获未来范围确认，不进入当前 Roadmap。 |
| 戴森球 | 已适配帆、火箭、接收站、光子与项目效果；完整球壳、帆吸收和恒星亮度系统不是本轮已批准工作。 |
| 区域蓝图 | 仍未实现。机器配方复制不是区域复制粘贴。 |
| 有限矿量 | **待设计确认。** 当前行为是持续开采；若要加入有限或高品位矿区，必须先确定软锁保护、勘测、物流重规划和性能边界。 |
| 资源地理平衡 | 当前 Earth 生成全部 15 种 DSP 原料；气态巨星额外生成氢、氘和可燃冰兼容矿区。基础/进阶/稀有资源按行星分层尚在等待用户决定，不能声称资源地理已平衡。 |
| 地形改造 | 尚未实现。 |
| 车辆表现与服务范围 | 真实道路在途货物已存在；完整搬运车/无人机美术、动作和服务范围可视化仍未完成。 |
| 大工厂性能 | 有视口裁剪、区块和 LOD 契约；尚未完成满负载性能基准。 |

## UI 与验证规则

- 生产 UI 的唯一逻辑设计视口是 **1920×1080**；3840×2160 是主要视觉验收目标。窗口只做一次等比缩放与居中留白，不能改变布局比例或内容相机。
- 每次功能变更运行受影响的标准聚焦测试；J1–J10 runtime 旅程链和完整发布脚本均为显式 opt-in，不能冒充日常功能验收。
- `tests/run_core_complete.sh` 目前不运行已退役的 Golden Path/J1–J10 runtime；README 不应再声称它验证该路径。

## 工业画布美术同步（2026-09-11）

### 相机上限、四相分流器与候选建筑（2026-09-11 追加）

- **已批准**：Factory 地图缩小到局部视野上限，避免整张星球进入同一画面；四相分流器退出当前建造与制造；旧 Factorio 风格建筑通过独立 Demo 逐项确认。
- **已实现**：四相分流器的建筑、成品及旧配方仅保留兼容身份；建造栏、配方列表和直接命令均禁止新放置/制造。旧建筑和物资可读、可拆，旧生产保留缓存并停止运行，可更换为当前配方。导入器保留稳定的美术索引并同步退休标记。
- **已验证**：主代理实际重跑 `factory_splitter_retirement`、`factory_building_deployment`、`factory_dsp_integration`、`factory_bootstrap_content`、`content_planner_contract`、`asset_conservation`、`core_integrity`，全部退出码为 0；导入器输出与 DSP 内容分片 JSON 一致。
- **已验证**：固定布局 policy、界面 scale contract、window matrix 和 UI domain 静态边界检查通过；这不替代实际地图操作、候选 Demo 画面或满负载性能验收。
- **已实现并验证**：相机可见面积上限为 8192 格，所有缩放、重置、区域聚焦、旧缩放恢复与画布尺寸变化均共用限制；保留 16 逻辑像素/格的近景上限。主代理实际通过 `factory_camera_zoom_limit`、`factory_canvas_grid_contract`、`factory_workspace_ui`、`factory_landing_terrain_ui`，并以真实 OpenGL 4K 渲染通过 `factory_visual_layers`。
- **已验证**：局部重置视图不再沿用旧全图模式暂停矿机与运输动画；`factory_road_animation` 和 `factory_core_extractor` 实机测试通过，降低动态效果、过期快照与可见对象预算仍限制动画工作。
- **已实现并验证**：五个建筑候选 Demo 共用逐项导航和运行/停机/幽灵对照。41 个原始文件（约 22 MiB）与来源、许可、哈希随项目保存，检查不依赖源素材库。主代理通过 `import_building_candidates.py --check` 与实际 OpenGL `building_candidates_test.gd`，核对五张 4K 截图、真实动画差异、停机静止、旧图集释放和经济状态隔离。
- **用户已确认**：第 1 项电弧炉用于锻炉/冶炼；原生 `grid_arc_smelter` 与 `grid_dsp_arc_smelter` 的实体、图标、成品物品及预览接入该外观。正式包按 50 帧/30 fps 离线合成，运行时只加载所需小帧并共享缓存；占地与配方保持原规则。
- **外观已认可，待正式接入**：用户查看后认可制造工厂、燃料精炼厂、化工处理站和热能工厂，并要求修正热能工厂预览底座框。该框已从居中 5×5 调整为按底座定位的 5×6，图片比例保持一致；主代理通过实际 4K 候选渲染、65%/100%/125% 缩放底座包围检查，以及 UI domain、policy、scale 和 window-matrix 回归。见[候选建筑说明](./Factory_Building_Candidates_zh_CN.md)。这四项正式建筑映射与接入尚未完成。

- **已实现**：正式 Factory 采用入库的 CC0 连续地表照片、源模型烘焙铁/铜矿簇、MIT 冰矿图集，按权威地形与矿区采样呈现；保留 11×11 Core Extractor 与半径 18 格的圆形采掘范围。源文件、生成器、许可及哈希证据均随资产保存。
- **已实现**：工业默认进入画布，采用固定宽度检查器、矿机信息优先层级和可显式收起的建造栏；活动工具取消、矿区透明角落拖动、建筑图层及画布点击已集成。
- **已验证**：主代理在本轮实际重跑素材、地形/圆形采矿、成品部署 UI、采矿/道路动画、绘制层级、固定布局/缩放/窗口矩阵与资产完整性检查，并查看真实 Main 的 4K 截图。具体命令入口、范围与限制见[工业画布美术重构](./Factory_Natural_Art_Refactor_zh_CN.md)。
- 此项不代表地形改造、资源地理平衡、完整车辆美术、区域蓝图或满负载性能基准已完成；独立待办仍见 `remaining-work.md`。

## 前次代码同步（2026-09-10）

- 中英开局引导统一为核心选址、库存建筑部署、道路连接、机器配方和建筑成品制造。引导只认本地点生产与可用 Location 库存，不叠加旧仓库私库存，也不被远端产出跳过。
- 地点库存、任务与工业面板复用已生成的核心、建筑和物品美术。未初始化地表与待部署核心是不同阶段；部署幽灵只显示缺少成品，不显示现场施工进度或 ETA。
- DSP 太阳能板加入与原生阵列相同的日照规则；退休路由器标记 `legacy_only`，移除其旧建造 BOM/工时。
- `factory_bootstrap_reachability_snapshot()` 检查真实开局核心成品、初始设备、兼容矿区、名义功率与初级配方闭包，并检查成品建筑有制造机器。它是定性检查，不能替代摆放、道路、数量与时间推进测试。旧 `bootstrap_contract` 和旧快照明确标注为历史聚合经济兼容接口，不再冒称当前开局验证。

主代理已串行运行：`factory_bootstrap_content`、`content_sync_flow`、`content_sync_ui`、`location_stock_projection`、`location_operations_workspace`、`factory_dsp_integration`、`factory_building_deployment`、`factory_building_deployment_ui`、`factory_environment_effects`、`content_planner_contract`，以及 UI policy、scale、window-matrix 和双语 catalog 检查，均通过。另核对导入器输出与 DSP shard 逐字一致。

普通脚本运行形式为 `godot --headless --path <project> --script res://tests/<name>_test.gd -- --no-persistence`；UI policy/scale/matrix/catalog 使用对应 `.tscn`。实际日志和真实 3840×2160 地点截图位于 `/tmp/helios-*`，不纳入提交。本轮未运行完整发布脚本、J1–J10 或满负载性能基准。

## 工厂画布视觉修复（2026-09-10）

- 已实现：地表和矿区先绘制，道路、建筑、在途货物和部署幽灵随后绘制，建筑/道路放置预览最后绘制；矿区不再盖住道路及有效或无效选址提示。
- 道路工业画布直接显示现有透明建筑素材，保持原图比例和颜色，去掉建筑上的信息卡与成片文字。预览携带建筑身份并显示对应图像；实际部署仍使用原始格子占地。扩大的矿机图像可优先于矿区选中，相邻建筑按统一的前后顺序绘制和选择。
- 地表使用固定世界尺度和镜像连续采样，降低底色对比；矿区在真实边界内做透明过渡，道路使用连续材质及外缘。五张现有建筑/地形/道路素材开启 mipmap；没有新生成图片，既有 PNG 和生成来源记录保持不变。
- 主代理实际串行通过：`factory_visual_layers_test`（真实 3840×2160 像素断言、矿机点击和相邻建筑重叠）、`factory_visual_capture`（当前核心开局与道路命令驱动的 Main 实机画面）、`factory_canvas_grid_contract_test`、`factory_landing_terrain_ui_test`、`factory_building_deployment_ui_test`、`factory_workspace_ui_test`、`factory_dsp_art_ui_test`、`factory_road_animation_test`、`responsive_ui_policy_test`、`ui_scale_contract_test`、`responsive_ui_matrix_test`、`ui_domain_integrity_test`。将绘制顺序临时改回旧顺序的负对照，正确检出道路和两种放置预览的三项遮挡失败；随后恢复修复并重新通过渲染测试。
- 证据在本地忽略目录 `artifacts/ui/factory-visuals/{before,after,layers}`；运行使用 `--no-persistence`，未运行完整发布检查或 J1–J10。新增截图脚本使用成品部署与道路，不复用旧端口/现场施工捕获脚本。旧 `factory_workspace_ui_test` 的三项部署断言已同步为 `DEPLOY_BUILDING` 且没有现场 funding 字段；其中其它旧连接夹具仍只是兼容测试。

## 小型美术标定场景（2026-09-10）

- 已实现独立 `art_calibration.tscn`：Hurricane/Nullius 四层真实建筑动画、Malcolm Riley 铁矿、Poly Haven 沙地和 rubberduck 烟雾，提供运行/停机/矿区放置预览与逐层、逐帧、配色、亮度、占地锚点和缩放控制。
- 选定原图与源定义实际存入 `assets/art_calibration/`，逐文件记录来源和 SHA-256，保留作者署名与许可证据；独立导入脚本可核对和重建 manifest。未修改正式 Factory 的建筑映射、占地、道路或库存。
- 主代理实际通过正常 OpenGL 4K 场景测试、导入一致性检查及 fixed-layout policy/scale/window-matrix、UI domain 检查。真实截图位于忽略目录 `artifacts/ui/art-calibration`。
- 启动、来源、当前标定参数和未覆盖范围见[美术标定说明](./Art_Calibration_zh_CN.md)。本样本不代表全游戏美术替换或完整地形素材集已完成。

## 原创矿机模型与动画样本（2026-09-11）

- 已实现原创 HELIX-01：Blender 参数化建模、实体螺旋钻头、钻架进给、液压杆与风扇动作。原生 `.blend` 和自包含 `.glb` 实际保存在 `assets/models/helix_miner/`；GLB 有 178 个网格、5 条运动通道，连续时间轴保留三个片段边界。
- Cycles 烘焙启动 24 帧、采掘循环 60 帧、停机 24 帧，均为 512×512 RGBA；另有独立静态软阴影、低透明度护板色罩和发光层。相机投影计算地面原点锚点，元数据不从透明边缘推断占地。模型生成脚本及资产哈希已记录。
- 新增独立 `miner_preview.tscn` 与 `run_miner_preview.ps1`。请求停机先完成当前采掘周期，再播放抬升；中途反向请求保留当前过渡。界面刷新帧数范围会屏蔽滑条信号，避免被误当用户拖帧。地面、矿石和烟雾沿用已署名参考资源；该矿机模型本身不复用参考建筑。
- 主代理实际通过 `miner_asset_contract_test.py`（源文件哈希、真实 GLB 网格/运动通道/片段连接）、正常 OpenGL 4K `miner_preview_test.gd`（运行、反向请求、延迟停机、静止像素、分层、锚点、固定布局和经济状态不变），以及 policy/scale/window-matrix/UI domain 检查。
- 这是单方向、独立展示的原创模型原型。Blender 程序化材质完整保留在源文件及烘焙图中，GLB 使用标准 PBR 基础值；尚未替换正式 Factory 矿机，也未宣称完成全部方向、动态阴影、LOD 或大工厂资源预算。详见[矿机资产说明](../assets/models/helix_miner/README.md)。

## 双矿机原素材 demo（2026-09-11，独立美术预览）

- 已实现：Krastorio 2 MK2 与 Hurricane Core Extractor 同窗双面板，原始 PNG 字节不变，44 个来源文件与 48 个独立图层定义保存在 `assets/art_calibration/reference_miners/`，含来源哈希、原许可元数据及实际上游参数证据。
- MK2 保留四向、主体/前景/输出/阴影与工作效果，30 张钻头原帧按 195 步源序列播放，24 步/秒；Core 采用 704²/120 帧/30 FPS、64+56 双页、独立静态阴影与发光。源像素偏移和贴图缩放独立换算。
- 启停、拖帧、倍率、图层和方向按钮在各面板独立生效；退出恢复预览进入前的 Game 模拟/持久化开关。不替换正式 Factory 矿机或改变经济状态。
- 主代理实际通过原图/哈希/UTF-8/动画帧检查、正常 OpenGL 4K 双矿机测试，覆盖按钮绑定、跨页、帧序列、平滑位移、分层、静止像素、固定窗口矩阵及退出恢复；截图在忽略目录 `artifacts/ui/reference-miners/`。
- 这是源动画的展示适配，未复刻原引擎的完整工作淡入淡出、湿式采矿或资源目标移动时序，也未验证生产级贴图预算。入口与限制见[双矿机说明](../assets/art_calibration/reference_miners/README.md)。

## Core Extractor 正式矿机接入（2026-09-11，当前追加要求）

- 用户选定第二个 Core Extractor，并追加 11×11 大型本体与圆形采掘影响范围。四种地面采掘设施共用真实原素材；新部署占地 11×11，采掘半径 18 格。圆形范围与碰撞/道路接入分开，地形、成品建筑库存及开局包规则继续生效。
- 正式资源在 `assets/ui/factory/miner/core_extractor/`：120 帧、30 FPS、独立阴影、工作发光。离线切帧与逐帧 mipmap 避免生产运行时解码完整参考图集；图标、背包物品、实体和摆放幽灵使用同一入口。
- 动画只消费快照的运行状态与实际速率，断电、输出满、无矿时停帧并熄灯；减少动态效果、总览和预算限制冻结动作。圆形采掘圈在选中或摆放时显示。
- 来源和派生处理见[正式资源署名](../assets/ui/factory/miner/core_extractor/ATTRIBUTION.md)。HELIX、化工标定和双矿机对照仍作为独立预览保留。
- 主代理本次实际串行通过：`factory_core_extractor_assets_test.py` 固定原图/派生哈希与透明通道；`factory_circular_mining_test.gd` 圆边/角排除、地理保留、真实产率封顶及旧占地保存；正常 OpenGL 4K `factory_core_extractor_test.gd` 真实部署/道路供电/断路恢复/工作像素/停帧/库存图标；`factory_visual_layers_test.gd` 矿区上方实体、幽灵、红绿预览与点选。
- 主代理本次还通过 `factory_building_deployment_test.gd` 从零原材料到制造新矿机的完整开局闭环、`factory_building_deployment_ui_test.gd`、`factory_dsp_art_ui_test.gd`、`content_sync_ui_test.gd`、`factory_workspace_ui_test.gd`、`factory_road_animation_test.gd`、资产守恒、核心完整性与内容/规划契约检查；固定 policy/scale/window-matrix、UI domain 和双语目录检查通过。未运行全发布门禁或 J1–J10。
- 运行 `tools/run_core_extractor_factory.ps1` 可打开命令驱动的正式 Main 工厂示例；`-Capture` 仅截图后退出。示例不读取/写入玩家存档，4K 证据在忽略目录 `artifacts/ui/core-extractor-live/`。
- 旧实体保留历史占地以保护已有道路；重新部署才使用 11×11。旧幽灵在实际部署时重验新占地，不能放下则继续等待。此轮不宣称完成所有建筑美术、有限矿量耗尽、重叠矿机的统一矿格速率分配或大工厂冷加载性能基准。

## 历史资料

- [1.29 Core Complete Ledger](./archive/remaining-work-1.29.md) 保留原样，记录旧聚合工业的证据，不是当前待办。
- [道路前正式设计方向归档](./archive/design-direction-before-content-sync-20260910.md) 保留原样，供追溯被道路/成品部署决策覆盖的提案。
- `Core_Gameplay_Implementation_Review_zh_CN.md` 与 `Industrial_Depth_Implementation_Plan_zh_CN.md` 已自带历史范围说明；不能作为当前 Factory 验收依据。
