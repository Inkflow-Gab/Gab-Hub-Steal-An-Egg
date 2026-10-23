--==============================================================================
--  GAB HUB | Steal An Egg   --  v2.0.0 (mobile-first rebuild)
--  by Gab (Inkflow-Gab) — keyless, Delta/Android friendly
--
--  Built around the game's CURRENT data APIs:
--    ReplicatedStorage.Client.EggState        -> ReadFieldEggs() records
--    ReplicatedStorage.Shared.Save            -> Save.Get() player data
--    ReplicatedStorage.Data.Assets            -> rarity directory
--    ReplicatedStorage.Packages.Networking    -> named remotes (RF/..., RE/...)
--
--  Menu bind: RightShift (changeable in Settings tab)
--==============================================================================

if not game then
    error("GabHub: run this inside a Roblox executor, not a plain Lua editor.", 0)
end

local Hub     = { Version = "2.0.0" }
local SESSION = { connections = {}, instances = {}, dead = false }

-- Re-execution safety: tear down any previous run cleanly ----------------------
if getgenv().GabHub_SAE and type(getgenv().GabHub_SAE.Unload) == "function" then
    pcall(getgenv().GabHub_SAE.Unload)
    task.wait(0.1)
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
local CollectionService = game:GetService("CollectionService")
local TweenService      = game:GetService("TweenService")
local TeleportService   = game:GetService("TeleportService")
local Lighting          = game:GetService("Lighting")
local HttpService       = game:GetService("HttpService")
local VirtualUser       = game:GetService("VirtualUser")

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Bookkeeping / sa hãnfety helpers
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

--------------------------------------------------------------------------------
-- Config  (JSON file, survives re-joins)
--------------------------------------------------------------------------------
local ConfigFile = "GabHub_SAE.json"

local Defaults = {
    Keybind = "RightShift",

    -- Steal
    AutoSteal      = false,
    StealAreas     = {},
    StealMinRarity = 1,
    StealPriority  = "Rarest",
    StealSpeed     = 24,
    StealTeleport  = false,
    CooldownFailed = 1.5,

    -- Base / placement
    AutoPlace      = false,
    AutoHatch      = false,
    PlaceMinRarity = 1,

    -- Selling (by rarity index)
    AutoSellEggs = false,
    AutoSellPets = false,
    SellMaxRarity = 4,

    -- Rewards & upgrades
    AutoClaim      = false,
    AutoBaseUp     = false,
    AutoTreadmill  = false,
    AutoBuyTrail   = false,
    AutoEquipBest  = false,

    -- Combat
    BatAura     = false,
    BatRadius   = 14,
    BatDelay    = 0.25,
    GuardAura   = false,
    DefendEgg   = false,
    AntiRagdoll = true,

    -- Movement
    WalkSpeed  = 16,
    JumpPower  = 50,
    InfJump    = false,
    Noclip     = false,
    AntiAFK    = true,

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
local function safeEncode(tbl)
    local ok, data = pcall(function() return HttpService:JSONEncode(tbl) end)
    if ok then return data end
    return nil
end

function Hub.SaveConfig()
    if type(writefile) ~= "function" then return end
    local str = safeEncode(Config)
    if str then pcall(writefile, ConfigFile, str) end
end
function Hub.LoadConfig()
    if type(readfile) ~= "function" or type(isfile) ~= "function" then return end
    local exists = pcall(isfile, ConfigFile)
    if not exists then return end
    local data = safeDecode(safeCall(readfile, ConfigFile))
    if type(data) == "table" then
        for key, value in pairs(data) do
            if type(Config[key]) == type(value) or Config[key] == nil then
                Config[key] = value
            end
        end
    end
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
-- Game API  (dynamic discovery + caching)
--------------------------------------------------------------------------------
local NetCache = {}
local function getRemote(path)
    if NetCache[path] ~= nil then
        return NetCache[path] or nil
    end
    local result
    local networking = ReplicatedStorage:FindFirstChild("Packages")
        and ReplicatedStorage.Packages:FindFirstChild("Networking")
    if networking then
        result = networking:FindFirstChild(path, true)
    end
    if not result then
        result = ReplicatedStorage:FindFirstChild(path, true)
    end
    NetCache[path] = result or false
    return result
end

local function callRemote(path, isEvent, ...)
    local remote = getRemote(path)
    if not remote then return nil end
    local args = { ... }
    if isEvent then
        local ok = pcall(function()
            remote:FireServer(unpack(args))
        end)
        return ok
    else
        local ok, result = pcall(function() return remote:InvokeServer(unpack(args)) end)
        if ok then return result end
        return nil
    end
end

local EggStateModule, SaveModule, AssetsModule
safeCall(function()
    local client = ReplicatedStorage:FindFirstChild("Client")
    local mod = client and client:FindFirstChild("EggState")
    if mod then EggStateModule = require(mod) end
end)
safeCall(function()
    local shared = ReplicatedStorage:FindFirstChild("Shared")
    local mod = shared and shared:FindFirstChild("Save")
    if mod then SaveModule = require(mod) end
end)
safeCall(function()
    local data = ReplicatedStorage:FindFirstChild("Data")
    local mod = data and data:FindFirstChild("Assets")
    if mod then AssetsModule = require(mod) end
end)

local AreaList = {
    "Forest", "Lake", "Desert", "Jungle", "Snow", "Volcano",
    "Abyss Ocean", "Prehistoric", "Cosmic", "Cherry Blossom",
    "Titan Temple", "Light Dark",
}

local RarityOrder = {
    ["Common"]    = 1, ["Uncommon"]  = 2, ["Rare"]      = 3,
    ["Epic"]      = 4, ["Legendary"] = 5, ["Mythic"]    = 6,
    ["Secret"]    = 7, ["Limited"]   = 7, ["Exclusive"] = 7,
    ["Divine"]    = 8, ["Special"]   = 8, ["Eternal"]   = 9,
}
local function rarityRank(name)
    if type(name) ~= "string" then return 0 end
    return RarityOrder[name] or 0
end

local function getSave()
    if not SaveModule then return nil end
    local ok, data = pcall(SaveModule.Get)
    if ok and type(data) == "table" then return data end
    return nil
end

local function eggRarityOf(item)
    if type(item) == "table" then
        local r = item.Rarity
        if type(r) == "table" then
            local name = r.DisplayName or r.Name or r._id
            local rank = rarityRank(name)
            if rank > 0 then return name, rank end
        elseif type(r) == "string" then
            local rank = rarityRank(r)
            if rank > 0 then return r, rank end
        end
        local cat = item.AssetCategory
        if AssetsModule and cat then
            local ok, entry = pcall(function()
                return AssetsModule.Directory and AssetsModule.Directory[cat]
            end)
            if ok and type(entry) == "table" and type(entry.Rarity) == "table" then
                local name = entry.Rarity.DisplayName or entry.Rarity.Name
                local rank = rarityRank(name)
                if rank > 0 then return name, rank end
            end
        end
    end
    return "Unknown", 0
end

local function eggIncomeOf(item)
    if type(item) ~= "table" then return 0 end
    local v = item.IncomePerSecond or item.Income or item.IncomeValue
    if type(v) == "number" then return v end
    return 0
end

local function eggPositionOf(item)
    if type(item) ~= "table" then return nil end
    local cf = item.BoundsCFrame or item.CFrame
    if cf then
        local ok, pos = pcall(function() return cf.Position end)
        if ok and typeof(pos) == "Vector3" then return pos end
    end
    local p = item.Position
    if typeof(p) == "Vector3" then return p end
    -- Last resort: locate the workspace instance by its uid attribute/tag
    local uid = item.Uid or item.UID
    if uid then
        local _, tagged = pcall(CollectionService.GetTagged, CollectionService, "CarryAreaEgg")
        if type(tagged) == "table" then
            local target = tostring(uid)
            for _, obj in ipairs(tagged) do
                local attr = obj:GetAttribute("Uid") or obj:GetAttribute("UID")
                if attr ~= nil and tostring(attr) == target then
                    local prim = obj:IsA("BasePart") and obj or obj:FindFirstChildWhichIsA("BasePart", true)
                    if prim then return prim.Position end
                end
            end
        end
    end
    return nil
end

local function fieldEggs()
    if EggStateModule and type(EggStateModule.ReadFieldEggs) == "function" then
        local ok, res = pcall(EggStateModule.ReadFieldEggs)
        if ok and type(res) == "table" and type(res.Records) == "table" then
            return res.Records
        end
    end
    local snap = callRemote("RF/EggWorld/AskFieldEggSnapshot", false)
    if type(snap) == "table" then
        if type(snap.Records) == "table" then return snap.Records end
        return snap
    end
    return nil
end

local function getEggInventory()
    local data = getSave()
    if data and type(data.EggInventory) == "table" then
        return data.EggInventory
    end
    return nil
end

local function hasEggInInventory(uid)
    local inv = getEggInventory()
    return inv ~= nil and inv[uid] ~= nil
end

local function findPromptNearEgg(rootPos, maxDist)
    local best, bestDist = nil, maxDist or 18
    local tagged = safeCall(function() return CollectionService:GetTagged("CarryAreaEgg") end)
    if type(tagged) == "table" then
        for _, obj in ipairs(tagged) do
            local prompt = (obj:IsA("ProximityPrompt") and obj)
                or obj:FindFirstChildWhichIsA("ProximityPrompt", true)
            if prompt and prompt.Parent then
                local anchor = prompt.Parent:IsA("BasePart") and prompt.Parent
                    or prompt.Parent:FindFirstChildWhichIsA("BasePart", true)
                if anchor then
                    local d = (anchor.Position - rootPos).Magnitude
                    if d < bestDist then
                        best, bestDist = prompt, d
                    end
                end
            end
        end
    end
    return best
end

--------------------------------------------------------------------------------
-- Character helpers
--------------------------------------------------------------------------------
local function findChar()
    return LocalPlayer.Character
end
local function findRoot()
    local c = findChar()
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function findHumanoid()
    local c = findChar()
    return c and c:FindFirstChildOfClass("Humanoid")
end

local function myPlot()
    local plots = Workspace:FindFirstChild("Plots")
    if not plots then return nil end
    local uid = LocalPlayer.UserId
    local name = LocalPlayer.Name
    for _, candidate in ipairs(plots:GetChildren()) do
        local attr = candidate:GetAttribute("Owner")
            or candidate:GetAttribute("OwnerUserId")
            or candidate:GetAttribute("OwnerId")
            or candidate:GetAttribute("UserId")
            or candidate:GetAttribute("Player")
        if attr ~= nil and (attr == uid or tostring(attr) == tostring(uid) or attr == name) then
            return candidate
        end
    end
    return nil
end

local function plotCenter()
    local plot = myPlot()
    if plot then
        local prim = plot:IsA("BasePart") and plot or plot:FindFirstChildWhichIsA("BasePart", true)
        if prim then return prim.Position end
    end
    local root = findRoot()
    return root and root.Position or nil
end

-- Navigation -------------------------------------------------------------------
local navigating = false
local function stopNavigation()
    navigating = false
    local hum = findHumanoid()
    if hum then
        safeCall(function() hum:Move(Vector3.zero, false) end)
    end
end

local function walkTo(targetPos, speed, timeout)
    if not targetPos then return false end
    local hum = findHumanoid()
    if not hum then return false end
    navigating = true
    local t0 = os.clock()
    local arrived = false
    while navigating and not SESSION.dead and (not timeout or os.clock() - t0 < timeout) do
        local root = findRoot()
        if not root then break end
        local delta = targetPos - root.Position
        local dist = delta.Magnitude
        if dist <= 5 then
            arrived = true
            break
        end
        local dt = task.wait()
        if dt <= 0 then dt = 0.016 end
        local step = math.min(dist, (speed or Config.StealSpeed or 24) * dt)
        safeCall(function()
            hum:Move(delta.Unit * step / math.max(dt, 1/240), false)
        end)
        -- Yield; RefreshHumanoidState handled by engine
    end
    navigating = false
    return arrived
end

local function teleportTo(pos)
    local root = findRoot()
    if root and pos then
        root.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
    end
end

--------------------------------------------------------------------------------
-- Character patches (speed / anti-ragdoll)
--------------------------------------------------------------------------------
local function applyCharacterPatches(humanoid)
    if not humanoid then return end
    safeCall(function()
        humanoid.WalkSpeed = Config.WalkSpeed
        humanoid.UseJumpPower = true
        humanoid.JumpPower = Config.JumpPower
        if Config.AntiRagdoll then
            humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
            humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
            humanoid.PlatformStand = false
        end
    end)
end

track(LocalPlayer.CharacterAdded:Connect(function(char)
    task.wait(0.25)
    applyCharacterPatches(char:FindFirstChildOfClass("Humanoid"))
end))
if LocalPlayer.Character then
    applyCharacterPatches(LocalPlayer.Character:FindFirstChildOfClass("Humanoid"))
end

local function applyMovement(value)
    local hum = findHumanoid()
    if hum then
        safeCall(function() hum.WalkSpeed = value end)
    end
end
applyMovement(Config.WalkSpeed)

-- Anti AFK ----------------------------------------------------------------------
track(UserInputService.Idled:Connect(function()
    if Config.AntiAFK then
        safeCall(function()
            VirtualUser:CaptureController()
            VirtualUser:Set2DInput(true)
        end)
    end
end))

-- Infinite jump ------------------------------------------------------------------
track(UserInputService.JumpRequest:Connect(function()
    if not Config.InfJump then return end
    local hum = findHumanoid()
    if hum then
        safeCall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
    end
end))

-- NoClip ---------------------------------------------------------------------
track(RunService.Stepped:Connect(function()
    if not Config.Noclip then return end
    local char = findChar()
    if char then
        for _, part in ipairs(char:GetChildren()) do
            if part:IsA("BasePart") and part.CanCollide then
                part.CanCollide = false
            end
        end
    end
end))

--------------------------------------------------------------------------------
-- FEATURE: Auto Steal
--------------------------------------------------------------------------------
local lastAttempt = {}
local stealThread = nil

local function passesFilters(record, uid)
    local pos = eggPositionOf(record)
    if not pos then return false end
    local area = record.AreaId or record.Area
    if next(Config.StealAreas) and area and not Config.StealAreas[area] then
        return false
    end
    local _, rank = eggRarityOf(record)
    if rank > 0 and rank < (Config.StealMinRarity or 1) then
        return false
    end
    if hasEggInInventory(uid) then return false end
    local cooldown = lastAttempt[uid]
    if cooldown and os.clock() < cooldown then return false end
    return true
end

local function pickTarget()
    local records = fieldEggs()
    if not records then return nil end
    local root = findRoot()
    local rootPos = root and root.Position
    local best, bestScore = nil, nil
    for uid, record in pairs(records) do
        if type(record) == "table" then
            if passesFilters(record, uid) then
                local pos = eggPositionOf(record)
                local _, rank = eggRarityOf(record)
                local income = eggIncomeOf(record)
                local dist = rootPos and pos and (rootPos - pos).Magnitude or math.huge
                local score
                if Config.StealPriority == "Nearest" then
                    score = -dist
                elseif Config.StealPriority == "Richest" then
                    score = income * 1000 - dist * 0.01
                else
                    score = (rank > 0 and rank or 1) * 100000 - dist
                end
                if bestScore == nil or score > bestScore then
                    best = record
                    bestScore = score
                    best.Uid = best.Uid or uid
                end
            end
        end
    end
    return best
end

local function returnHome()
    local pos = plotCenter()
    if not pos then return false end
    if Config.StealTeleport then
        teleportTo(pos)
        task.wait(0.4)
        return true
    end
    return walkTo(pos, Config.StealSpeed, 15)
end

local function tryPickup(uid)
    callRemote("RF/EggWorld/AskFieldEggCarry", false, { Uid = uid })
    task.wait(0.1)
    local root = findRoot()
    if root then
        local prompt = findPromptNearEgg(root.Position, 22)
        if prompt and fireproximityprompt then
            safeCall(function()
                prompt.HoldDuration = 0
                fireproximityprompt(prompt)
            end)
        end
    end
    task.wait(0.3)
    return hasEggInInventory(uid)
end

local function firstUnplacedEgg()
    local inv = getEggInventory()
    if not inv then return nil end
    for uid, data in pairs(inv) do
        if type(data) == "table" and not data.Placement and not data.Locked then
            return uid
        end
    end
    return nil
end

local function stealLoop()
    while not SESSION.dead and Config.AutoSteal do
        local target = pickTarget()
        local carrying = firstUnplacedEgg()

        if not carrying and not target then
            task.wait(1.2)
            continue
        end

        if carrying then
            -- Always deliver what we hold first
            returnHome()
            task.wait(0.5)
            if Config.AutoPlace then
                safeCall(function()
                    callRemote("RF/EggWorld/AskPlaceEgg", false, { Uid = carrying })
                end)
            end
        else
            local uid = target.Uid or target.UID
            local pos = eggPositionOf(target)
            if pos then
                if Config.StealTeleport then
                    teleportTo(pos + Vector3.new(0, 2, 0))
                else
                    walkTo(pos, Config.StealSpeed, 30)
                end
                task.wait(0.2)
                if not hasEggInInventory(uid) then
                    if not tryPickup(uid) then
                        lastAttempt[uid] = os.clock() + (Config.CooldownFailed or 1.5)
                    else
                        Notify("Steal", "Egg secured — heading home.", "success")
                    end
                end
            else
                lastAttempt[uid] = os.clock() + 2
            end
        end
        task.wait(0.25)
    end
end

local function ensureStealThread()
    if not Config.AutoSteal then
        if navigating then stopNavigation() end
        return
    end
    local alive = stealThread
        and coroutine.status(stealThread) ~= "dead"
    if not alive then
        stealThread = task.spawn(function()
            local ok, err = pcall(stealLoop)
            if not ok then
                warn("[GabHub] steal loop:", tostring(err))
            end
        end)
    end
end
track(RunService.Heartbeat:Connect(ensureStealThread))

--------------------------------------------------------------------------------
-- FEATURE: Auto Place / Auto Hatch  (~ every 2s)
--------------------------------------------------------------------------------
track(RunService.Heartbeat:Connect(function()
    if SESSION.dead or os.clock() % 2 > 0.2 then return end
    local inv = getEggInventory()
    if not inv then return end
    for uid, data in pairs(inv) do
        if type(data) == "table" then
            local _, rank = eggRarityOf(data)
            if Config.AutoPlace and not data.Placement and not data.Locked
            and rank >= (Config.PlaceMinRarity or 1) then
                safeCall(function()
                    callRemote("RF/EggWorld/AskPlaceEgg", false, { Uid = uid })
                end)
            end
            if Config.AutoHatch and data.Placement then
                local ready = nil
                if type(data.HatchAt) == "number" then
                    ready = os.time() >= data.HatchAt
                end
                if ready ~= false then
                    safeCall(function()
                        callRemote("RF/EggWorld/AskFinishHatch", false, { Uid = uid })
                    end)
                end
            end
        end
    end
end))

--------------------------------------------------------------------------------
-- FEATURE: Auto Sell eggs & pets  (~ every 2.5s)
--------------------------------------------------------------------------------
local function sellPass()
    local inv = getEggInventory()
    if not inv then return 0 end
    local wear = getRemote("RF/EggWorld/AskWearTool")
    local sell = getRemote("RE/PetSatchel/SellPet")
    if not wear or not sell then return 0 end
    local sold = 0
    for uid, data in pairs(inv) do
        if type(data) == "table" and not data.Placement and not data.Locked then
            local _, rank = eggRarityOf(data)
            if rank > 0 and rank <= (Config.SellMaxRarity or 4) then
                local ok = pcall(function()
                    wear:InvokeServer(uid)
                    sell:FireServer({ uid })
                end)
                if ok then
                    sold += 1
                    task.wait(0.12)
                end
            end
        end
    end
    return sold
end

local function sellPetsPass()
    local data = getSave()
    local pets = data and (data.PetInventory or data.Pets)
    if type(pets) ~= "table" then return 0 end
    local sell = getRemote("RE/PetSatchel/SellPet")
    if not sell then return 0 end
    local count = 0
    for uid, pet in pairs(pets) do
        if type(pet) == "table" then
            if pet.Placement or pet.Equipped or pet.Locked then continue end
            local _, rank = eggRarityOf(pet)
            if rank > 0 and rank <= (Config.SellMaxRarity or 4) then
                local ok = pcall(function() sell:FireServer({ uid }) end)
                if ok then
                    count += 1
                    task.wait(0.12)
                end
            end
        end
    end
    return count
end

track(RunService.Heartbeat:Connect(function()
    if SESSION.dead or os.clock() % 2.5 > 0.2 then return end
    if Config.AutoSellEggs then
        local ok, n = pcall(sellPass)
        if ok and n and n > 0 then
            Notify("Sell", ("Sold %d egg(s)."):format(n), "info")
        end
    end
    if Config.AutoSellPets then
        local ok, n = pcall(sellPetsPass)
        if ok and n and n > 0 then
            Notify("Sell", ("Sold %d pet(s)."):format(n), "info")
        end
    end
end))

--------------------------------------------------------------------------------
-- FEATURE: Claim / upgrades / treadmill / trail (~ every 6s)
--------------------------------------------------------------------------------
local function upgradeBase()
    safeCall(function()
        local re = getRemote("RE/Homestead/AskNearbyPurchase")
        if re then re:FireServer() end
    end)
    safeCall(function()
        local re = getRemote("RE/Homestead/AskBaseTierRaise")
        if re then re:FireServer() end
    end)
end

track(RunService.Heartbeat:Connect(function()
    if SESSION.dead or os.clock() % 6 > 0.25 then return end
    if Config.AutoClaim then
        safeCall(function() callRemote("RF/AwayEarnings/AskCollect", false) end)
        safeCall(function() callRemote("RF/Codex/AskRedeemAll", false) end)
        safeCall(function() callRemote("RF/GroupPerk/RedeemPerk", false) end)
    end
    if Config.AutoBaseUp then
        upgradeBase()
    end
    if Config.AutoEquipBest then
        safeCall(function()
            local rf = getRemote("RF/Haul/WearBest") or getRemote("RF/PenRoster/ConfirmEquipBestBadge")
            if rf then rf:InvokeServer() end
        end)
    end
    if Config.AutoBuyTrail then
        safeCall(function()
            local rf = getRemote("RF/Trailwear/AskPurchase")
            if rf then rf:InvokeServer() end
        end)
    end
    if Config.AutoTreadmill then
        local plot = myPlot()
        if plot then
            local seat = nil
            for _, obj in ipairs(plot:GetDescendants()) do
                local n = tostring(obj.Name):lower()
                if n:find("treadmill", 1, true) then
                    if obj:IsA("Seat") then
                        seat = obj
                        break
                    else
                        local inner = obj:FindFirstChildWhichIsA("Seat", true)
                        if inner then
                            seat = inner
                            break
                        end
                    end
                end
            end
            local hum = findHumanoid()
            local root = findRoot()
            if seat and hum and root then
                local pos = seat:IsA("BasePart") and seat.Position or nil
                if pos and (root.Position - pos).Magnitude > 6 then
                    walkTo(pos, Config.StealSpeed, 10)
                end
                if not seat.Occupant then
                    safeCall(function() seat:Sit(hum) end)
                end
                safeCall(function()
                    local rf = getRemote("RF/Treadmill/AskTierRaise")
                    if rf then rf:InvokeServer() end
                end)
            end
        end
    end
end))

--------------------------------------------------------------------------------
-- FEATURE: Combat (bat + guards)
--------------------------------------------------------------------------------
local function swingBat()
    safeCall(function()
        local re = getRemote("RE/BatSwing/Trigger")
        if re then re:FireServer() end
    end)
end
local function strikeNearby()
    safeCall(function()
        local re = getRemote("RE/GuardPatrol/ForestStrike")
        if re then re:FireServer() end
    end)
end

track(RunService.Heartbeat:Connect(function()
    if SESSION.dead or os.clock() % (Config.BatDelay or 0.25) > 0.06 then return end
    local root = findRoot()
    if not root then return end
    if Config.BatAura then
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer then
                local r = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
                if r and (r.Position - root.Position).Magnitude <= (Config.BatRadius or 14) then
                    swingBat()
                    break
                end
            end
        end
    end
    if Config.GuardAura then
        strikeNearby()
    end
end))

track(RunService.Heartbeat:Connect(function()
    if SESSION.dead or not Config.DefendEgg or os.clock() % 0.4 > 0.08 then return end
    local root = findRoot()
    if not root then return end
    local home = plotCenter()
    if not home or (root.Position - home).Magnitude > 55 then return end
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then
            local r = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
            local h = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
            if r and h and h.Health > 0 and (r.Position - home).Magnitude < 26 then
                swingBat()
                break
            end
        end
    end
end))

--------------------------------------------------------------------------------
-- FEATURE: Egg ESP
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
        if (not ok or not espGui.Parent) and LocalPlayer:FindFirstChild("PlayerGui") then
            espGui.Parent = LocalPlayer.PlayerGui
        end
    end
    return espGui
end

track(RunService.Heartbeat:Connect(function()
    if not Config.EggESP then
        if espGui then espGui:ClearAllChildren() end
        return
    end
    if SESSION.dead or os.clock() % 1 > 0.25 then return end
    local camera = Workspace.CurrentCamera
    local root = findRoot()
    if not camera or not root then return end
    local gui = ensureEspGui()
    gui:ClearAllChildren()
    local records = fieldEggs()
    if not records then return end
    for uid, record in pairs(records) do
        if type(record) == "table" then
            local pos = eggPositionOf(record)
            if pos and (pos - root.Position).Magnitude <= (Config.ESPDistance or 250) then
                local screen, onScreen = camera:WorldToViewportPoint(pos)
                if onScreen then
                    local rarity, rank = eggRarityOf(record)
                    local label = Instance.new("TextLabel")
                    label.Name = "GabESP_" .. tostring(uid)
                    label.Text = ("%s\n[%s]"):format(
                        tostring(record.Name or record.EggName or "Egg"),
                        tostring(rarity))
                    label.Font = Enum.Font.GothamBold
                    label.TextSize = 13
                    label.TextColor3 = rank >= 8 and Color3.fromRGB(255, 70, 160)
                        or rank >= 6 and Color3.fromRGB(255, 90, 60)
                        or Color3.fromRGB(255, 200, 120)
                    label.TextStrokeTransparency = 0.25
                    label.BackgroundTransparency = 0.4
                    label.BackgroundColor3 = Color3.new(0, 0, 0)
                    label.BorderSizePixel = 0
                    label.Size = UDim2.fromOffset(96, 34)
                    label.Position = UDim2.new(0, screen.X - 48, 0, screen.Y - 17)
                    label.AutomaticSize = Enum.AutomaticSize.None
                    label.Parent = gui
                end
            end
        end
    end
end))

--------------------------------------------------------------------------------
-- FEATURE: FPS boost
--------------------------------------------------------------------------------
local fpsSweepThread = nil
local function applyFpsBoost(on)
    if not on then return end
    if fpsSweepThread and coroutine.status(fpsSweepThread) ~= "dead" then return end
    safeCall(function()
        Lighting.GlobalShadows = false
        Lighting.FogEnd = 9e9
        Lighting.Brightness = 1
    end)
    fpsSweepThread = task.spawn(function()
        while not SESSION.dead and Config.FPSBoost do
            safeCall(function()
                for _, obj in ipairs(Workspace:GetDescendants()) do
                    if obj:IsA("ParticleEmitter") then
                        obj.Enabled = false
                    end
                end
            end)
            task.wait(4)
        end
    end)
end

--------------------------------------------------------------------------------
-- GUI  (hand-rolled, touch-safe)
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
local PageOrder = { "Main", "Steal", "Base", "Shop", "Combat", "Move", "Visual", "Settings" }

local function guiParent()
    local parent
    pcall(function()
        if typeof(gethui) == "function" then parent = gethui() end
    end)
    if parent then return parent end
    pcall(function()
        parent = game:GetService("CoreGui")
    end)
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

    -- Notification stack lives inside the same ScreenGui ------------------------
    notifyHolder = Instance.new("Frame")
    notifyHolder.Name = "Notices"
    notifyHolder.BackgroundTransparency = 1
    notifyHolder.Size = UDim2.new(0, 220, 0, 320)
    notifyHolder.Position = UDim2.new(1, -12, 0, 40)
    notifyHolder.AnchorPoint = Vector2.new(1, 0)
    notifyHolder.ZIndex = 50
    notifyHolder.Parent = ScreenGui
    local nAnim = Instance.new("UIListLayout")
    nAnim.Padding = UDim.new(0, 5)
    nAnim.SortOrder = Enum.SortOrder.LayoutOrder
    nAnim.VerticalAlignment = Enum.VerticalAlignment.Bottom
    nAnim.HorizontalAlignment = Enum.HorizontalAlignment.Right
    nAnim.Parent = notifyHolder
    trackInstance(notifyHolder)

    MainFrame = Instance.new("Frame")
    MainFrame.Name = "Root"
    MainFrame.Size = UDim2.fromOffset(560, 384)
    MainFrame.Position = UDim2.new(0.5, -280, 0.5, -192)
    MainFrame.BackgroundColor3 = PANEL
    MainFrame.BorderSizePixel = 0
    MainFrame.BorderSizePixel = 0
    MainFrame.Parent = ScreenGui
    makeCorner(MainFrame, 12)
    local stroke = Instance.new("UIStroke")
    stroke.Color = ACCENT
    stroke.Thickness = 1
    stroke.Transparency = 0.45
    stroke.Parent = MainFrame

    -- Title bar ---------------------------------------------------------------
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

    -- Mobile scale ------------------------------------------------------------
    local uiScale = Instance.new("UIScale")
    uiScale.Scale = 1
    uiScale.Parent = MainFrame
    trackInstance(uiScale)
    local function fit()
        safeCall(function()
            local vp = ScreenGui.AbsoluteSize
            local abs = MainFrame.AbsoluteSize
            if vp.X <= 10 or abs.X <= 10 then return end
            uiScale.Scale = math.clamp(math.min((vp.X - 16) / abs.X, (vp.Y - 16) / abs.Y), 0.45, 1)
        end)
    end
    track(ScreenGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit))
    task.delay(0.3, fit)

    -- Left nav ---------------------------------------------------------------
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
        Main = "🏠", Steal = "🥚", Base = "📦", Shop = "🛒",
        Combat = "⚔️", Move = "🏃", Visual = "👁", Settings = "⚙",
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

    -- Content ----------------------------------------------------------------
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

--------------------------------------------------------------------------------
-- GUI control builders
--------------------------------------------------------------------------------
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
    return row
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
    return btn
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
    fill.Size = UDim2.new(math.clamp(((tonumber(Config[key]) or minV) - minV) / (maxV - minV), 0, 1), 0, 1, 0)
    fill.Parent = bar
    makeCorner(fill, 3)
    local dragging = false
    local function setFromX(x)
        local ratio = math.clamp((x - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1), 0, 1)
        local raw = minV + (maxV - minV) * ratio
        local val = step and (math.floor(raw / step + 0.5) * step) or raw
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
    return row
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
        chip.BackgroundColor3 = Config.StealAreas[area] and ACCENT or PANEL2
        chip.Font = FONT
        chip.TextSize = 10
        chip.TextColor3 = Config.StealAreas[area] and Color3.new(1, 1, 1) or DIM
        chip.Text = area
        chip.Parent = holder
        makeCorner(chip, 6)
        chip.MouseButton1Click:Connect(function()
            if Config.StealAreas[area] then
                Config.StealAreas[area] = nil
            else
                Config.StealAreas[area] = true
            end
            chip.BackgroundColor3 = Config.StealAreas[area] and ACCENT or PANEL2
            chip.TextColor3 = Config.StealAreas[area] and Color3.new(1, 1, 1) or DIM
            Hub.SaveConfig()
        end)
    end
end

--------------------------------------------------------------------------------
-- Pages
--------------------------------------------------------------------------------
local function buildPages()
    local applyFps = applyFpsBoost

    -- MAIN ----------------------------------------------------------------------
    section(Pages.Main, "Welcome")
    addLabel(Pages.Main, "Rebuilt, keyless and touch-first. Menu bind: RightShift.")
    addLabel(Pages.Main, "Recommended start: Auto Steal + Auto Claim + Auto Place + Auto Hatch.")
    addToggle(Pages.Main, "Auto Steal eggs", "AutoSteal")
    addToggle(Pages.Main, "Auto claim rewards (offline + codex + perk)", "AutoClaim")
    addToggle(Pages.Main, "Auto place eggs on your base", "AutoPlace")
    addToggle(Pages.Main, "Auto hatch placed eggs", "AutoHatch")
    addToggle(Pages.Main, "Auto sell eggs (by rarity)", "AutoSellEggs")
    addToggle(Pages.Main, "Auto sell pets (by rarity)", "AutoSellPets")
    addButton(Pages.Main, "Diagnostics — report what the hub can see", function()
        local records = fieldEggs()
        local inv = getEggInventory()
        local carry = getRemote("RF/EggWorld/AskFieldEggCarry")
        Notify("Diagnostics", ("eggs=%s | inventory=%s | carry-remote=%s"):format(
            records and "OK" or "MISSING",
            inv and "OK" or "MISSING",
            carry and "OK" or "MISSING"), "info")
    end)

    -- STEAL ---------------------------------------------------------------------
    addAreaChips(Pages.Steal)
    section(Pages.Steal, "Targeting")
    addSlider(Pages.Steal, "Movement speed (studs/s)", "StealSpeed", 16, 160, 1, function(v)
        applyMovement(v)
    end)
    addToggle(Pages.Steal, "Teleport mode (risky, instant)", "StealTeleport")
    addLabel(Pages.Steal, "Priority: Rarest → highest rarity first (fallback: nearest).")
    addButton(Pages.Steal, "Steal once now", function()
        local target = pickTarget()
        if not target then
            Notify("Steal", "No egg matched the current filters.", "error")
            return
        end
        local uid = target.Uid or target.UID
        local pos = eggPositionOf(target)
        if Config.StealTeleport then
            teleportTo(pos)
        else
            walkTo(pos, Config.StealSpeed, 30)
        end
        task.wait(0.2)
        if tryPickup(uid) then
            Notify("Steal", "Picked up — placing/heading home.", "success")
            returnHome()
            if Config.AutoPlace then
                safeCall(function()
                    callRemote("RF/EggWorld/AskPlaceEgg", false, { Uid = uid })
                end)
            end
        else
            lastAttempt[uid] = os.clock() + 2
            Notify("Steal", "Pickup failed — retrying later.", "error")
        end
    end)

    -- BASE ----------------------------------------------------------------------
    section(Pages.Base, "Base automation")
    addToggle(Pages.Base, "Auto upgrade base tiers", "AutoBaseUp")
    addToggle(Pages.Base, "Auto treadmill (walk + sit + train)", "AutoTreadmill")
    addToggle(Pages.Base, "Auto equip best pets", "AutoEquipBest")
    section(Pages.Base, "Selling")
    addSlider(Pages.Base, "Sell up to rarity index (1=Common … 9=Eternal)", "SellMaxRarity", 1, 9, 1)
    addButton(Pages.Base, "Sell eggs once", function()
        local count = sellPass()
        Notify("Sell", ("Sold %d egg(s)."):format(count), "success")
    end)
    addButton(Pages.Base, "Sell pets once", function()
        local count = sellPetsPass()
        Notify("Sell", ("Sold %d pet(s)."):format(count), "success")
    end)

    -- SHOP ----------------------------------------------------------------------
    section(Pages.Shop, "Spending")
    addToggle(Pages.Shop, "Auto buy trail (affordable)", "AutoBuyTrail")
    addLabel(Pages.Shop, "Purchases are rate-limited to one attempt every 6 seconds.")

    -- COMBAT --------------------------------------------------------------------
    section(Pages.Combat, "Combat")
    addToggle(Pages.Combat, "Bat aura (slap nearby players)", "BatAura")
    addSlider(Pages.Combat, "Bat aura radius", "BatRadius", 6, 40, 1)
    addButton(Pages.Combat, "Slap now", swingBat)
    addToggle(Pages.Combat, "Guard strike aura", "GuardAura")
    addToggle(Pages.Combat, "Defend my base", "DefendEgg")
    addLabel(Pages.Combat, "Anti-ragdoll patches re-apply automatically on respawn.")

    -- MOVE ----------------------------------------------------------------------
    section(Pages.Move, "Movement")
    addSlider(Pages.Move, "WalkSpeed", "WalkSpeed", 16, 350, 1, applyMovement)
    addSlider(Pages.Move, "JumpPower", "JumpPower", 50, 350, 1, function(v)
        local hum = findHumanoid()
        if hum then
            safeCall(function()
                hum.JumpPower = v
                hum.UseJumpPower = true
            end)
        end
    end)
    addToggle(Pages.Move, "Infinite jump", "InfJump")
    addToggle(Pages.Move, "NoClip", "Noclip")
    addToggle(Pages.Move, "Anti AFK", "AntiAFK")

    -- VISUAL --------------------------------------------------------------------
    section(Pages.Visual, "Egg ESP")
    addToggle(Pages.Visual, "Egg ESP", "EggESP")
    addSlider(Pages.Visual, "ESP render distance", "ESPDistance", 50, 800, 10)
    section(Pages.Visual, "Performance")
    addToggle(Pages.Visual, "FPS boost", "FPSBoost", applyFps)
    addLabel(Pages.Visual, "FPS boost removes particles every 4s and clears shadows.")

    -- SETTINGS ------------------------------------------------------------------
    section(Pages.Settings, "Config")
    addLabel(Pages.Settings, "Config auto-saves to GabHub_SAE.json after every change.")
    addButton(Pages.Settings, "Save config now", function()
        Hub.SaveConfig()
        Notify("Config", "Saved.", "success")
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
        Config.Keybind = keybind
        Hub.SaveConfig()
        Notify("Config", "Defaults restored (keybind kept).", "info")
    end)
    addButton(Pages.Settings, "Unload hub", function()
        Hub.Unload()
    end)
    addLabel(Pages.Settings, "Gab Hub | Steal An Egg — open-source rebuild by Gab.")
    addLabel(Pages.Settings, "github.com/Inkflow-Gab")
end

-- Keybind -------------------------------------------------------------------------
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
Notify("Gab Hub", ("Loaded v%s — Steal An Egg."):format(Hub.Version), "success")

return Hub
