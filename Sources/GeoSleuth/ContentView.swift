import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var runner = AgentRunner()
    @AppStorage("claudeCommand") private var claudeCommand = "claude"
    @AppStorage("model") private var model = ""
    @AppStorage("autoOpenMaps") private var autoOpenMaps = true

    @State private var photo: URL?
    @State private var image: NSImage?
    @State private var exifGPS: (lat: Double, lon: Double)?
    @State private var mode: AnalysisMode = .quick
    @State private var hint = ""
    @State private var loginError: String?
    @State private var dropTargeted = false
    @State private var pasteMonitor: Any?

    var body: some View {
        HStack(spacing: 0) {
            leftPanel
                .frame(width: 340)
                .padding(16)
            Divider()
            rightPanel
                .padding(16)
        }
        .onAppear {
            AppDelegate.pendingOpen = { url in load(url) }
            if let q = AppDelegate.queued { AppDelegate.queued = nil; load(q) }
            installPasteMonitor()
        }
        .onDisappear {
            if let m = pasteMonitor { NSEvent.removeMonitor(m) }
            pasteMonitor = nil
        }
        .onChange(of: runner.state) { _, newState in
            if newState == .finished, autoOpenMaps, let r = runner.result, let lat = r.lat, let lon = r.lon {
                GoogleMaps.open(lat: lat, lon: lon)
            }
        }
    }

    // MARK: - Left

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            dropZone

            HStack {
                Button { choosePhoto() } label: { Label("选择照片…", systemImage: "folder") }
                Button { pasteFromClipboard() } label: { Label("粘贴图片  ⌘V", systemImage: "doc.on.clipboard") }
            }
            .disabled(runner.state == .running)

            if let gps = exifGPS {
                VStack(alignment: .leading, spacing: 6) {
                    Label("照片自带 GPS 坐标", systemImage: "location.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Text("\(GoogleMaps.fmt(gps.lat)), \(GoogleMaps.fmt(gps.lon))")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Button("在 Google 地图中打开") { GoogleMaps.open(lat: gps.lat, lon: gps.lon) }
                        .buttonStyle(.borderedProminent)
                    Text("照片 EXIF 里已经有位置，无需 AI 分析；也可以继续用 AI 交叉验证。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else if photo != nil {
                Label("照片没有 GPS 信息，需要 AI 分析", systemImage: "location.slash")
                    .foregroundStyle(.secondary)
            }

            Picker("模式", selection: $mode) {
                ForEach(AnalysisMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .disabled(runner.state == .running)

            TextField("提示（可选），例如：应该在中国南方", text: $hint, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .disabled(runner.state == .running)

            if runner.state == .running {
                HStack {
                    ProgressView().controlSize(.small)
                    elapsed
                    Spacer()
                    Button("取消", role: .destructive) { runner.cancel() }
                }
            } else {
                Button {
                    Task { await startAnalysis() }
                } label: {
                    Label("开始 AI 定位", systemImage: "sparkle.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(photo == nil)
            }

            Spacer()
            Text("基于开源项目 geo-sleuth，由本机 Claude Code 驱动。照片会被发送给 Claude，并可能用于反向图片搜索。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                              style: StrokeStyle(lineWidth: 2, dash: image == nil ? [6] : []))
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.05)))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(6)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("拖入照片、点击选择，或 ⌘V 粘贴")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 240)
        .contentShape(Rectangle())
        .onTapGesture { if runner.state != .running { choosePhoto() } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard runner.state != .running, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { load(url) } }
            }
            return true
        }
    }

    private var elapsed: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let secs = Int(ctx.date.timeIntervalSince(runner.startedAt ?? ctx.date))
            Text(String(format: "已用时 %d:%02d", secs / 60, secs % 60))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Right

    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let loginError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(loginError)
                    Spacer()
                    if loginError.contains("登录") {
                        Button("在终端中登录") { AgentRunner.openLoginInTerminal(command: claudeCommand) }
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            if case .failed(let msg) = runner.state {
                Label(msg, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(6)
            }

            if let r = runner.result { resultCard(r) }

            HStack {
                Text("分析日志").font(.headline)
                Spacer()
                if let dir = runner.jobDir {
                    Button("打开工作目录") { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
                        .buttonStyle(.link)
                }
            }
            logView
        }
    }

    private func resultCard(_ r: GeoResult) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(r.place ?? "未知地点").font(.title2.bold())
                if let lat = r.lat, let lon = r.lon {
                    Text("\(GoogleMaps.fmt(lat)), \(GoogleMaps.fmt(lon))" + (r.radius_m.map { "  ±\(Int($0)) m" } ?? ""))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                if let c = r.confidence { Text("置信度：\(c)").foregroundStyle(.secondary) }
                if let s = r.summary { Text(s).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                if let lat = r.lat, let lon = r.lon {
                    HStack {
                        Button("在 Google 地图中打开") { GoogleMaps.open(lat: lat, lon: lon) }
                            .buttonStyle(.borderedProminent)
                        Button("卫星视图") { GoogleMaps.open(lat: lat, lon: lon, satellite: true) }
                    }
                    .padding(.top, 4)
                }
            }
            Spacer()
            if let ev = runner.evidenceImage, let img = NSImage(contentsOf: ev) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 180, maxHeight: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture { NSWorkspace.shared.open(ev) }
                    .help("证据图（点击查看大图）")
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(runner.log) { line in
                        Text(line.text)
                            .font(line.kind == .text ? .body : .system(.caption, design: .monospaced))
                            .foregroundStyle(color(for: line.kind))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
            .overlay {
                if runner.log.isEmpty {
                    Text("选好照片后点击「开始 AI 定位」").foregroundStyle(.tertiary)
                }
            }
            .onChange(of: runner.log.count) { _, _ in
                if let last = runner.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func color(for kind: LogLine.Kind) -> Color {
        switch kind {
        case .info: return .blue
        case .text: return .primary
        case .tool: return .secondary
        case .error: return .red
        }
    }

    // MARK: - Actions

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    /// ⌘V anywhere in the window pastes an image when the clipboard holds one;
    /// otherwise the key event passes through (e.g. pasting text into the hint field).
    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods == .command, event.charactersIgnoringModifiers?.lowercased() == "v",
                  runner.state != .running, ClipboardImage.available
            else { return event }
            pasteFromClipboard()
            return nil
        }
    }

    private func pasteFromClipboard() {
        guard let url = ClipboardImage.read() else { NSSound.beep(); return }
        load(url)
    }

    private func load(_ url: URL) {
        guard runner.state != .running else { return }
        guard let img = NSImage(contentsOf: url) else { return }
        photo = url
        image = img
        exifGPS = ExifGPS.read(from: url)
        if let gps = exifGPS, autoOpenMaps {
            GoogleMaps.open(lat: gps.lat, lon: gps.lon)
        }
    }

    private func startAnalysis() async {
        guard let photo else { return }
        loginError = nil
        if let err = await AgentRunner.checkLogin(command: claudeCommand) {
            loginError = err
            return
        }
        runner.start(photo: photo, mode: mode, hint: hint, command: claudeCommand, model: model)
    }
}
