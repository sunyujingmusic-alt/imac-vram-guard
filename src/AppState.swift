import Foundation
import SwiftUI
import UserNotifications
import AppKit

@MainActor
final class AppState: ObservableObject {

    // MARK: 实时状态
    @Published var snap: VRAMSnapshot?
    @Published var history: [VRAMSnapshot] = []
    @Published var screens: [ScreenState] = []
    @Published var lines: [LogLine] = []

    // MARK: 任务状态
    @Published var busy = false
    @Published var busyTitle = ""
    @Published var busyDetail = ""

    // MARK: 结果 / 环境
    @Published var lastPurge: PurgeOutcome?
    @Published var hardwareOK = true
    @Published var hardwareNote = ""
    @Published var modelID = ""

    // MARK: 设置（持久化）
    @Published var alertThreshold: Int {
        didSet { UserDefaults.standard.set(alertThreshold, forKey: "vram.alertThreshold") }
    }
    @Published var watchEnabled: Bool {
        didSet { UserDefaults.standard.set(watchEnabled, forKey: "vram.watchEnabled") }
    }
    @Published var autoPurge: Bool {
        didSet { UserDefaults.standard.set(autoPurge, forKey: "vram.autoPurge") }
    }
    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin(launchAtLogin) }
    }
    /// 启动时自动恢复三屏最佳配置（适合外接屏偶尔抢走主屏的情况）
    @Published var restoreOnLaunch: Bool {
        didSet { UserDefaults.standard.set(restoreOnLaunch, forKey: "vram.restoreOnLaunch") }
    }

    private var monitor: Task<Void, Never>?
    private var lastAlert = Date.distantPast
    private var lastAutoPurge = Date.distantPast

    init() {
        let ud = UserDefaults.standard
        alertThreshold = ud.object(forKey: "vram.alertThreshold") as? Int ?? 500
        watchEnabled = ud.object(forKey: "vram.watchEnabled") as? Bool ?? true
        autoPurge = ud.object(forKey: "vram.autoPurge") as? Bool ?? false
        launchAtLogin = ud.object(forKey: "vram.launchAtLogin") as? Bool ?? false
        restoreOnLaunch = ud.object(forKey: "vram.restoreOnLaunch") as? Bool ?? false
        start()
    }

    // MARK: - 启动

    func start() {
        modelID = Machine.modelIdentifier
        hardwareOK = Machine.isTargetMachine && VRAM.acceleratorPresent
        if !Machine.isTargetMachine {
            hardwareNote = "当前机型 \(modelID) 与预设的 \(Machine.expectedModel) 不一致，三屏 ID 与显存读数接口可能不匹配。"
        } else if !VRAM.acceleratorPresent {
            hardwareNote = "未检测到 \(VRAM.accelClass)，显存读数不可用。"
        } else if !Displays.isInstalled {
            hardwareNote = "未找到 displayplacer（\(Displays.toolPath)），分辨率相关功能不可用。请先 brew install displayplacer。"
        } else {
            hardwareNote = "\(modelID) · \(Machine.gpuLabel) · macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion) 系列"
        }

        log("显存管家已启动 · \(hardwareNote)", kind: hardwareOK ? .good : .warn)

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        refresh()
        startMonitoring()

        if restoreOnLaunch {
            log("已开启「启动时自动恢复」，正在校验三屏…", kind: .info)
            Task { await self.restore() }
        }
    }

    private func startMonitoring() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func tick() {
        guard !busy else { return }          // 清理过程中不做读数，避免干扰
        guard watchEnabled else { return }
        refresh()
    }

    func refresh() {
        if let s = VRAM.read() {
            let wasNil = snap == nil
            snap = s
            history.append(s)
            if history.count > 240 { history.removeFirst(history.count - 240) }
            if !wasNil { evaluateAlert(s) }
        }
        if Displays.isInstalled { screens = Displays.list() }
    }

    // MARK: - 告警

    /// 自动清理的空闲显存下限（高级调节项，默认 300MB；界面不暴露）
    private var autoPurgeFloor: Int {
        UserDefaults.standard.object(forKey: "vram.autoPurgeFloor") as? Int ?? 300
    }

    private func evaluateAlert(_ s: VRAMSnapshot) {
        guard s.freeMB < alertThreshold else { return }
        guard Date().timeIntervalSince(lastAlert) > 600 else { return }
        lastAlert = Date()
        log("空闲显存跌至 \(s.freeMB)MB（阈值 \(alertThreshold)MB），建议清理", kind: .warn)
        notify(title: "显存告急：空闲 \(s.freeMB)MB",
               body: "孤儿缓存 \(s.orphanMB)MB。录屏前建议先清理一次，避免 GPU 显存耗尽导致内核崩溃。")

        if autoPurge, s.freeMB < autoPurgeFloor, Date().timeIntervalSince(lastAutoPurge) > 600 {
            lastAutoPurge = Date()
            log("自动清理已触发", kind: .info)
            Task { await self.purge(skipConfirm: true) }
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    // MARK: - 功能一：清理显存缓存（孤儿显存）

    /// 息屏 → 唤醒：让 WindowServer 拆建显示表面，逼出陈旧孤儿缓存。
    /// 这是实机验证唯一稳定正收益的手段（实测空闲 353MB → 2144MB）。
    ///
    /// 关于重试判据：原脚本用的是「可用显存(空闲+孤儿)增量 < 200MB 就再息屏一次」。
    /// 实测发现该判据在脏基线上会误判——唤醒的作用主要是把「孤儿」转成「空闲」，
    /// 两者之和几乎不变（本次 2772→2767MB），于是白白多跑了一轮 18 秒息屏。
    /// 真正决定会不会崩的是「空闲」这一项，所以这里改用空闲显存绝对值判据：
    /// 一次唤醒后空闲仍 < 800MB 才补一次。
    func purge(skipConfirm: Bool = false) async {
        guard !busy else { return }
        guard let before = VRAM.read() else {
            log("读取显存失败", kind: .bad)
            return
        }
        snap = before

        busy = true
        busyTitle = "正在清理显存缓存"
        defer {
            busy = false
            busyTitle = ""
            busyDetail = ""
        }

        log("清理前：空闲 \(before.freeMB)MB · 使用中 \(before.inUseMB)MB · 孤儿缓存 \(before.orphanMB)MB", kind: .info)

        // 给用户 3 秒准备时间，避免屏幕毫无征兆地熄灭
        for i in stride(from: 3, to: 0, by: -1) {
            busyDetail = "\(i) 秒后屏幕将熄灭约 15 秒"
            await Shell.sleep(seconds: 1)
        }

        var wakes = 0
        await wakeCycle()
        wakes += 1

        if let mid = VRAM.read() {
            snap = mid
            log("第 1 轮唤醒后：空闲 \(mid.freeMB)MB · 孤儿 \(mid.orphanMB)MB", kind: .info)
            if mid.freeMB < 800 {
                log("空闲仍偏低，再息屏一轮", kind: .info)
                await wakeCycle()
                wakes += 1
            }
        }

        // 唤醒重建显示时 macOS 偶发把主屏判给外接屏，这里校验并自动夺回
        await restoreIfNeeded()

        if let after = VRAM.read() {
            snap = after
            history.append(after)
            lastPurge = PurgeOutcome(before: before, after: after, wakes: wakes)
            let gain = after.freeMB - before.freeMB
            log("清理完成（\(wakes) 轮唤醒）：空闲 \(before.freeMB) → \(after.freeMB)MB（+\(gain)MB），"
                + "孤儿缓存 \(before.orphanMB) → \(after.orphanMB)MB",
                kind: gain > 0 ? .good : .warn)
            notify(title: "显存已清理：空闲 \(after.freeMB)MB",
                   body: "较清理前 +\(gain)MB，孤儿缓存降至 \(after.orphanMB)MB。")
        }
    }

    private func wakeCycle() async {
        busyDetail = "显示器休眠中…"
        await Shell.run(Tool.pmset, ["displaysleepnow"])
        await Shell.sleep(seconds: 6)
        busyDetail = "唤醒显示器…"
        await Shell.run(Tool.caffeinate, ["-u", "-t", "3"])
        await Shell.sleep(seconds: 8)
    }

    // MARK: - 功能二：恢复三屏最佳配置（含主屏夺回）

    func restore() async {
        guard !busy else { return }
        guard Displays.isInstalled else {
            log("displayplacer 不可用，无法恢复分辨率", kind: .bad)
            return
        }
        busy = true
        busyTitle = "正在恢复三屏最佳配置"
        busyDetail = "校验中…"
        defer { busy = false; busyTitle = ""; busyDetail = "" }

        await restoreIfNeeded()
        refresh()
    }

    /// 校验 → 必要时下发 → 再校验。最多两轮；状态本就正确时不重复下发（省一次闪烁）。
    private func restoreIfNeeded() async {
        guard Displays.isInstalled else { return }
        var current = Displays.list()
        screens = current

        if Displays.isOptimal(current) {
            log("三屏已是最佳配置，未下发任何命令（无闪烁）", kind: .good)
            return
        }

        for attempt in 1...2 {
            log("第 \(attempt) 次下发最佳配置…", kind: .info)
            busyDetail = "下发最佳配置（第 \(attempt) 次）…"
            let r = Displays.applyBest()
            if r.status != 0 && !r.stderr.isEmpty {
                log("displayplacer 返回：\(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))", kind: .warn)
            }
            await Shell.sleep(seconds: 8)
            current = Displays.list()
            screens = current
            if Displays.isOptimal(current) { break }
        }

        if Displays.isOptimal(current) {
            log("已恢复最佳：\(Displays.bestSummary)", kind: .good)
        } else {
            let detail = current.map {
                "\($0.friendlyName) \($0.res)@(\($0.origin))"
                    + ($0.rotation == 0 ? "" : " \($0.rotation)°")
            }.joined(separator: " / ")
            log("未能完全生效（\(detail)）。请到 系统设置 → 显示器 把白色菜单栏拖到 iMac 内置屏。", kind: .bad)
        }
    }

    // MARK: - 日志

    private static let fileLogFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private var fileLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/iMac 显存管家.log")
    }

    func log(_ text: String, kind: LogLine.Kind) {
        lines.insert(LogLine(date: Date(), text: text, kind: kind), at: 0)
        if lines.count > 80 { lines.removeLast(lines.count - 80) }
        appendFileLog(text)
    }

    private func appendFileLog(_ text: String) {
        let line = "[\(Self.fileLogFormatter.string(from: Date()))] \(text)\n"
        let url = fileLogURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            if let d = line.data(using: .utf8) { handle.write(d) }
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 开机自启

    private var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.vramguard.launcher.plist")
    }

    private func applyLaunchAtLogin(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "vram.launchAtLogin")
        let path = Bundle.main.bundlePath
        if on {
            let plist: [String: Any] = [
                "Label": "com.vramguard.launcher",
                "ProgramArguments": ["/usr/bin/open", "-a", path],
                "RunAtLoad": true,
            ]
            try? FileManager.default.createDirectory(
                at: agentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: agentURL)
            }
            Shell.runSync(Tool.launchctl, ["unload", agentURL.path])
            Shell.runSync(Tool.launchctl, ["load", agentURL.path])
            log("已设置开机自启", kind: .good)
        } else {
            Shell.runSync(Tool.launchctl, ["unload", agentURL.path])
            try? FileManager.default.removeItem(at: agentURL)
            log("已取消开机自启", kind: .info)
        }
    }
}
