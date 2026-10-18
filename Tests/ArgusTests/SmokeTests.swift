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
