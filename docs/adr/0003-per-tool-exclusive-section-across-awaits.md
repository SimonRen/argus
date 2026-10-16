# Serialize renewals and switches per tool with an exclusive section that spans awaits

All operations that read and then write a tool's credentials or its vault entries — a saved-account renewal, a switch, Save, Remove, Undo and the poll-time sync-back — run inside a per-tool exclusive section owned by the `Vault` actor: a chained unstructured `Task` per tool, so the next operation for that tool starts only after the previous one has finished, including all its network and subprocess awaits. UI state is a `@MainActor @Observable` object; the poller is main-actor and loops on `Task.sleep`; tool adapters are stateless `Sendable` values. (tech-design §1)

## Why

A Swift `actor` serializes only the synchronous stretches of its methods: at every `await` other calls can interleave. A renewal awaits an HTTP POST; a switch awaits `security` subprocesses. Without an explicit chain, a switch can read a saved account's refresh token while a renewal of that account is between "POST sent" and "rotated token persisted", and with single-use tokens that interleaving is unrecoverable. The chain is the one primitive that gives exclusion across suspension points, and it also lets the renewal body run in an unstructured task so cancelling a poll never abandons a sent request.

Per tool (not per account, not app-wide) is the grain that matches the risk: a switch touches the tool's live store, the outgoing account and the target account at once, so per-account locks would need ordering rules; an app-wide chain would make a Codex switch wait behind an agy renewal for no reason.

## Considered alternatives

- **One actor per tool adapter.** Rejected because actor isolation alone gives no cross-await exclusion; each adapter would still need the chain, and adapters would have to share vault access across actors.
- **Everything on the main actor with per-account async locks.** Rejected because a switch spans several accounts plus the tool's live store, and subprocess pipe reads and file I/O would sit next to the UI thread.
- **Combine / GCD queues.** Rejected because their `@Sendable` closures fight Swift 6 strict concurrency at every state write and still need async bridging to `URLSession`.

## Consequences

- `Vault` exposes `exclusive(tool:_:)`; renewal, switch, Save, Remove, Undo and poll-time sync-back bodies call vault reads/writes synchronously inside it; vault read/write methods have no `await` inside.
- Every operation re-reads what it decides on inside the section: a renewal skips an entry that is gone, live, incomplete or no longer holds the token that triggered it, and skips every entry of the tool while its live state is unknown, unsupported or incomplete; a poll-time sync-back writes only if the entry still exists and is readable, the live identity still matches and the bytes still differ, and for Claude only from an interval batch whose pair read equals the previous batch's; Remove captures the bytes an in-flight renewal just persisted; Undo never overwrites a newer entry.
- The poller joins a queued or in-flight fetch of the same account instead of starting a second one, so a manual refresh during a batch cannot queue a second renewal with a spent token.
- Liveness for the renew-or-skip decision is read from the tool's live store inside the section, never from UI state.
- `URLRequest.timeoutInterval` is 15 s; the `security` helper kills its child after 20 s (pid watchdog), so a hung operation cannot block the tool's chain indefinitely.
- The poller's loop task is the only task ever cancelled (on interval change or quit); a batch and any renewal run to completion.
- `Process`/`Pipe` never leave the `security` helper; its `terminationHandler` is installed before `run()`, stdin is closed after writing, and handlers capture only `Sendable` values.
- Risk: a switch waits behind an in-flight renewal of the same tool for up to the HTTP timeout; acceptable at ~15 accounts.
