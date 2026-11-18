# Codex quota CLI compatibility repair

## Observed failure

The installed Headroom build 158 showed this existing fetch attempt in its diagnostic UI:

```text
codex.cli (cli) available
error=Codex returned invalid data: codex app-server closed stdout
```

The temporary debug-settings toggle was returned to off after inspection. No account switch,
credential read, provider probe button, or client configuration modification was performed.

## Isolated reproduction

Both the installed standalone CLI and the desktop-bundled CLI were launched with a fresh
temporary HOME/CODEX_HOME, an empty environment apart from temporary paths and system PATH,
and `-c cli_auth_credentials_store="file"`. No real configuration or credentials were loaded.
The standalone CLI reports version 0.152.1.

The old `-s read-only -a untrusted app-server` invocation exits 2 before initialization:

```text
error: invalid value 'untrusted' for '--ask-for-approval <APPROVAL_POLICY>'
  [possible values: on-request, never]
```

Removing only `-a untrusted` keeps the read-only sandbox and allows an initialize RPC to
return a result with id 1. The isolated process was terminated and reaped after that handshake;
no account read or real request was sent. `--help` alone did not detect this argument error.
Official transport reference: https://developers.openai.com/codex/app-server/

## TDD evidence

- `codex-rpc-approval-red-20260905.log`: rejected filter invocation, matched **zero** tests,
  exit 3. This is not behavioral red evidence.
- `codex-rpc-approval-behavior-red-20260905.log`: 15 tests matched, 2 new behavioral failures,
  exit 1; both default initializers hit `closed stdout` when the fake CLI rejects `untrusted`.
- `codex-rpc-approval-focused-green-20260905.log`: focused rerun after implementation.

The fake CLI only allows initialization and account read RPCs, asserts the read-only sandbox
arguments, and returns distinct nonzero quota windows. It never accesses user data.

The status-probe TTY path is not used by this RPC fetch and is not changed in this repair.

## Verification before packaging

At HEAD `592543e9661cdfc023da3f6838f0d48b84a93608` plus the repair working diff:

- Focused: 62 tests in 4 suites passed; no retries or timeouts.
- `quality_gate.py --parent-ref 592543e`: PASS, exit 0, 844 selections, 71/71 groups,
  zero failures/retries/timeouts, test baseline new/resolved 0/0.
- SwiftFormat 290/290, strict new/resolved 0/0; SwiftLint 150/150, strict new/resolved 0/0.
- Platform: macOS 26.6 arm64, Swift 6.3.3.
- Summary: `codex-rpc-approval-quality-gate-20260905.json`; full output is retained locally
  in `codex-rpc-approval-quality-gate-20260905.log`.
- The 2 new tests extend an existing suite; selections remain 844.
- Installed-app quota success and the user's current menu-bar appearance remain separate
  runtime verification steps. The currently selected high-contrast option was off when inspected.
