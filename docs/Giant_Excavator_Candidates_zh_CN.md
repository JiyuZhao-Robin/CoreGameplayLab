# 巨型挖掘机素材候选

> 已暂停：用户后续要求只做纯平地与现有矿脉，暂不继续山体开挖及挖掘机选型。以下保留为历史调查，不代表已选定或接入。

调查日期：2026-09-11。用户要求非常巨大的挖掘设备，优先本地 Factorio 风格素材或网上可复用资源；明确不使用 OpenGameArt Excavator。以下是候选调查，不代表车辆或山体挖掘玩法已经接入。

## 首选外形：BigDrills / Bucket Wheel Excavators

- [官方模组页](https://mods.factorio.com/mod/BigDrills)，作者 Laserzwei；原模型归属 JorgenRe 的 [BigDrill](https://mods.factorio.com/mod/BigDrill)。包含 Bagger 258、262、288 等巨型斗轮设备。
- [官方效果图](https://assets-mod.factorio.com/assets/bbfdfbb8bce98892e19e72c59f1d45be599161e7.png)：长臂、输送机构与巨型工业体量最符合这次要求。
- 页面与官方 API 标注 MIT，但源码栏为 N/A。本次官方 ZIP 下载返回 HTTP 403，门户要求登录；没有取得完整包，不能确认其中全部美术的授权链、方向数、动画或可编辑三维源文件。
- 在 Factorio 中属于大型固定采矿设备，不能据此声称是现成可行驶车辆。即使取得美术，移动、转向、接触山体、排料与地形修改仍需本项目实现。
- 最新查得 0.6.3；API 文件名 `BigDrills_0.6.3.zip`，发布包 SHA1 `99084fa544b74f56515db6bc36c30d6da34a692e`。本地素材库没有同名素材。

## 可复用备选：Canal Excavator

- 本地预览：`D:/Project/factorio_free_graphics_for_modders/entity/Canal Excavator (MIT) - Canal Excavator - machine.png`，同目录另有三个方向。
- [正式美术仓库](https://github.com/jurgyy/Factorio-Canal-Excavator-Graphics)独立提供素材；已实际读取其 MIT LICENSE，版权所有者为 jurgyy，2024。复制时保留版权及许可文件。
- 已检查仓库树与 `animations.lua`：四方向机器、阴影、落料、石块、扬尘等独立图层。东向 `Machine.lua` 明确为 64 帧、每帧 466×368、8×8 排列；并非只有本地四张预览。
- 仓库包含 Blender 渲染工具与扬尘场景；没有在当前树中找到完整挖掘机 `.blend`，不能称为完整可编辑车辆模型。
- [玩法模组](https://mods.factorio.com/mod/canal-excavator)是 7×3 固定开渠设施。它有重型钢架和斗链外观，体量比 Bagger 288 候选小；放大静态预览不能补足细节或行驶动作。
- 本地素材索引 README 明确删去了动画、旋转、阴影、遮罩；正式采用应从上述原始美术仓库取文件。

## 仅作外形参考：Captain of Industry Bagger 288

[Bagger 288 模组](https://coigame.com/Mod/1137/Bagger-288)符合巨型斗轮车辆外形，但采用 [COI-Keep](https://coigame.com/Legal/CoI-Keep)：授权限于 Captain of Industry，不能直接移植到本项目。未复制该素材。

## 结论

BigDrills 优先作为巨型设备外形候选；Canal Excavator 是目前核实到原始动画与 MIT 文件的备选。尚未找到同时满足“巨型、可商用开放许可、完整可编辑三维源模型、行驶/挖掘动画齐备”的现成整车。树木采用 Kenney 的决定独立执行，不等待车辆选型。
