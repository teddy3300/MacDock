import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "常规"
    case trigger = "触发"
    case appearance = "外观"
    case advanced = "高级"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .general: return "gearshape"
        case .trigger: return "cursorarrow.rays"
        case .appearance: return "paintpalette"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var selectedTab: SettingsTab = .general
    @State private var showingResetAlert = false

    var body: some View {
        VStack(spacing: 0) {
            // Tab Header
            HStack(spacing: 12) {
                ForEach(SettingsTab.allCases) { tab in
                    Button(action: { selectedTab = tab }) {
                        VStack(spacing: 4) {
                            Image(systemName: tab.iconName)
                                .font(.system(size: 16, weight: selectedTab == tab ? .semibold : .regular))
                            Text(tab.rawValue)
                                .font(.system(size: 12, weight: selectedTab == tab ? .medium : .regular))
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Tab Content
            ScrollView(.vertical, showsIndicators: true) {
                Group {
                    switch selectedTab {
                    case .general:
                        GeneralSettingsView(settings: settings)
                    case .trigger:
                        TriggerSettingsView(settings: settings)
                    case .appearance:
                        AppearanceSettingsView(settings: settings)
                    case .advanced:
                        AdvancedSettingsView(settings: settings)
                    }
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Footer Bar
            HStack {
                Button("恢复默认设置") {
                    showingResetAlert = true
                }
                .buttonStyle(.link)
                .foregroundColor(.secondary)
                .font(.caption)

                Spacer()

                Text("MacDock 1.0.0")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        }
        .frame(width: 530, height: 510)
        .alert("确定要恢复默认设置吗？", isPresented: $showingResetAlert) {
            Button("取消", role: .cancel) {}
            Button("恢复默认", role: .destructive) {
                settings.resetToDefaults()
            }
        } message: {
            Text("所有选项（包括延迟、尺寸、排除列表）都将恢复为初始默认值。")
        }
    }
}

// MARK: - General Tab

struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var showingAddSheet = false
    @State private var selectedExcludedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Section 1: System Integration
            VStack(alignment: .leading, spacing: 10) {
                Text("系统集成")
                    .font(.headline)

                Toggle("开机自动启动", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                ))

                Toggle("在菜单栏显示状态图标", isOn: $settings.showMenuBarIcon)
                Text("建议开启，方便随时从右上角暂停预览、配置偏好或退出应用。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Section 2: Close Behavior
            VStack(alignment: .leading, spacing: 10) {
                Text("单窗口关闭行为")
                    .font(.headline)

                Picker("当关闭唯一窗口时：", selection: $settings.closeLastWindowQuitsApp) {
                    Text("仅关闭窗口（保持应用后台常驻）").tag(false)
                    Text("彻底退出该应用程序 (Quit)").tag(true)
                }
                .pickerStyle(.radioGroup)

                Text("选择仅关闭窗口可避免误关音乐播放器、微信或浏览器等需要后台运行的应用。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Section 3: Excluded Apps
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("应用黑名单（不触发悬停预览）")
                        .font(.headline)
                    Spacer()
                    Button("+ 添加") {
                        showingAddSheet = true
                    }
                    Button("- 移除") {
                        if let sel = selectedExcludedID {
                            settings.unexclude(bundleID: sel)
                            selectedExcludedID = nil
                        }
                    }
                    .disabled(selectedExcludedID == nil)
                }

                if settings.excludedBundleIDs.isEmpty {
                    Text("当前未排除任何应用。你可以将密码管理器、全屏游戏等加入黑名单。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 16)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                        .cornerRadius(6)
                } else {
                    List(settings.excludedBundleIDs, id: \.self, selection: $selectedExcludedID) { bid in
                        HStack(spacing: 8) {
                            if let icon = AppCatalog.icon(bundleID: bid) {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 20, height: 20)
                            } else {
                                Image(systemName: "app")
                                    .frame(width: 20, height: 20)
                            }
                            Text(AppCatalog.name(bundleID: bid))
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text(bid)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(height: 110)
                    .cornerRadius(6)
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddExcludedAppSheet(isPresented: $showingAddSheet, settings: settings)
        }
    }
}

struct AddExcludedAppSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var settings: AppSettings
    @State private var runningApps: [NSRunningApplication] = []

    var body: some View {
        VStack(spacing: 16) {
            Text("选择要排除的应用程序")
                .font(.headline)

            List(runningApps, id: \.processIdentifier) { app in
                if let bid = app.bundleIdentifier {
                    HStack {
                        if let icon = app.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 24, height: 24)
                        }
                        VStack(alignment: .leading) {
                            Text(app.localizedName ?? bid)
                                .font(.system(size: 13, weight: .medium))
                            Text(bid)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("排除") {
                            settings.exclude(bundleID: bid)
                            isPresented = false
                        }
                        .disabled(settings.isExcluded(bundleID: bid))
                    }
                }
            }
            .frame(width: 380, height: 260)

            HStack {
                Button("从访达选择...") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.application]
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        if let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier {
                            settings.exclude(bundleID: bid)
                        }
                    }
                    isPresented = false
                }

                Spacer()

                Button("取消") {
                    isPresented = false
                }
            }
        }
        .padding(20)
        .onAppear {
            runningApps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
                .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        }
    }
}

// MARK: - Trigger Tab

struct TriggerSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Section 1: Hover Delay
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("悬停触发延迟")
                        .font(.headline)
                    Spacer()
                    Text("\(Int(settings.hoverDelay * 1000)) 毫秒")
                        .foregroundColor(.accentColor)
                        .fontWeight(.semibold)
                }

                Slider(value: $settings.hoverDelay, in: 0.05...0.80, step: 0.05)

                Text("鼠标停留在 Dock 图标上达到此时间后才弹出小预览。数值越大越能防止划过 Dock 时的误触。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Section 2: Dismiss Delay
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("离开消失延迟")
                        .font(.headline)
                    Spacer()
                    Text("\(Int(settings.dismissDelay * 1000)) 毫秒")
                        .foregroundColor(.accentColor)
                        .fontWeight(.semibold)
                }

                Slider(value: $settings.dismissDelay, in: 0.10...1.00, step: 0.05)

                Text("鼠标离开 Dock 图标或预览面板后关闭的缓冲时间。增加此数值可让您更从容地将鼠标移入卡片进行操作。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Section 3: Full Preview
            VStack(alignment: .leading, spacing: 10) {
                Text("二级大屏完整预览")
                    .font(.headline)

                Toggle("启用移入卡片时的大屏完整预览", isOn: $settings.enableFullPreview)

                Toggle("仅在按住 Option 键悬停卡片时展开大屏预览", isOn: $settings.requireOptionForFullPreview)
                    .disabled(!settings.enableFullPreview)
                    .padding(.leading, 20)

                Toggle("启用实时动态画面流 (GPU 硬件加速)", isOn: $settings.enableLiveStreamPreview)
                    .disabled(!settings.enableFullPreview)
                    .padding(.leading, 20)

                if settings.enableFullPreview && settings.enableLiveStreamPreview {
                    Picker("实时流目标帧率：", selection: $settings.liveStreamFPS) {
                        Text("15 FPS (极低功耗)").tag(15)
                        Text("30 FPS (平衡流畅，推荐)").tag(30)
                        Text("60 FPS (极致顺滑)").tag(60)
                    }
                    .pickerStyle(.menu)
                    .padding(.leading, 20)
                }

                Text("大屏预览会在屏幕中央显示当前窗口。开启实时动态画面流后，大屏预览将像画中画一样实时播放正在运行的窗口视频或动态。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Section 4: Middle Click Action
            VStack(alignment: .leading, spacing: 10) {
                Text("鼠标中键点击预览卡片")
                    .font(.headline)

                Picker("", selection: $settings.middleClickAction) {
                    ForEach(MiddleClickAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }
}

// MARK: - Appearance Tab

struct AppearanceSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Section 1: Card Size
            VStack(alignment: .leading, spacing: 10) {
                Text("小预览缩略图尺寸")
                    .font(.headline)

                Picker("卡片高度：", selection: $settings.cardHeight) {
                    Text("紧凑 (80 pt)").tag(CGFloat(80))
                    Text("标准 (110 pt)").tag(CGFloat(110))
                    Text("宽大 (140 pt)").tag(CGFloat(140))
                }
                .pickerStyle(.segmented)

                Text("调整一级预览小窗口在 Dock 上方的卡片缩略图显示尺寸。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Section 2: Display Elements
            VStack(alignment: .leading, spacing: 10) {
                Text("卡片展示元素")
                    .font(.headline)

                Toggle("显示窗口标题栏", isOn: $settings.showWindowTitle)

                Toggle("显示卡片关闭按钮 (✕)", isOn: $settings.showCloseButton)

                Toggle("解析并显示 Google Chrome 多账号 Profile 身份标签", isOn: $settings.showChromeProfile)
                Text("支持智能识别多 Chrome 用户标签（例如“工作”、“个人”），方便快速区分同名窗口。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Advanced Tab

struct AdvancedSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var screenRecordingAuthorized = ScreenCapture.isAuthorized
    @State private var accessibilityTrusted = WindowActions.isTrusted
    @State private var cacheCount = 0
    @State private var cacheBytes = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Section 1: Windows
            VStack(alignment: .leading, spacing: 10) {
                Text("窗口过滤")
                    .font(.headline)

                Toggle("在预览中包含已最小化的窗口", isOn: $settings.includeMinimizedWindows)
                Text("关闭后仅展示当前屏幕上实际可见的窗口。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Section 2: Permissions
            VStack(alignment: .leading, spacing: 12) {
                Text("系统权限检测")
                    .font(.headline)

                HStack {
                    Image(systemName: screenRecordingAuthorized ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(screenRecordingAuthorized ? .green : .red)
                    VStack(alignment: .leading) {
                        Text("屏幕录制权限")
                            .font(.system(size: 13, weight: .medium))
                        Text(screenRecordingAuthorized ? "已授权，可截取窗口预览" : "未授权，无法获取窗口实时图像")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if !screenRecordingAuthorized {
                        Button("去授权") {
                            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                            NSWorkspace.shared.open(url)
                        }
                    }
                }

                HStack {
                    Image(systemName: accessibilityTrusted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(accessibilityTrusted ? .green : .red)
                    VStack(alignment: .leading) {
                        Text("辅助功能权限")
                            .font(.system(size: 13, weight: .medium))
                        Text(accessibilityTrusted ? "已授权，可精准识别并控制窗口关闭/置顶" : "未授权，无法定位窗口及执行控制")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if !accessibilityTrusted {
                        Button("去授权") {
                            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }

            Divider()

            // Section 3: Thumbnail Cache
            VStack(alignment: .leading, spacing: 10) {
                Text("缩略图磁盘缓存")
                    .font(.headline)

                HStack {
                    Text("当前缓存：\(cacheCount) 个文件 (\(formatBytes(cacheBytes)))")
                        .font(.system(size: 13))
                    Spacer()
                    Button("清理缓存") {
                        ThumbnailStore.shared.clearAll {
                            refreshCacheInfo()
                        }
                    }
                }

                Text("用于最小化及切后台窗口的快速预览展示。占用空间超过 80MB 时会自动轮转修剪。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            screenRecordingAuthorized = ScreenCapture.isAuthorized
            accessibilityTrusted = WindowActions.isTrusted
            refreshCacheInfo()
        }
    }

    private func refreshCacheInfo() {
        ThumbnailStore.shared.cacheInfo { count, bytes in
            self.cacheCount = count
            self.cacheBytes = bytes
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB, .useBytes]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
