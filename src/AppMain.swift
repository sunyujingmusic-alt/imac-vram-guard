import SwiftUI
import AppKit

@main
struct VRAMGuardApp: App {
    @StateObject private var state = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("iMac 显存管家", id: "dashboard") {
            DashboardView()
                .environmentObject(state)
        }
        .defaultSize(width: 800, height: 760)

        MenuBarExtra {
            MenuBarContent().environmentObject(state)
        } label: {
            MenuBarLabel().environmentObject(state)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 延迟一拍，等 SwiftUI 完成窗口创建/尺寸恢复后再定位
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            Self.placeMainWindow()
        }
    }

    /// 多屏机器上 SwiftUI 会记住窗口上次所在的屏——可能是正在休眠的外接竖屏，
    /// 用户就会以为 APP 没打开。这里每次启动都把主窗口挪回主屏（全局原点 (0,0) 那块）居中。
    static func placeMainWindow() {
        // 主屏的定义就是"占据全局原点 (0,0) 的屏"，拿它最准
        let target = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        guard let screen = target else { return }

        for window in NSApp.windows {
            guard window.frame.width > 400, window.frame.height > 400 else { continue }
            let visible = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(CGPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2
            ))
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 关闭窗口不退出（菜单栏常驻）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 点击 Dock 图标时重新拉起窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppDelegate.placeMainWindow() }
        return true
    }
}
