<img src="assets/icon.svg" width="64" height="64" alt="">

# NudgeAgent

A macOS menu bar app for people with ADHD. Set a goal, and it notices when you drift away from it and gently nudges you back. See [DESIGN.md](DESIGN.md) for how it works.

## Install (download)

1. Download `NudgeAgent-<version>.dmg` from the [latest release](../../releases/latest) and open it.
2. Drag `NudgeAgent` onto the `Applications` folder in the window that appears, then eject the disk.
3. The app is not notarized by Apple yet, so macOS blocks the first launch. Either:
   - Double-click it, close the warning, then go to **System Settings > Privacy & Security**, scroll down and click **Open Anyway**; or
   - run `xattr -dr com.apple.quarantine /Applications/NudgeAgent.app` in Terminal, then open it.
4. Look for the dashed circle icon in the menu bar (if the menu bar is full, it may be hidden behind the notch).

Runs on macOS 14 or later, Apple Silicon and Intel.

## Run from source

Requirements: macOS 14 or later, Swift toolchain (Xcode or Command Line Tools), an Anthropic API key.

```bash
./scripts/run.sh
```

This builds `build/NudgeAgent.app`, signs it ad hoc and opens it. A target icon appears in the menu bar.

On first launch the welcome window asks for:

1. **API key**: stored in the macOS Keychain. For development, `ANTHROPIC_API_KEY` in the environment also works.
2. **Accessibility**: needed to read window titles and the Firefox address bar.
3. **Screen Recording**: used only to check unclear windows. Screenshots are never stored.
4. **Automation** (asked per browser on first use): reads the current tab's address.

Ad-hoc signing means macOS forgets the Accessibility and Screen Recording grants after each rebuild. To avoid that, sign with a stable certificate: `SIGN_IDENTITY="Apple Development: ..." ./scripts/run.sh`.

## Use it

- **New goal** (menu): write one sentence, for example "Find 20 qualified fintech leads in DACH and add them to Attio". Review the profile it proposes, then start.
- **Hotkeys**: `ctrl+option+P` parking lot (dump a thought, keep working), `ctrl+option+=` progress +1.
- **Debug window** (menu): live sensor stream and every classification with its reason. Use it to check data quality.
- Local data (corrections, session log, recaps, parking lot) lives in `~/Library/Application Support/NudgeAgent/`. No screenshots or page content are stored.

## Layout

| Folder | Module |
|---|---|
| `Sources/NudgeAgent/Shared` | Data types and interfaces between modules |
| `Sources/NudgeAgent/Sensors` | App, window title, browser URL, idle, lock, clipboard, meetings, file changes |
| `Sources/NudgeAgent/Intelligence` | Claude API client, goal to profile, classifier cascade |
| `Sources/NudgeAgent/Vision` | Window screenshot, on-device text recognition, privacy exclusions |
| `Sources/NudgeAgent/Engine` | Trip tracking, drift timing, nudge ladder, "Back to X" |
| `Sources/NudgeAgent/UI` | Menu bar, goal setup, nudge cards, settings, debug, recap |
