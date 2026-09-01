# DSPONLINE 全量源码分析

- 分析日期：2026-09-01
- 参考仓库：`/Volumes/T9/Developer/projects/DSPONLINE`
- 固定基线：`63149cc195f6a624d264c9585899513dced5bc31`
- 目标仓库：`/Volumes/T9/Developer/projects/CoreGameplayLab`

## 结论先行

DSPONLINE 是一个以 React 19、TypeScript、Web Worker、IndexedDB、Node.js、SQLite、Electron 和 Capacitor 构成的跨端工业生产网络游戏。它真正值得 CoreGameplayLab 复用的不是 React 组件本身，而是以下设计：

1. 权威状态、只读投影、领域命令三者分离。
2. 模拟按“全局前置阶段 → 行星局部阶段 → 稳定合并 → 全局后置屏障”执行。
3. 画布拓扑、运行时数值、视觉对象和命中索引分层。
4. 大存档使用 Worker、可转移二进制、校验绑定、CAS 和单写者 fencing。
5. 离线推进先精确校准，再使用受验证的宏观合同；不可靠时保守降级。
6. 移动端用显式 route、overlay 和浏览器历史状态机，而不是把桌面布局压缩。
7. 模态框统一处理 inert、焦点循环、Escape、滚动锁和焦点归还。
8. 测试覆盖领域等价性、真实大存档、浏览器生命周期、发布和运维。

不建议复制的部分：

- `src/App.tsx` 12,698 行，聚合了运行时协调、画布交互、存档、离线、导航和大量 UI 状态。
- `src/game/engine.ts` 14,075 行，虽然规则集中且可审计，但模块职责已经过宽。
- `src/styles.css` 24,634 行，再叠加主题和专项样式后存在较高的覆盖顺序成本。
- 根组件中存在大量互斥布尔页面状态和交互瞬态。
- `src/i18n/legacyTranslations.ts` 仍保留渲染后字符串翻译兼容层。
- Web、Electron、Android、服务端和部署代码共仓，发布能力强，但认知负担很高。

## 审计规模

| 指标 | 数值 |
| --- | ---: |
| 跟踪文件 | 1,065 |
| 文本行数（不含 53 个二进制文件） | 304,977 |
| TypeScript/JavaScript 可解析代码文件 | 676 |
| 静态解析错误 | 0 |
| TypeScript/JavaScript 测试文件 / 行 | 324 / 88,333 |
| Android Java 测试文件 / 行 | 8 / 467 |
| 测试文件 / 行合计 | 332 / 88,800 |
| TypeScript/JavaScript 测试声明粗计 | 2,503 |
| `src/` 文件 / 行 | 460 / 165,939 |
| `server/` 文件 / 行 | 83 / 34,872 |
| `tests/` 文件 / 行 | 78 / 36,129 |
| `docs/` 文件 / 文本行 | 198 / 32,141 |

当前内容类型规模：78 个物品 ID、76 个科技 ID、39 个建筑 ID、80 个配方 ID、22 个行星 ID、8 个恒星系 ID、13 个成就 ID、32 个战役任务 ID。`ConstructionId` 不是独立字符串联合，而是由建筑、线路和分拣器等构造类型组合产生。

## 文档导航

- [01-system-architecture.md](./01-system-architecture.md)：启动、分层、状态权威、模块依赖、构建和测试。
- [02-gameplay-simulation.md](./02-gameplay-simulation.md)：状态模型、内容、模拟顺序、物流、电力、科研、戴森球、离线和性能。
- [03-ui-interaction.md](./03-ui-interaction.md)：桌面 Shell、画布、Inspector、工作区、移动端、模态、主题和本地化。
- [04-persistence-cloud-native-ops.md](./04-persistence-cloud-native-ops.md)：本地存档、恢复日志、云服务、SQLite、PWA、Electron、Android 和部署。
- [05-reuse-plan-for-core-gameplay-lab.md](./05-reuse-plan-for-core-gameplay-lab.md)：面向当前 Godot 项目的复用边界、映射和实施顺序。
- [06-file-and-line-audit-index.md](./06-file-and-line-audit-index.md)：全部 1,065 个文件的逐文件、逐行归属与顶层声明区间索引。

## “每个文件、每行代码”的审计口径

本次没有声称对 304,977 行文本逐行写自然语言复述。那种产物会比源码更难检索，也会迅速失效。采用的是可验证、可定位的全量审计：

- 对 Git 基线中的每一个跟踪文件建立条目。
- 记录文件类别、真实字节数和文本行数；二进制文件明确标记为不适用行号。
- 对 TypeScript、TSX、JavaScript、MJS、CJS 等可解析代码记录全部 import 和顶层声明的精确起止行。
- 对 Markdown、JSON、YAML、CSS、HTML、Shell、Java、Gradle、图片、字体和二进制文件记录用途与审计方式。
- 对高风险核心文件按连续行区间人工解释其职责、数据流、不变量和复用价值。
- 用 Git 跟踪文件集合与审计条目集合做一对一覆盖检查。

因此，任意代码行都可以先通过文件审计目录定位到所属顶层声明，再通过专题文档理解其系统语义。没有顶层声明的行属于 import、类型导出、模块初始化、注释或声明间结构区，由文件级说明覆盖。

## 事实边界

- 结论基于固定 Git 提交和仓库内源码、测试、配置及文档。
- 参考工作树已有 `LICENSE`、`NOTICE`、`README.en.md`、`README.md` 删除状态；本次未恢复、修改或依赖其工作树副本，许可信息按固定提交读取。
- 没有启动 DSPONLINE、连接生产服务、读取真实账号或玩家存档，也没有执行发布脚本。
- 仓库文档中记录的线上版本、节点和制品信息只作为实现背景；本分析不把它们当成实时运维状态。

## 许可边界

基线的包元数据和许可证声明为 PolyForm Noncommercial 1.0.0，并另有商业使用与商标文件。将 DSPONLINE 的源码、样式、文本、品牌、图标、截图或内容数据直接复制到商业项目之前，必须单独确认授权。本文建议优先复用架构思想、状态机、不变量和测试方法，在 Godot 中独立实现。
