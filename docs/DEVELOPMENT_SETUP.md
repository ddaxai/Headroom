---
summary: "Development setup: stable signing and reducing Keychain prompts."
read_when:
  - Setting up local development
  - Reducing Keychain prompts during rebuilds
  - Configuring dev signing
---

# Development Setup Guide

## Reducing Keychain Permission Prompts

When developing Headroom, you may see frequent Keychain permission prompts like:

> **CodexBar wants to access key "Claude Code-credentials" in your keychain.**

There are two separate cases. Relay API keys are stored in Headroom's owner-only
`~/Library/Application Support/CodexBar/relay-credentials.json`, so opening the relay card does not need
Keychain access. Browser-cookie imports and Claude OAuth still use their provider-owned Keychain items.
Those prompts can recur when a rebuild changes the code signature or when an old copy of Headroom/CodexBar is
still running from a different path.

### Quick Fix (Temporary)

When the prompt appears, click **"Always Allow"** instead of just "Allow". This grants access to the current build.

### Permanent Fix (Recommended)

Use a stable development certificate that doesn't change between rebuilds:

#### 1. Create Development Certificate

```bash
./Scripts/setup_dev_signing.sh
```

This creates a self-signed certificate named "CodexBar Development".

#### 2. Trust the Certificate

1. Open **Keychain Access.app**
2. Find **"CodexBar Development"** in the **login** keychain
3. Double-click it
4. Expand the **"Trust"** section
5. Set **"Code Signing"** to **"Always Trust"**
6. Close the window (enter your password when prompted)

#### 3. Configure Your Shell

Add this to your `~/.zshrc` (or `~/.bashrc` if using bash):

```bash
export APP_IDENTITY='CodexBar Development'
```

Then restart your terminal:

```bash
source ~/.zshrc
```

#### 4. Rebuild

```bash
./Scripts/compile_and_run.sh
```

Now your builds use the stable certificate, so prompts for provider-owned items are much less frequent.

> Note: `compile_and_run.sh` now auto-detects a valid signing identity (Developer ID or CodexBar Development).
> Set `APP_IDENTITY` to override the auto-detected choice.

---

## Cleaning Up Old App Bundles

Headroom packaging writes only `.build/headroom-artifacts/Headroom.app`. If an older app is still
installed, inspect its exact path and move that one bundle to Trash; do not recursively remove all
matching app bundles.

---

## Development Workflow

### Standard Build & Run

```bash
./Scripts/compile_and_run.sh
```

This script:
1. Stops only the exact Headroom paths and known legacy CodexBar bundle path it owns
2. Runs `swift build` (release mode)
3. Runs the sharded full test suite when `--test` is passed
4. Packages the app with `./Scripts/package_relay_app.sh`
5. Launches `CodexBar.app`
6. Verifies it stays running

The packaged app is always written to `.build/headroom-artifacts/Headroom.app`; it is never left in the
repository root. Launching without `-n` plus the app's bundle-ID guard prevents a second menu-bar instance
when the same build is opened from another path.

Launching an unbundled `CodexBar` executable, including SwiftPM builds using `.build` or a custom scratch path, disables
Keychain access for that process to avoid repeated password prompts. Use the packaged `CodexBar.app` when local
validation needs browser cookies or stored credentials; packaged app bundles keep their normal Keychain behavior
regardless of signing mode.

When the script falls back to ad-hoc signing, it preserves existing provider state by default.
That means a provider may still ask for access to its own Keychain item, but relay API keys remain file-backed.
If you want a clean reset of CodexBar-owned keychain state for an ad-hoc build, run
`./Scripts/compile_and_run.sh --clear-adhoc-keychain` before relaunching.
Third-party keychain items still need stable signing if you want macOS to remember **Always Allow** across rebuilds.

### Quick Build (No Tests)

```bash
swift build -c release
./Scripts/package_relay_app.sh
```

### Run Tests Only

```bash
make test
```

### Debug Build

```bash
swift build  # defaults to debug
./Scripts/package_relay_app.sh debug
```

---

## Troubleshooting

### "Headroom is already running"

The compile_and_run script should kill old instances, but if it doesn't:

```bash
./Scripts/stop_headroom.sh
```

### "Permission denied" when accessing Keychain

Make sure you clicked **"Always Allow"** or set up the development certificate (see above).

### Multiple app bundles keep appearing

This usually means an old copy is still running from another path. The compile_and_run script stops the exact
Headroom paths plus the known `/Applications/CodexBar.app` path; it deliberately does not kill an unrelated app by name.

If you still see old bundles, quit the exact processes first, then move only these known stale bundles to Trash:

- `/Applications/CodexBar.app`
- any repository-root `Headroom.app` or `CodexBar.app` left by an older build

Keep `/Applications/Headroom.app` as the single installed copy.

After quitting the exact old processes, the repeatable install path is:

```bash
./Scripts/package_relay_app.sh release
./Scripts/install_headroom.sh
```

The installer refuses to replace a running app, moves old bundles to a recoverable directory under
`/private/tmp`, and launches Headroom without `open -n`.

### App doesn't reflect latest changes

Always rebuild and restart:

```bash
./Scripts/compile_and_run.sh
```

Or manually:

```bash
./Scripts/package_relay_app.sh
./Scripts/launch.sh
```
