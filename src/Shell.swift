import Foundation

struct ShellResult {
    let stdout: String
    let stderr: String
    let status: Int32
}

enum Shell {
    /// 同步执行。仅用于耗时极短的命令（ioreg / displayplacer list）。
    @discardableResult
    static func runSync(_ path: String, _ args: [String]) -> ShellResult {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return ShellResult(stdout: "", stderr: "命令不存在：\(path)", status: -1)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do {
            try p.run()
        } catch {
            return ShellResult(stdout: "", stderr: error.localizedDescription, status: -1)
        }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return ShellResult(
            stdout: String(data: d, encoding: .utf8) ?? "",
            stderr: String(data: e, encoding: .utf8) ?? "",
            status: p.terminationStatus
        )
    }

    /// 异步执行，不阻塞主线程（caffeinate -u -t 3 自身就要跑 3 秒）。
    @discardableResult
    static func run(_ path: String, _ args: [String]) async -> ShellResult {
        await withCheckedContinuation { (cont: CheckedContinuation<ShellResult, Never>) in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: runSync(path, args))
            }
        }
    }

    static func sleep(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
