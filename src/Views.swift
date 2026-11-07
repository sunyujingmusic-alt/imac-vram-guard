import SwiftUI
import AppKit

// MARK: - 主面板

struct DashboardView: View {
    @EnvironmentObject var state: AppState
    @State private var confirmPurge = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                heroSection
                SegmentedBar(snap: state.snap)
                historySection
                screensSection
                actionsSection
                settingsSection
                logSection
            }
            .padding(22)
        }
        .frame(minWidth: 720, minHeight: 640)
        .overlay(alignment: .center) {
            if state.busy { BusyOverlay(title: state.busyTitle, detail: state.busyDetail) }
        }
        .frame(minWidth: 700, maxWidth: 1000, minHeight: 600, maxHeight: 950)
        .alert("确认清理显存缓存？", isPresented: $confirmPurge) {
            Button("取消", role: .cancel) { }
            Button("开始清理") { Task { await state.purge(skipConfirm: true) } }
        } message: {
            Text("屏幕会熄灭约 15 秒，正在进行的录屏或视频会议会中断。清理结束后会自动校验并夺回主屏。")
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("iMac 显存管家")
                    .font(.system(size: 22, weight: .semibold))
                Text(state.hardwareNote.isEmpty ? "正在识别硬件…" : state.hardwareNote)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: state.hardwareOK ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundColor(state.hardwareOK ? .green : .orange)
            Text(state.modelID.isEmpty ? "—" : state.modelID)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    // MARK: 显存读数

    private var heroSection: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("剩余显存")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(state.snap?.freeMB ?? 0)")
                        .font(.system(size: 46, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(healthColor)
                    Text("MB")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                    Text("/ 4096 MB")
                        .font(.system(size: 13))
                        .foregroundColor(Color.secondary.opacity(0.7))
                }
                HStack(spacing: 8) {
                    StatusPill(text: (state.snap?.health ?? .good).label, color: healthColor)
                    if let s = state.snap {
                        Text("可用（含可回收）\(s.availableMB) MB")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 8) {
                MetricRow(label: "使用中", value: state.snap?.inUseMB ?? 0, color: .orange)
                MetricRow(label: "孤儿缓存", value: state.snap?.orphanMB ?? 0, color: .purple)
                MetricRow(label: "空闲", value: state.snap?.freeMB ?? 0, color: .green)
            }
            .frame(width: 220)

            if let p = state.lastPurge {
                VStack(alignment: .leading, spacing: 4) {
                    Text("上次清理")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("空闲 \(p.before.freeMB) → \(p.after.freeMB) MB")
                        .font(.system(size: 13, weight: .medium))
                    Text("孤儿 −\(p.orphanDrop) MB · \(p.wakes) 轮唤醒")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
            }
        }
    }

    private var healthColor: Color {
        switch state.snap?.health ?? .good {
        case .good:   return .green
        case .warn:   return .orange
        case .danger: return .red
        }
    }

    // MARK: 趋势

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("空闲显存趋势")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text("近 \(min(state.history.count, 240) * 3 / 60) 分钟 · 每 3 秒采样")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            HistoryChart(data: state.history, threshold: state.alertThreshold)
                .frame(height: 96)
        }
    }

    // MARK: 三屏

    private var screensSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("三屏状态")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                if Displays.isInstalled {
                    Text(Displays.isOptimal(state.screens) ? "最佳配置 ✓" : "与最佳配置不一致")
                        .font(.system(size: 12))
                        .foregroundColor(Displays.isOptimal(state.screens) ? .green : .orange)
                } else {
                    Text("displayplacer 未安装")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
            }
            HStack(spacing: 10) {
                ForEach(orderedScreens) { s in
                    ScreenCard(screen: s)
                }
            }
            Text("最佳配置：\(Displays.bestSummary)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private var orderedScreens: [ScreenState] {
        state.screens.sorted { a, b in
            let ra = Displays.role(of: a)?.rawValue ?? 99
            let rb = Displays.role(of: b)?.rawValue ?? 99
            return ra < rb
        }
    }

    // MARK: 操作

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("操作")
                .font(.system(size: 13, weight: .medium))
            HStack(spacing: 10) {
                Button {
                    confirmPurge = true
                } label: {
                    Label("清理显存缓存", systemImage: "sparkles")
                        .frame(minWidth: 150)
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.busy)

                Button {
                    Task { await state.restore() }
                } label: {
                    Label("恢复三屏最佳配置", systemImage: "rectangle.3.group")
                        .frame(minWidth: 150)
                }
                .disabled(state.busy || !Displays.isInstalled)

                Button {
                    state.refresh()
                } label: {
                    Label("立即刷新", systemImage: "arrow.clockwise")
                }
                .disabled(state.busy)

                Spacer()
            }
            Text("清理 = 息屏→唤醒，逼出陈旧孤儿缓存（实测空闲 353MB→2144MB）；恢复 = 下发三屏 1920×1080（含竖屏 90°）并夺回主屏。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // MARK: 设置

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("监控与提醒")
                .font(.system(size: 13, weight: .medium))
            HStack(spacing: 24) {
                Toggle("实时采样（3 秒）", isOn: $state.watchEnabled)
                Toggle("空闲低于阈值时提醒", isOn: .constant(true)).disabled(true)
                HStack(spacing: 8) {
                    Text("阈值")
                        .font(.system(size: 12))
                    Slider(value: Binding(
                        get: { Double(state.alertThreshold) },
                        set: { state.alertThreshold = Int($0) }
                    ), in: 100...1500, step: 50)
                    .frame(width: 130)
                    Text("\(state.alertThreshold) MB")
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 62, alignment: .leading)
                }
            }
            HStack(spacing: 24) {
                Toggle("开机自启", isOn: $state.launchAtLogin)
                Toggle("启动时自动恢复三屏最佳配置", isOn: $state.restoreOnLaunch)
                Toggle("告急时自动清理（空闲 <300MB）", isOn: $state.autoPurge)
            }
            Text("报告结论：空闲显存跌到 200MB 以下时录屏极易触发 GPU 显存耗尽内核崩溃。默认阈值 500MB 留出提前量。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
    }

    // MARK: 日志

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("运行日志")
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                Spacer()
                Button("打开日志文件") {
                    let url = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Logs/iMac 显存管家.log")
                    NSWorkspace.shared.open(url.deletingLastPathComponent())
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(state.lines) { l in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(Self.timeFormatter.string(from: l.date))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Color.secondary.opacity(0.8))
                            Text(l.text)
                                .font(.system(size: 11))
                                .foregroundColor(logColor(l.kind))
                            Spacer()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 110)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.textBackgroundColor)))
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private func logColor(_ k: LogLine.Kind) -> Color {
        switch k {
        case .info:  return .primary
        case .good:  return .green
        case .warn:  return .orange
        case .bad:   return .red
        }
    }
}

// MARK: - 组件

struct StatusPill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
            .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
            .foregroundColor(color)
    }
}

struct MetricRow: View {
    let label: String
    let value: Int
    let color: Color
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 12)).foregroundColor(.secondary)
            Spacer()
            Text("\(value) MB")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
        }
    }
}

struct SegmentedBar: View {
    let snap: VRAMSnapshot?
    var body: some View {
        GeometryReader { geo in
            let total = Double(VRAMSnapshot.totalMB)
            let inUse = Double(snap?.inUseMB ?? 0) / total
            let orphan = Double(snap?.orphanMB ?? 0) / total
            let free = Double(snap?.freeMB ?? 0) / total
            HStack(spacing: 2) {
                Bar(fraction: inUse, color: .orange)
                Bar(fraction: orphan, color: .purple)
                Bar(fraction: free, color: .green)
            }
            .frame(width: geo.size.width)
        }
        .frame(height: 12)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private struct Bar: View {
        let fraction: Double
        let color: Color
        var body: some View {
            GeometryReader { g in
                color.frame(width: max(0, min(1, fraction)) * g.size.width)
            }
        }
    }
}

struct HistoryChart: View {
    let data: [VRAMSnapshot]
    let threshold: Int

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.controlBackgroundColor))

                if data.count > 1 {
                    areaPath(width: w, height: h)
                        .fill(LinearGradient(
                            colors: [Color.green.opacity(0.35), Color.green.opacity(0.03)],
                            startPoint: .top, endPoint: .bottom))
                    linePath(width: w, height: h)
                        .stroke(Color.green, lineWidth: 1.6)

                    // 阈值线
                    let y = h - CGFloat(Double(threshold) / Double(VRAMSnapshot.totalMB)) * h
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: w, y: y))
                    }
                    .stroke(Color.red.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                } else {
                    Text("采样中…").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
        }
    }

    private func points(width: CGFloat, height: CGFloat) -> [CGPoint] {
        let total = Double(VRAMSnapshot.totalMB)
        guard data.count > 1 else { return [] }
        let step = width / CGFloat(data.count - 1)
        return data.enumerated().map { i, s in
            let y = height - CGFloat(Double(min(s.freeMB, VRAMSnapshot.totalMB)) / total) * height
            return CGPoint(x: CGFloat(i) * step, y: y)
        }
    }

    private func linePath(width: CGFloat, height: CGFloat) -> Path {
        var p = Path()
        for (i, pt) in points(width: width, height: height).enumerated() {
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
    }

    private func areaPath(width: CGFloat, height: CGFloat) -> Path {
        var p = linePath(width: width, height: height)
        let pts = points(width: width, height: height)
        if let last = pts.last, let first = pts.first {
            p.addLine(to: CGPoint(x: last.x, y: height))
            p.addLine(to: CGPoint(x: first.x, y: height))
            p.closeSubpath()
        }
        return p
    }
}

struct ScreenCard: View {
    let screen: ScreenState

    private var target: String { Displays.targetLabel(for: screen) }
    private var resOK: Bool { Displays.isOK(screen) }
    private var isBuiltin: Bool { Displays.role(of: screen) == .builtin }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: isBuiltin ? "laptopcomputer" : "display")
                    .foregroundColor(.secondary)
                Text(screen.friendlyName)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            }
            Text(screen.res.isEmpty ? "未检测到" : screen.res)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundColor(resOK ? .primary : .orange)
            HStack(spacing: 4) {
                Text("目标 \(target)").font(.system(size: 10))
                Image(systemName: resOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 10))
                Text(verbatim: "")
            }
            .foregroundColor(resOK ? .green : .orange)
            .font(.system(size: 10))

            Divider().padding(.vertical, 2)
            HStack(spacing: 4) {
                Text(screen.originText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                if screen.isMain {
                    Text("主屏").font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        .foregroundColor(.accentColor)
                }
                if screen.rotation != 0 {
                    Text("\(screen.rotation)°").font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(resOK ? Color.clear : Color.orange.opacity(0.6), lineWidth: 1))
    }
}

struct BusyOverlay: View {
    let title: String
    let detail: String
    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).opacity(0.65)
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text(title).font(.system(size: 15, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundColor(.secondary)
            }
            .padding(28)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(NSColor.windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.2)))
            .shadow(radius: 18)
        }
        .ignoresSafeArea()
    }
}


// MARK: - 菜单栏

struct MenuBarContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var confirm = false

    var body: some View {
        Group {
            if let s = state.snap {
                Text("空闲 \(s.freeMB) MB · 共 4096 MB")
                Text("使用中 \(s.inUseMB) MB · 孤儿缓存 \(s.orphanMB) MB")
                Text("状态：\(s.health.label)")
            } else {
                Text("显存读数不可用")
            }
            Divider()
            Button {
                confirm = true
            } label: {
                Label("清理显存缓存（屏幕熄灭约 15 秒）", systemImage: "sparkles")
            }
            .disabled(state.busy)
            Button {
                Task { await state.restore() }
            } label: {
                Label("恢复三屏最佳配置", systemImage: "rectangle.3.group")
            }
            .disabled(state.busy || !Displays.isInstalled)
            Divider()
            Button("打开主窗口") {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }
            Toggle("实时采样", isOn: $state.watchEnabled)
            Toggle("开机自启", isOn: $state.launchAtLogin)
            Divider()
            Button("退出") { NSApp.terminate(nil) }
        }
        .confirmationDialog("清理显存缓存？屏幕会熄灭约 15 秒。", isPresented: $confirm) {
            Button("开始清理") { Task { await state.purge(skipConfirm: true) } }
            Button("取消", role: .cancel) { }
        }
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text(state.snap.map { "\($0.freeMB)" } ?? "--")
                .monospacedDigit()
        }
    }

    private var icon: String {
        switch state.snap?.health ?? .good {
        case .good:   return "memorychip"
        case .warn:   return "memorychip.exclamationmark"
        case .danger: return "exclamationmark.triangle.fill"
        }
    }
}
