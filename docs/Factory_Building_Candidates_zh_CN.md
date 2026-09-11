# 工业建筑候选 Demo

候选 Demo 用于逐项确认旧 Factorio 风格素材的用途和外观。用户已确认第 1 项电弧炉；其正式美术接入原生电弧熔炉和 DSP 电弧熔炉。其它四项仍待确认。外观替换不改变生产配方、占地、道路、库存或存档。

## 候选顺序

| Demo | 原素材 | 建议游戏用途 | 需要确认的部分 |
| --- | --- | --- | --- |
| 1 | Hurricane Arc Furnace | 锻炉 / 电弧熔炉 | **已确认**，接入 `grid_arc_smelter` 和 `grid_dsp_arc_smelter` |
| 2 | Hurricane Manufacturer | 自动制造机 / 装配设备 | 是否适合作为初级制造设备，还是应留给高级制造 |
| 3 | Hurricane Fuel Refinery | 炼油厂 | 塔罐轮廓、管线和现有道路工业画面的匹配 |
| 4 | Hurricane Chemical Stager | 化工厂 | 是否和炼油厂足够容易区分，以及色罩配色 |
| 5 | Hurricane Thermal Plant | 火力发电站 | 发电设施辨识度和工作动画 |

这五个候选与当前已选的 Core Extractor 同属 Hurricane 美术体系。第 2–5 项的角色匹配仍是建议，外观和正式映射继续逐项确认。既有矿机映射保持当前已批准状态。

## 查看方法

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
