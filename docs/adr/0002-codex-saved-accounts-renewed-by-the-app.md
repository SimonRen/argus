# Renew saved Codex accounts in the app over HTTP, not through the Codex CLI

Saved (non-live) Codex accounts are renewed by the app itself with the OAuth refresh grant at `https://auth.openai.com/oauth/token` (client id `app_EMoamEEZ73f0CkXaXp7hrann`), inside the Codex tool's exclusive section, with the request always awaited and the rotated tokens persisted to the vault before the new access token is used. The Codex CLI keeps renewing the live account; the app never renews it. (tech-design §5)

## Why

The deciding requirement is that a cancelled or interrupted renewal must not strand the account. Codex refresh tokens rotate and are single-use; a refresh request whose response is dropped leaves a spent token, and the next attempt fails with `refresh_token_reused`. That guarantee is enforceable only when the process that sent the request is the one that persists the answer. Delegating renewal to a spawned `codex app-server` (the approach of the most mature reference app) means the only remedy for a hung child is to kill it, and killing it mid-renewal is exactly the strand — a watchdog and the no-strand promise cannot both hold.

HTTP renewal is also the same pattern the Claude and Antigravity adapters already use, so one renewal/persist path serves all three tools, and allowance polling keeps working when the Codex binary is missing, updated, or changes its JSON-RPC methods.

## Considered alternatives

- **CLI-delegated renewal (per-account `CODEX_HOME`, `codex -s read-only -a never app-server`, JSON-RPC `account/rateLimits/read`).** Rejected because a hung app-server can only be killed, which can strand a rotated token; it also adds a process per poll, a JSON-RPC client and per-account folders.
- **Hybrid: HTTP allowance, CLI renewal only when expired.** Rejected because it carries every failure mode of the CLI path plus a second code path, to avoid an endpoint the app already calls for the other tools.

## Consequences

- Renewal triggers only when the stored access token's `exp` is within 5 minutes or the allowance fetch returned 401; there is no periodic keep-alive renewal.
- Renewal body: `{client_id, grant_type:"refresh_token", refresh_token, scope:"openid profile email"}`; non-empty `id_token`/`access_token`/`refresh_token` from the reply replace the stored ones, `last_refresh` is set, unknown `auth.json` keys are preserved.
- 400/401 → account marked needs sign-in, vault file untouched, no automatic retry; timeout/5xx/network → transient, retried next cycle with the old token (if the server had rotated it, that retry gets `invalid_grant` and the account is marked needs sign-in — nothing is destroyed).
- Liveness is checked inside the exclusive section by re-reading Codex's live `auth.json` identity (email + `chatgpt_account_id`); a live account is never renewed, and no saved account is renewed while the live state is unknown, unsupported or incomplete.
- Risk: OpenAI could restrict the refresh grant to its own client (attestation). Trigger to revisit: renewal starts failing for all saved Codex accounts while the CLI still works.
