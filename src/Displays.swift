import Foundation

/// 三屏控制：读取状态 + 下发「最佳配置」（含主屏夺回）。
///
/// 最佳配置基线（2026-11-06 22:32 实机采集，即当前系统状态）：
///   · iMac 内置 5K   1920x1080 HiDPI  横屏  @(0,0) 主屏
///   · 飞利浦 43"      1920x1080 HiDPI  横屏  @(-1920,1080)
///   · 27" 外接竖屏    1920x1080 HiDPI  旋转 90°  @(1920,0)
/// 三块屏的逻辑分辨率都是 1920x1080；竖屏只是同一模式旋转 90°，
/// displayplacer 把它的当前模式记为 1080x1920，这是正常的、属于最佳配置。
///
/// 下发机制沿用《显存优化报告.md》第七节的实机结论：全量下发 + 带括号原点 +
/// 以内置屏原点为基准平移（保留手动排列、夺回主屏），三个要点缺一不可。
enum Displays {

    // MARK: - 屏幕角色

    enum Role: Int, CaseIterable {
        case builtin, philips, portrait
    }

    /// displayplacer 的 Persistent screen id 会随接口 / 线材 / EDID 变化。
    /// 2026-11-06 发现 27" 竖屏 ID 由 03B62C37… 变为 241D439C…，
    /// 旧版 APP 只认一个写死的 ID，于是这块屏显示「目标 —」并被误报为不一致。
    /// 现在按「当前 ID → 历史 ID → 屏幕特征」三级识别，换接口也不会再失效。
    private static let knownIDs: [Role: [String]] = [
        .builtin:  ["0698F542-A165-E9A3-6B96-59656E1A5DAF"],
        .philips:  ["EBA7FA99-82D7-7AE4-E094-4A6014E00734"],
        .portrait: [
            "241D439C-C03B-3F17-DC2B-C54C4FD5A8BD",  // 当前（2026-11-06，90° 竖屏）
            "03B62C37-C746-554D-9D75-EB91FCDEB2E1",  // 历史（旧构建，270° 竖屏）
        ],
    ]

    static let builtinID  = knownIDs[.builtin]![0]
    static let phlID      = knownIDs[.philips]![0]
    static let portraitID = knownIDs[.portrait]![0]

    static let roleName: [Role: String] = [
        .builtin:  "iMac 内置 5K",
        .philips:  "飞利浦 BDM4350",
        .portrait: "27 英寸外接屏（竖屏）",
    ]

    static func role(id: String, typeName: String, rotation: Int) -> Role? {
        for (r, ids) in knownIDs where ids.contains(id) { return r }
        // ID 全都不认识时，按屏幕特征兜底识别
        if typeName.localizedCaseInsensitiveContains("built in") { return .builtin }
        if typeName.contains("43 inch") { return .philips }
        if rotation != 0 || typeName.contains("27 inch") { return .portrait }
        return nil
    }

    static func role(of screen: ScreenState) -> Role? {
        role(id: screen.id, typeName: screen.typeName, rotation: screen.rotation)
    }

    // MARK: - 最佳配置

    struct BestSetting {
        let logicalRes: String   // 用户视角的逻辑分辨率：三屏均为 1920x1080
        let modeRes: String      // displayplacer 当前模式 / 下发用的 res:
        let rotation: Int        // 0 = 横屏，90 = 竖屏
        let hz60: Bool           // 外接屏需要显式 hz:60 才能命中模式
    }

    static let best: [Role: BestSetting] = [
        .builtin:  BestSetting(logicalRes: "1920x1080", modeRes: "1920x1080", rotation: 0,  hz60: false),
        .philips:  BestSetting(logicalRes: "1920x1080", modeRes: "1920x1080", rotation: 0,  hz60: true),
        .portrait: BestSetting(logicalRes: "1920x1080", modeRes: "1080x1920", rotation: 90, hz60: true),
    ]

    static let bestSummary = "三屏均 1920×1080 HiDPI · 27 英寸竖屏旋转 90°（模式显示 1080×1920）· 内置 5K 为主屏"

    /// 卡片上显示的目标值；竖屏额外标出旋转角
    static func targetLabel(for screen: ScreenState) -> String {
        guard let r = role(of: screen), let b = best[r] else { return "—" }
        return b.rotation == 0 ? b.modeRes : "\(b.modeRes) · \(b.rotation)°"
    }

    /// 分辨率 + 旋转角都对才算达标（旧版只看分辨率，270° 会被误判成最佳）
    static func isOK(_ screen: ScreenState) -> Bool {
        guard let r = role(of: screen), let b = best[r] else { return false }
        return screen.res == b.modeRes && screen.rotation == b.rotation
    }

    // MARK: displayplacer 路径

    static let searchPaths = [
        "/usr/local/bin/displayplacer",      // Intel Mac + Homebrew 默认位置
        "/opt/homebrew/bin/displayplacer",   // Apple Silicon
    ]

    static var toolPath: String {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) } ?? searchPaths[0]
    }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: toolPath)
    }

    // MARK: 读取

    static func list() -> [ScreenState] {
        let out = Shell.runSync(toolPath, ["list"]).stdout
        return parse(out)
    }

    static func parse(_ out: String) -> [ScreenState] {
        var screens: [ScreenState] = []
        var id = "", type = "", res = "", origin = "", main = false, rot = 0

        func flush() {
            guard !id.isEmpty else { return }
            let name = role(id: id, typeName: type, rotation: rot).flatMap { roleName[$0] } ?? type
            screens.append(ScreenState(
                id: id,
                friendlyName: name,
                typeName: type,
                res: res,
                origin: origin,
                isMain: main,
                rotation: rot
            ))
        }

        for rawLine in out.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("Persistent screen id:") {
                flush()
                id = value(of: line, after: "Persistent screen id:")
                type = ""; res = ""; origin = ""; main = false; rot = 0
            } else if line.hasPrefix("Type:") {
                type = value(of: line, after: "Type:")
            } else if line.hasPrefix("Origin:") {
                let v = value(of: line, after: "Origin:")
                main = v.contains("main display")
                origin = firstMatch(of: "\\(-?[0-9]+,-?[0-9]+\\)", in: v).flatMap { s -> String in
                    var t = s; t.removeFirst(); t.removeLast(); return t
                } ?? ""
            } else if line.hasPrefix("Rotation:") {
                let v = value(of: line, after: "Rotation:")
                rot = Int(v.components(separatedBy: " ").first ?? "") ?? 0
            } else if line.contains("<-- current mode") {
                res = firstMatch(of: "res:[0-9]+x[0-9]+", in: line)?
                    .replacingOccurrences(of: "res:", with: "") ?? ""
            }
        }
        flush()
        return screens
    }

    private static func value(of line: String, after prefix: String) -> String {
        line.replacingOccurrences(of: prefix, with: "").trimmingCharacters(in: .whitespaces)
    }

    private static func firstMatch(of pattern: String, in text: String) -> String? {
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[r])
    }

    // MARK: 状态判定

    /// 三屏都在场、分辨率与旋转角都对，且内置屏占据全局原点 (0,0)（= 主屏是内置屏）。
    /// 外接屏的具体坐标不作为判据：排列属于用户偏好，下发时会按当前排布平移保留。
    static func isOptimal(_ screens: [ScreenState]) -> Bool {
        var byRole: [Role: ScreenState] = [:]
        for s in screens {
            if let r = role(of: s), byRole[r] == nil { byRole[r] = s }
        }
        for r in Role.allCases {
            guard let s = byRole[r], isOK(s) else { return false }
        }
        guard let b = byRole[.builtin] else { return false }
        return b.origin == "0,0"
    }

    // MARK: 下发最佳配置

    /// 三个要点缺一不可（均为实测踩坑）：
    ///  1. 必须先把 (0,0) 从当前主屏名下腾出来，否则整条命令被 macOS 静默否决（exit=0 但毫无变化）
    ///  2. 非主屏坐标相对主屏原点，换主屏必须整体平移（平移也顺带保住手动排好的排列）
    ///  3. 所有屏都要显式带 origin，且写成带括号的 origin:(x,y)——
    ///     不带括号的负数原点会被静默丢弃
    ///
    /// 竖屏用 degree:90（当前最佳姿态）。旧版写的是 degree:270，会把屏幕翻到另一侧。
    @discardableResult
    static func applyBest() -> ShellResult {
        let screens = list()
        guard let cmds = bestCommands(for: screens) else {
            return ShellResult(
                stdout: "",
                stderr: "未能识别三块屏幕（\(screens.map(\.friendlyName).joined(separator: " / "))），已取消下发",
                status: -1
            )
        }
        return Shell.runSync(toolPath, cmds)
    }

    /// 纯函数：只根据给定的屏幕实况算出要下发的 displayplacer 参数，不产生任何副作用。
    /// 单独拆出来便于回归验证，也便于日后打印「将要下发什么」。
    static func bestCommands(for screens: [ScreenState]) -> [String]? {
        var byRole: [Role: ScreenState] = [:]
        for s in screens {
            if let r = role(of: s), byRole[r] == nil { byRole[r] = s }
        }
        guard let builtin = byRole[.builtin],
              let philips = byRole[.philips],
              let portrait = byRole[.portrait] else { return nil }

        // 用「当前实际 ID」下发，而不是写死的常量：ID 变了也能生效
        let b = best[.builtin]!, p = best[.philips]!, d = best[.portrait]!
        var phlOrigin = "-1920,1080"
        var portraitOrigin = "1920,0"

        if let bp = point(of: builtin.origin) {
            if let pp = point(of: philips.origin)   { phlOrigin = "\(pp.x - bp.x),\(pp.y - bp.y)" }
            if let dp = point(of: portrait.origin)  { portraitOrigin = "\(dp.x - bp.x),\(dp.y - bp.y)" }
        }
        // 原点仍落在 (0,0) 说明该屏与内置屏重叠（镜像），只能按当前排列让开
        if phlOrigin == "0,0"      { phlOrigin = "-1920,1080" }
        if portraitOrigin == "0,0" { portraitOrigin = "1920,0" }

        func command(_ s: ScreenState, _ cfg: BestSetting, _ origin: String) -> String {
            let hz = cfg.hz60 ? "hz:60 " : ""
            let deg = cfg.rotation == 0 ? "" : " degree:\(cfg.rotation)"
            return "id:\(s.id) res:\(cfg.modeRes) \(hz)scaling:on color_depth:8 origin:(\(origin))\(deg)"
        }

        return [
            command(builtin,  b, "0,0"),
            command(philips,  p, phlOrigin),
            command(portrait, d, portraitOrigin),
        ]
    }

    private static func point(of origin: String) -> (x: Int, y: Int)? {
        let parts = origin.split(separator: ",").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }
}
