# MacDock — 原生程序坞增强层

原生 Swift / AppKit 辅助应用，**不改动、不替换原生程序坞**，提供 Windows 风格的悬停窗口预览：

1. **悬停预览（仅已打开的程序）**
   - 鼠标移到**原生程序坞**上**已运行**的应用图标 → 图标上方弹出小预览框，
     显示该应用的有效窗口（最多 5 个），实时刷新；最小化窗口也保留标题卡片。
   - 窗口卡片左上角有红色关闭按钮；点击卡片 → 激活并把该窗口带到前台。
   - 鼠标移入小预览框 → 在屏幕中央放大为完整预览。
   - **未打开的应用 / 右侧文件夹堆栈 / 废纸篓：一律不处理。**

## 对齐跟踪

- 图标位置优先从 Dock Accessibility 实时读取，每 0.25 秒刷新；权限不可用时才回退到 `com.apple.dock.plist` 估算。
- 悬停时若原生程序坞弹出自己的预览窗口，本应用会**以它的中心为准**对齐锚点，
  因此开启程序坞放大效果(magnification)时也能跟随图标实际位置。

## 针对应用窗口截图（非全屏）

- 每个窗口用 `CGWindowListCreateImage` **单独截取该窗口自身内容**，不是截屏幕区域。
- 因此：预览显示的是**这个应用**的窗口（不被其它窗口遮挡的内容干扰），
  也天然**不会包含我们自己的预览面板**（无无限回放）。

## 对齐

- 面板锚定在**推算出的图标位置正上方**，位置固定不跳动（不做基于原生预览的 Y 轴漂移）。
- 已用原生程序坞预览窗口中心验证：`est=824 native=824 diff=0`。

## 原理（为什么是叠加层）

- 原生程序坞（Dock.app）是受 SIP 保护的系统进程，没有任何公开 API 能向它内部添加 UI。
- 本应用优先读取 Dock Accessibility 的真实图标 frame，同时读取 `persistent-apps` 和 `persistent-others` 保持应用/文件夹布局；
  用定时轮询 `NSEvent.mouseLocation`（无需权限）判断鼠标悬停在哪个应用图标上，
  再弹出我们自己的预览窗口。
- 截图使用 ScreenCaptureKit/兼容回退；关闭窗口使用辅助功能 API 的目标窗口关闭按钮。

## 构建与运行

```bash
# 1. 创建稳定签名证书（仅首次；本机已完成）
Scripts/make_cert.sh

# 2. 构建成 .app（自签名，TCC 授权跨重建保持）
Scripts/build.sh          # release
Scripts/build.sh debug    # 调试版

# 3. 启动
Scripts/run.sh            # open build/MacDock.app

# 4. 打包正式交付文件
Scripts/package.sh        # 输出 DMG、ZIP 和 SHA-256 到 dist/

# 单元自检
.build/debug/MacDock --run-tests

# 调试辅助
.build/debug/MacDock --dump-dock-geometry   # 打印推算出的程序坞图标位置
.build/debug/MacDock --capture-test         # 检测权限 + 截全屏到 /tmp
.build/debug/MacDock --dump-windows         # 打印窗口列表

# 日志
tail -f ~/Library/Logs/MacDock.log
```

> 请通过 `Scripts/run.sh` 或 `open build/MacDock.app` 运行。
> 不要用裸二进制跑正式使用——权限归属会变成终端。

## 首次使用需要授权（一次性）

启动后右上角出现权限横幅，点「去设置」：

| 权限 | 用途 | 系统设置位置 |
| --- | --- | --- |
| 屏幕录制 | 截取窗口内容用于预览 | 系统设置 → 隐私与安全性 → 屏幕录制 |
| 辅助功能 | 关闭窗口（AX 关闭按钮） | 系统设置 → 隐私与安全性 → 辅助功能 |

**关于签名**：应用使用自签名证书 `MacDock Development` 签名，签名身份固定，
因此这两项权限**只需授予一次**，之后重建/重启都保持有效。
（之前用 ad-hoc 签名时每次重建身份都会变，导致权限反复失效。）

## 使用说明

- **悬停已运行的应用图标**：显示该应用的有效窗口；移入小预览 → 大屏完整预览。
- **卡片左上角红色关闭按钮**：关闭对应预览窗口。
- **点击卡片**：激活该窗口并把窗口带到前台。

## 已知限制

1. Dock Accessibility 不可用时会回退到估算位置；底部 Dock 支持最好，侧边/顶部 Dock 仍不支持。
2. 预览窗口渲染在程序坞上方（无法真正画进原生程序坞内部）。
3. 最小化窗口可以显示标题卡片，但系统可能无法提供可用截图；其他桌面（Space）的窗口显示能力取决于系统权限。

## 项目结构

```
Sources/MacDock/
├── main.swift              # 入口 + CLI 自检/调试参数
├── AppDelegate.swift       # 生命周期、工作区监听
├── OverlayController.swift # 统筹：鼠标监视、预览、权限横幅
├── NativeDockGeometry.swift# Dock 图标实时 frame + plist 回退
├── MouseMonitor.swift      # 60Hz 轮询鼠标，判定悬停图标
├── Support/DockAccessibility.swift # 读取 Dock 实时图标和文件夹 frame
├── Models/DockState.swift  # 运行中应用快照
├── Preview/                # 小预览/大预览面板 + PreviewController
├── Capture/                # 窗口枚举 + ScreenCaptureKit 截图
└── Support/                # AX 关闭窗口、图标缓存、日志等
```
