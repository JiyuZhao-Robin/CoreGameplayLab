# 工业画布、地形与矿区美术重构

本轮范围：工业工作区的地形、矿区画布、建造栏和检查器。全游戏其它工作区不在本轮重构范围。用户要求完成后提交并推送当前分支。

## 参考与采用方式

| 一手参考 | 本项目采用的原则 | 未复制的内容 |
| --- | --- | --- |
| [Factorio FFF 214：Concrete rendering](https://www.factorio.com/blog/post/fff-214) | 连续的大尺度地表材质与局部细节、形状遮罩分离，减轻重复格子感 | 官方图片、引擎代码 |
| [Factorio FFF 199：Tile transitions](https://www.factorio.com/blog/post/fff-199) | 地形边缘视觉与实际可建造地块保持可理解的对应关系 | 官方岸线精灵 |
| [ResourceEntityPrototype](https://lua-api.factorio.com/latest/prototypes/ResourceEntityPrototype.html) | 矿石采用独立变体和疏密层级，可偏移视觉位置；地图颜色与近景图像分离 | 有限矿量与耗尽规则、官方矿石图 |
| [Factorio FFF 238：GUI](https://www.factorio.com/blog/post/fff-238) | 克制面板装饰、提高内容层级与可读性，将相关操作靠近被选对象 | 官方 UI 图集 |
| [FactorishWasm terrain.rs](https://github.com/msakuta/FactorishWasm/blob/c3778cd0e9b706c8dd2c785a10ac6ed70cf3d9f6/src/terrain.rs) | 逻辑地形生成与邻居相关的背景呈现分开 | Rust 实现与资源分配规则 |
| [Jactorio](https://github.com/jaihysc/Jactorio) 的 `src/game/world/world.cpp` 与 `data/base/prototypes/worldGen.py` | 地表、矿区各自独立的生成层和配置 | C++/Python 代码及其运行依赖 |

官方文档阅读时显示版本 2.1.17；仅用于结构参考，不把 Factorio 版本或参数当作本项目协议。

## 规则与呈现边界

- `FactoryTerrain.terrain_type()` 和 `field_contains()` 继续是地形语义与矿区边界的唯一权威。没有改噪声阈值、资源地理、开局安全区或已有存档占地。
- Factory v1 快照增加可选的 `terrain_seed`、`generator_version`、`terrain_scale_tiles`，补齐渲染和预放置检查需要的实际生成输入。
- 新地表渲染以世界坐标采样四张真实无缝材质；每块读取一格邻居外沿，连续过渡不依赖邻块是否已渲染。材质相位不受相机移动和 LOD 改变。
- 地表蒙版缓存最多 96 块，视口采样预算 8192 格；远景仍使用粗 LOD，不能据远景颜色决定单格可建造性。地形参数、边界、玩家 tile delta、世界变化会使缓存失效。
- 矿区近景使用透明矿簇图集，坐标和矿区 seed 确定变体与小幅偏移。疏密表示视觉分布与边缘过渡，不是新的局部矿量或品位权威。持续采矿、圆形 tile-center 覆盖和产率上限保持原合同。
- 矿区远景显示矿区地理轮廓与资源颜色，近景图集与地图标记分别处理。选中描边沿实际矿格边缘；11×11 矿机与半径 18 的圆形影响范围保留。
- 地表层位于所有道路、建筑阴影、本体、货物、幽灵及选址预览之下。矿簇的透明外缘不成为建筑碰撞范围。
- 活动建造工具优先把真实点击位置交给部署预检；浏览时，矿区透明角落可以拖动画布。矿簇网格保留到下一次 Canvas 绘制开始，避免缓存刷新后仍在使用的绘制 RID 失效。

## 美术与可重建来源

生产资源位于 `assets/ui/factory/natural/`，文件哈希、原始来源、作者、许可和烘焙参数见该目录的 `manifest.json` 与 `ATTRIBUTION.md`。

- Poly Haven / ambientCG 的 CC0 地表照片：草砾、土壤、沙地、岩面。
- CC0 `boulder_01` 原始岩石模型在项目中保留，固定相机、灯光、随机种子烘焙为铁/铜矿簇；这是本项目重材质派生。
- MIT Petraspace 冰矿图集用于冷冻、晶体类资源；变体与疏密轴明确记录为本项目导入约定。
- 本地素材索引把 FactorioPlus 矿簇标为 MIT，但上游许可不一致，因此未选用。没有使用 Wube 官方游戏 PNG。

```powershell
python tools/import_factory_natural_art.py
& D:/DevCache/helios-blender/blender-4.5.9-windows-x64/blender.exe --background --python tools/render_factory_minerals.py -- --project-root D:/Projects/standalone/core_gameplay_lab
python tools/import_factory_natural_art.py
python tests/factory_natural_assets_test.py
```

导入器读取本机参考库，运行游戏仅依赖已入库文件；Blender 重建默认读取已入库的源模型。源模型与许可证据目录带 `.gdignore`，不参与 Godot 运行时导入。

`.gitattributes` 保留带哈希清单的资产包原始字节，并固定三个生成器为 LF；Windows 的自动换行转换不会改坏来源哈希。标定与双矿机导入器也先验证全部输入与证据，来源不匹配时不会覆盖现有包。

## UI

工业页默认进入建造画布；检查器固定宽度、内部滚动；名称/状态/速率/供电优先，矿机随后显示圆形范围、覆盖、品位和持续速率，运输详情后置。底部建造栏可由玩家显式收起，建筑卡完整显示名称与库存数量。修订号进入提示，不再作为主要遥测。画布可放大到每格 16 个逻辑像素，仍是独立内容相机。

应用保持唯一 1920×1080 逻辑视口与 `canvas_items/keep`。物理窗口变化不改变面板比例、布局或展开状态。

## 验证范围

2026-09-11 主代理在本次工作区实际运行、检查退出码与日志后通过：

| 范围 | 聚焦检查 |
| --- | --- |
| 素材与重建来源 | `factory_natural_assets_test.py`（含篡改 receipt 后导入失败且目标零写入）、`factory_core_extractor_assets_test.py`、`miner_asset_contract_test.py`、`reference_mining_assets_test.py` |
| 地形与矿区规则 | `factory_terrain_test.gd`、`factory_circular_mining_test.gd`、`factory_natural_rendering_test.gd`（真实采样、存档参数往返、缓存失效、矿区孔洞与真实拖动） |
| 真实画面与动画 | 正常 OpenGL 的 `factory_natural_surface_test.gd`、`factory_visual_layers_test.gd`、`factory_core_extractor_test.gd`（运行、断电、堵塞、恢复、减弱动态、圆形范围）、`factory_road_animation_test.gd` |
| 当前玩家路径 | `factory_workspace_ui_test.gd`、`factory_landing_terrain_ui_test.gd`、`factory_building_deployment_ui_test.gd`、`factory_dsp_art_ui_test.gd`、`factory_canvas_grid_contract_test.gd` |
| 固定布局与双语 | `responsive_ui_policy_test.tscn`、`ui_scale_contract_test.tscn`、`responsive_ui_matrix_test.tscn`、`ui_domain_integrity_test.tscn`、`localization_catalog_test.tscn` |
| 状态完整性 | `asset_conservation_test.gd`、`core_integrity_test.gd` |
| 前期样本随本次入库 | 正常 OpenGL 的 `art_calibration_test.gd`、`miner_preview_test.gd`、`reference_mining_demo_test.gd`，两个标定导入器的 `--check` 与 `art_import_preflight_test.py` |

另运行真实 Main 的 `factory_visual_capture.gd`，以应用命令部署核心、两座矿机、锻炉、制造机、道路和缺货幽灵；输出七张 3840×2160 图片到忽略目录 `artifacts/ui/factory-natural-final/`。主代理查看选中矿机、圆形范围和自然地形画面，确认建筑位于矿石之上、检查器固定在右侧、建造卡完整可达。`factory_natural_surface` 的材料分区图是受控渲染夹具，`06-natural-geography.png` 才是实际星球生成结果。

子代理提供素材/界面实现与只读评审；上表检查均由主代理运行。完整发布脚本、J1–J10 旅程和满负载性能基准未运行。`factory_workspace_main_integration_test.gd` 仍测试历史手动端口，`factory_operations_ui_test.gd` 仍断言旧默认页与现场资金策略；这两项未作为当前道路/成品部署的验收，清理仍属独立未完成项。

提交前另以 Git 暂存区在系统临时目录重新检出美术包、生成器、导入器与测试，重跑五项 Python 素材/预检检查全部通过；1150 个资产及生成器的 Git blob 与工作区原始字节一致。该检查覆盖重新检出后的资源完整性，不是完整游戏导出测试。
