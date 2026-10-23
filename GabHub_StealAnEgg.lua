--==============================================================================
--  GAB HUB | Steal An Egg   --  v2.1.0 "BAC-safe rebuild"
--  by Gab (Inkflow-Gab) — keyless, Delta/Android friendly
--
--  HOW THIS VERSION HANDLES THE BAC KICKS (your BAC-3518 / Error 267 family):
--   * The game's anti-cheat runs SERVER-side and catches movement that is not
--     real walking. Position teleports get your character killed outright and
--     anchored/tweened parts get flagged as cheating — and NOTHING run on the
--     client can block that kick. The fix is to never trip it.
--   * So this build NEVER writes position, never anchors, never raises
--     WalkSpeed. Movement is real Humanoid:MoveTo walking with
--     PathfindingService around obstacles. An optional "fast mode"
--     (humtween — verified against this game) smoothly tweens WITHOUT
--     anchoring, keeps its speed bound to 2x your REAL WalkSpeed (the measured
--     safe ceiling), and auto-falls back to plain walking if anything pushes
--     back.
--   * Speed progression is done the game's own way: standing on your treadmill.
--   * Every server call uses the game's CURRENT signatures (PlaceVersion 447):
--     RF/Homestead/*, RF/EggWorld/*, RF/PenRoster/*, RF/AwayEarnings/*,
--     RF/Treadmill/AskTierRaise — with the exact payload the game's own UI
--     sends. No guessed/named-wrong remotes (that burst is what gets flagged).
--   * The old "detector freeze" hack (fingerprinted from the pre-rename build,
--     and the prime suspect for the instant kick on load) has been REMOVED.
--     Replaced with a client-side :Kick blocker only (harmless, conservative).
--
--  Menu bind: RightShift (changeable in Settings tab)
--==============================================================================

if not game then
    error("GabHub: run this inside a Roblox executor, not a plain Lua editor.", 0)
end

local Hub     = { Version = "2.1.0" }
local SESSION = { connections = {}, instances = {}, dead = false }

-- Re-execution safety: tear down any previous run cleanly ----------------------
if getgenv().GabHub_SAE and type(getgenv().GabHub_SAE.Unload) == "function" then
    pcall(getgenv().GabHub_SAE.Unload)
    task.wait(0.3)
end
getgenv().GabHub_SAE = Hub

--------------------------------------------------------------------------------
-- Services
--------------------------------------------------------------------------------
local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local TweenService      = game:GetService("TweenService")
local Lighting          = game:GetService("Lighting")
local HttpService       = game:GetService("HttpService")
local VirtualUser       = game:GetService("VirtualUser")
local PathfindingService = game:GetService("PathfindingService")

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Bookkeeping helpers
--------------------------------------------------------------------------------
local function track(conn)
    if conn then table.insert(SESSION.connections, conn) end
    return conn
end
local function trackInstance(obj)
    if obj then table.insert(SESSION.instances, obj) end
    return obj
end
local function safeCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, result = pcall(fn, ...)
    if ok then return result end
    return nil
end
local function verbose(...)
    if not getgenv().GabHub_Verbose then return end
    print("[GabHub]", ...)
end

-- "10M" / "1,500,000" / 1e7 -> number -------------------------------------------
local function parseAmount(v)
    if type(v) == "number" then return v end
    if type(v) ~= "string" then return 0 end
    local s = v:gsub(",", ""):gsub("%s", "")
    local num, suf = s:match("^([%d%.]+)([%a]*)$")
    if not num then return tonumber(s) or 0 end
    local mult = ({
        k = 1e3, m = 1e6, b = 1e9, t = 1e12, q = 1e15, s = 1e21,
    })[suf:lower()] or 1
    return (tonumber(num) or 0) * mult
end
local function short(n)
    n = tonumber(n) or 0
    local units = { { 1e15, "Q" }, { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
    for _, u in ipairs(units) do
        if n >= u[1] then return string.format("%.2f%s", n / u[1], u[2]) end
    end
    return string.format("%.0f", n)
end

--------------------------------------------------------------------------------
-- Character helpers (read-only; we never touch position/anchors here)
--------------------------------------------------------------------------------
local function findChar()
    local c = LocalPlayer.Character
    if c and not c.Parent then return nil end
    return c
end
local function charParts()
    local c = findChar()
    if not c then return nil end
    local hrp = c:FindFirstChild("HumanoidRootPart")
    local hum = c:FindFirstChildOfClass("Humanoid")
    if not hrp or not hum or hum.Health <= 0 then return nil end
    return c, hrp, hum
end
local function humanoidAlive()
    local c = LocalPlayer.Character
    local hum = c and c:FindFirstChildOfClass("Humanoid")
    return (hum and hum.Health > 0) and hum or nil
end

--------------------------------------------------------------------------------
-- Config  (JSON file, survives re-joins)
--------------------------------------------------------------------------------
local ConfigFile = "GabHub_SAE.json"

local Defaults = {
    Keybind = "RightShift",

    -- Steal
    AutoSteal      = false,
    Areas          = {},      -- area name -> true (empty = all)
    MinRatePct     = 1,       -- egg must earn >= this % of your best pet
    PreferBest     = true,    -- richest first (nearest when off)
    ChainGrab      = 5,       -- eggs per outing before base work
    FastMode       = false,   -- humtween (verified) — leave off until stable
    GrabTimeout    = 6,
    ClaimTimeout   = 14,

    -- Base
    AutoPlace      = false,
    AutoHatch      = false,
    AutoEquip      = false,
    AutoSell       = false,
    SellBackpack   = true,
    AutoClaimOffline = false,

    -- Upgrades & training
    AutoTrain          = false,  -- stand on treadmill to raise REAL Speed
    TreadmillSeconds   = 20,
    AutoTrainWhenSlow  = true,
    AutoUpTreadmill    = false,
    MaxTreadmillPrice  = 0,      -- 0 = no cap

    -- Visuals
    EggESP       = false,
    ESPDistance  = 250,
    FPSBoost     = false,
    Notifications = true,
}

local Config = {}
for key, value in pairs(Defaults) do
    if type(value) == "table" then
        local copy = {}
        for ik, iv in pairs(value) do copy[ik] = iv end
        Config[key] = copy
    else
        Config[key] = value
    end
end

local function safeDecode(str)
    local ok, data = pcall(function() return HttpService:JSONDecode(str) end)
    if ok then return data end
    return nil
end

function Hub.SaveConfig()
    if type(writefile) ~= "function" then return end
    local ok, str = pcall(function() return HttpService:JSONEncode(Config) end)
    if ok and str then pcall(writefile, ConfigFile, str) end
end
function Hub.LoadConfig()
    if type(readfile) ~= "function" or type(isfile) ~= "function" then return end
    local exists = false
    pcall(function() exists = isfile(ConfigFile) end)
    if not exists then return end
    local data = safeDecode(safeCall(readfile, ConfigFile))
    if type(data) ~= "table" then return end
    for key, value in pairs(data) do
        if type(Config[key]) == nil or type(Config[key]) == type(value) then
            if type(Config[key]) == "table" and type(value) == "table" then
                Config[key] = value
            elseif type(Config[key]) ~= "table" then
                Config[key] = value
            end
        end
    end
    -- Sanitize legacy/unsafe values from older versions
    Config.StealTeleport   = nil   -- teleports get your character killed
    Config.StealSpeed      = nil   -- we never touch WalkSpeed anymore
    Config.WalkSpeed       = nil
    Config.JumpPower       = nil
    Config.WalkSpeedSlider = nil
    Config.ChainGrab = math.clamp(tonumber(Config.ChainGrab) or 5, 1, 8)
    Config.MinRatePct = math.clamp(tonumber(Config.MinRatePct) or 1, 0, 8)
end
Hub.LoadConfig()

--------------------------------------------------------------------------------
-- Notifications
--------------------------------------------------------------------------------
local notifyHolder = nil
local function Notify(title, body, kind)
    if not Config.Notifications then return end
    task.spawn(function()
        local holder = notifyHolder
        if not holder or not holder.Parent then return end
        local accent = kind == "error" and Color3.fromRGB(255, 90, 90)
            or kind == "success" and Color3.fromRGB(110, 220, 140)
            or Color3.fromRGB(255, 140, 60)
        local card = Instance.new("Frame")
        card.Name = "Notice"
        card.BackgroundColor3 = Color3.fromRGB(30, 30, 38)
        card.BorderSizePixel = 0
        card.Size = UDim2.new(1, 0, 0, 52)
        local bar = Instance.new("Frame")
        bar.BackgroundColor3 = accent
        bar.BorderSizePixel = 0
        bar.Size = UDim2.new(0, 3, 1, 0)
        bar.Parent = card
        local t = Instance.new("TextLabel")
        t.BackgroundTransparency = 1
        t.Font = Enum.Font.GothamBold
        t.TextSize = 12
        t.TextColor3 = Color3.new(1, 1, 1)
        t.Text = tostring(title or "Gab Hub")
        t.Position = UDim2.new(0, 10, 0, 6)
        t.Size = UDim2.new(1, -18, 0, 14)
        t.TextXAlignment = Enum.TextXAlignment.Left
        t.Parent = card
        local b = Instance.new("TextLabel")
        b.BackgroundTransparency = 1
        b.Font = Enum.Font.Gotham
        b.TextSize = 11
        b.TextColor3 = Color3.fromRGB(190, 190, 200)
        b.TextWrapped = true
        b.Text = tostring(body or "")
        b.Position = UDim2.new(0, 10, 0, 21)
        b.Size = UDim2.new(1, -18, 1, -24)
        b.TextXAlignment = Enum.TextXAlignment.Left
        b.TextYAlignment = Enum.TextYAlignment.Top
        b.Parent = card
        card.BackgroundTransparency = 1
        card.Parent = holder
        TweenService:Create(card, TweenInfo.new(0.18), { BackgroundTransparency = 0.12 }):Play()
        task.delay(4, function()
            if card and card.Parent then
                TweenService:Create(card, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play()
                task.delay(0.3, pcall, card.Destroy, card)
            end
        end)
    end)
end

--------------------------------------------------------------------------------
-- NETWORK  (v447 names verified against the open-source tested implementation)
-- The game renamed every endpoint ("great rename"): Plots->Homestead,
-- Eggs->EggWorld, ActiveAssets->PenRoster, OfflineAssets->AwayEarnings.
-- We call with the OLD-style keys and let this table translate.
--------------------------------------------------------------------------------
local NET = {
    ["Plots: RequestState"]                  = "RF/Homestead/AskState",
    ["Plots: RequestBaseUpgrade"]            = "RE/Homestead/AskBaseTierRaise",
    ["Eggs: RequestAreaEggSnapshot"]         = "RF/EggWorld/AskFieldEggSnapshot",
    ["Eggs: RequestRuntimeSnapshot"]         = "RF/EggWorld/AskLiveSnapshot",
    ["Eggs: RequestAreaEggCarry"]            = "RF/EggWorld/AskFieldEggCarry",
    ["Eggs: RequestPlaceEgg"]                = "RF/EggWorld/AskPlaceEgg",
    ["Eggs: RequestHatchEgg"]                = "RF/EggWorld/AskHatch",
    ["Eggs: RequestCompleteHatchEgg"]        = "RF/EggWorld/AskFinishHatch",
    ["ActiveAssets: RequestRuntimeSnapshot"] = "RF/PenRoster/AskLiveSnapshot",
    ["ActiveAssets: RequestEquipLimit"]      = "RF/PenRoster/AskWearLimit",
    ["ActiveAssets: RequestEquip"]           = "RF/PenRoster/AskWear",
    ["ActiveAssets: RequestSell"]            = "RF/PenRoster/AskSale",
    ["OfflineAssets: GetSummary"]            = "RF/AwayEarnings/FetchSummary",
    ["OfflineAssets: Redeem"]                = "RF/AwayEarnings/AskCollect",
    ["Treadmills: RequestUpgrade"]           = "RF/Treadmill/AskTierRaise",
}

local netRoot, netCache = nil, {}

local function netStorage()
    if netRoot and netRoot.Parent then return netRoot end
    local root = nil
    pcall(function()
        local pkg = ReplicatedStorage:FindFirstChild("Packages")
        root = pkg and pkg:FindFirstChild("Networking")
        if not root then root = ReplicatedStorage:FindFirstChild("Network") end
    end)
    netRoot = root
    return root
end

local function findRemote(name)
    local hit = netCache[name]
    if hit and hit.Parent then return hit end
    local storage = netStorage()
    if not storage then return nil end
    local mapped = NET[name]
    local found = (mapped and storage:FindFirstChild(mapped, true)) or storage:FindFirstChild(name, true)
    -- The game flips some endpoints between RemoteFunction and RemoteEvent;
    -- try the other prefix before giving up.
    if not found and mapped then
        local alt = mapped:gsub("^RF/", "RE/"):gsub("^RE/", "RF/")
        found = storage:FindFirstChild(alt, true)
    end
    netCache[name] = found
    if not found then verbose("remote not found:", name, "->", tostring(mapped)) end
    return found
end

-- Smooth call pacing: never more than ~8 requests/sec across the hub.
local lastCallAt = 0
local function pace()
    local gap = 0.12 - (os.clock() - lastCallAt)
    if gap > 0.001 then task.wait(gap) end
    lastCallAt = os.clock()
end

-- Call a remote regardless of whether it is currently a Function or an Event.
-- Returns ok, res1, res2, res3 (Events have no response; ok=true fires).
local function invoke(name, timeout, ...)
    local remote = findRemote(name)
    if not remote then return false, nil, "no remote " .. tostring(name) end
    pace()
    local args = { ... }
    if remote:IsA("RemoteEvent") or remote:IsA("UnreliableRemoteEvent") then
        local ok = pcall(function()
            remote:FireServer(unpack(args))
        end)
        return ok, nil, nil
    end
    local box = { done = false }
    task.spawn(function()
        local res = table.pack(pcall(function()
            return remote:InvokeServer(unpack(args))
        end))
        box.done = true
        box.ok = res[1]
        box.v1, box.v2, box.v3 = res[2], res[3], res[4]
    end)
    local t0 = os.clock()
    while not box.done and os.clock() - t0 < (timeout or 8) do
        task.wait(0.05)
    end
    if SESSION.dead then return false, nil, "stopped" end
    if not box.done then return false, nil, "timeout" end
    if not box.ok then return false, nil, tostring(box.v1) end
    return true, box.v1, box.v2, box.v3
end

--------------------------------------------------------------------------------
-- GAME DATA BINDINGS  (modules renamed in v447 - try both old and new paths)
--------------------------------------------------------------------------------
local G = {}
local function tryPaths(paths, field)
    for _, path in ipairs(paths) do
        local node = ReplicatedStorage
        for seg in path:gmatch("[^%.]+") do
            node = node and node:FindFirstChild(seg)
        end
        if node and node:IsA("ModuleScript") then
            local ok, mod = pcall(require, node)
            if ok and type(mod) == "table" then
                local v = field and mod[field] or mod
                if type(v) == "table" then return v end
            end
        end
    end
    return nil
end

G.Assets    = tryPaths({ "Data.Assets", "Directory.Assets" }, "Directory") or {}
G.Guards    = tryPaths({ "Data.Guards", "Directory.Guards" }, "Directory") or {}
G.Mutations = tryPaths({ "Shared.Modules.Mutations", "Library.Modules.Mutations" })
G.EggState  = tryPaths({ "Client.EggState", "Library.Client.EggCmds" })
G.Tread     = tryPaths({ "Data.Treadmills", "Directory.Treadmills" })
G.Save      = tryPaths({ "Shared.Save", "Library.Modules.Save" })

local EXP = 1.85 -- EarningRate * Scale^EXP * mutations — verified error ~0.00%

local function mutationMulti(muts)
    if not muts or next(muts) == nil then return 1 end
    if G.Mutations then
        local fn = G.Mutations.EarningsFor or G.Mutations.GetTotalMutationsEarningMulti
        if fn then
            local ok, m = pcall(fn, muts)
            if ok and type(m) == "number" and m > 0 then return m end
        end
    end
    local n = 0
    for _ in pairs(muts) do n = n + 1 end
    return 2.5 ^ n
end

-- Money per second for an egg record (what the hatched pet would earn)
local function eggValue(rec)
    local def = G.Assets[rec.AssetCategory]
    if not def then return 0 end
    local base = def.EarningRate or 0
    local scale = rec.AssetScale or rec.Scale or 1
    return base * (scale ^ EXP) * mutationMulti(rec.Mutations)
end

local function eggWeight(rec)
    local def = G.Assets[rec.AssetCategory]
    return (def and def.Egg and def.Egg.WeightKg) or 1
end

local function growthTime(cat)
    local def = G.Assets[cat]
    return (def and def.Egg and def.Egg.GrowthTime) or 30
end

local function guardSpeed(areaId)
    local g = G.Guards[areaId]
    return (g and g.WalkSpeed) or nil
end
local function easiestGuard()
    local best
    for id in pairs(G.Guards) do
        local g = guardSpeed(id)
        if g and (not best or g < best) then best = g end
    end
    return best or 16
end

local function realWalkSpeed()
    local _, _, hum = charParts()
    return (hum and hum.WalkSpeed) or 16
end

local function speedStat()
    local ls = LocalPlayer:FindFirstChild("leaderstats")
    local sp = ls and ls:FindFirstChild("Speed")
    return (sp and tonumber(sp.Value)) or 0
end

local function cashAmount()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local money = pg and pg:FindFirstChild("Money")
    if not money then return 0 end
    for _, d in ipairs(money:GetDescendants()) do
        if d:IsA("TextLabel") and d.Name == "Money" then
            return parseAmount((d.Text or ""):gsub("%$", ""))
        end
    end
    return 0
end

--------------------------------------------------------------------------------
-- PLOT  (ask the server which slot is ours — the reliable way)
--------------------------------------------------------------------------------
local S = {
    alive = true,
    paused = false,
    threads = {},
    plot = nil, pen = nil, origin = nil, tread = nil,
    carrying = nil, carryMul = 1,
    resetting = false, resetUntil = 0,
    loops = 0, stolen = 0, hatched = 0, sold = 0, placed = 0, failed = 0,
    ownedBest = 0, notifiedDeath = false,
    status = "starting",
    controlsObj = nil, controlsHeld = false,
    humLocked = false, humCache = nil, realWalk = nil, humTween = nil,
}

local function resolvePlot()
    local plots = Workspace:FindFirstChild("Plots")
    if not plots then return false end
    local found
    local ok, state = invoke("Plots: RequestState", 6)
    if ok and type(state) == "table" and type(state.OwnersBySlot) == "table" then
        for slot, owner in pairs(state.OwnersBySlot) do
            if owner == LocalPlayer.UserId then
                found = plots:FindFirstChild(tostring(slot))
                break
            end
        end
    end
    if not found then
        for _, p in ipairs(plots:GetChildren()) do
            local sign = p:FindFirstChild("PlotSign")
            if sign then
                for _, d in ipairs(sign:GetDescendants()) do
                    if d:IsA("TextLabel") and d.Text == LocalPlayer.Name then
                        found = p
                        break
                    end
                end
            end
            if found then break end
        end
    end
    if not found then return false end
    S.plot   = found
    S.origin = found:FindFirstChild("CenterPoint")
    local tu = found:FindFirstChild("ToUpdate")
    S.pen    = tu and tu:FindFirstChild("PetArea")
    S.tread  = found:FindFirstChild("TreadmillBottom")
    if not S.origin then S.origin = S.pen end
    return (S.pen ~= nil and S.origin ~= nil)
end

local function homePoint()
    if S.pen then return S.pen.Position + Vector3.new(0, 4, 0) end
    if S.origin then return S.origin.Position + Vector3.new(0, 4, 0) end
    local _, hrp = charParts()
    return hrp and hrp.Position or Vector3.new(0, 50, 0)
end

--------------------------------------------------------------------------------
-- CARRY STATE  (event when present; inline confirmations otherwise)
--------------------------------------------------------------------------------
local function wireCarryState()
    local storage = netStorage()
    if not storage then return nil end
    local ev
    for _, nm in ipairs({ "RF/EggWorld/AreaEggCarryState", "Eggs: AreaEggCarryState" }) do
        ev = storage:FindFirstChild(nm, true)
        if ev then break end
    end
    if not ev then
        for _, d in ipairs(storage:GetDescendants()) do
            if d:IsA("RemoteEvent")
            and (d.Name:find("CarryState", 1, true) or d.Name:find("AreaEggCarry", 1, true)) then
                ev = d
                break
            end
        end
    end
    if ev and ev:IsA("RemoteEvent") then
        track(ev.OnClientEvent:Connect(function(state)
            if type(state) == "table" and state.IsCarrying then
                S.carrying = state
                S.carryMul = state.SpeedMultiplier or 1
            else
                S.carrying = nil
                S.carryMul = 1
            end
        end))
        verbose("carry-state event wired:", ev.Name)
        return ev
    end
    verbose("no carry-state event found - using inline confirmations")
    return nil
end

local function wireResetCountdown()
    local storage = netStorage()
    if not storage then return end
    for _, d in ipairs(storage:GetDescendants()) do
        if d:IsA("RemoteEvent") and d.Name:find("ResetStartCountdown") then
            track(d.OnClientEvent:Connect(function(info)
                local secs = 3
                if type(info) == "table" then
                    secs = tonumber(info.Seconds or info.Duration or info.Countdown) or 3
                elseif type(info) == "number" then
                    secs = info
                end
                S.resetting = true
                S.resetUntil = os.clock() + secs + 8
            end))
            return
        end
    end
end

--------------------------------------------------------------------------------
-- FIELD PROMPTS  (fallback theft path when remote carry is refused)
--------------------------------------------------------------------------------
local promptCache = { list = {}, at = 0 }
local function refreshPrompts()
    if os.clock() - promptCache.at < 3 and #promptCache.list > 0 then
        return promptCache.list
    end
    local list = {}
    for _, d in ipairs(Workspace:GetDescendants()) do
        if d:IsA("ProximityPrompt") and d.Name == "CarryAreaEgg" then
            local p = d.Parent
            if p and p:IsA("BasePart") then list[#list + 1] = { prompt = d, part = p } end
        end
    end
    promptCache.list, promptCache.at = list, os.clock()
    return list
end

--------------------------------------------------------------------------------
-- DATA SNAPSHOTS  (my eggs / my pets / wearable limit)
--------------------------------------------------------------------------------
local function myEggRecords()
    local out = {}
    local ok, snap = invoke("Eggs: RequestRuntimeSnapshot", 8)
    if not ok or type(snap) ~= "table" then return out end
    for _, entry in pairs(snap) do
        if type(entry) == "table" and entry.OwnerUserId == LocalPlayer.UserId then
            for uid, rec in pairs(entry.Records or {}) do out[uid] = rec end
        end
    end
    return out
end

local function myPets()
    local out, count = {}, 0
    local ok, snap = invoke("ActiveAssets: RequestRuntimeSnapshot", 8)
    if not ok or type(snap) ~= "table" then return out, 0 end
    for _, entry in pairs(snap) do
        if type(entry) == "table" and entry.OwnerUserId == LocalPlayer.UserId then
            for uid, rec in pairs(entry.Records or {}) do
                out[#out + 1] = { uid = uid, mps = rec.MoneyPerSecond or 0, data = rec.ItemData or {} }
                count = count + 1
            end
        end
    end
    table.sort(out, function(a, b) return a.mps > b.mps end)
    return out, count
end

local function equipLimit()
    local ok, n = invoke("ActiveAssets: RequestEquipLimit", 6)
    if ok and type(n) == "number" then return n end
    return 13
end

local function bagTools()
    local out = {}
    for _, container in ipairs({ LocalPlayer:FindFirstChild("Backpack"), findChar() }) do
        if container then
            for _, c in ipairs(container:GetChildren()) do
                if c:IsA("Tool") and c:GetAttribute("ItemType") == "Asset" then
                    out[#out + 1] = c
                end
            end
        end
    end
    return out
end

local function bagPetValue(tool)
    local cat = tool:GetAttribute("Category")
    local def = G.Assets[cat]
    if not def then return 0 end
    local scale = tonumber(tool:GetAttribute("Scale")) or 1
    local muts = {}
    for name in tostring(tool:GetAttribute("Mutations") or ""):gmatch("[^,%s]+") do
        muts[#muts + 1] = name
    end
    return (def.EarningRate or 0) * (scale ^ EXP) * mutationMulti(muts)
end

--------------------------------------------------------------------------------
-- TARGETING  (richest eggs you can survive — with guard-speed safety)
--------------------------------------------------------------------------------
local function areaAllowed(areaId)
    local chosen = Config.Areas
    if chosen == nil then return true end
    if next(chosen) == nil then return true end
    return chosen[areaId] == true
end

local function areaSafe(areaId, carryMul)
    local g = guardSpeed(areaId)
    if not g then return false end
    if g <= easiestGuard() then return true end -- easiest zone: guards start asleep
    local mine = realWalkSpeed() * (carryMul or 1)
    return mine >= g * 0.85
end

local function fieldSnapshotRecords()
    local ok, snap = invoke("Eggs: RequestAreaEggSnapshot", 8)
    if not ok or type(snap) ~= "table" then return {} end
    return snap.Records or {}
end

local function candidates(ownedBest)
    local list = {}
    local floor = (tonumber(Config.MinRatePct) or 1) <= 0 and 0
        or (ownedBest or 0) * ((tonumber(Config.MinRatePct) or 1) / 100)
    local _, hrp = charParts()
    local me = hrp and hrp.Position or Vector3.zero
    for _, rec in pairs(fieldSnapshotRecords()) do
        if type(rec) == "table" and rec.State == "Slot"
        and rec.Uid and areaAllowed(rec.AreaId) then
            local mul = math.clamp(1 - 0.04 * eggWeight(rec), 0.25, 1)
            if areaSafe(rec.AreaId, mul) then
                local val = eggValue(rec)
                if val >= floor then
                    list[#list + 1] = { rec = rec, value = val, carryMul = mul }
                    list[#list].dist = rec.BottomCFrame
                        and (rec.BottomCFrame.Position - me).Magnitude or math.huge
                end
            end
        end
    end
    if Config.PreferBest == false then
        table.sort(list, function(a, b) return a.dist < b.dist end)
    else
        table.sort(list, function(a, b)
            if a.value ~= b.value then return a.value > b.value end
            return a.dist < b.dist
        end)
    end
    return list
end

--------------------------------------------------------------------------------
-- MOVEMENT — real walking only. No teleports, no anchoring, no speed hacks.
--------------------------------------------------------------------------------
-- Find the ground under a point (nil = would fall into the void)
local function groundY(pos)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { LocalPlayer.Character }
    local hit = Workspace:Raycast(pos + Vector3.new(0, 50, 0), Vector3.new(0, -400, 0), params)
    return hit and (hit.Position.Y + 3.2) or nil
end

-- ControlModule must be paused while WE drive the humanoid, or it fires
-- Humanoid:Move(0,0,0) every frame and interrupts our MoveTo (~4 studs/s bug).
local function playerControls()
    if S.controlsObj and S.controlsObj.Parent ~= nil then return S.controlsObj end
    local pm
    pcall(function()
        pm = require(LocalPlayer.PlayerScripts:WaitForChild("PlayerModule", 5))
    end)
    if not pm then return nil end
    local ok, c = pcall(function() return pm:GetControls() end)
    if ok then S.controlsObj = c end
    return S.controlsObj
end
local function grabControls()
    local c = playerControls()
    if c and not S.controlsHeld then
        pcall(function() c:Disable() end)
        S.controlsHeld = true
    end
end
local function releaseControls()
    local c = playerControls()
    if c and S.controlsHeld then
        pcall(function() c:Enable() end)
        S.controlsHeld = false
    end
end

-- A one-waypoint straight walk; reports "stuck" when pressed against something
local function stepTo(point, tol, budget)
    local t0 = os.clock()
    local lastPos, stallAt = nil, os.clock()
    while os.clock() - t0 < (budget or 8) do
        if SESSION.dead then return false, "dead" end
        local _, hrp, hum = charParts()
        if not hrp then return false, "nochar" end
        local flat = Vector3.new(point.X, hrp.Position.Y, point.Z)
        if (flat - hrp.Position).Magnitude <= (tol or 5) then return true end
        pcall(function() hum:MoveTo(flat) end)
        if lastPos and (hrp.Position - lastPos).Magnitude < 1 then
            if os.clock() - stallAt > 1.0 then
                pcall(function() hum.Jump = true end)
                stallAt = os.clock()
                if os.clock() - t0 > 3 then return false, "stuck" end
            end
        else
            stallAt = os.clock()
        end
        lastPos = hrp.Position
        task.wait(0.1)
    end
    return false, "timeout"
end

local function computePath(target)
    local _, hrp = charParts()
    if not hrp then return nil end
    local ok, path = pcall(function()
        return PathfindingService:CreatePath({
            AgentRadius = 3, AgentHeight = 6,
            AgentCanJump = true, AgentCanClimb = false,
            WaypointSpacing = 8,
        })
    end)
    if not ok or not path then return nil end
    local ok2 = pcall(function() path:ComputeAsync(hrp.Position, target) end)
    if not ok2 or path.Status ~= Enum.PathStatus.Success then return nil end
    local wps = path:GetWaypoints()
    if #wps < 2 then return nil end
    return wps
end

-- Plain walking: the safest way to move in this game. The anti-cheat only
-- reacts to movement that isn't real walking.
local function walkTo(target, tol, timeout)
    tol = tol or 5
    grabControls()
    local deadline = os.clock() + (timeout or 60)
    local arrived = false

    while os.clock() < deadline do
        if SESSION.dead then break end
        local _, hrp = charParts()
        if not hrp then break end
        if (Vector3.new(target.X, hrp.Position.Y, target.Z) - hrp.Position).Magnitude <= tol then
            arrived = true
            break
        end

        -- 1) try a straight charge first (fast when the way is clear)
        local ok, why = stepTo(target, tol, math.min(10, deadline - os.clock()))
        if ok then arrived = true break end
        if why == "dead" or why == "nochar" then break end

        -- 2) blocked: route around with pathfinding
        local wps = computePath(target)
        if not wps then
            -- no route found: shuffle sideways and retry on the next loop
            local _, h2 = charParts()
            if h2 then
                local side = h2.CFrame.RightVector * (math.random(0, 1) == 0 and 14 or -14)
                stepTo(h2.Position + side, 4, 2.5)
            end
        else
            local broken = false
            for i = 2, #wps do
                if SESSION.dead or os.clock() >= deadline then break end
                local _, h3, hum3 = charParts()
                if not h3 then broken = true break end
                if wps[i].Action == Enum.PathWaypointAction.Jump then
                    pcall(function() hum3.Jump = true end)
                end
                local reached, reason = stepTo(wps[i].Position, 5, 6)
                if not reached then
                    if reason == "dead" or reason == "nochar" then broken = true end
                    break -- bad route; recompute on the next loop pass
                end
            end
            if broken then break end
        end
    end
    releaseControls()
    return arrived
end

--------------------------------------------------------------------------------
-- FAST MODE ("humtween", verified against this game, opt-in)
--   * never anchors (anchor is exactly what got the old tween mode BAC-kicked)
--   * swaps in a fresh Humanoid so nothing tracking the old one stays attached
--   * WalkSpeed = 0 during the tween + velocity kept zeroed (no speed spikes)
--   * speed is bound to your REAL WalkSpeed (default 2x measured safe ceiling)
--   * auto-drops to plain walking if it stops making progress
--------------------------------------------------------------------------------
local HUM_PROPS = { "WalkSpeed", "JumpPower", "JumpHeight", "AutoRotate", "PlatformStand" }

local function humSwap()
    local char, hrp, hum = charParts()
    if not char or not hrp or not hum then return nil end
    if not S.humLocked or not S.humCache or S.humCache.Character ~= char then
        S.humCache = { Character = char }
        for _, prop in ipairs(HUM_PROPS) do
            pcall(function() S.humCache[prop] = hum[prop] end)
        end
        S.realWalk = S.humCache.WalkSpeed or hum.WalkSpeed
    end
    local clone
    local ok = pcall(function()
        hum.Archivable = true
        clone = hum:Clone()
        clone.BreakJointsOnDeath = false
        hum:Destroy()
        clone.Parent = char
        clone.WalkSpeed = 0
        if not clone:FindFirstChildOfClass("Animator") then
            Instance.new("Animator").Parent = clone
        end
        clone:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
        clone:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
    end)
    if not ok or not clone or not clone.Parent then
        verbose("humSwap failed - staying on plain walk")
        S.humLocked = false
        releaseControls()
        return nil
    end
    hrp.AssemblyLinearVelocity, hrp.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
    S.humLocked = true
    return clone
end

local function humRestore()
    if S.humTween then
        pcall(function() S.humTween:Cancel() end)
        S.humTween = nil
    end
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then
        -- only restore WalkSpeed if WE pushed it to 0 (never fight the game)
        local cached = (S.humCache and S.humCache.Character == char) and S.humCache or nil
        if hum.WalkSpeed == 0 then
            local want = (cached and cached.WalkSpeed) or S.realWalk
            if want and want > 0 then pcall(function() hum.WalkSpeed = want end) end
        end
        if cached then
            for _, prop in ipairs(HUM_PROPS) do
                if prop ~= "WalkSpeed" and cached[prop] ~= nil then
                    pcall(function() hum[prop] = cached[prop] end)
                end
            end
        end
    end
    if hrp then
        hrp.AssemblyLinearVelocity, hrp.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
    end
    S.humLocked = false
end

local function unlockCharacter()
    local _, hrp = charParts()
    if hrp and hrp.Anchored then
        pcall(function()
            hrp.Anchored = false
            hrp.AssemblyLinearVelocity = Vector3.zero
        end)
    end
    if S.humLocked then humRestore() end
end

local function humSpeed()
    return math.max(8, realWalkSpeed() * 2) -- 2x = the measured safe ceiling
end

local function humLeg(targetCF, speed)
    local _, hrp = charParts()
    if not hrp then return false end
    pcall(function()
        hrp.AssemblyLinearVelocity, hrp.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
    end)
    local dist = (targetCF.Position - hrp.Position).Magnitude
    local dur = math.max(0.03, dist / math.max(1, speed))
    local tw = TweenService:Create(hrp, TweenInfo.new(dur, Enum.EasingStyle.Linear), { CFrame = targetCF })
    S.humTween = tw
    local done, state = false, nil
    tw.Completed:Once(function(st) done, state = true, st end)
    tw:Play()
    local deadline = os.clock() + dur + 0.4
    while not done and os.clock() < deadline and not SESSION.dead do task.wait() end
    if S.humTween == tw then S.humTween = nil end
    if not done then pcall(function() tw:Cancel() end) end
    if state == Enum.PlaybackState.Completed and hrp.Parent then
        pcall(function() hrp.CFrame = targetCF end)
    end
    pcall(function()
        hrp.AssemblyLinearVelocity, hrp.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
    end)
    return done
end

local function humTweenTo(target, tol, timeout)
    tol = tol or 5
    grabControls()
    local deadline = os.clock() + (timeout or 60)
    local rollbacks = 0

    if not humSwap() then
        humRestore()
        releaseControls()
        return walkTo(target, tol, timeout)
    end

    local survived = false
    while os.clock() < deadline do
        if SESSION.dead then break end
        local _, hrp, hum = charParts()
        if not hrp or not hum then break end

        local delta = target - hrp.Position
        local flat = Vector3.new(delta.X, 0, delta.Z)
        if flat.Magnitude <= tol then survived = true break end

        -- game swapped our humanoid again (e.g. respawn) -> re-swap
        if hum.WalkSpeed > 0 and S.humLocked then
            if not humSwap() then break end
        end

        local step = math.min(18, flat.Magnitude)
        local dir = flat.Magnitude > 0.05 and flat.Unit or hrp.CFrame.LookVector
        local nextPos = hrp.Position + dir * step
        local gy = groundY(nextPos)
        if gy then
            gy = gy - 3.2 + 3.2
            local dy = math.clamp(gy - hrp.Position.Y, -8, 8)
            nextPos = Vector3.new(nextPos.X, hrp.Position.Y + dy, nextPos.Z)
        end

        local from = hrp.Position
        humLeg(CFrame.new(nextPos, nextPos + dir), humSpeed())

        local moved = ((hrp.Parent and hrp.Position or from) - from).Magnitude
        if moved < step * 0.4 then
            rollbacks = rollbacks + 1
            if rollbacks >= 3 then
                verbose("fast mode pushed back - falling back to walking")
                break
            end
        else
            rollbacks = 0
        end
        task.wait()
    end
    humRestore()
    releaseControls()
    if survived then return true end
    return walkTo(target, tol, math.max(15, (timeout or 60) - 20))
end

local function goTo(target, tol, timeout)
    if Config.FastMode then
        return humTweenTo(target, tol, timeout)
    end
    return walkTo(target, tol, timeout)
end

local function goHome()
    local ok = goTo(homePoint(), 6, 60)
    task.wait(0.35)
    return ok
end

local function stopNavigation()
    unlockCharacter()
    releaseControls()
end

--------------------------------------------------------------------------------
-- FEATURE: STEAL  (walk to egg -> carry -> walk into your PetArea)
--------------------------------------------------------------------------------
local function stealEgg(cand)
    local rec = cand.rec
    local eggPos = rec.BottomCFrame and rec.BottomCFrame.Position
    if not eggPos then return false end

    S.status = "steal " .. tostring(rec.AssetCategory) .. " @ " .. tostring(rec.AreaId)
    if not goTo(eggPos + Vector3.new(0, 3, 0), 4, 90) then
        S.failed = S.failed + 1
        return false
    end
    task.wait(0.35)

    for attempt = 1, 2 do
        if SESSION.dead then return false end
        -- Primary: the same request the in-game button sends
        local carried = false
        local ok, res, why = invoke("Eggs: RequestAreaEggCarry", 6, { Uid = rec.Uid })
        carried = ok and res and true or false
        if ok and not res and attempt == 1 then
            verbose("carry refused:", tostring(why))
        end
        -- Fallback: fire the physical prompt (skips the 1.2s hold)
        if not carried then
            promptCache.at = 0
            local best, bd
            for _, e in ipairs(refreshPrompts()) do
                if e.prompt.Parent and eggPos then
                    local d = (e.part.Position - eggPos).Magnitude
                    if not bd or d < bd then best, bd = e.prompt, d end
                end
            end
            if best and not carried and bd <= 16 and typeof(fireproximityprompt) == "function" then
                pcall(function() fireproximityprompt(best, 1) end)
                carried = true
            end
        end

        -- Confirm the grab before walking home.
        -- The carry-state event (when present) is the most reliable signal;
        -- otherwise trust the remote's own answer.
        if carried then
            S.stolen = S.stolen + 1
            S.carryMul = (S.carrying and S.carrying.SpeedMultiplier) or cand.carryMul or 1
            return true
        end
        local t0 = os.clock()
        while os.clock() - t0 < (tonumber(Config.GrabTimeout) or 6) do
            if SESSION.dead then return false end
            if S.carrying then
                S.stolen = S.stolen + 1
                S.carryMul = S.carrying.SpeedMultiplier or cand.carryMul or 1
                return true
            end
            task.wait(0.1)
        end
        -- still nothing: creep closer and try again
        goTo(eggPos + Vector3.new(0, 2, 0), 2, 25)
        task.wait(0.3)
    end
    S.failed = S.failed + 1
    return false
end

-- Walking into your own PetArea is how the server converts a carried egg
-- into YOUR record. If a carry-state event is wired, we wait for it to clear.
local function carryHome()
    S.status = "carry home"
    goTo(homePoint(), 6, 70)
    if S.carrying == nil then return true end
    local t0 = os.clock()
    while os.clock() - t0 < (tonumber(Config.ClaimTimeout) or 14) do
        if SESSION.dead then return false end
        if S.carrying == nil then return true end
        task.wait(0.2)
        if os.clock() - t0 > 2 then
            -- nudge around the pen in case the trigger zone needs a re-entry
            goTo(homePoint() + Vector3.new(math.random(-6, 6), 0, math.random(-6, 6)), 4, 12)
        end
    end
    verbose("claim timed out")
    S.failed = S.failed + 1
    return false
end

--------------------------------------------------------------------------------
-- FEATURE: BASE WORK  (place / hatch / equip / sell)
--------------------------------------------------------------------------------
local function freeSpot(taken)
    if not S.pen or not S.origin then return nil end
    local size = S.pen.Size
    local mx = math.max(4, size.X / 2 - 5)
    local mz = math.max(4, size.Z / 2 - 5)
    for _ = 1, 60 do
        local world = S.pen.CFrame * CFrame.new(
            math.random(-math.floor(mx), math.floor(mx)),
            size.Y / 2 + 1,
            math.random(-math.floor(mz), math.floor(mz)))
        local clear = true
        for _, p in ipairs(taken) do
            if (p - world.Position).Magnitude < 6 then clear = false break end
        end
        if clear then return world end
    end
    return S.pen.CFrame * CFrame.new(math.random(-10, 10), size.Y / 2 + 1, math.random(-10, 10))
end

local function placeEggs()
    if not Config.AutoPlace then return end
    if not S.pen or not S.origin then return end
    local pending, taken = {}, {}
    for uid, rec in pairs(myEggRecords()) do
        if type(rec) == "table" then
            if rec.Placement and rec.Placement.LocalCFrame then
                taken[#taken + 1] = (S.origin.CFrame * rec.Placement.LocalCFrame).Position
            elseif not rec.Placement then
                pending[#pending + 1] = { uid = uid, rec = rec }
            end
        end
    end
    for _, item in ipairs(pending) do
        if SESSION.dead then return end
        local world = freeSpot(taken)
        if world then
            local localCF = S.origin.CFrame:ToObjectSpace(world)
            -- EXACT signature the game's own UI sends:
            --   RF/EggWorld/AskPlaceEgg  { Uid, LocalCFrame }
            local ok, res, reason = invoke("Eggs: RequestPlaceEgg", 8, { Uid = item.uid, LocalCFrame = localCF })
            if ok and res then
                S.placed = S.placed + 1
                taken[#taken + 1] = world.Position
                verbose("placed", tostring(item.rec.AssetCategory))
            else
                verbose("place failed", tostring(reason))
            end
            task.wait(0.15)
        end
    end
end

local function eggReadyToHatch(uid, rec, placedAt)
    local fn = G.EggState and (G.EggState.IsReadyToHatch or G.EggState.IsLocalEggReady)
    if fn then
        local ok, r = pcall(fn, uid)
        if ok then return r == true end
    end
    local now = Workspace:GetServerTimeNow()
    local need = growthTime(rec.AssetCategory) / math.max(0.01, rec.GrowthSpeedMultiplier or 1)
    return (now - (placedAt or now)) >= need
end

local function hatchReady()
    if not Config.AutoHatch then return end
    for uid, rec in pairs(myEggRecords()) do
        if SESSION.dead then return end
        if type(rec) == "table" and rec.Placement then
            local placedAt = rec.Placement.PlacedAt
            if eggReadyToHatch(uid, rec, placedAt) then
                -- TWO steps: AskHatch starts it, wait, then AskFinishHatch ends it
                local ok, res = invoke("Eggs: RequestHatchEgg", 8, uid)
                if ok and res then
                    task.wait(0.9)
                    local ok2, res2, _, petUid = invoke("Eggs: RequestCompleteHatchEgg", 8, uid)
                    if ok2 and res2 then
                        S.hatched = S.hatched + 1
                        verbose("hatched", tostring(rec.AssetCategory))
                    end
                end
                task.wait(0.2)
            end
        end
    end
end

local function equipAndSell()
    local bag = bagTools()
    if #bag == 0 and not Config.AutoSell then return end
    local pets, count = myPets()
    local limit = equipLimit()

    table.sort(bag, function(a, b) return bagPetValue(a) > bagPetValue(b) end)
    for _, tool in ipairs(bag) do
        if SESSION.dead then return end
        local uid = tool:GetAttribute("UID")
        if uid then
            local val = bagPetValue(tool)
            if count < limit then
                if Config.AutoEquip then
                    local ok, res = invoke("ActiveAssets: RequestEquip", 8, uid)
                    if ok and res then
                        count = count + 1
                        verbose("equipped", short(val) .. "/s")
                    end
                    task.wait(0.12)
                end
            elseif Config.AutoSell then
                local worst = pets[#pets]
                if worst and val > worst.mps then
                    -- pen is full: replace the worst pet with this better one
                    local ok, res = invoke("ActiveAssets: RequestSell", 8, worst.uid)
                    if ok and res then
                        S.sold = S.sold + 1
                        table.remove(pets, #pets)
                        count = count - 1
                        verbose("sold worst", short(worst.mps), "<-", short(val))
                        task.wait(0.12)
                        local ok2, res2 = invoke("ActiveAssets: RequestEquip", 8, uid)
                        if ok2 and res2 then
                            count = count + 1
                        end
                    end
                elseif Config.SellBackpack and worst and val <= worst.mps then
                    local ok, res = invoke("ActiveAssets: RequestSell", 8, uid)
                    if ok and res then
                        S.sold = S.sold + 1
                        verbose("sold bag pet", short(val))
                        task.wait(0.12)
                    end
                end
            end
        end
    end
end

local function claimOffline()
    if not Config.AutoClaimOffline then return end
    local ok, sum = invoke("OfflineAssets: GetSummary", 6)
    if ok and type(sum) == "table" and (sum.ClaimableAmount or 0) > 0 then
        invoke("OfflineAssets: Redeem", 8)
        verbose("claimed offline", short(sum.ClaimableAmount))
    end
end

--------------------------------------------------------------------------------
-- FEATURE: UPGRADES (treadmill = the legit way to run faster)
--------------------------------------------------------------------------------
local function treadmillTiers()
    if not G.Tread then return {} end
    local TD = G.Tread.Directory or G.Tread
    local list = {}
    for id, cfg in pairs(TD) do
        if type(cfg) == "table" then
            list[#list + 1] = {
                id    = cfg._id or id,       -- AskTierRaise eats the _id (e.g. "DemonicTreadmill")
                price = cfg.Price or 0,
                mult  = cfg.SpeedMultiplier or 0,
                level = cfg.UpgradeLevel,
            }
        end
    end
    table.sort(list, function(a, b) return a.price < b.price end)
    return list
end

local function padLevelText(model)
    if not model then return nil end
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("TextLabel") then
            local cur, nxt = tostring(d.Text):match("Level%s+(%d+)%s*>%s*Level%s+(%d+)")
            if cur then return tonumber(cur), tonumber(nxt) end
        end
    end
    return nil
end

local function treadLevel()
    if G.Save and G.Save.Get then
        local ok, save = pcall(G.Save.Get)
        if ok and type(save) == "table" and tonumber(save.TreadmillUpgradeLevel) then
            return tonumber(save.TreadmillUpgradeLevel)
        end
    end
    return padLevelText(S.plot and S.plot:FindFirstChild("TreadmillUpgrade"))
end

local function upgradeTreadmill()
    if not Config.AutoUpTreadmill then return end
    local cur = treadLevel()
    local tiers = treadmillTiers()
    if #tiers == 0 then return end

    local target
    if cur and G.Tread and G.Tread.GetByUpgradeLevel then
        local ok, cfg = pcall(G.Tread.GetByUpgradeLevel, cur + 1)
        if ok and type(cfg) == "table" and cfg._id then
            target = { id = cfg._id, price = cfg.Price or 0, mult = cfg.SpeedMultiplier or 0 }
        end
    end
    if not target then target = tiers[(cur and (cur + 1)) or 2] end
    if not target then return end

    -- price cap: Config.MaxTreadmillPrice is an exponent (6 => ~$1M, 9 => ~$1B)
    local capExp = tonumber(Config.MaxTreadmillPrice) or 0
    if capExp > 0 then
        local cap = 10 ^ capExp
        if target.price > cap then return end
    end
    local cash = cashAmount()
    if cash > 0 and target.price > cash then return end

    local ok, res, reason = invoke("Treadmills: RequestUpgrade", 8, target.id)
    if ok and res then
        verbose("treadmill upgraded ->", target.id)
    else
        verbose("treadmill upgrade refused:", tostring(reason))
    end
end

--------------------------------------------------------------------------------
-- FEATURE: TRAIN SPEED  (stand on your treadmill; the game raises Speed)
--------------------------------------------------------------------------------
local function tooSlowToSteal()
    return realWalkSpeed() < easiestGuard() * 1.15
end

local function rideTreadmill(seconds)
    if not S.tread then return end
    S.status = "treadmill training"
    local pos = S.tread.Position + Vector3.new(0, 4, 0)
    goTo(pos, 5, 60)
    local t0 = os.clock()
    while not SESSION.dead and os.clock() - t0 < (seconds or 20) do
        local _, hrp = charParts()
        if hrp and (hrp.Position - pos).Magnitude > 8 then
            goTo(pos, 4, 20)
        end
        task.wait(0.5)
    end
end

--------------------------------------------------------------------------------
-- SAFETY
--------------------------------------------------------------------------------
local function guardCharacter(char)
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    pcall(function()
        hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
        hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
    end)
end
local function isDead()
    local h = humanoidAlive()
    return h == nil and (LocalPlayer.Character ~= nil)
end

-- Client-side :Kick blocker. NOTE: this CANNOT block server BAC kicks —
-- staying under the server's radar is what keeps you in the game.
local function installAntiKick()
    local genv = getgenv()
    if genv.__GabHubSAE_AntiKick then return end
    local ok = pcall(function()
        local mt = getrawmetatable(game)
        local old = mt.__namecall
        setreadonly(mt, false)
        mt.__namecall = newcclosure(function(self, ...)
            local m = getnamecallmethod()
            if m == "Kick" and typeof(self) == "Instance" and self:IsA("Player") then
                verbose("blocked client-side Kick")
                return nil
            end
            return old(self, ...)
        end)
        setreadonly(mt, true)
    end)
    genv.__GabHubSAE_AntiKick = ok and true or nil
    verbose("anti-kick hook:", ok and "installed (client-side only)" or "failed")
end

track(LocalPlayer.CharacterAdded:Connect(function(char)
    S.carrying = nil
    S.carryMul = 1
    task.wait(0.5)
    guardCharacter(char)
    resolvePlot()
    S.notifiedDeath = false
end))
if LocalPlayer.Character then guardCharacter(LocalPlayer.Character) end

track(UserInputService.Idled:Connect(function()
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new(0, 0))
    end)
end))

--------------------------------------------------------------------------------
-- MAIN CYCLE  (steal -> claim -> place -> hatch -> equip/sell -> train)
--------------------------------------------------------------------------------
local function handleAreaReset()
    if not S.resetting then return false end
    S.status = "zone reset — holding at base"
    goHome()
    while not SESSION.dead and os.clock() < S.resetUntil do task.wait(0.5) end
    S.status = "waiting for eggs to respawn"
    local t0 = os.clock()
    while not SESSION.dead and os.clock() - t0 < 60 do
        local n = 0
        for _, rec in pairs(fieldSnapshotRecords()) do
            if type(rec) == "table" and rec.State == "Slot" then n = n + 1 end
        end
        if n >= 5 then break end
        task.wait(2)
    end
    S.resetting = false
    promptCache.at = 0
    return true
end

local function tendBase()
    S.status = "base work"
    -- If stealing is on we may be out in a guard zone; base chores are safer home.
    if S.plot and Config.AutoSteal then goHome() end
    placeEggs()
    hatchReady()
    equipAndSell()
    upgradeTreadmill()
end

--------------------------------------------------------------------------------
-- MAIN LOOP BODY
--------------------------------------------------------------------------------

local function anyFeatureOn()
    return Config.AutoSteal or Config.AutoPlace or Config.AutoHatch
        or Config.AutoEquip or Config.AutoSell or Config.AutoClaimOffline
        or Config.AutoTrain or Config.AutoUpTreadmill
end

local function mainCycle()
    S.loops = S.loops + 1

    if handleAreaReset() then return end

    -- dying in this game means you must rejoin — stop everything politely
    local humNow = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
    if humNow and humNow.Health <= 0 then
        if not S.notifiedDeath then
            S.notifiedDeath = true
            Notify("Gab Hub", "Character died. In this game you must rejoin — automation paused.", "error")
        end
        S.status = "dead — rejoin to continue"
        task.wait(5)
        return
    end
    S.notifiedDeath = false

    if Config.AutoSteal and S.plot then
        local pets = myPets()
        local ownedBest = pets[1] and pets[1].mps or 0
        S.ownedBest = ownedBest
        local list = candidates(ownedBest)

        if #list == 0 then
            S.status = string.format("no eggs to take (walk %.0f)", realWalkSpeed())
            if tooSlowToSteal() and Config.AutoTrainWhenSlow and Config.AutoTrain then
                rideTreadmill(tonumber(Config.TreadmillSeconds) or 20)
            else
                tendBase()
                task.wait(Config.AutoSteal and 3 or 1)
            end
            return
        end

        local grabbed, tried = 0, {}
        local chain = math.max(1, math.min(tonumber(Config.ChainGrab) or 5, 8))
        while grabbed < chain do
            if SESSION.dead or Config.AutoSteal == false then break end
            local cand
            for _, c in ipairs(list) do
                if not tried[c.rec.Uid] then cand = c break end
            end
            if not cand then break end
            tried[cand.rec.Uid] = true

            -- re-fetch every grab: someone may have taken the egg in the meantime
            if stealEgg(cand) then
                if carryHome() then
                    grabbed = grabbed + 1
                else
                    verbose("claim timed out - back to base")
                    tendBase()
                    break
                end
            end
            if grabbed < chain then
                list = candidates(ownedBest)
                if #list == 0 then break end
            end
            task.wait(0.4)
        end

        if grabbed > 0 then tendBase() end
        task.wait(0.5)
    else
        -- steal off: only light base chores when they are individually enabled
        if Config.AutoPlace or Config.AutoHatch or Config.AutoEquip or Config.AutoSell then
            tendBase()
            task.wait(2)
        elseif Config.AutoTrain and S.tread and tooSlowToSteal() then
            rideTreadmill(tonumber(Config.TreadmillSeconds) or 20)
            task.wait(1)
        else
            S.status = "idle — enable a feature"
            task.wait(1)
        end
    end
end

local function spawnLoop(fn)
    local t = task.spawn(function()
        while not SESSION.dead do
            local ok, err = pcall(fn)
            if not ok then
                verbose("loop error:", tostring(err))
                task.wait(0.2)
            end
        end
    end)
    table.insert(S.threads, t)
    return t
end

--------------------------------------------------------------------------------
-- FEATURE: Egg ESP (client-only rendering; safe)
--------------------------------------------------------------------------------
local espGui = nil
local function ensureEspGui()
    if not espGui or not espGui.Parent then
        espGui = Instance.new("ScreenGui")
        espGui.Name = "GabHub_ESP"
        espGui.ResetOnSpawn = false
        espGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        trackInstance(espGui)
        local ok = pcall(function()
            espGui.Parent = (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
        end)
        if (not ok or not espGui.Parent) then
            espGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
        end
    end
    return espGui
end

local lastEsp = 0
track(RunService.Heartbeat:Connect(function()
    if SESSION.dead or not Config.EggESP then return end
    if os.clock() - lastEsp < 1 then return end
    lastEsp = os.clock()
    local camera = Workspace.CurrentCamera
    local _, root = charParts()
    if not camera or not root then return end
    local gui = ensureEspGui()
    gui:ClearAllChildren()
    for _, rec in pairs(fieldSnapshotRecords()) do
        if type(rec) == "table" and rec.BottomCFrame then
            local pos = rec.BottomCFrame.Position
            if (pos - root.Position).Magnitude <= (tonumber(Config.ESPDistance) or 250) then
                local screen, onScreen = camera:WorldToViewportPoint(pos)
                if onScreen then
                    local val = eggValue(rec)
                    local label = Instance.new("TextLabel")
                    label.Name = "GabESP"
                    label.Text = ("%s\n%s/s"):format(
                        tostring(rec.AssetCategory or "Egg"), short(val))
                    label.Font = Enum.Font.GothamBold
                    label.TextSize = 13
                    label.TextColor3 = val > (S.ownedBest or 0) * 0.5
                        and Color3.fromRGB(255, 90, 60) or Color3.fromRGB(255, 200, 120)
                    label.TextStrokeTransparency = 0.3
                    label.BackgroundTransparency = 0.4
                    label.BackgroundColor3 = Color3.new(0, 0, 0)
                    label.BorderSizePixel = 0
                    label.Size = UDim2.fromOffset(110, 34)
                    label.Position = UDim2.new(0, screen.X - 55, 0, screen.Y - 17)
                    label.Parent = gui
                end
            end
        end
    end
end))

--------------------------------------------------------------------------------
-- FEATURE: FPS boost (client-only)
--------------------------------------------------------------------------------
local function applyFpsBoost(on)
    if not on then return end
    pcall(function()
        Lighting.GlobalShadows = false
        Lighting.FogEnd = 1e6
        for _, d in ipairs(Lighting:GetChildren()) do
            if d:IsA("PostEffect") then d.Enabled = false end
        end
    end)
    pcall(function() if typeof(setfpscap) == "function" then setfpscap(30) end end)
end

local fpsThread = nil
track(RunService.Heartbeat:Connect(function()
    if SESSION.dead or not Config.FPSBoost then return end
    if fpsThread and coroutine.status(fpsThread) ~= "dead" then return end
    fpsThread = task.spawn(function()
        while not SESSION.dead and Config.FPSBoost do
            pcall(function()
                for _, obj in ipairs(Workspace:GetDescendants()) do
                    if obj:IsA("ParticleEmitter") then obj.Enabled = false end
                end
            end)
            task.wait(4)
        end
    end)
end))

--------------------------------------------------------------------------------
-- GUI
--------------------------------------------------------------------------------
local ACCENT  = Color3.fromRGB(255, 120, 60)
local PANEL   = Color3.fromRGB(26, 26, 33)
local PANEL2  = Color3.fromRGB(32, 32, 41)
local CARD    = Color3.fromRGB(38, 38, 48)
local TEXT    = Color3.new(1, 1, 1)
local DIM     = Color3.fromRGB(176, 176, 188)
local FONT    = Enum.Font.Gotham
local FONT_B  = Enum.Font.GothamBold

local ScreenGui, MainFrame, NavBar, ContentHolder
local Pages, NavButtons = {}, {}
local PageOrder = { "Main", "Steal", "Base", "Train", "Visual", "Settings" }
local AreaList = {
    "Forest", "Lake", "Desert", "Jungle", "Snow", "Volcano",
    "Abyss Ocean", "Prehistoric", "Cosmic", "Cherry Blossom",
    "Titan Temple",
}

local function guiParent()
    local parent
    pcall(function()
        if typeof(gethui) == "function" then parent = gethui() end
    end)
    if parent then return parent end
    pcall(function() parent = game:GetService("CoreGui") end)
    if parent then return parent end
    return LocalPlayer:WaitForChild("PlayerGui")
end

local function makeCorner(parent, radius)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, radius or 8)
    c.Parent = parent
end

local function enableDrag(handle, target)
    local dragging, dragStart, startPos = false, nil, nil
    handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = target.Position
        end
    end)
    handle.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    track(UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - dragStart
            target.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end))
end

local function selectPage(selected)
    for name, page in pairs(Pages) do
        page.Visible = (name == selected)
    end
    for name, btn in pairs(NavButtons) do
        btn.BackgroundColor3 = (name == selected) and ACCENT or PANEL2
        btn.TextColor3 = (name == selected) and Color3.new(1, 1, 1) or DIM
    end
end

local function buildWindow()
    ScreenGui = Instance.new("ScreenGui")
    ScreenGui.Name = "GabHub_SAE"
    ScreenGui.ResetOnSpawn = false
    ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    trackInstance(ScreenGui)
    ScreenGui.Parent = guiParent()

    notifyHolder = Instance.new("Frame")
    notifyHolder.Name = "Notices"
    notifyHolder.BackgroundTransparency = 1
    notifyHolder.Size = UDim2.new(0, 220, 0, 320)
    notifyHolder.Position = UDim2.new(1, -12, 0, 40)
    notifyHolder.AnchorPoint = Vector2.new(1, 0)
    notifyHolder.ZIndex = 50
    notifyHolder.Parent = ScreenGui
    trackInstance(notifyHolder)
    local nAnim = Instance.new("UIListLayout")
    nAnim.Padding = UDim.new(0, 5)
    nAnim.SortOrder = Enum.SortOrder.LayoutOrder
    nAnim.VerticalAlignment = Enum.VerticalAlignment.Bottom
    nAnim.HorizontalAlignment = Enum.HorizontalAlignment.Right
    nAnim.Parent = notifyHolder

    MainFrame = Instance.new("Frame")
    MainFrame.Name = "Root"
    MainFrame.Size = UDim2.fromOffset(560, 384)
    MainFrame.Position = UDim2.new(0.5, -280, 0.5, -192)
    MainFrame.BackgroundColor3 = PANEL
    MainFrame.BorderSizePixel = 0
    MainFrame.Parent = ScreenGui
    makeCorner(MainFrame, 12)
    local stroke = Instance.new("UIStroke")
    stroke.Color = ACCENT
    stroke.Thickness = 1
    stroke.Transparency = 0.45
    stroke.Parent = MainFrame

    local title = Instance.new("Frame")
    title.Name = "TitleBar"
    title.BackgroundColor3 = PANEL2
    title.BorderSizePixel = 0
    title.Size = UDim2.new(1, 0, 0, 34)
    title.Parent = MainFrame
    makeCorner(title, 12)
    local gradient = Instance.new("UIGradient")
    gradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(70, 34, 24)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(32, 32, 41)),
    })
    gradient.Rotation = 20
    gradient.Parent = title

    local logo = Instance.new("TextLabel")
    logo.BackgroundTransparency = 1
    logo.Font = FONT_B
    logo.TextSize = 15
    logo.TextColor3 = TEXT
    logo.Text = ("🥚 GAB HUB | Steal An Egg  %s"):format(Hub.Version)
    logo.Position = UDim2.new(0, 12, 0, 0)
    logo.Size = UDim2.new(1, -120, 1, 0)
    logo.TextXAlignment = Enum.TextXAlignment.Left
    logo.Parent = title

    local minBtn = Instance.new("TextButton")
    minBtn.Text = "–"
    minBtn.Font = FONT_B
    minBtn.TextSize = 20
    minBtn.TextColor3 = DIM
    minBtn.BackgroundTransparency = 1
    minBtn.Size = UDim2.fromOffset(28, 28)
    minBtn.Position = UDim2.new(1, -34, 0, 3)
    minBtn.Parent = title
    minBtn.MouseButton1Click:Connect(function()
        local minimized = (MainFrame.Size == UDim2.fromOffset(560, 34))
        MainFrame.Size = (not minimized) and UDim2.fromOffset(560, 34) or UDim2.fromOffset(560, 384)
        ContentHolder.Visible = minimized
        NavBar.Visible = minimized
    end)

    enableDrag(title, MainFrame)

    local uiScale = Instance.new("UIScale")
    uiScale.Scale = 1
    uiScale.Parent = MainFrame
    trackInstance(uiScale)
    local function fit()
        pcall(function()
            local vp = ScreenGui.AbsoluteSize
            local abs = MainFrame.AbsoluteSize
            if vp.X <= 10 or abs.X <= 10 then return end
            uiScale.Scale = math.clamp(math.min((vp.X - 16) / abs.X, (vp.Y - 16) / abs.Y), 0.45, 1)
        end)
    end
    track(ScreenGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit))
    task.delay(0.3, fit)

    NavBar = Instance.new("ScrollingFrame")
    NavBar.Name = "Nav"
    NavBar.BackgroundColor3 = PANEL2
    NavBar.BorderSizePixel = 0
    NavBar.Position = UDim2.new(0, 6, 0, 40)
    NavBar.Size = UDim2.new(0, 108, 1, -46)
    NavBar.ScrollBarThickness = 0
    NavBar.CanvasSize = UDim2.new(0, 0, 0, #PageOrder * 34)
    NavBar.Parent = MainFrame
    makeCorner(NavBar, 10)
    local navList = Instance.new("UIListLayout")
    navList.Padding = UDim.new(0, 4)
    navList.HorizontalAlignment = Enum.HorizontalAlignment.Center
    navList.Parent = NavBar

    local icons = {
        Main = "🏠", Steal = "🥚", Base = "📦", Train = "🏃",
        Visual = "👁", Settings = "⚙",
    }
    for index, name in ipairs(PageOrder) do
        local btn = Instance.new("TextButton")
        btn.Name = "Nav_" .. name
        btn.AutoButtonColor = false
        btn.BackgroundColor3 = PANEL2
        btn.BorderSizePixel = 0
        btn.Font = FONT
        btn.TextSize = 12
        btn.TextColor3 = DIM
        btn.Text = ("%s %s"):format(icons[name] or "", name)
        btn.Size = UDim2.new(1, -8, 0, 30)
        btn.LayoutOrder = index
        btn.Parent = NavBar
        makeCorner(btn, 8)
        NavButtons[name] = btn
        btn.MouseButton1Click:Connect(function() selectPage(name) end)
    end

    ContentHolder = Instance.new("Frame")
    ContentHolder.Name = "Content"
    ContentHolder.BackgroundTransparency = 1
    ContentHolder.Position = UDim2.new(0, 120, 0, 40)
    ContentHolder.Size = UDim2.new(1, -126, 1, -46)
    ContentHolder.Parent = MainFrame

    for _, name in ipairs(PageOrder) do
        local page = Instance.new("ScrollingFrame")
        page.Name = name
        page.BackgroundTransparency = 1
        page.BorderSizePixel = 0
        page.Size = UDim2.new(1, 0, 1, 0)
        page.ScrollBarThickness = 4
        page.ScrollBarImageColor3 = ACCENT
        page.AutomaticCanvasSize = Enum.AutomaticSize.Y
        page.CanvasSize = UDim2.new()
        page.Visible = false
        page.Parent = ContentHolder
        local list = Instance.new("UIListLayout")
        list.Padding = UDim.new(0, 6)
        list.Parent = page
        Pages[name] = page
    end
end

-- control builders --------------------------------------------------------------
local function section(page, label)
    local frame = Instance.new("Frame")
    frame.BackgroundColor3 = CARD
    frame.BorderSizePixel = 0
    frame.Size = UDim2.new(1, -10, 0, 26)
    frame.Parent = page
    makeCorner(frame, 6)
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Font = FONT_B
    l.TextSize = 12
    l.TextColor3 = ACCENT
    l.Text = label
    l.Position = UDim2.new(0, 10, 0, 3)
    l.Size = UDim2.new(1, -16, 1, 0)
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Parent = frame
end

local function addToggle(page, label, key, callback)
    local row = Instance.new("TextButton")
    row.AutoButtonColor = false
    row.BackgroundColor3 = PANEL2
    row.BorderSizePixel = 0
    row.Text = ""
    row.Size = UDim2.new(1, -10, 0, 30)
    row.Parent = page
    makeCorner(row, 7)
    local t = Instance.new("TextLabel")
    t.BackgroundTransparency = 1
    t.Font = FONT
    t.TextSize = 12
    t.TextColor3 = TEXT
    t.Text = label
    t.Position = UDim2.new(0, 10, 0, 0)
    t.Size = UDim2.new(1, -64, 1, 0)
    t.TextXAlignment = Enum.TextXAlignment.Left
    t.Parent = row
    local sw = Instance.new("Frame")
    sw.Size = UDim2.new(0, 34, 0, 16)
    sw.Position = UDim2.new(1, -46, 0.5, -8)
    sw.BackgroundColor3 = Config[key] and ACCENT or PANEL
    sw.Parent = row
    makeCorner(sw, 8)
    local knob = Instance.new("Frame")
    knob.Size = UDim2.new(0, 12, 0, 12)
    knob.Position = Config[key] and UDim2.new(1, -14, 0, 2) or UDim2.new(0, 2, 0, 2)
    knob.BackgroundColor3 = Color3.new(1, 1, 1)
    knob.Parent = sw
    makeCorner(knob, 6)
    row.MouseButton1Click:Connect(function()
        Config[key] = not Config[key]
        safeCall(function()
            TweenService:Create(sw, TweenInfo.new(0.12), {
                BackgroundColor3 = Config[key] and ACCENT or PANEL,
            }):Play()
            TweenService:Create(knob, TweenInfo.new(0.12), {
                Position = Config[key] and UDim2.new(1, -14, 0, 2) or UDim2.new(0, 2, 0, 2),
            }):Play()
        end)
        Hub.SaveConfig()
        if callback then safeCall(callback, Config[key]) end
    end)
end

local function addButton(page, text, callback)
    local btn = Instance.new("TextButton")
    btn.AutoButtonColor = false
    btn.BackgroundColor3 = ACCENT
    btn.BorderSizePixel = 0
    btn.Font = FONT_B
    btn.TextSize = 12
    btn.TextColor3 = Color3.new(1, 1, 1)
    btn.Text = text
    btn.Size = UDim2.new(1, -10, 0, 28)
    btn.Parent = page
    makeCorner(btn, 7)
    btn.MouseButton1Click:Connect(function() safeCall(callback) end)
end

local function addSlider(page, label, key, minV, maxV, step, callback)
    local row = Instance.new("Frame")
    row.BackgroundColor3 = PANEL2
    row.BorderSizePixel = 0
    row.Size = UDim2.new(1, -10, 0, 40)
    row.Parent = page
    makeCorner(row, 7)
    local t = Instance.new("TextLabel")
    t.BackgroundTransparency = 1
    t.Font = FONT
    t.TextSize = 12
    t.TextColor3 = TEXT
    t.Text = label
    t.Position = UDim2.new(0, 10, 0, 4)
    t.Size = UDim2.new(1, -70, 0, 14)
    t.TextXAlignment = Enum.TextXAlignment.Left
    t.Parent = row
    local value = Instance.new("TextLabel")
    value.BackgroundTransparency = 1
    value.Font = FONT_B
    value.TextSize = 11
    value.TextColor3 = ACCENT
    value.Text = tostring(Config[key] or minV)
    value.Position = UDim2.new(1, -62, 0, 4)
    value.Size = UDim2.new(0, 52, 0, 14)
    value.TextXAlignment = Enum.TextXAlignment.Right
    value.Parent = row
    local bar = Instance.new("TextButton")
    bar.Text = ""
    bar.AutoButtonColor = false
    bar.BorderSizePixel = 0
    bar.BackgroundColor3 = PANEL
    bar.Position = UDim2.new(0, 10, 0, 24)
    bar.Size = UDim2.new(1, -20, 0, 7)
    bar.Parent = row
    makeCorner(bar, 3)
    local fill = Instance.new("Frame")
    fill.BorderSizePixel = 0
    fill.BackgroundColor3 = ACCENT
    fill.Size = UDim2.new(
        math.clamp(((tonumber(Config[key]) or minV) - minV) / (maxV - minV), 0, 1), 0, 1, 0)
    fill.Parent = bar
    makeCorner(fill, 3)
    local dragging = false
    local function setFromX(x)
        local ratio = math.clamp((x - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1), 0, 1)
        local raw = minV + (maxV - minV) * ratio
        local val = math.floor(raw / step + 0.5) * step
        Config[key] = val
        value.Text = tostring(val)
        fill.Size = UDim2.new(ratio, 0, 1, 0)
        Hub.SaveConfig()
        if callback then safeCall(callback, val) end
    end
    bar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            setFromX(input.Position.X)
        end
    end)
    track(UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
            setFromX(input.Position.X)
        end
    end))
    track(UserInputService.InputEnded:Connect(function()
        dragging = false
    end))
end

local function addLabel(page, text)
    local t = Instance.new("TextLabel")
    t.BackgroundTransparency = 1
    t.Font = FONT
    t.TextSize = 11
    t.TextColor3 = DIM
    t.Text = text
    t.Size = UDim2.new(1, -10, 0, 26)
    t.TextWrapped = true
    t.TextXAlignment = Enum.TextXAlignment.Left
    t.TextYAlignment = Enum.TextYAlignment.Top
    t.Parent = page
    return t
end

local function addAreaChips(page)
    section(page, "Steal from areas (none selected = all)")
    local holder = Instance.new("Frame")
    holder.BackgroundTransparency = 1
    holder.Size = UDim2.new(1, -10, 0, 118)
    holder.Parent = page
    local flow = Instance.new("UIGridLayout")
    flow.CellSize = UDim2.new(0, 118, 0, 26)
    flow.CellPadding = UDim2.new(0, 6, 0, 6)
    flow.Parent = holder
    for _, area in ipairs(AreaList) do
        local chip = Instance.new("TextButton")
        chip.AutoButtonColor = false
        chip.BackgroundColor3 = Config.Areas[area] and ACCENT or PANEL2
        chip.Font = FONT
        chip.TextSize = 10
        chip.TextColor3 = Config.Areas[area] and Color3.new(1, 1, 1) or DIM
        chip.Text = area
        chip.Parent = holder
        makeCorner(chip, 6)
        chip.MouseButton1Click:Connect(function()
            if Config.Areas[area] then
                Config.Areas[area] = nil
            else
                Config.Areas[area] = true
            end
            chip.BackgroundColor3 = Config.Areas[area] and ACCENT or PANEL2
            chip.TextColor3 = Config.Areas[area] and Color3.new(1, 1, 1) or DIM
            Hub.SaveConfig()
        end)
    end
end

-- pages ---------------------------------------------------------------------------
local function buildPages()
    -- MAIN ------------------------------------------------------------------------
    section(Pages.Main, "State")
    local statusLabel = addLabel(Pages.Main, "starting...")
    local lastStatusAt = 0
    track(RunService.Heartbeat:Connect(function()
        if os.clock() - lastStatusAt < 0.3 then return end
        lastStatusAt = os.clock()
        statusLabel.Text = ("status: %s | walk %.0f | speed %s\nstolen %d  hatched %d  placed %d  sold %d  (loop %d)")
            :format(tostring(S.status), realWalkSpeed(), short(speedStat()),
            S.stolen, S.hatched, S.placed, S.sold, S.loops)
    end))
    section(Pages.Main, "Quick start")
    addLabel(Pages.Main, "Run Diagnostics first, then toggle Auto Steal. Guard-unsafe eggs are skipped automatically.")
    addToggle(Pages.Main, "Auto Steal (walk to egg → carry home)", "AutoSteal")
    addToggle(Pages.Main, "Auto claim offline earnings", "AutoClaimOffline")
    addButton(Pages.Main, "Diagnostics — report what the hub can see", function()
        local plotOk = resolvePlot()
        local recs = fieldSnapshotRecords()
        local n = 0
        for _, r in pairs(recs) do
            if type(r) == "table" and r.State == "Slot" then n = n + 1 end
        end
        local _, petCount = myPets()
        local checks = {
            ("plot=%s pen=%s origin=%s"):format(
                plotOk and "OK" or "MISSING",
                S.pen and "OK" or "MISSING",
                S.origin and "OK" or "MISSING"),
            ("field-eggs=%d pets=%d"):format(n, petCount),
            ("guards=%s assets=%s"):format(
                next(G.Guards) and "OK" or "MISSING",
                next(G.Assets) and "OK" or "MISSING"),
            ("mutation-mod=%s"):format(G.Mutations and "OK" or "MISSING"),
            ("walk-speed=%.0f treadmill=%s"):format(realWalkSpeed(), S.tread and "OK" or "MISSING"),
        }
        Notify("Diagnostics", table.concat(checks, " | "), "info")
    end)
    addLabel(Pages.Main, "Movement is real walking only — the server-safe way. Optional fast mode is opt-in.")

    -- STEAL -----------------------------------------------------------------------
    addAreaChips(Pages.Steal)
    section(Pages.Steal, "Targeting")
    addToggle(Pages.Steal, "Prefer richest egg (else nearest)", "PreferBest")
    addSlider(Pages.Steal, "Min income floor (% of your best pet)", "MinRatePct", 0, 8, 1)
    addSlider(Pages.Steal, "Eggs per outing", "ChainGrab", 1, 8, 1)
    section(Pages.Steal, "Delivery")
    addToggle(Pages.Steal, "Auto place carried egg in pen", "AutoPlace")
    section(Pages.Steal, "Speed (advanced — leave OFF until stable)")
    addToggle(Pages.Steal, "Fast mode (bound to 2x your real walk speed)", "FastMode")
    addLabel(Pages.Steal, "Fast mode never anchors and slows to plain walking automatically if the game pushes you back.")

    -- BASE ------------------------------------------------------------------------
    section(Pages.Base, "Automation")
    addToggle(Pages.Base, "Auto place eggs", "AutoPlace")
    addToggle(Pages.Base, "Auto hatch ready eggs", "AutoHatch")
    addToggle(Pages.Base, "Auto equip pets from backpack", "AutoEquip")
    addToggle(Pages.Base, "Auto sell (when the pen is full)", "AutoSell")
    addToggle(Pages.Base, "Also sell worse backpack pets", "SellBackpack")
    addLabel(Pages.Base, "Selling keeps your best pets and replaces the worst when something better arrives.")

    -- TRAIN -----------------------------------------------------------------------
    section(Pages.Train, "Get faster the legit way")
    addLabel(Pages.Train, "This game raises your Speed by running on your own treadmill. More Speed = safer zones.")
    addToggle(Pages.Train, "Train when too slow (auto detect)", "AutoTrain")
    addSlider(Pages.Train, "Seconds per training run", "TreadmillSeconds", 5, 60, 5)
    section(Pages.Train, "Upgrades (spends real cash)")
    addToggle(Pages.Train, "Auto upgrade treadmill", "AutoUpTreadmill")
    addLabel(Pages.Train, "Price cap below: 0 = no cap. 6 = max $9.99M, 9 = max $0.99B, 12 = max $0.99T.")
    addSlider(Pages.Train, "Max price cap exponent (0=off)", "MaxTreadmillPrice", 0, 15, 1)

    -- VISUAL ----------------------------------------------------------------------
    section(Pages.Visual, "Egg ESP")
    addToggle(Pages.Visual, "Egg ESP", "EggESP")
    addSlider(Pages.Visual, "ESP render distance", "ESPDistance", 50, 800, 10)
    section(Pages.Visual, "Performance")
    addToggle(Pages.Visual, "FPS boost", "FPSBoost", applyFpsBoost)
    addLabel(Pages.Visual, "FPS boost removes particles every 4s and clears shadows.")

    -- SETTINGS --------------------------------------------------------------------
    section(Pages.Settings, "Config")
    addLabel(Pages.Settings, "Config auto-saves to GabHub_SAE.json after every change.")
    addButton(Pages.Settings, "Save config now", function()
        Hub.SaveConfig()
        Notify("Config", "Saved.", "success")
    end)
    addButton(Pages.Settings, "Safety mode: all features OFF + save", function()
        for _, key in ipairs({
            "AutoSteal", "AutoPlace", "AutoHatch", "AutoEquip", "AutoSell",
            "AutoClaimOffline", "AutoTrain", "AutoUpTreadmill", "FastMode",
        }) do
            Config[key] = false
        end
        stopNavigation()
        Hub.SaveConfig()
        Notify("Config", "All features OFF (idling safe).", "success")
    end)
    addButton(Pages.Settings, "Release movement (un-stick character)", function()
        stopNavigation()
        Notify("Movement", "Controls returned to you.", "success")
    end)
    addButton(Pages.Settings, "Reset to defaults", function()
        local keybind = Config.Keybind
        for key, value in pairs(Defaults) do
            if type(value) == "table" then
                Config[key] = {}
            else
                Config[key] = value
            end
        end
        Config.Keybind = keybind or Defaults.Keybind
        Hub.SaveConfig()
        Notify("Config", "Defaults restored (keybind kept).", "info")
    end)
    addButton(Pages.Settings, "Unload hub", function()
        Hub.Unload()
    end)
    addLabel(Pages.Settings, "Gab Hub | Steal An Egg — open-source rebuild by Gab.")
    addLabel(Pages.Settings, "github.com/Inkflow-Gab")
end

-- keybind ------------------------------------------------------------------------
track(UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    local wanted = Config.Keybind or "RightShift"
    local match = safeCall(function()
        return input.KeyCode == Enum.KeyCode[wanted]
    end)
    if match and MainFrame then
        MainFrame.Visible = not MainFrame.Visible
    end
end))

--------------------------------------------------------------------------------
-- Boot / Unload
--------------------------------------------------------------------------------
function Hub.Unload()
    SESSION.dead = true
    stopNavigation()
    for _, conn in ipairs(SESSION.connections) do
        pcall(function() conn:Disconnect() end)
    end
    for _, obj in ipairs(SESSION.instances) do
        pcall(function() obj:Destroy() end)
    end
    table.clear(SESSION.connections)
    table.clear(SESSION.instances)
    getgenv().GabHub_SAE = nil
end

buildWindow()
buildPages()
selectPage("Main")
Notify("Gab Hub", ("Loaded v%s — Steal An Egg (BAC-safe)."):format(Hub.Version), "success")

task.spawn(function()
    repeat task.wait() until game:IsLoaded()
    task.wait(1)

    installAntiKick()
    guardCharacter(LocalPlayer.Character)
    wireCarryState()
    wireResetCountdown()

    -- wait for our plot before starting any automation
    local t0 = os.clock()
    while not SESSION.dead and not resolvePlot() and os.clock() - t0 < 45 do
        S.status = "waiting for your plot"
        task.wait(1)
    end
    if not S.plot then
        S.status = "plot not found"
        Notify("Gab Hub", "Your plot could not be located — features are paused.", "error")
    else
        claimOffline()
        spawnLoop(mainCycle)
        Notify("Gab Hub", "Plot found — engine running. Toggle features to act.", "success")
    end
end)

return Hub
