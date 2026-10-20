import Foundation
import Observation

/// Registration state of the app as a login item.
public enum LoginItemStatus: Sendable, Equatable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
}

/// The system's login-item registration for this app.
public protocol LoginItemService: Sendable {
    func status() -> LoginItemStatus
    func register() throws
    func unregister() throws
}

/// Backs the launch-at-login toggle: the toggle is on only while the service reports `.enabled`.
@MainActor @Observable public final class LoginItemController {
    public private(set) var isOn: Bool
    public private(set) var message: String?
    /// A register or unregister is under way; the toggle already shows where it is going.
    public private(set) var isChanging = false

    @ObservationIgnored private let service: any LoginItemService

    public init(service: any LoginItemService) {
        self.service = service
        self.isOn = service.status() == .enabled
    }

    public func refresh() {
        isOn = service.status() == .enabled
    }

    /// The toggle moves at once and settles on what the service reports. Register, unregister and status are synchronous
    /// calls into the system's login-item service, so they run off the main thread.
    public func set(_ on: Bool) async {
        let previous = isOn
        isOn = on
        isChanging = true
        defer { isChanging = false }
        let service = service
        do {
            let status: LoginItemStatus? = try await Task.detached {
                guard on else {
                    try service.unregister()
                    return nil
                }
                try service.register()
                return service.status()
            }.value
            if let status {
                switch status {
                case .enabled:
                    isOn = true
                    message = nil
                case .requiresApproval:
                    isOn = false
                    message = "Allow Argus in System Settings → General → Login Items."
                case .notFound:
                    isOn = false
                    message = "Install Argus to ~/Applications first (make install)."
                case .notRegistered:
                    isOn = false
                    message = nil
                }
            } else {
                isOn = false
                message = nil
            }
        } catch {
            isOn = previous
            message = "Couldn't change launch at login: \(error.localizedDescription)"
        }
    }
}
