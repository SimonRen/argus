import AppKit
import ArgusCore
import SwiftUI

/// The Settings window: titled and closable, sized to its content.
@MainActor final class SettingsWindowController {
    private let makeView: () -> AnyView
    private var window: NSWindow?

    init(makeView: @escaping () -> AnyView) {
        self.makeView = makeView
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: makeView())
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

/// Polling, launch at login and updates (ui/manager-redesign/Settings.dc.html).
struct SettingsView: View {
    let state: AppState
    let commands: AccountCommands
    let loginItem: LoginItemController
    let updater: Updater
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = Theme(scheme)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        VStack(spacing: 16) {
            card(t) {
                row(height: 52) {
                    Text("Refresh every").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Picker("Refresh interval", selection: Binding(get: { state.intervalMinutes }, set: { commands.setInterval($0) })) {
                        ForEach([3, 5, 10], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().help("How often allowances are polled")
                }
                t.hair.frame(height: 1)
                row(height: 56) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Launch at login").font(.system(size: 13, weight: .medium))
                        Text(loginItem.message ?? "Argus needs to be in your Applications folder.").font(.system(size: 11.5))
                            .foregroundStyle(loginItem.message == nil ? t.ter : t.deadText).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("Launch at login", isOn: Binding(get: { loginItem.isOn }, set: { on in Task { await loginItem.set(on) } }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small).tint(t.action).disabled(loginItem.isChanging)
                }
            }
            card(t) {
                row(height: 52) {
                    Text("Argus").font(.system(size: 13, weight: .medium))
                    Text("Version \(version)").font(.system(size: 12.5)).foregroundStyle(t.ter)
                    Spacer()
                    Button("Check for Updates…") { updater.checkForUpdates() }
                }
                t.hair.frame(height: 1)
                row(height: 48) {
                    Text("Check for updates automatically").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Toggle("Check for updates automatically", isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small).tint(t.action)
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 20)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(t.text)
        .background(t.win)
    }

    private func card(_ t: Theme, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0, content: content)
            .background(t.tableCard).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(t.hair, lineWidth: 1))
    }

    private func row(height: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 10, content: content)
            .padding(.leading, 16).padding(.trailing, 12).padding(.vertical, 8).frame(minHeight: height)
    }
}
