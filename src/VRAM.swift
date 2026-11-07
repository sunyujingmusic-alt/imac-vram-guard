import Foundation

/// 显存读数：AMD 驱动在 IORegistry 里暴露的性能统计。
/// macOS 没有官方命令行工具，这是脚本里已验证可用的唯一来源。
enum VRAM {
    /// Radeon Pro 570X (Ellesmere) 对应的加速器类名
    static let accelClass = "AMDRadeonX4000_AMDEllesmereGraphicsAccelerator"

    /// ioreg 在 /usr/sbin（不是 /usr/bin）。APP 不继承 shell 的 PATH，必须用绝对路径，
    /// 这里再兜一层候选路径，避免将来系统调整位置后失效。
    static let ioregPath: String = Tool.resolve("ioreg")

    static var acceleratorPresent: Bool {
        let r = Shell.runSync(ioregPath, ["-r", "-d", "1", "-w", "0", "-c", accelClass])
        return r.stdout.contains(accelClass)
    }

    static func read() -> VRAMSnapshot? {
        let r = Shell.runSync(ioregPath, ["-r", "-d", "1", "-w", "0", "-c", accelClass])
        let inuse  = lastNumber(in: r.stdout, key: "inUseVidMemoryBytes")
        let orphan = lastNumber(in: r.stdout, key: "orphanedReusableVidMemoryBytes")
        let free   = lastNumber(in: r.stdout, key: "vramFreeBytes")
        guard inuse + orphan + free > 0 else { return nil }
        return VRAMSnapshot(
            date: Date(),
            inUseMB: Int(inuse / 1048576),
            orphanMB: Int(orphan / 1048576),
            freeMB: Int(free / 1048576)
        )
    }

    /// IORegistry 里同名键会出现在多个统计块（PerformanceStatistics / ...Accum）中，
    /// 取最后一次出现的值（与脚本 `tail -1` 行为一致，实测各块数值相同）。
    private static func lastNumber(in text: String, key: String) -> Int64 {
        guard let re = try? NSRegularExpression(pattern: "\"\(key)\"=(\\d+)") else { return 0 }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last, last.numberOfRanges > 1 else { return 0 }
        return Int64(ns.substring(with: last.range(at: 1))) ?? 0
    }
}

// MARK: - 机型识别

/// 解析系统命令的绝对路径：APP 不继承 shell 的 PATH，必须显式定位
enum Tool {
    private static let searchDirs = ["/usr/sbin", "/usr/bin", "/bin", "/sbin"]

    static func resolve(_ name: String, fallback: String? = nil) -> String {
        for dir in searchDirs {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return fallback ?? "/usr/bin/\(name)"
    }

    static var pmset: String { resolve("pmset") }
    static var caffeinate: String { resolve("caffeinate") }
    static var sysctl: String { resolve("sysctl", fallback: "/usr/sbin/sysctl") }
    static var launchctl: String { resolve("launchctl") }
}

enum Machine {
    static var modelIdentifier: String {
        let r = Shell.runSync(Tool.sysctl, ["-n", "hw.model"])
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 本 APP 是为一台特定机器写的，这里做兼容性校验
    static let expectedModel = "iMac19,1"
    static let gpuLabel = "Radeon Pro 570X · 4GB"

    static var isTargetMachine: Bool { modelIdentifier == expectedModel }
}
