import Foundation
import Testing
import ArgusCore

fileprivate let approvalMessage = "Allow Argus in System Settings → General → Login Items."
fileprivate let notFoundMessage = "Install Argus to ~/Applications first (make install)."

fileprivate struct FakeLoginItemError: LocalizedError {
    var errorDescription: String? { "Operation not permitted" }
}

/// A login item whose status after `register()` / `unregister()` is scripted per test.
fileprivate final class FakeLoginItemService: LoginItemService, @unchecked Sendable {
    private let lock = NSLock()
    private var current: LoginItemStatus
    private var afterRegister: LoginItemStatus
    private let afterUnregister: LoginItemStatus
    private let registerThrows: Bool
    private let unregisterThrows: Bool
    private var registerCount = 0
    private var unregisterCount = 0
    /// `register()` waits for it (5 s at most) before it does anything.
    private let hold: DispatchSemaphore?
    private var registeredOnMain: Bool?

    init(
        initial: LoginItemStatus,
        afterRegister: LoginItemStatus = .enabled,
        afterUnregister: LoginItemStatus = .notRegistered,
        registerThrows: Bool = false,
        unregisterThrows: Bool = false,
        hold: DispatchSemaphore? = nil
    ) {
        self.current = initial
        self.afterRegister = afterRegister
        self.afterUnregister = afterUnregister
        self.registerThrows = registerThrows
        self.unregisterThrows = unregisterThrows
        self.hold = hold
    }

    var registerCalls: Int { lock.withLock { registerCount } }
    var unregisterCalls: Int { lock.withLock { unregisterCount } }
    /// Whether the last `register()` ran on the main thread.
    var registerRanOnMain: Bool? { lock.withLock { registeredOnMain } }

    func setAfterRegister(_ status: LoginItemStatus) {
        lock.withLock { afterRegister = status }
    }

    func status() -> LoginItemStatus {
        lock.withLock { current }
    }

    func register() throws {
        _ = hold?.wait(timeout: .now() + 5)
        try lock.withLock {
            registerCount += 1
            registeredOnMain = pthread_main_np() == 1
            if registerThrows { throw FakeLoginItemError() }
            current = afterRegister
        }
    }

    func unregister() throws {
        try lock.withLock {
            unregisterCount += 1
            if unregisterThrows { throw FakeLoginItemError() }
            current = afterUnregister
        }
    }
}

@MainActor
@Test func `REQ/F08-AC-8.c2 register throwing reverts the toggle off and shows the error`() async {
    let service = FakeLoginItemService(initial: .notRegistered, registerThrows: true)
    let controller = LoginItemController(service: service)
    #expect(controller.isOn == false)

    await controller.set(true)

    #expect(service.registerCalls == 1)
    #expect(controller.isOn == false)
    #expect(controller.message == "Couldn't change launch at login: Operation not permitted")
}

@MainActor
@Test func `REQ/F08-AC-8.c2 requires approval after register reverts the toggle and shows the approval message`() async {
    let service = FakeLoginItemService(initial: .notRegistered, afterRegister: .requiresApproval)
    let controller = LoginItemController(service: service)

    await controller.set(true)

    #expect(service.registerCalls == 1)
    #expect(controller.isOn == false)
    #expect(controller.message == approvalMessage)
}

@MainActor
@Test func `REQ/F08-AC-8.c2 not found after register reverts the toggle and shows the install message`() async {
    let service = FakeLoginItemService(initial: .notRegistered, afterRegister: .notFound)
    let controller = LoginItemController(service: service)

    await controller.set(true)

    #expect(controller.isOn == false)
    #expect(controller.message == notFoundMessage)
}

@MainActor
@Test func `REQ/F08-AC-8.c2 enabled after register keeps the toggle on with no message`() async {
    let service = FakeLoginItemService(initial: .notRegistered, afterRegister: .enabled)
    let controller = LoginItemController(service: service)

    await controller.set(true)

    #expect(service.registerCalls == 1)
    #expect(controller.isOn == true)
    #expect(controller.message == nil)
}

@MainActor
@Test func `REQ/F08-AC-8.c2 a successful register clears an earlier failure message`() async {
    let service = FakeLoginItemService(initial: .notRegistered, afterRegister: .requiresApproval)
    let controller = LoginItemController(service: service)
    await controller.set(true)
    #expect(controller.message == approvalMessage)

    service.setAfterRegister(.enabled)
    await controller.set(true)

    #expect(service.registerCalls == 2)
    #expect(controller.isOn == true)
    #expect(controller.message == nil)
}

@MainActor
@Test func `REQ/F08-AC-8.c2 unregister throwing reverts the toggle back on and shows the error`() async {
    let service = FakeLoginItemService(initial: .enabled, unregisterThrows: true)
    let controller = LoginItemController(service: service)
    #expect(controller.isOn == true)

    await controller.set(false)

    #expect(service.unregisterCalls == 1)
    #expect(controller.isOn == true)
    #expect(controller.message == "Couldn't change launch at login: Operation not permitted")
}

@MainActor
@Test func `REQ/F08-AC-8.c2 successful unregister turns the toggle off with no message`() async {
    let service = FakeLoginItemService(initial: .enabled)
    let controller = LoginItemController(service: service)

    await controller.set(false)

    #expect(service.unregisterCalls == 1)
    #expect(controller.isOn == false)
    #expect(controller.message == nil)
}

@MainActor
@Test func `REQ/F08-AC-8.c2 the toggle reads the service status at init and on refresh`() {
    let enabled = LoginItemController(service: FakeLoginItemService(initial: .enabled))
    #expect(enabled.isOn == true)

    let pending = LoginItemController(service: FakeLoginItemService(initial: .requiresApproval))
    #expect(pending.isOn == false)

    let service = FakeLoginItemService(initial: .notRegistered, afterRegister: .enabled)
    let controller = LoginItemController(service: service)
    #expect(controller.isOn == false)
    try? service.register()
    controller.refresh()
    #expect(controller.isOn == true)
}

@MainActor
@Test func `REQ/F08-AC-8.c2 the toggle moves at once and waits while register runs off the main thread`() async {
    let hold = DispatchSemaphore(value: 0)
    let service = FakeLoginItemService(initial: .notRegistered, afterRegister: .enabled, hold: hold)
    let controller = LoginItemController(service: service)

    let setting = Task { await controller.set(true) }
    while !controller.isChanging { await Task.yield() }
    #expect(controller.isOn == true)

    hold.signal()
    await setting.value
    #expect(service.registerRanOnMain == false)
    #expect(!controller.isChanging)
    #expect(controller.isOn == true)
}
