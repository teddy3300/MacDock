# MacDock — macOS 原生程序坞窗口预览增强层

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14.0%2B-blue?logo=apple&style=flat-square" alt="macOS 14.0+" />
  <img src="https://img.shields.io/badge/Swift-5.9-orange?logo=swift&style=flat-square" alt="Swift 5.9" />
  <img src="https://img.shields.io/badge/Architecture-Apple%20Silicon%20%7C%20Intel-success?style=flat-square" alt="Architecture" />
  <img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="License" />
</p>

**MacDock** 是一款专为 macOS 设计的原生轻量级程序坞增强辅助工具。它在**不修改、不注入、不替换原生 Dock.app** 的前提下，为 macOS 带来了如同 Windows 任务栏般高效流畅的**鼠标悬停窗口预览**体验。

---

## ✨ 核心特性

- 🔍 **智能悬停预览**
  - 鼠标悬停在程序坞**正在运行**的应用图标上，立即在图标上方弹出浮动预览框。
  - 实时显示该应用所有有效窗口的缩略图（最多支持 5 个同时预览），最小化窗口同样保留标题与卡片。
  - 自动忽略未启动应用、右侧文件堆栈及废纸篓，避免无效干扰。

- 🖥️ **大图居中放大**
  - 鼠标移入小预览卡片时，自动在屏幕中央平滑放大为完整清晰预览，方便快速确认文档或网页细节。

- ⚡ **无缝窗口交互**
  - **点击卡片**：毫秒级激活对应窗口并将其平滑带到最前台。
  - **一键关闭**：每个窗口卡片左上角配备红色关闭按钮，通过 Accessibility API 直接关闭目标窗口，无需切换前台。

- 🎯 **像素级精确定位**
  - 优先通过 Dock Accessibility API 动态获取图标绝对位置，辅以 `com.apple.dock.plist` 实时参数回退。
  - 完美适配程序坞**放大效果（Magnification）**，对齐原生图标中心，杜绝抖动与漂移。

- 🔒 **单窗口独立截图与隐私安全**
  - 采用 ScreenCaptureKit / CGWindow 独立截取指定窗口自身画面，不捕获全屏区域，不被其他重叠窗口遮挡。
  - 原生支持画面防自回放递归。
  - **100% 本地离线运行**：零网络外联、零数据上传，绝不搜集任何用户隐私。

- 🪶 **原生性能与极低开销**
  - 纯 Swift + AppKit 原生编写，配置为 `LSUIElement` 辅助进程，不在 Dock 抢占图标。
  - 事件驱动结合 60Hz 动态节流检测，闲置时 CPU 占用几乎为 0。

---

## 💻 系统要求

- **操作系统**：macOS Sonoma 14.0 或更高版本
- **硬件架构**：Apple Silicon (M1/M2/M3/M4 系列) 及 Intel (x86_64)

---

## ⚙️ 首次运行权限授予

由于 macOS 系统的严格安全策略，应用首次启动时右上角会弹出权限指引横幅。您需要为 **MacDock** 开启两项基础系统权限：

| 权限类别 | 用途说明 | 设置路径 |
| :--- | :--- | :--- |
| **屏幕录制** *(Screen Recording)* | 单独捕获运行中窗口的内容生成缩略图 | **系统设置** → **隐私与安全性** → **屏幕录制** |
| **辅助功能** *(Accessibility)* | 获取 Dock 图标真实坐标以及执行卡片关闭窗口动作 | **系统设置** → **隐私与安全性** → **辅助功能** |

> [!TIP]
> **关于权限持久性（无需重复授权）**  
> 本项目的构建脚本默认使用本地自签名证书 `MacDock Development`。证书身份在本地唯一且固定，授权后即刻生效，**后续重新编译或重启电脑均无需再次授权**。

---

## 🚀 快速上手

### 方式一：运行打包好的应用（推荐）

如果已有发行包或本地已完成打包：

```bash
# 启动构建完成的应用
open build/MacDock.app
# 或使用启动脚本
./Scripts/run.sh
```

### 方式二：源码构建

```bash
# 1. 创建本地稳定自签名证书（仅首次需执行）
./Scripts/make_cert.sh

# 2. 编译发布版本（Release）
./Scripts/build.sh

# 如需编译调试版：
./Scripts/build.sh debug

# 3. 运行体验
./Scripts/run.sh
```

---

## 🛠️ 打包与开发者工具

### 打包正式交付文件 (DMG & ZIP)

```bash
# 自动执行构建、严格签名校验、生成 DMG 安装镜像与 ZIP 包并计算 SHA-256
./Scripts/package.sh
```
打包生成文件将存放于 `dist/` 目录下：
- `dist/MacDock-<version>-<arch>.dmg`
- `dist/MacDock-<version>-<arch>.zip`
- `dist/MacDock-<version>-<arch>.sha256`

### 诊断与自检命令

MacDock 提供了丰富的 CLI 诊断参数，便于开发与排错：

```bash
# 运行单元自检测试集
.build/debug/MacDock --run-tests

# 打印推算出的当前 Dock 几何尺寸与图标坐标
.build/debug/MacDock --dump-dock-geometry

# 诊断权限状态并测试屏幕捕获
.build/debug/MacDock --capture-test

# 列出当前窗口列表及层级信息
.build/debug/MacDock --dump-windows

# 实时查看本地诊断日志
tail -f ~/Library/Logs/MacDock.log
```

---

## 🏗️ 项目架构

```
MacDock/
├── Package.swift                    # SPM 项目配置文件 (macOS 14+)
├── Resources/
│   └── Info.plist                   # App Bundle 配置 (LSUIElement=true)
├── Scripts/
│   ├── make_cert.sh                 # 生成本地开发自签名证书
│   ├── make_icon.swift              # 动态生成应用图标集 (.iconset)
│   ├── build.sh                     # 构建并签发 .app 包
│   ├── package.sh                   # 打包 DMG、ZIP 及校验和
│   └── run.sh                       # 快速拉起已构建应用
└── Sources/MacDock/
    ├── main.swift                   # 程序入口与 CLI 诊断处理
    ├── AppDelegate.swift            # 应用生命周期管理、NSWorkspace 监听
    ├── OverlayController.swift      # 顶层统筹：协调监视器、预览面板与权限横幅
    ├── NativeDockGeometry.swift     # Dock 几何参数计算、plist 解析与回退
    ├── MouseMonitor.swift           # 鼠标轨迹轮询、悬停命中判断
    ├── Models/                      # 数据模型 (DockItem, DockState)
    ├── Preview/                     # 预览视图实现
    │   ├── SmallPreviewPanel.swift  # Dock 上方悬浮预览小面板
    │   ├── FullPreviewPanel.swift   # 居中大图全屏/大尺寸预览面板
    │   ├── WindowCardView.swift     # 单个窗口卡片（标题、红点关闭按钮、缩略图）
    │   └── PreviewController.swift  # 预览生命周期、交互与缓存调度
    ├── Capture/                     # 截图引擎
    │   ├── ScreenCapture.swift      # ScreenCaptureKit / CG 截图适配层
    │   ├── WindowEnumerator.swift   # 过滤与枚举有效窗口列表
    │   └── ThumbnailStore.swift     # 缩略图异步刷新与存储
    └── Support/                     # 底层辅助工具
        ├── DockAccessibility.swift  # 通过 Accessibility API 读取真实图标 Frame
        ├── WindowActions.swift      # 辅助功能关闭与置顶窗口实现
        ├── AppIconCache.swift       # 应用图标缓存
        └── Logger.swift             # 本地日志记录器
```

---

## ⚠️ 已知限制

1. **Dock 方向支持**：目前针对屏幕底部的 Dock 进行了精细校准，左侧与右侧 Dock 暂未完全适配。
2. **最小化与多桌面窗口**：受 macOS 系统沙盒与权限限制，位于其他 Space（虚拟桌面）或处于最小化状态的窗口，可能仅显示窗口标题卡片而无法截取即时动态内容。
3. **系统进程界限**：受 SIP（系统完整性保护）限制，预览窗口为悬浮 Overlay，无法直接嵌入原生 Dock 进程内部。

---

## 📄 开源许可证

本项目采用 [MIT 许可证](LICENSE) 开源。欢迎提交 Issue 或 Pull Request！
