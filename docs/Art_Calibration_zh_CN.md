# 工业美术标定场景

2026-09-11 用户选定右侧 **Hurricane Core Extractor** 作为正式矿机外观，
并追加大型本体与圆形采掘范围要求。正式派生资源位于
`assets/ui/factory/miner/core_extractor/`，包含独立序列帧、阴影、运行发光合成帧、
固定来源哈希和生成脚本。下列独立 demo 继续保留作素材对比；生产接入状态见
[内容同步记录](./Content_Synchronization_zh_CN.md)。

正式工厂效果入口：`tools/run_core_extractor_factory.ps1`。示例通过实际部署与道路命令
搭建铁/铜矿机、锻炉和制造机，打开正式 Main 的工业画布，选中矿机显示圆形范围。
新矿机本体 11×11、采掘半径 18 格；示例禁用存档持久化。

双矿机原素材 demo 入口：`tools/run_reference_miners.ps1`。同一窗口左侧是
Krastorio 2 MK2 四向电动矿机，右侧是 Hurricane Core Extractor；两边可独立
启停、暂停、拖帧、缩放和开关图层。默认倍率分别为 200% / 85%，界面显示
当前倍率及源占地，便于观察不同分辨率的原素材。
来源、参数与限制见[双矿机素材说明](../assets/art_calibration/reference_miners/README.md)。

2026-09-11 新增原创 **HELIX-01 回转矿机**，独立入口为
`tools/run_miner_preview.ps1`。该样本包含 Blender 源模型、带动画的 GLB、
启动 24 帧／采掘 60 帧／停机 24 帧，以及独立阴影、色罩和发光贴图。
说明和源文件见[原创矿机资产包](../assets/models/helix_miner/README.md)。
下文的 Hurricane 化工设备参考场景保持独立，可继续用于比较。

本场景将参考指南中的一组真实美术导入现有 Godot 工程，用于确认图层、
锚点、占地、帧播放和缩放。它是独立预览工具，当前没有替换正式 Factory
建筑或修改生产、道路、库存、部署契约。

## 启动与操作

在项目根目录的 PowerShell 运行：

```powershell
.\tools\run_art_calibration.ps1
```

启动器先刷新 Godot 导入，再直接启动
`res://src/ui/art_calibration/art_calibration.tscn`，传入 `--no-persistence`，
不读取或写入玩家存档。场景进入时还会关闭 Game 的持久化和模拟处理；
编辑器直接 F6 会先初始化项目自动加载项，推荐使用启动器以同时跳过读档。

- 左侧依次为运行样本、静态停机对照和矿区放置预览。
- 滚轮按鼠标位置缩放，左键或中键拖动；50%–200% 按钮和重置视角可快速对照。
- 播放/暂停、逐帧滑条和单帧按钮用于检查机械动作；停机关闭主体动画、发光和烟雾。
- 主体、阴影、等级色罩、发光、烟雾、铁矿可分别开关。
- 占地与锚点开关显示 4×4 格轮廓、中心十字和主体图像范围；环境亮度与三种配色用于对照。
- 烟雾样本原图是蓝绿色，场景着色器将它去色为灰色排气；底部保留原色缩略图。

UI 使用项目唯一的 1920×1080 逻辑视口与一次 CanvasItem 等比缩放。
3840×2160 是主要验收尺寸，窗口调整不重排控制面板。这里的缩放只改变
美术内容相机，不改变全局 UI 比例。

## 资源与标定契约

| 项目 | 当前选用 |
| --- | --- |
| 建筑 | Hurricane046 chemical-stager，经 Nullius 同一版本处理的 base/shadow/mask/emission 四层 |
| 单帧定义 | 主体与发光 394×397，各 60 帧、8 列；阴影 557×431，1 帧；色罩 279×194，1 帧 |
| 世界尺寸 | 单倍内容相机每格 48 逻辑像素；默认相机 125%，每格 60 逻辑像素 |
| 占地 | 本标定样本显式设为 4×4 格，不推断或修改正式建筑占地 |
| 锚点 | 格子占地中心；每层保留源 `scale`、`shift`，一起按 fit multiplier 转换 |
| 帧率 | 主体/发光 30 fps，烟雾 18 fps；这是本项目标定选择，上游没有提供共同帧率契约 |
| 阴影与混合 | 独立阴影 40% 不透明度，主体/色罩普通透明混合，运行发光加法混合 |
| 地面 | Rob Tuytel / Poly Haven Aerial Sand 的 2K diffuse，8 格采样跨度、交替镜像、低亮度显示 |
| 铁矿 | Malcolm Riley `pile-dust-crushed-iron-ore-1.png` 原尺寸，做视觉散布对照 |
| 烟雾 | rubberduck Blueish Smoke 原始 0001–0030，128×128 独立 PNG |
| 采样 | 原始图集无新增留白；运行时按有效帧切取并分别生成 mipmap，不对整张紧密图集混采相邻帧。地面/矿石启用导入 mipmap |

图像实际进入 `assets/art_calibration/`，不依赖运行时访问 `D:/Project`。
`selection.json` 固定源文件路径和 SHA-256；`manifest.json` 是可重建的
AssetDefinition。源 Lua 仅解析数字元数据，不执行上游代码。原图不裁改，
运行时切帧不写回图片。版权署名、原文证据、版本及处理说明见
[美术来源](../assets/art_calibration/ATTRIBUTION.md)。

重新导入或核对固定来源：

```powershell
python tools/import_art_calibration.py --reference-root D:/Project
python tools/import_art_calibration.py --reference-root D:/Project --check
```

## 验证与边界

正常渲染验证和 4K 截图入口：

```powershell
.\tools\run_art_calibration.ps1 -Capture
```

截图输出到忽略目录 `artifacts/ui/art-calibration`：总览、低亮度、占地/锚点、
50% 缩放和 200% 近景。测试检查有效帧边界、独立静态层、真实图像帧变化、
停机像素稳定、图层开关、矿区预览可见、锚点随缩放一致、控件边界、窗口布局
不变，以及预览交互前后游戏经济状态不变。headless 只执行结构检查，会明确
跳过像素验收。

2026-09-10 主代理已实际串行通过正常 OpenGL 4K `art_calibration_test`、
导入器 `--check`，以及 `responsive_ui_policy_test`、`ui_scale_contract_test`、
`responsive_ui_matrix_test`、`ui_domain_integrity_test`。已查看总览与低亮度截图；
后续修改应重跑受影响检查，不沿用此记录。

此独立化工标定场景仍只有单方向建筑样本、一张重复地面和矿石图标散布。正式工业画布已另行完成[自然地表与矿区美术重构](./Factory_Natural_Art_Refactor_zh_CN.md)，不要把这里的样本限制当作生产画布现状。镜像能连接纹理边缘，
仍有可见重复图案；未提供岸线/地形过渡、真实矿床贴图、多建筑统一标定或
大工厂显存/性能验收。逐帧内存纹理适合小标定场景，批量接入正式 Factory 前
需要独立的缓存与资源预算。没有运行完整发布脚本或 J1–J10。
