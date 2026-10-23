# 🥚 Gab Hub — Steal An Egg (v2.1.0 "BAC-safe rebuild")

**Keyless** • **Mobile-first (Delta Android)** • **No external dependencies** — rebuilt from scratch against the game's **PlaceVersion 447** codebase, using movement and remote signatures verified against a battle-tested open-source implementation.

## Loadstring

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Inkflow-Gab/Gab-Hub-Steal-An-Egg/main/GabHub_StealAnEgg.lua", true))()
```

Menu bind: **RightShift**.

## Why v2.1.x stops the "detected as cheating" (BAC-3518) kicks

The game's anti-cheat is **server-side**. It cannot be blocked by anything running in an executor — it watches *how you move* and *what you send*, and reacts:

- Writing your character's **position** (teleporting / "warp") → your character is killed (and this game has **no respawn** — you must rejoin).
- **Anchoring** yourself and tweening → flagged as cheating → "detected as cheating" (Error 267 / BAC-3518 family).
- **Wrongly-shaped** network calls repeated over and over → also flags the validator.

So v2.1.0 removes everything that tripped it:

1. ❌ **Removed the old "detector freeze" bypass** — it fingerprinted the *pre-rename* build and could freeze a legitimate system on the renamed v447 build. That instant-on-execute kick you saw? Prime suspect. Deleted entirely.
2. ❌ **Removed all teleport code.** Movement is now **real `Humanoid:MoveTo` walking with PathfindingService** — the server's radar only reacts to movement that isn't real walking.
3. ❌ **Removed WalkSpeed / JumpPower sliders.** Your Speed is never touched; the game raises it legitimately via your base **treadmill** (Speed ↑ = faster zones open up safely).
4. ✅ **Fixed every remote signature** against PlaceVersion 447: `RF/Homestead/*`, `RF/EggWorld/*` (including `AskPlaceEgg {Uid, LocalCFrame}` and the two-step `AskHatch` → `AskFinishHatch`), `RF/PenRoster/*`, `RF/AwayEarnings/*`, `RF/Treadmill/AskTierRaise` — exact payloads the game's own UI sends, globally paced to ~8 requests/sec.
5. ✅ **Client-only `:Kick` blocker** remains (harmless; blocks client-initiated kicks only — server BAC cannot be blocked, which is why staying under the radar is the real fix).
6. ✅ Optional **Fast mode** (humtween) for commuting: tweens *without anchoring*, speed is hard-bound to **2× your real WalkSpeed** (the measured safe ceiling), and silently falls back to plain walking if the game pushes back. It is **off by default** — leave it off until walking is stable for you.

## Features (matching the in-game tabs)

### 🏠 Main
- Live **status**: what it's doing, your walk speed, Speed stat, stolen/hatched/placed/sold counts
- **Auto Steal** • **Auto claim offline earnings**
- **Diagnostics** button — reports plot/pen/origin/field-eggs/pets/guards/assets/mutation-module/treadmill as OK or MISSING (send me the notification text if anything says MISSING)

### 🥚 Steal
- **Area chips**: pick which zones to steal from (none selected = all)
- **Guard-speed safety**: eggs in zones whose guards are faster than you (accounting for the carry weight penalty) are **skipped automatically** — dying in this game means rejoining, so it never would/can't risk it
- **Prefer richest** or nearest, **min income floor** (% of your best pet), **eggs per outing** (chain grab)
- **Fast mode** (opt-in, off by default) — see above

### 📦 Base
- **Auto Place** eggs into your pen (spaced, verified `LocalCFrame` placement)
- **Auto Hatch** two-step (AskHatch → wait → AskFinishHatch) when growth is complete
- **Auto Equip** best backpack pets • **Auto Sell** when the pen is full (replaces your *worst* pet when a better one arrives) • also sell worse backpack pets

### 🏃 Train
- **Auto Train**: stands on your treadmill — the game's own legit way to raise Speed (and therefore unlock zones safely)
- **Auto upgrade treadmill** with a **price cap exponent** (0 = off, 6 ≈ $1M, 9 ≈ $1B)

### 👁 Visual
- **Egg ESP** with value labels and render distance
- **FPS boost** (shadows off, particle sweep, FPS cap)

### ⚙️ Settings
- JSON config auto-saves to `GabHub_SAE.json`; unsafe legacy keys (teleport/speed sliders) are sanitized on load
- **Safety mode**: every feature OFF + saved (use this first if anything misbehaves)
- **Release movement** (un-stick your character), keybind, titlebar minimize, clean **Unload**

## How to run it safely (first session)

1. Join the game, wait ~2 s, execute the loadstring.
2. Press **Diagnostics** once and check the notification — everything should say OK.
3. Toggle **Auto Steal** only. Expect it to be *slower* than "instant" hubs — it **walks**, which is exactly why the server leaves it alone. Real Speed growth comes from the Treadmill tab.
4. Once that has run a while with no kick, explore the other tabs. **Fast mode stays off** until you're confident.

## Notes specific to this game

- **Death = no respawn.** If your character dies (e.g. carrying into a too-fast guard zone), you must rejoin. The hub pauses itself and notifies you — it never steals in zones your Speed can't outrun.
- **Zone resets**: the world re-serves every few minutes; the hub holds at your base when a reset countdown event fires and waits for eggs to respawn.
- Never fired by the script: `RE/RigSync/AskRigWipe` (self-firing it flags the server; only death notifications are used).

## Disclaimer
Using third-party scripts/games automation violates Roblox ToS — use an alt account. Not affiliated with Roblox or the game's developers.
