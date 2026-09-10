import AppKit
import Foundation

final class MenuController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let status = NSMenuItem(title: "Runtime：正在检查…", action: nil, keyEquivalent: "")
    private let version = NSMenuItem(title: "Runtime 版本：未知", action: nil, keyEquivalent: "")
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var service: String { "gui/\(getuid())/icu.minq.memoh.runtime" }
    private var plist: String { home.appendingPathComponent("Library/LaunchAgents/icu.minq.memoh.runtime.plist").path }
    private var directory: URL { home.appendingPathComponent("Library/Application Support/Memoh") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "M"
        statusItem.button?.toolTip = "Memoh Runtime"
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        status.isEnabled = false
        version.isEnabled = false
        menu.addItem(status)
        menu.addItem(version)
        menu.addItem(.separator())
        add(menu, "打开 Memoh", #selector(openWeb))
        add(menu, "启动 Runtime", #selector(startRuntime))
        add(menu, "停止 Runtime", #selector(stopRuntime))
        add(menu, "重启 Runtime", #selector(restartRuntime))
        menu.addItem(.separator())
        add(menu, "打开 Runtime 日志", #selector(openLog))
        add(menu, "打开配置目录", #selector(openConfig))
        menu.addItem(.separator())
        add(menu, "退出菜单栏", #selector(quit))
        statusItem.menu = menu
        update()
    }

    private func add(_ menu: NSMenu, _ title: String, _ selector: Selector) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @discardableResult private func launchctl(_ arguments: [String]) -> (Int32, String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch { return (1, "") }
    }

    private func update() {
        let package = home.appendingPathComponent(".local/lib/node_modules/@memohai/runtime/package.json")
        if let data = try? Data(contentsOf: package),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = json["version"] as? String { version.title = "Runtime 版本：\(value)" }
        let result = launchctl(["print", service])
        status.title = result.1.contains("state = running") ? "Runtime：运行中" : "Runtime：已停止"
    }
    func menuWillOpen(_ menu: NSMenu) { update() }
    @objc private func openWeb() {
        let file = home.appendingPathComponent(".memoh/runtime.json")
        guard let data = try? Data(contentsOf: file),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let server = config["server"] as? String,
              var url = URLComponents(string: server) else { return }
        if url.path.hasSuffix("/api") { url.path = String(url.path.dropLast(4)) }
        if let target = url.url { NSWorkspace.shared.open(target) }
    }
    @objc private func openLog() { NSWorkspace.shared.open(directory.appendingPathComponent("runtime.log")) }
    @objc private func openConfig() { NSWorkspace.shared.open(home.appendingPathComponent(".memoh")) }
    @objc private func startRuntime() {
        if launchctl(["print", service]).0 != 0 { launchctl(["bootstrap", "gui/\(getuid())", plist]) }
        launchctl(["kickstart", service]); update()
    }
    @objc private func stopRuntime() { launchctl(["bootout", service]); update() }
    @objc private func restartRuntime() {
        if launchctl(["print", service]).0 != 0 { startRuntime() }
        else { launchctl(["kickstart", "-k", service]); update() }
    }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

let app = NSApplication.shared
let controller = MenuController()
app.setActivationPolicy(.accessory)
app.delegate = controller
app.run()
