import Observation
import Testing
@testable import Argus

@Test func `popover warmup retries until the status item is ready and only runs once`() {
    var warmup = PopoverWarmup()
    var shows = 0

    #expect(!warmup.attempt(isReady: false) { shows += 1; return true })
    #expect(shows == 0)
    #expect(!warmup.attempt(isReady: true) { shows += 1; return false })
    #expect(shows == 1)
    #expect(warmup.attempt(isReady: true) { shows += 1; return true })
    #expect(warmup.attempt(isReady: true) { shows += 1; return true })
    #expect(shows == 2)
}

@Observable private final class Probe { var value = 0 }

/// Redraws `probe.value` the way the status item redraws its summary.
@MainActor private final class ProbeView {
    let probe = Probe()
    let tracking = RedrawTracking()
    var draws = 0

    func render() {
        _ = tracking.track { probe.value } onChange: { [weak self] in self?.render() }
        draws += 1
    }
}

/// Lets the main actor run the redraws a change queued.
@MainActor private func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor @Test func `a redraw called again keeps one observation armed, not one per call`() async {
    let view = ProbeView()
    view.render()
    // Two appearance changes since launch.
    view.render()
    view.render()
    #expect(view.draws == 3)

    view.probe.value = 1
    await settle()
    #expect(view.draws == 4)

    view.probe.value = 2
    await settle()
    #expect(view.draws == 5)
}
