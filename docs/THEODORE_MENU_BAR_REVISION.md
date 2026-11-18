# Relay menu-bar revision

## Required default experience

- Keep a single merged status item.
- Render `sprinkler.and.droplets.fill` with a white sprinkler body and blue water.
- Show the active Codex account's weekly **remaining** percentage to the symbol's right.
- Lower the percentage title by one point so its visual center aligns with the symbol.
- While Codex writes to a rollout session, animate six cached outward-water frames at 4 FPS. Detect
  writes with FSEvents, keep no animation timer alive at rest, and stop animation in Low Power Mode
  or under serious thermal pressure.
- Reuse the same cached water frames while CodexBar is refreshing; keep a static colored symbol at rest.
- Put a compact relay switcher in the opened status menu, before account and usage cards.
- Offer the original configuration ("官方") and every ready relay profile from that switcher.

## Usage presentation

- Default multi-account presentation to stacked cards.
- Keep each account visually distinct and retain the weekly remaining ring.
- Show the local rolling 24-hour token and estimated-cost line inside the active Codex account card.
  When a newly named model has no local price, derive a visibly `≈`-prefixed estimate from the known
  30-day blended rate instead of leaving the amount blank.
- Keep the longer-window cost line below it when available.
- Do not show the generic "Usage Dashboard" menu action in this fork.

## Relay settings

- Display the saved API key in a normal text field when a profile is selected.
- Keep the credential source of truth in Keychain and keep plaintext out of Git/profile JSON.
- A relay profile is available in the quick switcher only when it has a model, credential, enabled
  writable target, and protocol-compatible targets.

## QA

- Verify the packaged app, not only SwiftUI previews.
- Confirm the status item symbol and remaining percentage in the macOS menu bar.
- Open the status menu and exercise the relay row without applying an incomplete profile.
- Confirm the Codex stacked view contains the 24-hour token/cost summary and no Usage Dashboard row.
