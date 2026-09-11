# 工业建筑候选 Demo

候选 Demo 用于确认旧 Factorio 风格素材的用途和外观。用户已认可全部五项外观；第 1 项电弧炉已正式接入原生电弧熔炉和 DSP 电弧熔炉，其余四项待正式接入。用户追加要求修正热能工厂的底座占地框，见下文校准记录。

## 候选顺序

| Demo | 原素材 | 建议游戏用途 | 当前状态 |
| --- | --- | --- | --- |
| 1 | Hurricane Arc Furnace | 锻炉 / 电弧熔炉 | **已确认**，接入 `grid_arc_smelter` 和 `grid_dsp_arc_smelter` |
| 2 | Hurricane Manufacturer | 自动制造机 / 装配设备 | 外观已认可，待正式接入 |
| 3 | Hurricane Fuel Refinery | 炼油厂 | 外观已认可，待正式接入 |
| 4 | Hurricane Chemical Stager | 化工厂 | 外观已认可，待正式接入 |
| 5 | Hurricane Thermal Plant | 火力发电站 | 外观已认可；预览底座框已校准，待正式接入 |

这五个候选与当前已选的 Core Extractor 同属 Hurricane 美术体系。第 2–5 项外观已获认可，具体正式建筑 ID 映射和集成验证尚未完成。既有矿机映射保持当前已批准状态。

热能工厂的预览框从居中的 5×5 改为按底座定位的 5×6 格，中心位于本体帧宽度的 50%、高度的 55%。保留图片尺寸与纵横比，底座完整落在框内，烟囱顶部允许高出地面占地。运行、停机、部署预览使用同一校准，并随预览缩放同步变化。校准保存在 `candidate_stage.gd`，不改写固定来源清单或正式发电设施的碰撞/道路规则。

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
