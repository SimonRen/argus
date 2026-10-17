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

    @ObservationIgnored private let service: any LoginItemService

    public init(service: any LoginItemService) {
        self.service = service
        self.isOn = service.status() == .enabled
    }

    public func refresh() {
        isOn = service.status() == .enabled
    }

    public func set(_ on: Bool) {
        let previous = isOn
        do {
            if on {
                try service.register()
                switch service.status() {
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
                try service.unregister()
                isOn = false
                message = nil
            }
        } catch {
            isOn = previous
            message = "Couldn't change launch at login: \(error.localizedDescription)"
        }
    }
}
