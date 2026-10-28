# Keep saved logins as one owner-only file per account, payload stored as raw bytes

Saved logins live in `~/Library/Application Support/Argus/vault/<tool>/<id>.json` (`MagpieLite` before the rename), one file per account, mode 0600 in 0700 folders excluded from backup. `<id>` is the SHA-256 hex of a canonical identity string; the tool's credential is stored as base64 of the exact bytes read from the tool's live store. Every write is a staged `O_EXCL` 0600 file, `F_FULLFSYNC`, a clone of the old file to `.prev`, then `rename(2)`. A file that fails validation is unknown and is never written over. (tech-design §3)

## Why

Claude Code and Codex refresh tokens are single-use: once a renewal succeeds, the old token is dead, so the renewed credential must reach disk before anything else reads the account, and a write for one account must never be able to damage another account's token. One file per account makes the blast radius of a bad write exactly one account; a single vault file would turn every renewal into a read-modify-write of all fifteen tokens, and "doesn't parse" into "every account unknown".

The switch path must hand each tool back exactly the bytes it wrote — Claude Code reads its Keychain value as one-line JSON with keys such as `mcpOAuth`, Codex keeps unknown `auth.json` fields, and agy expects its `go-keyring-base64:` envelope. Foundation's JSON serializers reorder keys and re-escape characters, so the stored copy is never re-serialized on the switch path, with one exception: Claude's Keychain item is composed from the target's `claudeAiOauth` and the live item's MCP keys, so a switch never regresses the live MCP logins (tech-design §4). Codex and agy get their saved bytes back unchanged; base64 of the raw bytes makes that round trip a byte-equality assertion. Only renewal produces new bytes, by patching known token keys and keeping unknown ones.

Keychain storage was the obvious choice and was rejected by the owner: an ad-hoc-signed app's code signature changes on every rebuild, which re-triggers Keychain access prompts for the app's own items. Codex's own `auth.json` and CodexBar's token store are 0600 files, the same exposure class.

## Considered alternatives

- **macOS Keychain items owned by the app.** Rejected because every rebuild of the ad-hoc-signed app changes its designated requirement and re-prompts for each item; the owner chose files.
- **Single `vault.json`.** Rejected because every renewal rewrites all accounts and a parse failure blocks the whole vault; a global `.prev` would roll unrelated accounts back to spent refresh tokens.
- **Index file plus per-account payload files.** Rejected because it adds a two-file consistency problem for ordering nobody needs; the directory listing is the index and the hash-derived name finds an account from its live identity.
- **Decoded, re-serialized payloads.** Rejected because re-serialization is not byte-faithful and has silently reverted tool-owned keys in reference tools.

## Consequences

- Envelope schema v1: `{v, tool, identity{…}, identityKey, payload(base64), generation, capturedAt, origin("save"|"sync-back"|"kept"|"renewal"), kept(bool), clientId?(agy azp)}`.
- Canonical identity strings: `claude:<email lowercased>:<organizationUuid>`, `codex:<email lowercased>:<chatgpt_account_id>`, `agy:<email lowercased>` (id_token `email`, or `id_token_email`, which agy 1.4.9 stores in place of the id_token; until 2026-10-28 it was `agy:<id_token sub>`, and launch moves such files to the email key); incomplete identity: `<tool>:incomplete:<sha256(refresh token)>`.
- Load validation: JSON parses, `v == 1`, tool matches folder, SHA-256 of `identityKey` equals the file name, payload decodes; any failure → account shown as an unreadable vault entry, write path refuses that id.
- `.prev` is forensic only and is never restored automatically — its refresh token is almost certainly spent.
- Launch takes an exclusive non-blocking `flock` on `vault/.lock` for the process lifetime; a second instance exits.
- `isExcludedFromBackup` is re-applied to the vault folder on every launch (a recreated folder loses it).
- Allowance readings are kept in memory, never in vault files, so the files change only when a credential changes.
- Risk: plaintext tokens readable by any process running as the owner — same as the tools' own `auth.json`; mitigated by 0600/0700 and backup exclusion.
