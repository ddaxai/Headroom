# Unified Codex session history

Codex filters its local session list by the active `model_provider`. A normal relay switch therefore
uses a different history bucket from the built-in OpenAI provider even though the JSONL files remain
on disk.

This fork enables **Settings → Relay → Unified Codex session history** automatically. The first Relay
settings load or official/relay switch performs the migration before changing the active route.

When enabled, the app:

- routes both official OAuth and relay configurations through the stable `codexbar_shared` provider ID;
- keeps official mode on the normal `~/.codex/auth.json` OAuth credentials and does not copy tokens;
- backs up and rewrites matching `session_meta.model_provider` values in `sessions` and
  `archived_sessions`;
- backs up and updates every detected `state_5.sqlite`, including the root database, the legacy
  `sqlite/state_5.sqlite`, and a configured `sqlite_home` / `CODEX_SQLITE_HOME` database;
- stores the original provider in `codexbar_origin_provider`, which Codex ignores and CodexBar uses
  to preserve existing official-vs-relay token/cost attribution;
- automatically rolls back completed writes if a later migration step fails;
- blocks the requested route switch if the migration cannot complete safely.

Backups and a migration manifest are stored below the Relay backup directory in `UnifiedHistory`.
API keys and OAuth tokens are not included in the history migration manifest.

## Important limitation

Unified history makes conversations visible under both routes. It does not make backend-specific
`encrypted_content` portable. Continuing a conversation with a different provider can fail, so switch
back to the route that created the conversation before resuming it. Restart Codex after enabling the
feature so the desktop app reloads its provider-filtered history index.

Type-invalid response item IDs can also break replay even when `encrypted_content` is absent.
The [offline replay compatibility prototype](codex-replay-compatibility.md) handles request copies
and documents the remaining desktop integration boundary. It is not enabled in the switch flow.

New sessions created after enabling use the shared provider ID and do not contain a trustworthy route
identity. They remain included in the compact total, but are not assigned to the official or relay
subtotals unless a future route ledger can prove their origin.
