import AppKit
import MagpieLiteCore
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var instanceLock: InstanceLock?
    private var poller: Poller?
    private var statusItem: StatusItemController?
    private var commands: AccountCommands?
    private var manager: ManagerWindowController?

    static func main() {
        let delegate = AppDelegate()
        let app = NSApplication.shared
        app.delegate = delegate
        // The application holds its delegate weakly.
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = Self.makeMainMenu()

        let fm = FileManager.default
        let supportRoot = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MagpieLite", directoryHint: .isDirectory)
        guard let lock = InstanceLock.acquire(supportRoot: supportRoot) else {
            // Another copy already runs and owns the vault; with none running, the folder itself can't be opened.
            let copies = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").count
            if copies <= 1 {
                let alert = NSAlert()
                alert.messageText = "Magpie Lite can't open its folder"
                alert.informativeText = supportRoot.path
                alert.runModal()
            }
            NSApp.terminate(nil)
            return
        }
        instanceLock = lock

        let home = fm.homeDirectoryForCurrentUser
        // known-ceiling: a Finder-launched app does not see a shell-only CODEX_HOME → when the owner sets one.
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appending(path: ".codex", directoryHint: .isDirectory)
        let env = ToolEnvironment(home: home, codexHome: codexHome, user: NSUserName(), keychain: .login, security: SecurityCLI())
        let vault: Vault
        do {
            vault = try Vault(supportRoot: supportRoot)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Magpie Lite can't open its vault"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let tools: [any ToolAdapter] = [ClaudeTool(env: env), CodexTool(env: env), AgyTool(env: env)]
        let http = HTTPClient(session: URLSession(configuration: .ephemeral))
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let now: @Sendable () -> Date = { Date() }
        let state = AppState(defaults: .standard, now: now)
        let poller = Poller(state: state, tools: tools, vault: vault,
                            fetcher: AllowanceFetcher(http: http, version: version, now: now),
                            sleeper: TaskSleeper(), now: now, renewer: Renewer(http: http, tools: tools, now: now),
                            readingsFile: supportRoot.appending(path: "readings.json"), spacing: 2)
        self.poller = poller
        let switcher = Switcher(env: env, vault: vault, processes: .system)
        let commands = AccountCommands(state: state, poller: poller, vault: vault, tools: tools, switcher: switcher) {
            guard let codex = CodexProcesses.daemonExecutable(ProcessListing.system.lines()) else { return "no running app-server found" }
            return await CodexDaemon.restart(executable: codex, codexHome: codexHome)
        }
        self.commands = commands
        let preferences = MenuBarPreferences(defaults: .standard)
        let loginItem = LoginItemController(service: SMAppServiceLoginItem())
        manager = ManagerWindowController(makeView: {
            AnyView(ManagerView(state: state, commands: commands, preferences: preferences, loginItem: loginItem))
        }, onClose: { commands.closeUndo() })
        let statusItem = StatusItemController(state: state, preferences: preferences)
        let screen = PopoverScreen()
        let view = PopoverView(state: state, commands: commands, screen: screen, preferences: preferences, openManager: { [weak self] in self?.openManager() })
        let content = NSHostingController(rootView: view)
        content.sizingOptions = [.preferredContentSize]
        statusItem.attach(popover: content, screen: screen, onOpen: { Task { await poller.rereadLive() } }) { [weak self] in self?.openManager() }
        self.statusItem = statusItem
        Task {
            await switcher.settleInterruptedSwitch()
            poller.start()
        }
    }

    private func openManager() {
        statusItem?.closePopover()
        manager?.show()
    }

    /// The app menu: Quit, Close, Copy, Paste. An `.accessory` app draws no menu bar, but key equivalents still route here.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit Magpie Lite",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu = editMenu
        return main
    }
}
