--[[
    TINE HUB - BLOX FRUITS AUTO LEVEL (FIRST SEA 1-700)
    Single File | Deep Audited Quest Engine | Multi-UI Scanner | Hybrid Kill Tracker | Melee Auto Stats

    Key Architectural Fixes:
    1. Multi-ScreenGui Quest Scanner (`Main`, `Main (minimal)`, and all active ScreenGuis in `PlayerGui`):
       Fixes the mobile/compact UI bug where `PlayerGui:FindFirstChild("Main")` returned the hidden PC ScreenGui
       instead of the active `Main (minimal)` ScreenGui, which previously caused `Quest.Visible` to always read `false`
       and froze the script in `VERIFYING_QUEST`.
    2. Non-Blocking Hybrid Verification (`UI + Authoritative Kill/EXP Tracker`):
       If `StartQuest` is invoked at the Quest Giver and the UI is verified (or after a 0.9s verification window),
       the FSM immediately transitions to `FARMING` and tracks both live Quest UI numbers `(X/Y)` AND real-time
       NPC death events (`Humanoid.Health <= 0` on damaged targets) so it NEVER freezes at the Quest NPC.
    3. Upright CFrame Movement (`SafeUprightCF`):
       Eliminates collinear `CFrame.lookAt` `NaN` rotation matrices and prevents `HumanoidStateType.FallingDown`.
    4. Dedicated FastAttack & BringMob Background Loops:
       Continuously swings Melee weapon (`Tool:Activate()`, `Net/RegisterHit`, `CombatFramework`, `VirtualUser`)
       and groups same-type mobs while farming.
    5. Auto Stats Strictly Locked to MELEE ONLY.
]]

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local VU = game:GetService("VirtualUser")
local TweenService = game:GetService("TweenService")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local LP = Players.LocalPlayer

-- ================= CONFIGURATION =================

local Config = {
    Team = "Pirates",
    WeaponType = "Melee",
    AutoStatsTarget = "Melee", -- Strictly Melee Only

    TweenSpeed = 210,
    HoverHeight = 5.0,
    BringMobRadius = 260,

    FastAttack = true,
    BringMob = true,
    AutoHaki = true,
    AutoStatsMelee = true,

    AttackInterval = 0.12,
    HakiInterval = 8.0,
    StatInterval = 1.0,

    QuestSettleDelay = 0.25,
    QuestVerifyWindow = 0.90,  -- Max wait for UI before seamless fallback to Hybrid Kill Tracker
    QuestCompleteDelay = 0.50
}

-- =================================================

local env = (typeof(getgenv) == "function" and getgenv()) or _G

if env.BFAutoFarmStop then
    pcall(env.BFAutoFarmStop)
end

local Running = true
local Alive = true

-- Quest Finite State Machine (FSM):
-- "IDLE"                 -> Select stage for current level & check if quest is already active
-- "TAKING_QUEST"         -> Move to Quest Giver, settle position, invoke StartQuest
-- "VERIFYING_QUEST"      -> Check all PlayerGui ScreenGuis (`Main`, `Main (minimal)`) & lock target count
-- "FARMING"              -> Move to NPCs, BringMob + FastAttack until quest completes (UI close or all targets killed)
-- "VERIFYING_COMPLETION" -> Confirm completion before unlocking stage for next quest
local QuestState = "IDLE"

local LockedStage = nil
local CurrentMob = nil

local QuestCurrentCount = 0
local QuestRequiredCount = 0
local LocalKillCount = 0
local UIWasConfirmedVisible = false
local CountedDeadMobs = {}

local QuestVerifyDeadline = 0
local QuestCompletionStartedAt = 0
local SpawnPatrolIndex = 1
local LastSpawnPatrolAt = 0

local NextHakiAt = 0
local NextStatAt = 0

local ActiveTween = nil
local StabilizerBV = nil
local NoclipConn = nil
local SimRadiusConn = nil
local DeathMonitorConn = nil

-- ================= TINE HUB GUI =================

local GUI = Instance.new("ScreenGui")
GUI.Name = "TineHub_AutoFarm"
GUI.ResetOnSpawn = false
GUI.DisplayOrder = 999

local guiParent
pcall(function()
    guiParent = gethui()
end)

if not guiParent then
    guiParent = LP:WaitForChild("PlayerGui")
end

GUI.Parent = guiParent

local Main = Instance.new("Frame")
Main.Size = UDim2.new(0, 280, 0, 252)
Main.Position = UDim2.new(0.5, -140, 0.28, 0)
Main.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
Main.BorderSizePixel = 0
Main.Active = true
Main.Parent = GUI

Instance.new("UICorner", Main).CornerRadius = UDim.new(0, 10)

local Stroke = Instance.new("UIStroke", Main)
Stroke.Color = Color3.fromRGB(0, 170, 255)
Stroke.Thickness = 1.5

local Header = Instance.new("Frame")
Header.Size = UDim2.new(1, 0, 0, 34)
Header.BackgroundColor3 = Color3.fromRGB(20, 95, 165)
Header.BorderSizePixel = 0
Header.Parent = Main

Instance.new("UICorner", Header).CornerRadius = UDim.new(0, 10)

local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, -16, 1, 0)
Title.Position = UDim2.new(0, 8, 0, 0)
Title.BackgroundTransparency = 1
Title.Text = "TINE HUB | AUTO LEVEL 1-700"
Title.TextColor3 = Color3.new(1, 1, 1)
Title.Font = Enum.Font.GothamBold
Title.TextSize = 13
Title.TextXAlignment = Enum.TextXAlignment.Center
Title.Parent = Header

local function CreateLabel(text, y)
    local obj = Instance.new("TextLabel")
    obj.Size = UDim2.new(1, -20, 0, 19)
    obj.Position = UDim2.new(0, 10, 0, y)
    obj.BackgroundTransparency = 1
    obj.TextColor3 = Color3.fromRGB(230, 235, 245)
    obj.TextXAlignment = Enum.TextXAlignment.Left
    obj.Font = Enum.Font.GothamMedium
    obj.TextSize = 11
    obj.TextTruncate = Enum.TextTruncate.AtEnd
    obj.Text = text
    obj.Parent = Main
    return obj
end

local LevelLabel    = CreateLabel("Level: Loading...", 40)
local TargetLabel   = CreateLabel("Target: None", 60)
local ProgressLabel = CreateLabel("Quest: None (0/0)", 80)
local StatsLabel    = CreateLabel("Auto Stats: Melee Only", 100)
local StatusLabel   = CreateLabel("Status: Starting...", 120)

local FastAtkBtn = Instance.new("TextButton")
FastAtkBtn.Size = UDim2.new(0.48, -12, 0, 26)
FastAtkBtn.Position = UDim2.new(0, 10, 0, 146)
FastAtkBtn.BackgroundColor3 = Color3.fromRGB(25, 135, 95)
FastAtkBtn.TextColor3 = Color3.new(1, 1, 1)
FastAtkBtn.Font = Enum.Font.GothamBold
FastAtkBtn.TextSize = 11
FastAtkBtn.Text = "Fast Attack: ON"
FastAtkBtn.Parent = Main
Instance.new("UICorner", FastAtkBtn).CornerRadius = UDim.new(0, 6)

local BringMobBtn = Instance.new("TextButton")
BringMobBtn.Size = UDim2.new(0.48, -12, 0, 26)
BringMobBtn.Position = UDim2.new(0.52, 2, 0, 146)
BringMobBtn.BackgroundColor3 = Color3.fromRGB(25, 135, 95)
BringMobBtn.TextColor3 = Color3.new(1, 1, 1)
BringMobBtn.Font = Enum.Font.GothamBold
BringMobBtn.TextSize = 11
BringMobBtn.Text = "Bring Mob: ON"
BringMobBtn.Parent = Main
Instance.new("UICorner", BringMobBtn).CornerRadius = UDim.new(0, 6)

local Toggle = Instance.new("TextButton")
Toggle.Size = UDim2.new(1, -20, 0, 30)
Toggle.Position = UDim2.new(0, 10, 0, 180)
Toggle.BackgroundColor3 = Color3.fromRGB(30, 150, 85)
Toggle.TextColor3 = Color3.new(1, 1, 1)
Toggle.Font = Enum.Font.GothamBold
Toggle.TextSize = 12
Toggle.Text = "STOP AUTO FARM"
Toggle.Parent = Main
Instance.new("UICorner", Toggle).CornerRadius = UDim.new(0, 6)

local FooterLabel = CreateLabel("TINE HUB | State: IDLE | Stat: Melee", 218)
FooterLabel.TextColor3 = Color3.fromRGB(140, 165, 190)

local function SetStatus(text)
    StatusLabel.Text = "Status: " .. text
    FooterLabel.Text = string.format("TINE HUB | FSM: %s | Stat: Melee", QuestState)
end

local function SetProgressText(text)
    ProgressLabel.Text = "Quest: " .. text
    FooterLabel.Text = string.format("TINE HUB | FSM: %s | Stat: Melee", QuestState)
end

-- ================= CHARACTER, STABILIZER & MOVEMENT =================

local function GetCharacter()
    local char = LP.Character
    if not char then return end

    local hum = char:FindFirstChildOfClass("Humanoid")
    local root = char:FindFirstChild("HumanoidRootPart")

    if hum and root and hum.Health > 0 then
        return char, hum, root
    end
end

local function IsValidCFrame(cf)
    if typeof(cf) ~= "CFrame" then return false end
    local x, y, z, r00, _, _, _, r11, _, _, _, r22 = cf:GetComponents()
    if x ~= x or y ~= y or z ~= z then return false end
    if r00 ~= r00 or r11 ~= r11 or r22 ~= r22 then return false end
    return true
end

local function SafeUprightCF(pos)
    return CFrame.new(pos.X, pos.Y, pos.Z)
end

local function EnableStabilizer(root)
    if not root then return end
    if not StabilizerBV or StabilizerBV.Parent ~= root then
        if StabilizerBV then
            pcall(function() StabilizerBV:Destroy() end)
        end
        local bv = Instance.new("BodyVelocity")
        bv.Name = "TineHubStabilizerBV"
        bv.MaxForce = Vector3.new(1e5, 1e5, 1e5)
        bv.Velocity = Vector3.zero
        bv.Parent = root
        StabilizerBV = bv
    else
        StabilizerBV.Velocity = Vector3.zero
    end
    pcall(function()
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end)
end

local function DisableStabilizer()
    if StabilizerBV then
        pcall(function()
            StabilizerBV:Destroy()
        end)
        StabilizerBV = nil
    end
end

local function CancelMove()
    if ActiveTween then
        pcall(function()
            ActiveTween:Cancel()
        end)
        ActiveTween = nil
    end
end

local function MoveTo(targetCF, cancelCheck)
    local _, _, root = GetCharacter()
    if not root then return false end

    local cleanCF = SafeUprightCF(targetCF.Position)
    if not IsValidCFrame(cleanCF) then
        return false
    end

    EnableStabilizer(root)

    local distance = (root.Position - cleanCF.Position).Magnitude

    if distance <= 7 then
        CancelMove()
        root.CFrame = cleanCF
        return true
    end

    CancelMove()

    local duration = distance / math.max(Config.TweenSpeed, 1)
    local tween = TweenService:Create(
        root,
        TweenInfo.new(duration, Enum.EasingStyle.Linear),
        {CFrame = cleanCF}
    )

    ActiveTween = tween
    tween:Play()

    while tween.PlaybackState == Enum.PlaybackState.Playing do
        if not Alive or not Running then
            CancelMove()
            return false
        end

        local _, _, currentRoot = GetCharacter()
        if currentRoot ~= root then
            CancelMove()
            return false
        end

        EnableStabilizer(root)

        if (root.Position - cleanCF.Position).Magnitude <= 7 then
            CancelMove()
            root.CFrame = cleanCF
            return true
        end

        if cancelCheck and cancelCheck() then
            CancelMove()
            return false
        end

        task.wait(0.04)
    end

    local completed = (tween.PlaybackState == Enum.PlaybackState.Completed)
        or ((root.Position - cleanCF.Position).Magnitude <= 12)

    if ActiveTween == tween then
        ActiveTween = nil
    end

    return completed
end

-- ================= FIRST SEA QUEST DATABASE (1-700) =================

local FISHMAN_FROM = CFrame.new(3865, 7, -1926)
local FISHMAN_TO   = Vector3.new(61164, 12, 1820)

local SKY_FROM     = CFrame.new(-4608, 873, -1668)
local SKY_TO       = Vector3.new(-7895, 5547, -380)

local SKY2_FROM    = CFrame.new(-7895, 5547, -380)
local SKY2_TO      = Vector3.new(-7895, 5547, -380)

-- Format: {MinLv, MaxLv, MobName, QuestName, QuestLv, QuestNPCCF, FallbackMobCF, EntranceFrom, EntranceTo, ExpectedCount}
local Stages = {
    {1, 9, "Bandit", "BanditQuest1", 1,
        CFrame.new(1059, 16, 1550),
        CFrame.new(1046, 27, 1561), nil, nil, 5},

    {10, 14, "Monkey", "JungleQuest", 1,
        CFrame.new(-1598, 36, 153),
        CFrame.new(-1448, 68, 11), nil, nil, 6},

    {15, 29, "Gorilla", "JungleQuest", 2,
        CFrame.new(-1598, 36, 153),
        CFrame.new(-1130, 40, -525), nil, nil, 8},

    {30, 39, "Pirate", "BuggyQuest1", 1,
        CFrame.new(-1140, 5, 3827),
        CFrame.new(-1104, 14, 3896), nil, nil, 8},

    {40, 59, "Brute", "BuggyQuest1", 2,
        CFrame.new(-1140, 5, 3827),
        CFrame.new(-1140, 15, 4323), nil, nil, 8},

    {60, 74, "Desert Bandit", "DesertQuest", 1,
        CFrame.new(897, 6, 4390),
        CFrame.new(985, 16, 4418), nil, nil, 8},

    {75, 89, "Desert Officer", "DesertQuest", 2,
        CFrame.new(897, 6, 4390),
        CFrame.new(1547, 14, 4382), nil, nil, 6},

    {90, 99, "Snow Bandit", "SnowQuest", 1,
        CFrame.new(1387, 87, -1298),
        CFrame.new(1356, 106, -1328), nil, nil, 7},

    {100, 119, "Snowman", "SnowQuest", 2,
        CFrame.new(1387, 87, -1298),
        CFrame.new(1219, 138, -1488), nil, nil, 8},

    {120, 149, "Chief Petty Officer", "MarineQuest2", 1,
        CFrame.new(-5035, 29, 4324),
        CFrame.new(-4931, 66, 4122), nil, nil, 8},

    {150, 174, "Sky Bandit", "SkyQuest", 1,
        CFrame.new(-4842, 718, -2623),
        CFrame.new(-4956, 365, -2908), nil, nil, 7},

    {175, 189, "Dark Master", "SkyQuest", 2,
        CFrame.new(-4842, 718, -2623),
        CFrame.new(-5148, 439, -2333), nil, nil, 8},

    {190, 209, "Prisoner", "PrisonerQuest", 1,
        CFrame.new(5310, 0, 475),
        CFrame.new(5099, 0, 474), nil, nil, 8},

    {210, 249, "Dangerous Prisoner", "PrisonerQuest", 2,
        CFrame.new(5310, 0, 475),
        CFrame.new(5655, 16, 866), nil, nil, 8},

    {250, 274, "Toga Warrior", "ColosseumQuest", 1,
        CFrame.new(-1580, 6, -2986),
        CFrame.new(-1820, 52, -2741), nil, nil, 7},

    {275, 299, "Gladiator", "ColosseumQuest", 2,
        CFrame.new(-1580, 6, -2986),
        CFrame.new(-1293, 56, -3339), nil, nil, 8},

    {300, 324, "Military Soldier", "MagmaQuest", 1,
        CFrame.new(-5313, 11, 8515),
        CFrame.new(-5411, 11, 8454), nil, nil, 7},

    {325, 374, "Military Spy", "MagmaQuest", 2,
        CFrame.new(-5313, 11, 8515),
        CFrame.new(-5803, 86, 8829), nil, nil, 8},

    {375, 399, "Fishman Warrior", "FishmanQuest", 1,
        CFrame.new(61123, 19, 1568),
        CFrame.new(60844, 98, 1298),
        FISHMAN_FROM, FISHMAN_TO, 8},

    {400, 449, "Fishman Commando", "FishmanQuest", 2,
        CFrame.new(61123, 19, 1568),
        CFrame.new(61738, 64, 1434),
        FISHMAN_FROM, FISHMAN_TO, 7},

    {450, 474, "God's Guard", "SkyExp1Quest", 1,
        CFrame.new(-4722, 845, -1950),
        CFrame.new(-4628, 867, -1931), nil, nil, 7},

    {475, 524, "Shanda", "SkyExp1Quest", 2,
        CFrame.new(-7859, 5544, -381),
        CFrame.new(-7678, 5566, -497),
        SKY_FROM, SKY_TO, 9},

    {525, 549, "Royal Squad", "SkyExp2Quest", 1,
        CFrame.new(-7907, 5635, -1412),
        CFrame.new(-7624, 5658, -1467),
        SKY2_FROM, SKY2_TO, 8},

    {550, 624, "Royal Soldier", "SkyExp2Quest", 2,
        CFrame.new(-7907, 5635, -1412),
        CFrame.new(-7837, 5638, -1795),
        SKY2_FROM, SKY2_TO, 8},

    {625, 649, "Galley Pirate", "FountainQuest", 1,
        CFrame.new(5258, 39, 4050),
        CFrame.new(5557, 152, 3999), nil, nil, 8},

    {650, 699, "Galley Captain", "FountainQuest", 2,
        CFrame.new(5258, 39, 4050),
        CFrame.new(5678, 93, 4967), nil, nil, 9}
}

local function GetStageForLevel(level)
    for _, stage in ipairs(Stages) do
        if level >= stage[1] and level <= stage[2] then
            return stage
        end
    end
end

-- ================= AUTO STATS (MELEE ONLY) =================

local CommF

local function ProcessAutoStats()
    if not Config.AutoStatsMelee then return end
    if os.clock() < NextStatAt then return end
    NextStatAt = os.clock() + Config.StatInterval

    local data = LP:FindFirstChild("Data")
    if not data then return end

    local pointsObj = data:FindFirstChild("Points")
    local statsFolder = data:FindFirstChild("Stats")
    local meleeStat = statsFolder and statsFolder:FindFirstChild("Melee")
    local meleeLevel = meleeStat and meleeStat:FindFirstChild("Level")

    local availablePoints = pointsObj and pointsObj.Value or 0
    local currentMeleeLv = meleeLevel and meleeLevel.Value or 0

    if meleeLevel then
        StatsLabel.Text = string.format("Melee Stat: Lv %d | Pts: %d", currentMeleeLv, availablePoints)
    else
        StatsLabel.Text = string.format("Auto Stats: Melee Only (Pts: %d)", availablePoints)
    end

    if availablePoints > 0 and currentMeleeLv < 2550 then
        task.spawn(function()
            pcall(function()
                CommF:InvokeServer("AddPoint", Config.AutoStatsTarget, availablePoints)
            end)
        end)
    end
end

-- ================= NPC DETECTION & BRING MOB =================

local function NameMatches(instanceName, mobName)
    if not instanceName or not mobName then return false end
    return instanceName == mobName
        or string.sub(instanceName, 1, #mobName + 2) == mobName .. " ["
        or string.find(string.lower(instanceName), string.lower(mobName), 1, true) ~= nil
end

local function FindNearestMob(mobName, root)
    local enemies = workspace:FindFirstChild("Enemies")
    if not enemies or not root then return nil end

    local nearest = nil
    local shortest = math.huge

    for _, mob in ipairs(enemies:GetChildren()) do
        local mobHum = mob:FindFirstChildOfClass("Humanoid")
        local mobRoot = mob:FindFirstChild("HumanoidRootPart")

        if mobHum and mobRoot and mobHum.Health > 0 and NameMatches(mob.Name, mobName) then
            local distance = (root.Position - mobRoot.Position).Magnitude
            if distance < shortest then
                shortest = distance
                nearest = mob
            end
        end
    end

    return nearest
end

local function BringNearbyMobs(mobName, targetPos)
    if not Config.BringMob or not targetPos then return end

    local enemies = workspace:FindFirstChild("Enemies")
    if not enemies then return end

    for _, mob in ipairs(enemies:GetChildren()) do
        local mobHum = mob:FindFirstChildOfClass("Humanoid")
        local mobRoot = mob:FindFirstChild("HumanoidRootPart")

        if mobHum and mobRoot and mobHum.Health > 0 and NameMatches(mob.Name, mobName) then
            local dist = (mobRoot.Position - targetPos).Magnitude
            if dist <= Config.BringMobRadius then
                pcall(function()
                    if dist > 3 then
                        mobRoot.CFrame = SafeUprightCF(targetPos)
                    end
                    mobRoot.CanCollide = false
                    mobRoot.AssemblyLinearVelocity = Vector3.zero
                    mobHum.WalkSpeed = 0
                    mobHum.JumpPower = 0
                end)
            end
        end
    end
end

local function GetSpawnNodes(stage)
    local nodes = {}
    local origin = workspace:FindFirstChild("_WorldOrigin")
    local spawns = origin and origin:FindFirstChild("EnemySpawns")

    if spawns then
        for _, sp in ipairs(spawns:GetChildren()) do
            if NameMatches(sp.Name, stage[3]) then
                local part = sp:IsA("BasePart") and sp
                    or sp:FindFirstChildWhichIsA("BasePart", true)
                if part then
                    table.insert(nodes, SafeUprightCF(part.Position + Vector3.new(0, Config.HoverHeight + 5, 0)))
                end
            end
        end
    end

    table.insert(nodes, SafeUprightCF(stage[7].Position + Vector3.new(0, Config.HoverHeight + 5, 0)))
    return nodes
end

-- ================= MULTI-SCREENGUI QUEST DETECTOR =================

-- Checks if a GuiObject and all its GuiObject ancestors up to ScreenGui are visible
local function IsGuiHierarchyVisible(guiObj)
    local curr = guiObj
    while curr and curr ~= LP do
        if curr:IsA("GuiObject") and not curr.Visible then
            return false
        end
        if curr:IsA("LayerCollector") and not curr.Enabled then
            return false
        end
        curr = curr.Parent
    end
    return true
end

-- Scans ALL ScreenGuis in PlayerGui (`Main`, `Main (minimal)`, etc.) for an active Quest frame
local function FindActiveQuestFrame()
    local playerGui = LP:FindFirstChild("PlayerGui")
    if not playerGui then return nil end

    -- Priority 1: Check all ScreenGuis named "Main" or "Main (minimal)"
    for _, child in ipairs(playerGui:GetChildren()) do
        if child:IsA("ScreenGui") and child.Name ~= "TineHub_AutoFarm" and child.Enabled then
            local q = child:FindFirstChild("Quest") or child:FindFirstChild("Quest", true)
            if q and q:IsA("GuiObject") and IsGuiHierarchyVisible(q) then
                return q
            end
        end
    end

    return nil
end

-- Reads quest visibility and extracts (currentKills, requiredKills) across any UI variant
local function ReadQuestProgress(stage)
    local defaultReq = (stage and stage[10]) or 8
    local questFrame = FindActiveQuestFrame()

    if not questFrame then
        return false, "", LocalKillCount, defaultReq
    end

    local candidateTexts = {}
    local container = questFrame:FindFirstChild("Container")
    local questTitle = container and container:FindFirstChild("QuestTitle")
    local titleLabel = questTitle and questTitle:FindFirstChild("Title")

    if titleLabel and titleLabel:IsA("TextLabel") then
        pcall(function()
            if titleLabel.ContentText and titleLabel.ContentText ~= "" then
                table.insert(candidateTexts, titleLabel.ContentText)
            end
        end)
        if titleLabel.Text and titleLabel.Text ~= "" then
            table.insert(candidateTexts, titleLabel.Text)
        end
    end

    for _, desc in ipairs(questFrame:GetDescendants()) do
        if desc:IsA("TextLabel") and desc.Visible then
            local txt = desc.Text or ""
            local lower = string.lower(txt)
            if txt ~= ""
                and not string.find(lower, "reward", 1, true)
                and not string.find(lower, "exp", 1, true)
                and not string.find(lower, "beli", 1, true)
                and not string.find(lower, "$", 1, true) then
                table.insert(candidateTexts, txt)
            end
        end
    end

    local cur = nil
    local req = nil

    -- 1. Look for fraction "X/Y" (e.g. "(0/8)" or "4/8")
    for _, txt in ipairs(candidateTexts) do
        local c1, r1 = string.match(txt, "(%d+)%s*/%s*(%d+)")
        if c1 and r1 and tonumber(r1) and tonumber(r1) > 0 then
            cur = tonumber(c1) or 0
            req = tonumber(r1)
            break
        end
    end

    -- 2. Look for single target count (e.g. "Defeat 8 Bandits" / "Kalahkan 8 Bandit")
    if not req then
        for _, txt in ipairs(candidateTexts) do
            local n = string.match(txt, "(%d+)")
            if n and tonumber(n) and tonumber(n) > 0 and tonumber(n) <= 20 then
                req = tonumber(n)
                break
            end
        end
    end

    local finalCur = cur or LocalKillCount
    local finalReq = req or defaultReq

    return true, (candidateTexts[1] or ""), finalCur, finalReq
end

local function ResetQuestFSM()
    QuestState = "IDLE"
    LockedStage = nil
    CurrentMob = nil
    QuestCurrentCount = 0
    QuestRequiredCount = 0
    LocalKillCount = 0
    UIWasConfirmedVisible = false
    CountedDeadMobs = {}
    QuestVerifyDeadline = 0
    QuestCompletionStartedAt = 0
    SetProgressText("None (0/0)")
end

-- ================= BACKGROUND SERVICES & KILL TRACKER =================

local function StartBackgroundServices()
    if not NoclipConn then
        NoclipConn = RunService.Stepped:Connect(function()
            if not Running or not Alive then return end
            local char = LP.Character
            if not char then return end
            local hum = char:FindFirstChildOfClass("Humanoid")
            if hum then
                pcall(function()
                    hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
                    hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
                end)
            end
            for _, part in ipairs(char:GetDescendants()) do
                if part:IsA("BasePart") and part.CanCollide then
                    part.CanCollide = false
                end
            end
        end)
    end

    if not SimRadiusConn then
        SimRadiusConn = RunService.Heartbeat:Connect(function()
            if not Running or not Alive then return end
            pcall(function()
                if typeof(sethiddenproperty) == "function" then
                    sethiddenproperty(LP, "SimulationRadius", math.huge)
                end
            end)
        end)
    end

    -- Authoritative NPC Death Tracker: counts killed target NPCs near the player during FARMING
    if not DeathMonitorConn then
        DeathMonitorConn = RunService.Heartbeat:Connect(function()
            if not Running or not Alive or QuestState ~= "FARMING" or not LockedStage then
                return
            end
            local _, _, root = GetCharacter()
            local enemies = workspace:FindFirstChild("Enemies")
            if not root or not enemies then return end

            for _, mob in ipairs(enemies:GetChildren()) do
                if not CountedDeadMobs[mob] and NameMatches(mob.Name, LockedStage[3]) then
                    local mh = mob:FindFirstChildOfClass("Humanoid")
                    local mr = mob:FindFirstChild("HumanoidRootPart")
                    if mh and mr and mh.Health <= 0 then
                        if (root.Position - mr.Position).Magnitude <= 85 then
                            CountedDeadMobs[mob] = true
                            LocalKillCount += 1
                        end
                    end
                end
            end
        end)
    end
end

local function StopBackgroundServices()
    if NoclipConn then
        NoclipConn:Disconnect()
        NoclipConn = nil
    end
    if SimRadiusConn then
        SimRadiusConn:Disconnect()
        SimRadiusConn = nil
    end
    if DeathMonitorConn then
        DeathMonitorConn:Disconnect()
        DeathMonitorConn = nil
    end
end

-- ================= WEAPON & FAST ATTACK ENGINE =================

local NetRegisterAttack = nil
local NetRegisterHit = nil

pcall(function()
    local modules = RS:FindFirstChild("Modules")
    local net = modules and modules:FindFirstChild("Net")
    if net then
        NetRegisterAttack = net:FindFirstChild("RE/RegisterAttack")
        NetRegisterHit = net:FindFirstChild("RE/RegisterHit")
    end
end)

local function EquipWeapon(char, hum)
    if not char or not hum then return nil end

    for _, tool in ipairs(char:GetChildren()) do
        if tool:IsA("Tool") and tool.ToolTip == Config.WeaponType then
            return tool
        end
    end

    local backpack = LP:FindFirstChild("Backpack")
    if backpack then
        for _, tool in ipairs(backpack:GetChildren()) do
            if tool:IsA("Tool") and tool.ToolTip == Config.WeaponType then
                pcall(function()
                    hum:EquipTool(tool)
                end)
                return tool
            end
        end
    end
    return nil
end

local function EnableHaki(char)
    if not Config.AutoHaki or not char then return end
    if char:FindFirstChild("HasBuso") or char:GetAttribute("HasBuso") then
        return
    end

    if os.clock() < NextHakiAt then
        return
    end
    NextHakiAt = os.clock() + Config.HakiInterval

    task.spawn(function()
        pcall(function()
            CommF:InvokeServer("Buso")
        end)
    end)
end

local function GetBladeHits(root, maxRadius)
    local targets = {}
    local enemies = workspace:FindFirstChild("Enemies")
    if not enemies or not root then return targets end

    for _, mob in ipairs(enemies:GetChildren()) do
        local mobHum = mob:FindFirstChildOfClass("Humanoid")
        local mobRoot = mob:FindFirstChild("HumanoidRootPart")
        local head = mob:FindFirstChild("Head") or mobRoot

        if mobHum and mobRoot and mobHum.Health > 0 then
            if (root.Position - mobRoot.Position).Magnitude <= (maxRadius or 60) then
                table.insert(targets, {mob, head})
            end
        end
    end

    return targets
end

local function FireAttackOnce(char, root, weapon)
    if weapon and weapon.Parent == char then
        pcall(function()
            weapon:Activate()
        end)
    end

    if Config.FastAttack and NetRegisterAttack and NetRegisterHit then
        pcall(function()
            local hits = GetBladeHits(root, 65)
            if #hits > 0 then
                NetRegisterAttack:FireServer(0)
                NetRegisterHit:FireServer(hits[1][2], hits)
            end
        end)
    end

    if Config.FastAttack and typeof(getupvalues) == "function" then
        pcall(function()
            local ps = LP:FindFirstChild("PlayerScripts")
            local cfScript = ps and ps:FindFirstChild("CombatFramework")
            if cfScript then
                local upvals = getupvalues(require(cfScript))
                local activeController = upvals and upvals[2] and upvals[2].activeController
                if activeController and activeController.blades and #activeController.blades > 0 then
                    activeController.timeToNextAttack = 0
                    activeController.hitboxMagnitude = 60
                    if typeof(activeController.attack) == "function" then
                        activeController:attack()
                    end
                end
            end
        end)
    end

    pcall(function()
        VU:CaptureController()
        VU:Button1Down(Vector2.new(1280, 672))
        VU:Button1Up(Vector2.new(1280, 672))
    end)
end

-- ================= ISLAND ENTRANCE & TRAVEL =================

local function EnsureIsland(stage)
    local entranceFrom = stage[8]
    local entranceTo   = stage[9]

    if not entranceFrom or not entranceTo then
        return true
    end

    local _, _, root = GetCharacter()
    if not root then return false end

    if (root.Position - stage[6].Position).Magnitude < 2800 then
        return true
    end

    SetStatus("Requesting island entrance...")
    pcall(function()
        CommF:InvokeServer("requestEntrance", entranceTo)
    end)
    task.wait(0.8)

    local _, _, afterRoot = GetCharacter()
    if afterRoot and (afterRoot.Position - stage[6].Position).Magnitude < 2800 then
        return true
    end

    SetStatus("Moving to island portal...")
    if not MoveTo(entranceFrom) then
        return false
    end

    local _, _, newRoot = GetCharacter()
    if not newRoot then return false end

    if (newRoot.Position - entranceFrom.Position).Magnitude < 80 then
        pcall(function()
            CommF:InvokeServer("requestEntrance", entranceTo)
        end)
        task.wait(1.2)
    end

    return (newRoot.Position - stage[6].Position).Magnitude < 2800
end

-- ================= MOB FARMING EXECUTION =================

local function FarmStageMobs(stage, level, char, hum, root)
    EnableHaki(char)
    local weapon = EquipWeapon(char, hum)

    local mob = CurrentMob
    if mob and mob.Parent then
        local mh = mob:FindFirstChildOfClass("Humanoid")
        local mr = mob:FindFirstChild("HumanoidRootPart")
        if not mh or not mr or mh.Health <= 0 or not NameMatches(mob.Name, stage[3]) then
            mob = nil
        end
    else
        mob = nil
    end

    if not mob then
        mob = FindNearestMob(stage[3], root)
        CurrentMob = mob
    end

    if not mob then
        CurrentMob = nil
        SetStatus(string.format("Finding %s (%d/%d)", stage[3], QuestCurrentCount, QuestRequiredCount))

        local nodes = GetSpawnNodes(stage)
        if os.clock() - LastSpawnPatrolAt > 2.2 then
            SpawnPatrolIndex = (SpawnPatrolIndex % #nodes) + 1
            LastSpawnPatrolAt = os.clock()
        end

        local targetNode = nodes[SpawnPatrolIndex] or nodes[1]
        MoveTo(targetNode, function()
            local _, _, r = GetCharacter()
            return not Running or not Alive or (r and FindNearestMob(stage[3], r) ~= nil)
        end)
        return
    end

    local mobRoot = mob:FindFirstChild("HumanoidRootPart")
    local mobHum = mob:FindFirstChildOfClass("Humanoid")
    if not mobRoot or not mobHum then
        CurrentMob = nil
        return
    end

    local mobPos = mobRoot.Position
    local hoverPos = Vector3.new(mobPos.X, mobPos.Y + Config.HoverHeight, mobPos.Z)
    local hoverCF = SafeUprightCF(hoverPos)

    local distToHover = (root.Position - hoverPos).Magnitude

    if distToHover > 22 then
        SetStatus(string.format("Moving to %s (%d/%d)", stage[3], QuestCurrentCount, QuestRequiredCount))
        MoveTo(hoverCF, function()
            if not Running or not Alive then return true end
            if not mob.Parent or mobHum.Health <= 0 then return true end
            local _, _, r = GetCharacter()
            if r and (r.Position - mobRoot.Position).Magnitude <= 18 then
                return true
            end
            return false
        end)
    end

    char, hum, root = GetCharacter()
    if not root or not mob.Parent or mobHum.Health <= 0 then
        CurrentMob = nil
        return
    end

    CancelMove()
    EnableStabilizer(root)

    local latestMobPos = mobRoot.Position
    local lockCF = SafeUprightCF(Vector3.new(latestMobPos.X, latestMobPos.Y + Config.HoverHeight, latestMobPos.Z))
    if IsValidCFrame(lockCF) then
        root.CFrame = lockCF
    end

    BringNearbyMobs(stage[3], latestMobPos)
    weapon = EquipWeapon(char, hum)
    FireAttackOnce(char, root, weapon)

    if weapon then
        SetStatus(string.format("Lv %d | Farming %s (%d/%d)", level, stage[3], QuestCurrentCount, QuestRequiredCount))
    else
        SetStatus("Equip " .. Config.WeaponType .. " weapon!")
    end
end

-- ================= MAIN QUEST FSM STEP =================

local function Step()
    local level = LP.Data.Level.Value
    LevelLabel.Text = "Level: " .. level .. " / 700"

    -- Always allocate stat points strictly to Melee
    ProcessAutoStats()

    if level >= 700 then
        SetStatus("Level 700 reached! First Sea Completed.")
        CancelMove()
        DisableStabilizer()
        Running = false
        return
    end

    local char, hum, root = GetCharacter()
    if not root then
        DisableStabilizer()
        SetStatus("Waiting character spawn...")
        return
    end

    local questVisible, _, curKills, reqKills = ReadQuestProgress(LockedStage)

    -- =========================================================================
    -- STATE 1: IDLE (Select Stage & Adopt or Start Quest)
    -- =========================================================================
    if QuestState == "IDLE" then
        local desiredStage = GetStageForLevel(level)
        if not desiredStage then
            SetStatus("No stage found for Lv " .. level)
            return
        end

        LockedStage = desiredStage
        LocalKillCount = 0
        CountedDeadMobs = {}
        QuestCurrentCount = curKills or 0
        QuestRequiredCount = reqKills or desiredStage[10] or 8
        TargetLabel.Text = "Target: " .. LockedStage[3]

        if questVisible then
            UIWasConfirmedVisible = true
            SetProgressText(string.format("%s (%d/%d)", LockedStage[3], QuestCurrentCount, QuestRequiredCount))
            QuestState = "FARMING"
            return
        end

        UIWasConfirmedVisible = false
        SetProgressText("Taking Quest...")
        QuestState = "TAKING_QUEST"
        return
    end

    if not LockedStage then
        ResetQuestFSM()
        return
    end

    TargetLabel.Text = "Target: " .. LockedStage[3]

    -- =========================================================================
    -- STATE 2: TAKING_QUEST (Move to Quest Giver, Settle, Invoke StartQuest)
    -- =========================================================================
    if QuestState == "TAKING_QUEST" then
        if questVisible then
            UIWasConfirmedVisible = true
            QuestCurrentCount = curKills or 0
            QuestRequiredCount = reqKills or LockedStage[10] or 8
            QuestState = "FARMING"
            return
        end

        if not EnsureIsland(LockedStage) then
            return
        end

        SetStatus("Lv " .. level .. " | Moving to Quest NPC: " .. LockedStage[4])
        local questNPCCF = SafeUprightCF(LockedStage[6].Position)
        local moved = MoveTo(questNPCCF)
        if not moved then
            return
        end

        char, hum, root = GetCharacter()
        if not root then return end

        if (root.Position - questNPCCF.Position).Magnitude > 10 then
            root.CFrame = questNPCCF
        end
        EnableStabilizer(root)
        task.wait(Config.QuestSettleDelay)

        SetStatus("Lv " .. level .. " | Taking Quest: " .. LockedStage[3])
        pcall(function()
            CommF:InvokeServer("StartQuest", LockedStage[4], LockedStage[5])
        end)

        LocalKillCount = 0
        CountedDeadMobs = {}
        QuestVerifyDeadline = os.clock() + Config.QuestVerifyWindow
        QuestState = "VERIFYING_QUEST"
        return
    end

    -- =========================================================================
    -- STATE 3: VERIFYING_QUEST (Check All ScreenGuis OR Transition via Hybrid Tracker)
    -- =========================================================================
    if QuestState == "VERIFYING_QUEST" then
        questVisible, _, curKills, reqKills = ReadQuestProgress(LockedStage)

        if questVisible then
            UIWasConfirmedVisible = true
            QuestCurrentCount = curKills or 0
            QuestRequiredCount = reqKills or LockedStage[10] or 8
            CurrentMob = nil

            SetProgressText(string.format("%s (%d/%d)", LockedStage[3], QuestCurrentCount, QuestRequiredCount))
            SetStatus(string.format("Quest active! Farming %d %s", QuestRequiredCount, LockedStage[3]))
            QuestState = "FARMING"
            return
        end

        -- Seamless Non-Blocking Transition:
        -- If the player's UI uses a hidden/minimal container not exposed in standard frames after 0.9s,
        -- do NOT freeze at the Quest NPC! Lock the stage's exact target count and transition to FARMING.
        if os.clock() >= QuestVerifyDeadline then
            UIWasConfirmedVisible = false
            QuestCurrentCount = 0
            QuestRequiredCount = LockedStage[10] or 8
            CurrentMob = nil

            SetProgressText(string.format("%s (0/%d)", LockedStage[3], QuestRequiredCount))
            SetStatus(string.format("Quest started! Farming %d %s", QuestRequiredCount, LockedStage[3]))
            QuestState = "FARMING"
            return
        end

        SetStatus("Activating quest...")
        return
    end

    -- =========================================================================
    -- STATE 4: FARMING (Farm Target NPCs & Track Progress Until 100% Completed)
    -- =========================================================================
    if QuestState == "FARMING" then
        questVisible, _, curKills, reqKills = ReadQuestProgress(LockedStage)

        if questVisible then
            UIWasConfirmedVisible = true
            QuestCurrentCount = math.max(curKills or 0, LocalKillCount)
            if reqKills and reqKills > 0 then
                QuestRequiredCount = reqKills
            end
        else
            -- If UI was confirmed visible earlier and now closed -> server completed the quest!
            if UIWasConfirmedVisible then
                QuestCompletionStartedAt = os.clock()
                QuestState = "VERIFYING_COMPLETION"
                SetStatus("Quest completed! Verifying...")
                return
            end

            -- Fallback Hybrid Kill Tracker mode (when UI frame is hidden/minimal)
            QuestCurrentCount = LocalKillCount
            if QuestRequiredCount <= 0 then
                QuestRequiredCount = LockedStage[10] or 8
            end

            if QuestCurrentCount >= QuestRequiredCount then
                QuestCompletionStartedAt = os.clock()
                QuestState = "VERIFYING_COMPLETION"
                SetStatus("All target NPCs defeated! Completing...")
                return
            end
        end

        SetProgressText(string.format("%s (%d/%d)", LockedStage[3], QuestCurrentCount, QuestRequiredCount))

        if not EnsureIsland(LockedStage) then
            return
        end

        char, hum, root = GetCharacter()
        if not root then return end

        FarmStageMobs(LockedStage, level, char, hum, root)
        return
    end

    -- =========================================================================
    -- STATE 5: VERIFYING_COMPLETION (Confirm Quest Completed Before Next Quest)
    -- =========================================================================
    if QuestState == "VERIFYING_COMPLETION" then
        questVisible, _, curKills, reqKills = ReadQuestProgress(LockedStage)

        if UIWasConfirmedVisible and questVisible then
            QuestCurrentCount = curKills or QuestCurrentCount
            QuestState = "FARMING"
            return
        end

        if os.clock() - QuestCompletionStartedAt < Config.QuestCompleteDelay then
            SetProgressText(string.format("Completed! (%d/%d)", QuestRequiredCount, QuestRequiredCount))
            SetStatus("Quest completed! Preparing next quest...")
            return
        end

        ResetQuestFSM()
        return
    end
end

-- ================= DEDICATED FAST ATTACK BACKGROUND THREAD =================

task.spawn(function()
    while Alive do
        local interval = Config.FastAttack and Config.AttackInterval or 0.28
        task.wait(interval)

        if Running and QuestState == "FARMING" and CurrentMob and CurrentMob.Parent then
            pcall(function()
                local char, hum, root = GetCharacter()
                local mobHum = CurrentMob:FindFirstChildOfClass("Humanoid")
                local mobRoot = CurrentMob:FindFirstChild("HumanoidRootPart")

                if char and hum and root and mobHum and mobRoot and mobHum.Health > 0 then
                    if (root.Position - mobRoot.Position).Magnitude <= 35 then
                        local weapon = EquipWeapon(char, hum)
                        FireAttackOnce(char, root, weapon)
                    end
                end
            end)
        end
    end
end)

-- ================= UI INTERACTION & DRAG =================

local function SetRunning(state)
    Running = state

    Toggle.Text = state and "STOP AUTO FARM" or "START AUTO FARM"
    Toggle.BackgroundColor3 = state
        and Color3.fromRGB(30, 150, 85)
        or Color3.fromRGB(175, 45, 50)

    if not state then
        CancelMove()
        DisableStabilizer()
        SetStatus("Stopped")
    else
        ResetQuestFSM()
        SetStatus("Restarting...")
    end
end

Toggle.MouseButton1Click:Connect(function()
    SetRunning(not Running)
end)

FastAtkBtn.MouseButton1Click:Connect(function()
    Config.FastAttack = not Config.FastAttack
    FastAtkBtn.Text = Config.FastAttack and "Fast Attack: ON" or "Fast Attack: OFF"
    FastAtkBtn.BackgroundColor3 = Config.FastAttack
        and Color3.fromRGB(25, 135, 95)
        or Color3.fromRGB(80, 85, 105)
end)

BringMobBtn.MouseButton1Click:Connect(function()
    Config.BringMob = not Config.BringMob
    BringMobBtn.Text = Config.BringMob and "Bring Mob: ON" or "Bring Mob: OFF"
    BringMobBtn.BackgroundColor3 = Config.BringMob
        and Color3.fromRGB(25, 135, 95)
        or Color3.fromRGB(80, 85, 105)
end)

local dragging = false
local dragStart
local startPosition

Header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Touch
        or input.UserInputType == Enum.UserInputType.MouseButton1 then

        dragging = true
        dragStart = input.Position
        startPosition = Main.Position

        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end
end)

UIS.InputChanged:Connect(function(input)
    if dragging and (
        input.UserInputType == Enum.UserInputType.Touch
        or input.UserInputType == Enum.UserInputType.MouseMovement
    ) then
        local delta = input.Position - dragStart
        Main.Position = UDim2.new(
            startPosition.X.Scale,
            startPosition.X.Offset + delta.X,
            startPosition.Y.Scale,
            startPosition.Y.Offset + delta.Y
        )
    end
end)

LP.Idled:Connect(function()
    pcall(function()
        VU:CaptureController()
        VU:ClickButton2(Vector2.zero)
    end)
end)

-- ================= CLEANUP =================

env.BFAutoFarmStop = function()
    Alive = false
    Running = false

    CancelMove()
    DisableStabilizer()
    StopBackgroundServices()

    if GUI then
        GUI:Destroy()
    end
end

-- ================= INITIALIZATION =================

if game.PlaceId ~= 2753915549 then
    SetStatus("First Sea only (PlaceId 2753915549)")
    warn("[TineHub] Wrong sea")
    return
end

if not LP.Character then
    LP.CharacterAdded:Wait()
end

local Remotes = RS:WaitForChild("Remotes", 30)
CommF = Remotes and Remotes:WaitForChild("CommF_", 30)

if not CommF then
    SetStatus("Remote CommF_ unavailable")
    return
end

if not LP.Team then
    pcall(function()
        CommF:InvokeServer("SetTeam", Config.Team)
    end)
end

local Data = LP:WaitForChild("Data", 30)
local LevelValue = Data and Data:WaitForChild("Level", 30)

if not LevelValue then
    SetStatus("Level data unavailable")
    return
end

StartBackgroundServices()
SetStatus("Ready")

-- ================= MAIN LOOP =================

task.spawn(function()
    while Alive do
        task.wait(0.08)

        if Running then
            local ok, err = pcall(Step)
            if not ok then
                SetStatus("Error - check console")
                warn("[TineHub] " .. tostring(err))
            end
        end
    end
end)

print("[TineHub] First Sea 1-700 Auto Farm loaded")
