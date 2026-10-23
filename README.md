# 🥚 Gab Hub — Steal An Egg

**Keyless** • **Mobile-first (Delta Android)** • **No external dependencies** — a from-scratch rebuild of Gab's outdated Steal An Egg script, styled after modern hubs.

## Loadstring

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Inkflow-Gab/Gab-Hub-Steal-An-Egg/main/GabHub_StealAnEgg.lua", true))()
```

Menu bind: **RightShift** (changeable in the Settings tab).

## Features

### 🥚 Auto Steal
- Filters by **area**, **minimum rarity**, skips eggs you already own
- **Rarest-first targeting** (rarity second, distance tiebreak).Failed eggs cool down instead of spamming retries
- Walk mode (configurable speed) or riskier teleport mode
- Delivers the egg you're already carrying home first, every loop
- Auto Place carried eggs at your base after delivery

### 📦 Base
- **Auto Place** inventory eggs (rarity threshold)
- **Auto Hatch** placed eggs when ready
- **Auto Sell** eggs & pets up to a chosen rarity index
- **Auto upgrade** base tiers
- **Auto treadmill** (walks to your treadmill, sits it, tries tier raises)
- **Auto equip best** pets

### 🛒 Shop
- Auto buoy trail purchases, rate-limited once per 6s

### ⚔️ Combat
- Bat aura (radius slider), guard strike aura, **defend my base**

### 🏃 Movement
- WalkSpeed, JumpPower sliders (re-applied on respawn)
- Infinite jump, NoClip, **Anti AFK**

### 👁 Visual
- **Egg ESP** with rarity labels + render distance slider, rare colors
- **FPS boost** (no shadows + periodic particle sweep)

### ⚙️ Settings
- JSON config that auto-saves to `GabHub_SAE.json`
- Diagnostics button in **Main** — instantly reports what the hub can read (egg records / inventory / remotes)
- Clean **Unload** (stops every loop, closes the GUI)

## How the rebuild stays correct
- Reads the game's **current** data APIs directly (`Client.EggState`, `Shared.Save`, `Data.Assets`, `Packages.Networking`)
- Any missing remote/module is auto-detected and reported by **Diagnostics** instead of silently erroring
- Every network call and loop is pcall-wrapped — one bad response never kills the hub
- Touch-first GUI (drag works with mouse **and** finger), scales down to small screens automatically

## Disclaimer
Using third-party scripts/games automation violates Roblox ToS — use an alt account. Not affiliated with Roblox or the game's developers.
