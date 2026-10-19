# Each context keeps its own saved accounts; usage is fetched once per account

Each Claude Code or Codex context keeps its own list of saved logins. The default context's list stays at `vault/<tool>/<id>.json`; another context's is `vault/<tool>/<first 16 hex of sha256(path)>/<id>.json`. Save, Switch, Remove and Undo act on one context's list, and a switch's outgoing login is kept in that list. Usage readings stay per account: an account saved in several lists, or live in several contexts, is fetched once per batch and every context listing it shows that reading. This supersedes ADR-0004's "saved accounts stay global" and the switch refusal built on it. (tech-design F-09)

## Why

With one shared list, removing an account from one context's page removed it from all of them, and a context's page listed accounts the owner had only ever used in another folder. The owner manages each folder as its own set of accounts.

Separate lists also fit how the tools renew. A context's saved copy of an account comes from signing in within that context, so it has its own refresh-token chain. Two contexts can then run the same account side by side, and the old rule refusing a switch while the account was live elsewhere has no reason left. The hazard that remains is one chain in two places, which only a copied folder creates.

## Considered alternatives

- **Shared list, Remove deletes everywhere and says so.** Rejected by the owner: contexts are managed separately.
- **Shared list with per-context visibility.** Rejected: every context would still switch to the same saved copy, so one chain could end up live in two folders.
- **A reading per saved copy.** Rejected: usage belongs to the account, and fetching each copy would multiply requests against Claude's per-account hourly budget.

## Consequences

- The vault refuses a login whose refresh token another context's list already holds (a copied folder), and keeps refusing one held under another account in the same list. A switch's outgoing login that is refused this way isn't kept, and the switch goes ahead.
- A switch is refused only when the saved login being switched in is the very one another context runs on (same refresh token), and while another context's login can't be read.
- Each batch fetches an account once: with its live login when it is live in any context (the one lasting longest), else with the saved copy whose access token lasts longest, renewing that copy first when it is due. Renewal still skips an account live in any context.
- Each context's live login is synced back into its own list only.
- Removing a context leaves its list's files on disk. Argus stops reading and renewing them, and adding the same path again brings the list back. The guard that refused removing a context running on a saved login is gone, since nothing renews that login once the context is unread.
- Existing saved logins are the default context's list; nothing moves. A named context starts empty, and the owner saves its logins from its own page.
- Risk: copies not used for fetching are not renewed by Argus. They wait until a switch makes one live, when its tool renews it. A vendor that expires unused refresh tokens would then ask for a sign-in.
