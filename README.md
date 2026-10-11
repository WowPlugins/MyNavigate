# MyNavigate

从 ConsolePortLK 抽离出来的独立 UI 导航插件：用**手柄方向键**在暴雪/插件窗口中移动光标，
用 **ABXY** 执行控件动作（点击 / 右键 / 特殊点击 / 输入）。

- 不依赖 ConsolePort 的手柄驱动栈，只用 WoW 原生按键绑定
- 适用于 WLK 3.3.5（`Interface: 30300`）
- 配合安卓手柄控制器（发送 Shift1~Shift8）在 Winlator 里控制乌龟服 / WLK

## 安装

把 `MyNavigate` 整个文件夹放到：

```
Interface\AddOns\MyNavigate\
```

进入游戏后在插件列表里勾选加载，或 `/reload`。

## 按键映射

| 按键     | 功能                                        |
| -------- | ------------------------------------------- |
| Shift1   | 上                                          |
| Shift2   | 下                                          |
| Shift3   | 左                                          |
| Shift4   | 右                                          |
| Shift5   | A（左键点击）                               |
| Shift6   | B（右键点击）                               |
| Shift7   | X（左键点击）                               |
| Shift8   | Y（特殊：SpecialClick / 输入框聚焦 / 兜底左键） |

插件登录时会自动绑定并保存；首次登录会记录这些按键的原始绑定，可用 `/mynav reset` 恢复。

## 使用

1. 打开一个窗口（背包、角色、任务、商店等）
2. 屏幕上出现金色高亮环，旁边显示四个动作键当前的功能，例如 `A 拾取  B 菜单  X 拾取  Y 点击`
3. 用 Shift1~4 移动光标，Shift5~8 执行动作

**一个窗口都不开时不会高亮任何东西**——常驻 HUD（动作条、小地图、单位框体等）不在白名单里。

## 命令

| 命令                          | 说明                                                     |
| ----------------------------- | -------------------------------------------------------- |
| `/mynav on` / `off`           | 开启 / 关闭插件（关闭会解绑，原始绑定仍保留）            |
| `/mynav reset`                | 恢复插件接管前的原始按键绑定                             |
| `/mynav debug`                | 开关调试输出                                             |
| `/mynav dump [关键词]`        | 列出顶层帧（无关键词时只列屏幕上可见的），标注是否可导航 |
| `/mynav pick`                 | **鼠标选取**：点一下要加入导航的窗口，自动加入白名单     |
| `/mynav add` / `remove <帧名>`| 手动增删白名单                                           |
| `/mynav nodes`                | 打印当前扫描到的节点（名字 / 类型 / 可见 / 可绘制 / 坐标）|
| `/mynav tree <帧名>`          | 打印某个帧的子帧树                                       |

## 白名单机制

导航根节点只从「白名单窗口」里取，名单由两部分组成：

1. **内置模式**：`Core.lua` 里的 `PANEL_PATTERNS`（背包、角色、任务、商店、邮件、地图、设置、弹窗……）
2. **用户自定义**：`MyNavigateDB.extra`，通过 `/mynav pick` 或 `/mynav add` 添加，保存在存档里

这样既覆盖常见窗口，又能把你自己的插件面板一键接进来，同时避免把常驻 HUD 当成导航目标。

## 工作原理

- `Node.lua` 递归扫描根窗口下的所有子帧：
  - 可交互控件（Button / CheckButton / EditBox / Slider，或带 `OnEnter` / `OnMouseDown` 的 frame）→ 导航节点
  - 其它可见 frame → 遮挡矩形
- 扫描结束后剔除被遮挡矩形盖住的节点
- 选目标时：先按方向过滤（上下要求纵向距离大于横向，左右反之），再按「轴向拉伸后的距离」取最优；
  若找不到合适的，退化为「同方向上最近的节点」
- `Cursor.lua` 负责把金色环画到当前节点上、显示动作提示，并执行点击

## 文件结构

```
MyNavigate.toc   插件清单（加载顺序 / SavedVariables）
Bindings.xml     按键绑定声明（MYNAV_UP/DOWN/LEFT/RIGHT/A/B/X/Y）
Node.lua         节点扫描 + 方向选择算法（核心，移植自 ConsolePort）
Cursor.lua       虚拟光标：高亮环、动作提示、动作执行
Core.lua         入口：按键绑定、窗口白名单、刷新、斜杠命令
```

## 已知限制

- **按键设置（`KeyBindingFrame`）窗口无法用按键导航**：该窗口会吞掉键盘输入
  （按设计如此，它本来就是用来录按键的），所以在这个窗口里 Shift1~8 不会触发插件。
- 长列表（按键设置、任务列表等）只有**当前可见的行**在导航范围内。

## 调试

`/mynav debug` 打开后，每次刷新会打印一行：

```
MyNavigate 面板 3 节点 46 当前 AchievementFrameCategoriesContainerButton5
```

若某个窗口不响应：用 `/mynav dump` 看它在不在白名单，或用 `/mynav pick` 加进去。