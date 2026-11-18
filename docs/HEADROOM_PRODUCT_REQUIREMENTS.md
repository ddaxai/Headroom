# Headroom Product Requirements

Status: living product requirements for Headroom.

This document records the product requirements that should survive refactors, upstream syncs, and UI rewrites. It is intentionally narrower than upstream CodexBar.

## Product definition

Headroom is a native macOS menu-bar app for two primary jobs:

1. Manage and monitor multiple official Codex accounts.
2. Manage, route, switch, and locally measure custom API relay profiles.

The app should answer four questions quickly:

- Which account or relay is active now?
- How much official quota remains for each Codex account?
- How many tokens have actually been used locally by each account or relay over time?
- Can I switch route/account safely without losing history or attribution?

## P0 — must preserve

### 1. Native macOS shell

- Native macOS menu-bar application.
- No duplicate menu-bar instances during development, install, update, or relaunch.
- Settings window supports a predictable always-on-top pin control.
- Menu and settings interactions must remain stable across window sizes and macOS appearance changes.

### 2. Official Codex multi-account management

- Add multiple official Codex/ChatGPT accounts.
- Keep each managed account's authentication isolated in its own Codex home.
- Distinguish same-email accounts/workspaces when the provider account/workspace identity differs.
- Add, remove, reauthenticate, and switch accounts without requiring a fresh browser login every time.
- Switching to account B must not delete or overwrite account A's managed authentication.
- If the current live system account is displaced during a switch, preserve it as a managed account before mutating live auth whenever possible.
- Switching the active account must be atomic and must not leave a partially written `auth.json`.

### 3. Per-account official quota that survives switching

- Show each official account's independent quota/rate-limit state, including the important session/weekly windows and reset times exposed by Codex.
- Inactive accounts remain visible and retain their most recent valid quota snapshot.
- Quota snapshots survive app restart.
- The active-account marker is independent from whether another account's quota data is visible.
- A stale/failed refresh must never display another account's data under the wrong identity.

### 4. Persistent local usage attribution

- Track local token/cost history separately for each official Codex account.
- Track local token/cost history separately for each relay profile.
- Switching accounts or routes must never reassign old usage to the newly active identity.
- Maintain an explicit ownership/route timeline for the shared Codex session corpus.
- Preserve `official`, `relay`, and `unassigned` provenance instead of guessing when evidence is insufficient.
- Support manual attribution for genuinely ambiguous historical ranges.
- Surface attribution confidence/provenance when useful for debugging.
- Historical data remains available when an account/profile is inactive.

Required presentation windows:

- rolling 24 hours, preferably with hourly bars;
- 7 days where useful;
- 30 days/history view;
- token and cost summaries with model/project/session breakdowns when the underlying data supports them.

### 5. Custom relay profiles

Each relay profile needs:

- user-defined name;
- base URL;
- API key/credential stored separately from ordinary metadata;
- API format (`OpenAI Responses`, `OpenAI Chat Completions`, or `Anthropic Messages` where compatible);
- optional default model;
- per-target enablement/overrides;
- save, edit, delete, and quick switch;
- validation before writing live client configuration.

Supported routing targets currently required:

- Codex;
- Claude Code;
- Claude Desktop;
- Grok Build;
- OpenCode;
- Pi Agent.

Applying a relay profile should use transactional configuration writes with rollback on failure.

### 6. Local-first token measurement for relays

Relay-reported token usage is not considered authoritative.

Headroom must have a local measurement path whose primary token count does not depend on a relay's accounting endpoint. Relay/server values may still be shown as secondary reference data.

Target semantics:

- **Local Tokens**: Headroom's locally measured/estimated count and the primary comparison metric.
- **Relay Reported Tokens**: optional server-reported value, clearly labeled as such.
- **Balance / Actual Charged Cost**: may remain server-reported when only the relay can know the billing balance or charged amount.
- **Local Estimated Cost**: computed from the locally measured tokens and an explicit pricing table when available; never presented as the relay's exact charge.

The UI should allow discrepancies to be visible rather than silently reconciling them.

Implementation note: the current Codex JSONL scanner and route provenance partition are useful inputs, but a future independent meter must verify whether local `token_count` events themselves inherit server-reported usage. If they do, a tokenizer/proxy/request-response measurement layer is required for independence.

### 7. Unified Codex history without identity corruption

- Official and relay Codex modes may share one physical Codex session history.
- Shared physical storage must not imply shared accounting ownership.
- Route provenance determines the accounting partition.
- A full-corpus view can exist, but per-account/per-relay views must be proper partitions of the same stable corpus generation.

### 8. Usage UI

- Official-account summary cards.
- Relay summary cards.
- 24-hour/hourly token charts.
- 30-day/history charts.
- Usage details open in a fixed right-side rail/drawer where possible so the parent menu height does not jump.
- Account/relay switching should be available from the menu bar without navigating deep into Settings.
- Empty, stale, loading, error, and unassigned states must be explicit.

### 9. Safe update/install lifecycle

- Headroom can check the configured source branch for updates.
- Update flow must detect dirty worktrees, local-ahead/diverged state, missing checkout/scripts, and fetch failures.
- Build/package/install/relaunch is staged and recoverable.
- Replacing a running app must not create two concurrently registered menu-bar instances.

## P0 — design and UI engineering rules

Visual work must stop depending on repeated one-off pixel patches.

### Design tokens

One source of truth is required for:

- palette/colors;
- typography;
- spacing scale;
- corner radii;
- control heights;
- icon sizes;
- menu/card insets;
- hit-target sizes;
- drawer widths and card grid rules.

Existing `ConsoleDesign` / `ConsolePalette` should be treated as the beginning of this system rather than bypassed with local constants.

### Component contracts

Every custom component that mixes SwiftUI and AppKit must define geometry and behavior invariants. Examples:

- titlebar pin/sidebar accessory has an explicit container size and guaranteed visible hit frame;
- menu rows share fixed horizontal alignment tokens;
- cards do not change parent menu height when a detail rail opens;
- icon size and hit target are separate concepts;
- active, hover, disabled, loading, and error states are specified.

### Visual verification

For UI work, the acceptance loop is:

1. render the exact component/window in Xcode Preview or a deterministic fixture;
2. compare against a named reference state;
3. adjust tokens/component code, not unrelated call sites;
4. run geometry/snapshot tests;
5. launch the packaged Headroom app for final real-menu/titlebar validation.

A UI change is not complete merely because it compiles or because a unit test passes.

## Current implementation already aligned with these requirements

The current branch already contains substantial foundations for the product above:

- managed Codex accounts and live-account promotion;
- persisted per-account quota snapshots;
- account/workspace identity reconciliation;
- relay profile models, credential storage, endpoint validation, target config writers, and transactional config updates;
- relay quick switching and relay settings UI;
- local Codex token/cost scanning;
- `CodexSessionOwnershipTimeline` with account activation, route events, manual attribution, and persistent storage;
- official/relay/unassigned provenance classification;
- attributed official-account and relay partitions of the shared Codex corpus;
- Headroom-specific cards, hourly/history charts, detail rail, palette/design tokens;
- Headroom source update/package/install lifecycle;
- single-instance protections and migration logic.

## Known gaps / unresolved acceptance criteria

1. **Independent relay token truth** — local relay partitions exist, but the project still needs to prove whether the token values read from Codex JSONL are independent of inaccurate relay `usage` fields. If not, add a genuine local tokenizer/meter layer.
2. **Historical attribution completeness** — pre-timeline sessions may remain `unassigned`; do not guess. Manual attribution and migration UX need to be good enough for real historical cleanup.
3. **UI stability** — repeated titlebar/pin fixes show that geometry contracts and visual regression fixtures need to be first-class, especially where AppKit titlebar APIs wrap SwiftUI state.
4. **Architecture boundaries** — relay routing, usage attribution, account management, data presentation, and Headroom lifecycle should have explicit module boundaries before more large features are added.

## Deliberate non-goals unless requirements change

- Becoming a general-purpose monitor for every provider supported by upstream CodexBar.
- Trusting relay token totals as the canonical local usage truth.
- Recalculating a relay's exact billed charge when only the relay knows its billing rules.
- Silent attribution of ambiguous historical usage.
- Importing another project's entire UI/settings architecture wholesale.

## Architecture target for the next refactor

Keep the current CodexBar-native macOS foundation, but organize Headroom around five explicit domains:

1. **Identity & Accounts** — official Codex identities, managed homes, auth promotion, account snapshots.
2. **Routes & Relays** — relay profiles, credentials, target config generation, transactions, active route.
3. **Usage Ledger** — local corpus scanning/metering, ownership timeline, provenance, account/relay partitions, history.
4. **Presentation System** — design tokens, reusable cards/rows/controls, charts, fixed detail rail, preview fixtures.
5. **Lifecycle** — migration, single instance, source update, package/install/relaunch.

New features should attach to one of these domains instead of adding another cross-cutting patch to menu/store/settings code.
