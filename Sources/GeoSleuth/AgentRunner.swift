import AppKit
import Foundation

struct LogLine: Identifiable, Equatable {
    enum Kind { case info, text, tool, error }
    let id = UUID()
    let kind: Kind
    let text: String
}

/// Runs the geo-sleuth skill through a headless Claude Code (`claude -p`) session
/// and turns its stream-json output into log lines and a final GeoResult.
@MainActor
final class AgentRunner: ObservableObject {
    enum State: Equatable {
        case idle, running, finished, failed(String), cancelled
    }

    @Published var state: State = .idle
    @Published var log: [LogLine] = []
    @Published var result: GeoResult?
    @Published var jobDir: URL?
    @Published var evidenceImage: URL?
    @Published var startedAt: Date?

    private var process: Process?
    private var buffer = Data()
    private var assistantText = ""
    private var finalText = ""

    nonisolated static let resultMarker = "GEO_RESULT:"

    // MARK: - Shell helpers

    /// Builds a Process that runs `<claudeCommand> args...` through a login shell, so
    /// the user's PATH (uv, claude, homebrew) is available even when launched from Finder.
    nonisolated static func shellProcess(command: String, args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "exec \(command) \"$@\"", "zsh"] + args
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("CLAUDECODE") || key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CLAUDE_AGENT_SDK") {
            env.removeValue(forKey: key)
        }
        let home = NSHomeDirectory()
        let extra = ["\(home)/.local/bin", "\(home)/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        p.environment = env
        return p
    }

    /// Returns nil when logged in, or an error message otherwise.
    static func checkLogin(command: String) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = shellProcess(command: command, args: ["auth", "status"])
                let out = Pipe()
                p.standardOutput = out
                p.standardError = out
                do { try p.run() } catch {
                    cont.resume(returning: "无法启动 \(command)：\(error.localizedDescription)")
                    return
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? ""
                if p.terminationStatus == 127 || text.contains("command not found") {
                    cont.resume(returning: "找不到 Claude Code 命令行（\(command)）。请先安装：npm install -g @anthropic-ai/claude-code")
                    return
                }
                if let start = text.firstIndex(of: "{"),
                   let obj = try? JSONSerialization.jsonObject(with: Data(text[start...].utf8)) as? [String: Any],
                   let logged = obj["loggedIn"] as? Bool {
                    cont.resume(returning: logged ? nil : "Claude Code 命令行尚未登录。")
                    return
                }
                // Unknown output format: assume OK and let the run report errors.
                cont.resume(returning: nil)
            }
        }
    }

    static func openLoginInTerminal(command: String) {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("geosleuth-login.command")
        let body = """
        #!/bin/zsh -l
        export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
        echo "登录 Claude Code，完成后回到 GeoSleuth 重新开始分析。"
        \(command) auth login
        """
        try? body.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }

    // MARK: - Job setup

    static var skillSource: URL? {
        if let res = Bundle.main.resourceURL?.appendingPathComponent("geo-sleuth"),
           FileManager.default.fileExists(atPath: res.appendingPathComponent("SKILL.md").path) {
            return res
        }
        if let env = ProcessInfo.processInfo.environment["GEO_SLEUTH_SKILL"] {
            return URL(fileURLWithPath: env)
        }
        return nil
    }

    nonisolated static var jobsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GeoSleuth/jobs", isDirectory: true)
    }

    private func prepareJob(photo: URL) throws -> (dir: URL, photoName: String) {
        let fm = FileManager.default
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let dir = Self.jobsRoot.appendingPathComponent(stamp.string(from: Date()), isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let ext = photo.pathExtension.isEmpty ? "jpg" : photo.pathExtension.lowercased()
        let photoName = "photo.\(ext)"
        try fm.copyItem(at: photo, to: dir.appendingPathComponent(photoName))

        guard let skill = Self.skillSource else {
            throw NSError(domain: "GeoSleuth", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到内置的 geo-sleuth skill 资源。"])
        }
        let skillsDir = dir.appendingPathComponent(".claude/skills", isDirectory: true)
        try fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        try fm.copyItem(at: skill, to: skillsDir.appendingPathComponent("geo-sleuth"))
        return (dir, photoName)
    }

    private func prompt(photoName: String, mode: AnalysisMode, hint: String) -> String {
        let budget: String
        switch mode {
        case .quick:
            budget = """
            Time budget: about 10 minutes. Run intake.py (metadata, OCR, reverse image search) and use your own visual judgment; \
            skip expensive scans (terrain scan, sat_scan grid, large street-view batches). A city- or area-level answer is acceptable.
            """
        case .deep:
            budget = """
            Time budget: up to about 90 minutes. Follow the full geo-sleuth flow and narrow down as far as the evidence supports.
            """
        }
        let hintLine = hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "" : "\nHint from the user (treat it as a hypothesis, the image wins): \(hint)\n"
        return """
        Use the geo-sleuth skill to find where the photo ./\(photoName) (in the current directory) was taken.
        This is my own photo, used for personal purposes, so don't ask about its source. You are running non-interactively: \
        never wait for user input.
        \(budget)
        \(hintLine)
        Write the final report in Chinese (简体中文).

        When you are done, do BOTH of the following, even if you could only narrow it down to a region:
        1. Write ./geo_result.json with exactly this shape (WGS84 coordinates of the most likely camera position, \
        or the centre of the most likely region):
           {"lat": 0.0, "lon": 0.0, "radius_m": 0, "place": "地名（中文）", "confidence": "高/中/低", "summary": "一两句话的结论"}
        2. Print the same JSON on the very last line of your reply, prefixed with \(Self.resultMarker)
        If you cannot determine any location at all, use null for lat and lon.
        """
    }

    // MARK: - Run

    func start(photo: URL, mode: AnalysisMode, hint: String, command: String, model: String) {
        guard state != .running else { return }
        log = []
        result = nil
        evidenceImage = nil
        assistantText = ""
        finalText = ""
        buffer = Data()

        let job: (dir: URL, photoName: String)
        do { job = try prepareJob(photo: photo) } catch {
            state = .failed(error.localizedDescription)
            return
        }
        jobDir = job.dir
        append(.info, "工作目录：\(job.dir.path)")

        var args = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--allowedTools", "Bash", "Read", "Write", "Edit", "Glob", "Grep", "WebFetch", "WebSearch", "Skill", "Task", "TodoWrite",
            "--disallowedTools", "AskUserQuestion",
        ]
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        if !trimmedModel.isEmpty { args += ["--model", trimmedModel] }

        let p = Self.shellProcess(command: command, args: args)
        p.currentDirectoryURL = job.dir
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                for line in s.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    self?.append(.error, String(line))
                }
            }
        }
        p.terminationHandler = { [weak self] proc in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            let rest = stdout.fileHandleForReading.readDataToEndOfFile()
            Task { @MainActor in
                if !rest.isEmpty { self?.consume(rest) }
                self?.finish(status: proc.terminationStatus)
            }
        }

        do {
            try p.run()
        } catch {
            state = .failed("无法启动 Claude Code：\(error.localizedDescription)")
            return
        }
        process = p
        startedAt = Date()
        state = .running
        append(.info, "已启动 Claude Code（\(mode == .quick ? "快速" : "深度")模式），分析中…")

        let text = prompt(photoName: job.photoName, mode: mode, hint: hint)
        stdin.fileHandleForWriting.write(Data(text.utf8))
        try? stdin.fileHandleForWriting.close()
    }

    func cancel() {
        guard let p = process, p.isRunning else { return }
        state = .cancelled
        let pids = Self.descendants(of: p.processIdentifier)
        p.interrupt()
        for pid in pids { kill(pid, SIGTERM) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if p.isRunning { p.terminate() }
        }
        append(.info, "已取消。")
    }

    nonisolated private static func descendants(of pid: Int32) -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let kids = (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n").compactMap { Int32($0) }
        return kids + kids.flatMap { descendants(of: $0) }
    }

    // MARK: - Output parsing

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(line: lineData)
        }
    }

    private func handle(line: Data) {
        guard !line.isEmpty else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            if let s = String(data: line, encoding: .utf8) { append(.text, s) }
            return
        }
        switch obj["type"] as? String {
        case "assistant":
            let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for item in content {
                switch item["type"] as? String {
                case "text":
                    if let t = item["text"] as? String, !t.isEmpty {
                        assistantText += t + "\n"
                        append(.text, t)
                    }
                case "tool_use":
                    append(.tool, Self.describeTool(item))
                default: break
                }
            }
        case "result":
            if let r = obj["result"] as? String { finalText = r }
            if (obj["is_error"] as? Bool) == true {
                append(.error, finalText.isEmpty ? "Claude Code 返回错误。" : finalText)
            }
        default:
            break
        }
    }

    private static func describeTool(_ item: [String: Any]) -> String {
        let name = item["name"] as? String ?? "tool"
        let input = item["input"] as? [String: Any] ?? [:]
        let detail: String
        switch name {
        case "Bash":
            let desc = (input["description"] as? String).map { "\($0) — " } ?? ""
            detail = desc + ((input["command"] as? String) ?? "")
        case "Read", "Write", "Edit":
            detail = (input["file_path"] as? String) ?? ""
        case "WebSearch":
            detail = (input["query"] as? String) ?? ""
        case "WebFetch":
            detail = (input["url"] as? String) ?? ""
        case "Skill":
            detail = (input["skill"] as? String) ?? ""
        default:
            detail = (input["description"] as? String) ?? ""
        }
        let oneLine = detail.replacingOccurrences(of: "\n", with: " ")
        return "▸ \(name) \(oneLine.prefix(300))"
    }

    private func finish(status: Int32) {
        process = nil
        if state == .cancelled { return }

        result = readResultFile() ?? Self.parseMarker(in: finalText) ?? Self.parseMarker(in: assistantText)
        evidenceImage = findEvidence()

        if let r = result, r.hasCoordinate {
            state = .finished
            append(.info, "完成：\(r.place ?? "")")
        } else if result != nil {
            state = .finished
            append(.info, "分析结束，但没能确定坐标。")
        } else if status != 0 {
            state = .failed(finalText.isEmpty ? "Claude Code 退出码 \(status)" : finalText)
        } else {
            state = .failed("没有拿到结构化结果（GEO_RESULT）。可以查看日志或工作目录中的报告。")
        }
    }

    private func readResultFile() -> GeoResult? {
        guard let dir = jobDir,
              let data = try? Data(contentsOf: dir.appendingPathComponent("geo_result.json"))
        else { return nil }
        return try? JSONDecoder().decode(GeoResult.self, from: data)
    }

    nonisolated static func parseMarker(in text: String) -> GeoResult? {
        guard let range = text.range(of: resultMarker, options: .backwards) else { return nil }
        let tail = text[range.upperBound...]
        guard let open = tail.firstIndex(of: "{") else { return nil }
        var depth = 0
        var end: String.Index?
        for i in tail[open...].indices {
            if tail[i] == "{" { depth += 1 }
            if tail[i] == "}" { depth -= 1; if depth == 0 { end = i; break } }
        }
        guard let close = end else { return nil }
        return try? JSONDecoder().decode(GeoResult.self, from: Data(tail[open...close].utf8))
    }

    private func findEvidence() -> URL? {
        guard let dir = jobDir,
              let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles])
        else { return nil }
        var found: [URL] = []
        for case let url as URL in e {
            let name = url.lastPathComponent.lowercased()
            if name.hasPrefix("evidence"), ["jpg", "jpeg", "png"].contains(url.pathExtension.lowercased()) {
                found.append(url)
            }
        }
        return found.sorted { $0.path.count < $1.path.count }.first
    }

    private func append(_ kind: LogLine.Kind, _ text: String) {
        log.append(LogLine(kind: kind, text: text))
        if log.count > 3000 { log.removeFirst(log.count - 3000) }
    }
}
