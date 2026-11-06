# AA Macro — scaffolding

A native macOS (Swift/SwiftUI) macro for Anime Adventures. It **sees** the game with
ScreenCaptureKit + Apple Vision, **acts** with CGEvent mouse/keyboard events, and
**decides** with a state machine that checks each screen before acting — so it doesn't
drift the way click-replay tools (TinyTask etc.) do.

> Status: lobby → matchmaking → vote flow is wired to the real game screens (UPD 21.0.0).
> Still needed: results/defeat screen (an OCR guess is in place until then).
>
> Previously: scaffolding. Structure, loop and record/replay logic are written; screen regions,
> button templates and thresholds are placeholders until your screenshots come in.
> It hasn't been compiled yet — expect a few small fixes on the first Xcode build.

---

## Run it

1. Open `Package.swift` in Xcode (File → Open). Xcode treats it as a project.
2. Select the `AAMacro` scheme → My Mac → Run (⌘R).
3. macOS will ask for **Screen Recording** and **Accessibility** (and possibly **Input Monitoring**).
   Grant them in System Settings → Privacy & Security, then re-run.
   (When running from Xcode, the permission may attach to Xcode itself — that's fine for dev.
   Later we'll turn this into a proper `.app` so it has its own permissions.)
4. **F6** stops everything at any time.

## Frame around Roblox (`UI/DockPanel.swift`)

The macro wraps the Roblox window in a tight frame, like all-in-one Windows macros:
a **top bar** (status, permission checks, Start/Stop, ⚙️), a **right column** (Unit 1–6 cards:
priority, max level, range; auto-placement options) and a **bottom strip** (Current Process
log, Settings, Statistics, Record). They're three borderless panels flush against Roblox that
follow it, float above other apps, never overlap the game and never take keyboard focus.
Roblox is placed and sized automatically so the whole frame fits on screen.

## Reliability features

- **Walk by landmark** — after spawning in the summer area it steers toward the "Summer Event"
  board (strafe A/D to centre it, step W) until "Join Matchmaking?" appears; sidesteps blockers.
- **Popups** — outside matchmaking/vote/cards, clicks Close / OK / Skip / Claim / Continue / …
  on anything blocking the screen (checked every ~6 s during a match too).
- **Disconnects** — "Disconnected" dialog → Reconnect, wait, restart the loop.
- **Slot limits** — reads the "0/1" / "4/4" counter while holding a unit; full slots are skipped.
- **Upgrades** — through F → Unit Overview (finds the unit by its hotbar name, clicks its
  "Upg" button, cheapest copy first). Falls back to clicking the unit on the map.
- **Lag ×** — stretches every wait at once (Settings).
- **Stuck timer** — a run longer than N minutes is abandoned and restarted.
- **Loss streak** — optional stop after N losses in a row (off until the results screen is confirmed).
- **Vote** — waits 2 s after the vote box appears, clicks Yes up to 5× until it registers.

## Settings persistence

Settings save on every change (atomic write) to `~/Library/Application Support/AAMacro/`
and load on launch. Loading is tolerant: if an update adds a new setting, only that one
starts at its default — the rest of your settings are kept.

## What it does in Anime Adventures (from your screenshots)

1. **Lobby** — OCRs the left HUD for exactly "Play" and clicks it (no template needed).
2. **Summer area** — reads the event board ("Summer Event · Magic Town") as a map hint, then
   replays your recorded lobby walk in 0.3 s slices and stops the instant
   **"Join Matchmaking?"** appears. If the walk falls short it nudges forward with W.
3. **Matchmaking** — clicks **Find Match**, finds "Please enter this text…", reads the green
   code under it, clicks the **?** box, types it, clicks **Submit**. If the popup is still there
   (misread), it clears the box and reads again (3 tries).
4. **Vote** — waits for "Vote start", clicks **Yes**.
5. **Map ID** — compares the **minimap path** (bottom right) to each recorded map's minimap.
   Path shapes differ per map and don't change with the camera. Falls back to the board hint.
6. **Weather cards** — when "The weather shifts…" appears, reads the 3 cards, judges each
   by its background (green = buff, red = debuff) and the color of each effect line, picks the
   best per your rules, clicks it, then clicks **Vote**. (Checked on a real card screen:
   Low Tide → buff, Tsunami / Rising Tide → debuff, every red line detected correctly.)
7. **Upgrades** — clicks the placed unit, reads "UPG [n]" and "Upgrade: 7000¥" from the
   panel, waits for the yen, presses **R**, confirms the level went up, closes the panel.
   Stops at MAX or at the per-slot max level.
8. **Map ID** — reads the stage title first ("Magic Town Summer Hunt"); minimap is the backup.
   Name each recording after the map (e.g. "Magic Town").
9. **Placement** — reads each slot's cost from the hotbar ("1200 ¥"), waits until the yen
   counter can afford it, places, and checks yen dropped by ~that cost.

All screen regions live in `Core/Regions.swift`.

**Window size**: the app locks Roblox to 1000×627 pt at (40, 40) — your current windowed size —
and re-checks it every step, so if anything moves or resizes the window it snaps back.

**Recording a map**: start recording during the **vote screen**, so the saved fingerprint
(the minimap) is captured right away. Click Yes yourself — clicks that aren't placements are
not recorded.

## Auto mode — no recording needed (`Core/AutoPlanner.swift`)

While you hold a unit, the game paints the map: **green** = this unit can go here
(hills light up for hill units), **red** = enemy path and spots other players took.
Auto mode uses that:

1. Press the slot key, park the cursor on the hotbar, screenshot, press **Q** to cancel.
2. Classify a 160×100 grid into green / red. Path = red blobs that are big *and* thick
   (thin range rings and small blobs from other players' units are dropped).
3. Pick the green spot whose range covers the most path. Path already covered counts
   less, so units spread out along the path.
4. Place units in **Placement order** (Settings → Auto mode, e.g. `1 1 3 2 4`). Priority slots
   get a few upgrades right away, then everything is upgraded with priority slots first.
5. If the match is won, the layout is saved as that map's recording, so the next run on that
   map replays the proven layout.

Tested on a real Magic Town screenshot: path detected correctly, picks landed in the valid
green area beside the path. Unit range defaults to 12% of the window width; adjust per slot.

## The loop (`Core/MacroEngine.swift`)

```
lobby ──► walkToEvent ──► matchmaking ──► enterCode ──► loadingStage
  ▲                                                          │
  │                                                          ▼
results ◄──────────────────────────── playStage (identify map → replay recording)
  │
  └─ any error/timeout ──► recovering ──► lobby
```

| State | What it does | Needs from you |
|---|---|---|
| lobby | Finds the Play button (template match) and clicks it | `play_button.png` |
| walkToEvent | Replays the recorded lobby walk (W/A/S/D + durations) | Record it once (Settings tab) |
| matchmaking | OCRs the code inside `Region.matchmakingCode` | Screenshot → set the region + code length |
| enterCode | Clicks the input box, types the code, presses Return | Screenshot of how the code is entered |
| playStage | Identifies the map, replays its recording with verification | Record each map once |
| results | Waits for the end-of-match button (win **or** loss), clicks it, loops | `return_to_lobby.png` (+ `defeat_return_to_lobby.png` if the loss screen differs) |
| recovering | Looks at the screen and resumes from wherever it actually is (see below) | `close_popup.png` (optional) |

## Files

```
Sources/AAMacro/
  App.swift                 app entry, permission prompts, F6 stop key
  Core/
    Models.swift            MacroAction (walk/place/upgrade/wait/waitForWave), MapRecording, MacroSettings
    Store.swift             saves maps/settings/templates in ~/Library/Application Support/AAMacro/
    MacroEngine.swift       the state machine above + placement/upgrade verification + priority ordering
  Vision/
    ScreenCapture.swift     grabs only the Roblox window (works even if something overlaps it)
    Matcher.swift           template matching, image similarity, pixel color checks, OCR helpers
  Input/
    InputController.swift   clicks (move → wiggle → down → up, Roblox needs this), keys, holds, typing
    WindowManager.swift     finds Roblox, locks its size/position, converts coordinates
  Recording/
    Recorder.swift          record mode: turns your real play into editable actions
  UI/
    RootView.swift          the macro page: Run / Maps / Settings tabs
```

## Key ideas

**Coordinates are fractions of the window** (`NormPoint`, 0–1). The window is locked to
`1280×800` at `(40, 40)` before recording and before running, so the same fractions always
hit the same spot. Change `WindowManager.lockedSize` *before* recording any maps.

**Recording produces actions, not mouse paths.** While you play a map:
- holding W/A/S/D → `Walk W for 1.40s` (use this to walk to the lit-up arrows at the enemy spawn)
- pressing `3` then clicking → `Place slot 3 at (0.412, 0.630)`
- clicking a unit you placed, then pressing the upgrade key → `Upgrade unit #2 ×3`
- pauses over 2 s → `Wait 4.2s`

You can then reorder/delete steps or add "wait for wave N" on the Maps tab.

**Map recognition**: first OCR the stage name and match a map's keywords; if that fails,
compare against the screenshot saved when you recorded the map.

**Verified placement**: after each placement it checks your yen dropped (OCR). If not, it
presses Escape, waits (usually you just couldn't afford it yet) and retries at small offsets
around the recorded spot — helps with hill-only units.

**Losses**: a loss is just another results screen, so the loop continues to the lobby.
Also, a failed placement no longer aborts the run (it's skipped and logged), and
`recovering` checks the screen: results → click out; lobby → restart; still mid-match → wait
for the match to end; 5 failures in a row → Escape + 30 s cooldown.

**Cards**: never recorded. Whenever the macro waits or is about to act in a stage, it checks
for `card_screen.png`. If it's showing, it OCRs `Region.cardArea`, splits the text into cards
by horizontal position, tells buffs (green) from debuffs by sampling each card's color, and ranks them:
green buffs (except yen) → debuffs that only raise enemy HP or speed → yen buffs → any other
debuff. The word lists behind those rules, a priority list for tie-breaks and an avoid list are
all editable on Settings → Cards. It then clicks the winner, and clicks
`card_confirm.png` if that exists. While **recording**, clicks made during the card screen are
ignored, so your card picks never end up in a map's steps (`CardPicker.swift`).

**Upgrade priority**: on the Settings tab, toggle the slots that should go first. Their place +
upgrade steps run before everything else; recorded order is kept within each group.

## Templates you'll make from screenshots

Crop each button tightly from a screenshot taken at the locked window size and save it as a
PNG in `~/Library/Application Support/AAMacro/templates/`:

- ~~`play_button.png`~~ (not needed — found by OCR)
- `return_to_lobby.png`
- `close_popup.png` (any popup that can block the loop, e.g. level-up)
- `defeat_return_to_lobby.png` (only if the loss screen's button looks different)
- `card_screen.png` (something that's always visible when cards are offered, e.g. a title)
- `card_confirm.png` (only if picking a card needs a confirm click)

(Once you send screenshots I'll crop these and fill in the regions for you.)

## TODO once screenshots arrive

- [ ] Real values for `MacroEngine.Region` (code, stage name, wave, yen, card area)
- [ ] Your card priority / avoid lists
- [ ] Code length / format and how it's entered (typed vs on-screen buttons)
- [ ] Confirm the upgrade keybind (default `t` is a guess)
- [ ] Title-bar offset in `WindowManager.screenPoint` if clicks land a bit high
- [ ] Tune `Matcher.find` threshold
- [ ] Wire up `maxLevelPerSlot` (setting exists, not enforced yet)
- [ ] Optional: Discord webhook with a screenshot after each run
