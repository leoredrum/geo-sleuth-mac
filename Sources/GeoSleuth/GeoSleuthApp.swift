import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Files opened via Finder ("Open With"), Dock drops, or `open -a GeoSleuth photo.jpg`.
    static var pendingOpen: ((URL) -> Void)?
    static var queued: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let handler = Self.pendingOpen { handler(url) } else { Self.queued = url }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct GeoSleuthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("GeoSleuth", id: "main") {
            ContentView()
                .frame(minWidth: 820, minHeight: 620)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
        }
    }
}

struct SettingsView: View {
    @AppStorage("claudeCommand") private var claudeCommand = "claude"
    @AppStorage("model") private var model = ""
    @AppStorage("autoOpenMaps") private var autoOpenMaps = true

    var body: some View {
        Form {
            TextField("Claude Code 命令", text: $claudeCommand)
            TextField("模型（留空 = 默认）", text: $model)
                .help("例如 opus、sonnet，或完整模型 ID")
            Toggle("拿到坐标后自动打开 Google 地图", isOn: $autoOpenMaps)
            Text("分析任务保存在：\(AgentRunner.jobsRoot.path)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Link("定位能力来自开源项目 Oldcircle/geo-sleuth（MIT）",
                 destination: URL(string: "https://github.com/Oldcircle/geo-sleuth")!)
                .font(.caption)
        }
        .padding(20)
        .frame(width: 480)
    }
}
