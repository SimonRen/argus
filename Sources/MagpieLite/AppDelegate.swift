import AppKit
import MagpieLiteCore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var instanceLock: InstanceLock?
    private var poller: Poller?
    private var statusItem: StatusItemController?

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
            // Another copy already runs and owns the vault.
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
                            sleeper: TaskSleeper(), now: now, renewer: Renewer(http: http, tools: tools, now: now))
        self.poller = poller
        statusItem = StatusItemController(state: state, preferences: MenuBarPreferences(defaults: .standard))
        poller.start()
    }

    /// An `.accessory` app draws no menu bar, but key equivalents still route through the main menu.
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
        return main
    }
}
