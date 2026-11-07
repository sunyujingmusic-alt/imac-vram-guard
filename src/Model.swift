import Foundation

// MARK: - 显存快照

struct VRAMSnapshot: Identifiable {
    let id = UUID()
    let date: Date
    let inUseMB: Int      // inUseVidMemoryBytes      正在使用
    let orphanMB: Int     // orphanedReusableVidMemoryBytes  孤儿缓存（可回收）
    let freeMB: Int       // vramFreeBytes            立即可分配
}

extension VRAMSnapshot {
    /// 本机 Radeon Pro 570X 显存总量（MB）
    static let totalMB = 4096

    /// 空闲 + 孤儿缓存：理论上可动用的量
    var availableMB: Int { freeMB + orphanMB }

    /// 真正决定"会不会崩"的量：空闲显存。
    /// 孤儿缓存需要驱动回收才可用，回收速度跟不上分配压力就会触发 GPU 显存管理器耗尽。
    enum Health {
        case good, warn, danger

        var label: String {
            switch self {
            case .good:   return "健康"
            case .warn:   return "偏低"
            case .danger: return "危险"
            }
        }
    }

    /// 报告结论：空闲 <200MB 是崩溃征兆；<500MB 建议清理
    var health: Health {
        if freeMB < 250 { return .danger }
        if freeMB < 600 { return .warn }
        return .good
    }
}

// MARK: - 显示器状态

struct ScreenState: Identifiable {
    let id: String            // displayplacer 的 Persistent screen id
    let friendlyName: String  // iMac 内置 5K / 飞利浦 BDM4350 / DELL U2720Q
    let typeName: String      // displayplacer 报告的 Type
    let res: String           // 当前逻辑分辨率，如 1920x1080
    let origin: String        // 全局坐标 "x,y"
    let isMain: Bool
    let rotation: Int

    var originText: String { "(\(origin))" }
}

// MARK: - 日志

struct LogLine: Identifiable {
    let id = UUID()
    let date: Date
    let text: String
    let kind: Kind

    enum Kind {
        case info, good, warn, bad
    }
}

// MARK: - 清理结果

struct PurgeOutcome {
    let before: VRAMSnapshot
    let after: VRAMSnapshot
    let wakes: Int

    var freeGain: Int { after.freeMB - before.freeMB }
    var orphanDrop: Int { before.orphanMB - after.orphanMB }
}
