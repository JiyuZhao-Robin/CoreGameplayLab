# Helios Core Gameplay Lab

这是从主项目拆出的独立 Godot 项目，也是 Walking Skeleton 的实现目标。它只保留玩法规则、内容数据、存档逻辑和纯控件操作界面，不依赖主项目中的图片、模型、Shader 或 UI Art Pack。

当前 Save Schema 为 25。旧 Lab schema 24 的全局库存会在读取时一次性迁移到 `earth_orbit` Main Base；之后只序列化 Per-Location Inventory。

## 直接启动

1. Open Godot Project Manager.
2. Click **Import**.
3. Select this repository's `project.godot`.
4. Click **Import & Edit**.
5. Press **F6** to run the open scene, or **F5** to run the project.

也可以在仓库根目录运行：

```bash
godot --path .
```

## 当前玩法流程

1. 在 **星系地图** 点击已知地点，进入 Location 的 Overview / Resources / Industry / Logistics / Projects。
2. 在 **舰队** 将已经安装采矿激光的初始勘探船调入采矿舰队。
3. 在 **前线作业** 启动近地永久采集点，并使用顶部 **10×** 或 **50×** 加速。
4. 在 **工业建设** 分选混合矿、精炼金属并组装结构框架。
5. 使用创始库存中的少量再生金属、电子元件和数据核心完成早期设施建设。
6. 建立研究中心后推进科研、造船、补给和远征。

左侧的“当前引导”会根据实时状态给出下一步。所有按钮都调用复制后的真实核心命令，不是伪流程。

## 验证

```bash
godot --headless --editor --path . --quit
godot --headless --path . --script res://tests/headless_test.gd -- --no-persistence
godot --headless --path . res://tests/playflow_test.tscn -- --no-persistence
godot --headless --path . --script res://tests/location_inventory_test.gd -- --no-persistence
godot --headless --path . res://tests/location_ui_smoke_test.tscn -- --no-persistence
```
