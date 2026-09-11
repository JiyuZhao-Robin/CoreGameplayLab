# 工业建筑候选 Demo

候选 Demo 用于确认旧 Factorio 风格素材的用途和外观。用户已认可全部五项外观，现均已接入对应正式建筑。用户追加要求修正热能工厂的底座占地框，见下文校准记录。

## 候选顺序

| Demo | 原素材 | 建议游戏用途 | 当前状态 |
| --- | --- | --- | --- |
| 1 | Hurricane Arc Furnace | 锻炉 / 电弧熔炉 | **已确认**，接入 `grid_arc_smelter` 和 `grid_dsp_arc_smelter` |
| 2 | Hurricane Manufacturer | 自动制造机 / 装配设备 | 已接入 `grid_engineering_works`、`grid_dsp_assembling_machine_mk1/mk2/mk3` |
| 3 | Hurricane Fuel Refinery | 炼油厂 | 已接入 `grid_dsp_oil_refinery` |
| 4 | Hurricane Chemical Stager | 化工厂 | 已接入 `grid_dsp_chemical_plant`、`grid_dsp_quantum_chemical_plant` |
| 5 | Hurricane Thermal Plant | 火力发电站 | 已接入 `grid_dsp_thermal_power_plant`，底座已校准 |

这五个候选与当前已选的 Core Extractor 同属 Hurricane 美术体系。同家族各级建筑共用外观，等级与生产能力由既有名称及属性表达。

热能工厂的预览框从居中的 5×5 改为按底座定位的 5×6 格，中心位于本体帧宽度的 50%、高度的 55%。保留图片尺寸与纵横比，底座完整落在框内，烟囱顶部允许高出地面占地。运行、停机、部署预览使用同一校准，并随预览缩放同步变化。校准保存在 `candidate_stage.gd`，不改写固定来源清单或正式发电设施的碰撞/道路规则。

正式热能工厂保留原有 10×10 格占地，校准后的 5×6 地面矩形等比放入其中；制造/炼油/化工设备保留 12×10 格。完整图片依据地面锚点定位，实体、阴影、缺货幽灵、部署预览和可见图片点选共用该变换。

四套正式资源在 `assets/ui/factory/approved_industry/`，全部使用项目内固定源素材离线生成。制造、炼油、化工、热能分别为 128/64/60/80 帧，30 fps，主体最大边 256 px，工作光照已合成，阴影独立。668 个 PNG 共约 83.5 MiB，导入配置预先生成 mipmap；运行时按需加载小帧并共享缓存。满缓存约 200 MiB 的估算不替代满负载性能基准。

热能动画依据快照 `RUNNING` 与真实 `generation_kw > 0` 启停；制造/炼油/化工依据实际生产速率。缺燃料、无负荷、断电、输入不足及输出堵塞时停止对应动作并熄灯。降低动态效果、不可见对象、过期快照与可见对象预算继续限制动画。校验命令：`python tools/build_approved_industry_art.py --check`。

正式接入后主代理实际通过 `factory_approved_industry_test.gd` 的 4K 渲染、三档缩放、原始导入 mipmap、物品/建筑映射、工作动画像素、停帧熄灯、幽灵/预览和状态隔离检查；热能使用真实煤炭供电与耗尽夹具，并按正式应用流程刷新运行快照。电弧炉、矿机、DSP 图标、物品图标、工厂图层、候选 Demo、UI domain 及固定 policy/scale/window-matrix 回归均通过。实际新建筑截图位于忽略目录 `artifacts/ui/approved-industry/`。

## 查看方法

macOS 在项目根目录运行（无需 PowerShell）：

```sh
sh tools/run_building_candidates.sh
```

直接打开制造工厂使用 `sh tools/run_building_candidates.sh manufacturer`。脚本查找 PATH 中的 `godot` / `godot4` 或 `/Applications/Godot.app/Contents/MacOS/Godot`；自定义安装位置使用 `GODOT_BIN="/你的路径/Godot" sh tools/run_building_candidates.sh`。

启动脚本会先导入资源，再打开 Demo。素材原图及 `.import` 配置随 Git 上传；`.godot/imported/*.ctex` 是每台机器本地生成的缓存。首次拉取或更新素材后，直接运行场景可能报缓存缺失，请使用启动脚本或先在 Godot 编辑器中打开项目并等待导入完成。

在项目根目录运行 `tools/run_building_candidates.ps1`，或在 Godot 编辑器中打开 `src/ui/art_calibration/building_candidates/` 内的 Demo 场景并按 F6。

场景入口为 `src/ui/art_calibration/building_candidates/building_candidates.tscn`。启动脚本优先查找 PATH 中的 Godot，也支持 `-GodotPath '你的 Godot 路径'`；`-Capture` 运行真实渲染检查并生成截图。

下一项使用 `-Candidate manufacturer` 直接打开制造工厂。游戏场景命令行也支持 `--candidate=manufacturer`。

使用上一项、下一项或候选按钮逐个查看。运行、停机对照和占地预览用于判断外观；预览占地不意味着已修改正式建筑的碰撞尺寸。

所需图片、动画布局与来源证据存放在 `assets/art_calibration/building_candidates/`。正常查看 Demo 不需要本机外部素材库；重新导入工具才需要源素材路径。来源及逐文件哈希以该目录内清单为准。

## 验收边界

- 采用真实原素材与记录的动画帧布局；没有以程序几何占位物冒充候选建筑。
- 一次只加载当前候选，避免把所有大图集同时常驻。
- 正式接入前仍需按所选用途确认占地锚点、工作状态、图标、部署幽灵和运行资源预算。
- 本轮地图缩小上限和四相分流器移除独立交付，不以候选素材确认替代它们。

本次主代理实际通过项目内素材哈希校验和 `tests/building_candidates_test.gd` 的真实 4K 渲染检查：五套素材加载、每套主体动画像素变化、停机对照静止、逐项按钮/播放暂停、前一候选纹理释放、固定画布控件边界和游戏状态隔离。截图位于本地忽略目录 `artifacts/ui/building-candidates/`，未作为生产素材提交。

## 电弧炉正式接入

正式包位于 `assets/ui/factory/arc_furnace/`：50 帧、30 fps、256×256 主体与炉火合成帧，单独地面阴影。采用确认过的铜金色罩与原始图层偏移；源图和生成器哈希、派生文件哈希及许可随包保存。`python tools/build_arc_furnace_art.py --check` 仅用项目内文件校验。

原生熔炉保留 16×12 格、DSP 电弧熔炉保留 12×10 格。建造图标、成品物品、实体、缺货幽灵和部署预览共用批准外观；平面熔炉等未确认的其它设施不自动替换。运行帧按可见实体分别计时，只在实际产出状态下推进；失电、缺料或堵塞保留姿态并关闭炉火，降低动态效果、过期快照及可见对象预算继续生效。

本轮主代理实际通过：`factory_arc_furnace_test.gd` 的真实 4K 渲染、图标映射、动画/停帧、幽灵与摆放预览和状态隔离检查；`factory_core_extractor_test.gd`、`factory_dsp_art_ui_test.gd`、`location_material_art_test.gd`、`factory_visual_layers_test.gd`、`building_candidates_test.gd` 与 `ui_domain_integrity_test.tscn` 回归；正式包本地来源/派生哈希校验。物品美术测试同步为当前多图集与共享家族图标契约。实际工厂截图位于忽略目录 `artifacts/ui/arc-furnace-factory/`；其中运行/失电状态使用展示快照夹具，本轮未进行满负荷性能基准。
