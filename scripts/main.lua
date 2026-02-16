-- ============================================================
-- Archipelago Mod for The Talos Principle Reawakened
-- Main initialization and coordination
-- ============================================================

-- Load modules
local Logging = require("lib.logging")
local TetrominoUtils = require("lib.tetromino_utils")
local Visibility = require("lib.visibility")
local Progress = require("lib.progress")
local Scanner = require("lib.scanner")
local Inventory = require("lib.inventory")
local Collection = require("lib.collection")
local Config = require("lib.config")
local ItemMapping = require("lib.item_mapping")
local APClient = require("lib.ap_client")
local GoalDetection = require("lib.goal_detection")

Logging.LogInfo("==============================================")
Logging.LogInfo("Archipelago Mod Loading...")
Logging.LogInfo("==============================================")

-- ============================================================
-- Load configuration
-- ============================================================
Config.Load()

-- ============================================================
-- Shared state
-- ============================================================
local State = {
    CurrentProgress = nil,
    TrackedItems = {},
    CollectedThisSession = {},
    LevelTransitionCooldown = 0,
    LastAddedTetrominoId = nil,
    ArrangerActive = false  -- true while player is using an arranger/gate
}

-- External callback for Archipelago integration
-- Wired to APClient.SendLocationCheck below
OnLocationCheckedCallback = nil

-- ============================================================
-- Initialize Archipelago client
-- ============================================================

local apAvailable = false
if Config.offline_mode then
    Logging.LogInfo("Offline mode enabled — AP communication disabled")
    Logging.LogInfo("Items can be granted/revoked via debug keybinds (F5/F8)")
    Logging.LogInfo("Pickups will log item names and location IDs without sending to server")
    
    -- In offline mode, enforcement can start immediately
    Collection.APSynced = true
    
    -- Wire a local-only callback that logs and self-grants
    OnLocationCheckedCallback = function(tetrominoId)
        local locId = ItemMapping.GetLocationId(tetrominoId)
        Logging.LogInfo(string.format("[OFFLINE] Location check: %s (location_id=%s)", 
            tetrominoId, tostring(locId)))
        -- In offline mode, grant the item directly so the player can progress
        Collection.GrantItem(State, tetrominoId)
        Logging.LogInfo(string.format("[OFFLINE] Auto-granted: %s", tetrominoId))
    end
else
    apAvailable = APClient.Init(Config, State, Collection, ItemMapping)
    if apAvailable then
        -- Wire the location checked callback to the AP client
        OnLocationCheckedCallback = function(tetrominoId)
            APClient.SendLocationCheck(tetrominoId)
        end
        
        -- Connect (will happen asynchronously via poll)
        APClient.Connect()
        Logging.LogInfo("AP client initialized — connection will be established via poll()")
    else
        Logging.LogWarning("AP client not available — running in local-only mode")
        Logging.LogWarning("Items can still be granted/revoked via debug keybinds (F5/F8)")
    end
end

-- ============================================================
-- Initialize goal detection hooks
-- Transcendence: hooks the ending cutscene sequence event
-- Ascension: hooks BinkMediaPlayer:OpenUrl + RegisterSkippableCutsceneViewed
-- Fallback: polls TalosSaveSubsystem:IsGameCompleted()
-- ============================================================
GoalDetection.OnGoalCompleted = function(goalName)
    Logging.LogInfo(string.format("Goal completed: %s — sending to AP server", goalName))
    APClient.SendGoalComplete()
end
GoalDetection.RegisterHooks()

-- ============================================================
-- Handle tetromino physical pickup event (location checked)
-- This fires when the player walks into a tetromino in-world.
-- It does NOT mean the item is in their inventory — Archipelago
-- decides that separately via Collection.GrantItem().
-- ============================================================
local function OnTetrominoCollected(tetrominoId)
    Logging.LogInfo(string.format("*** LOCATION CHECKED: %s ***", tostring(tetrominoId)))
    
    -- Mark this location as checked so the item stays hidden
    Collection.MarkLocationChecked(tetrominoId)
    State.CollectedThisSession[tetrominoId] = true
    
    -- Clear visibility cache so the fast loop re-evaluates this item
    if VisibilityApplied then
        VisibilityApplied[tetrominoId] = nil
    end
    
    -- Delayed UI refresh: the enforce loop will remove the item from TMap
    -- but the HUD won't update until we explicitly tell it to.
    LoopAsync(2000, function()
        Collection.RefreshUI()
        return true -- run once
    end)
    
    -- Notify Archipelago client
    if OnLocationCheckedCallback then
        local ok, err = pcall(function()
            OnLocationCheckedCallback(tetrominoId)
        end)
        if not ok then
            Logging.LogError(string.format("Location callback error: %s", tostring(err)))
        end
    end
end

-- ============================================================
-- Hook player spawn - this is when we should refresh progress
-- ============================================================
RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(Context)
    Logging.LogDebug("Player spawned - refreshing progress and clearing tracked items")
    
    -- Force refresh the progress object since we may have loaded a different save
    State.CurrentProgress = nil
    Progress.FindProgressObject(State, true)
    
    State.TrackedItems = {}
    State.LevelTransitionCooldown = 50
    
    -- Clear visibility cache — actors are new after level transition
    VisibilityApplied = {}
    
    -- Log which save we're now tracking
    if State.CurrentProgress and State.CurrentProgress:IsValid() then
        local timePlayed = 0
        local level = "?"
        pcall(function() timePlayed = State.CurrentProgress.TimePlayed end)
        pcall(function() level = State.CurrentProgress.LastPlayedPersistentLevel end)
        Logging.LogInfo(string.format("Now tracking save with timePlayed=%.0f, level=%s", timePlayed, tostring(level)))
    end
    
    -- Schedule delayed enforcement + scan to ensure everything is fully loaded
    LoopAsync(2000, function()
        -- Enforce collection state before scanning so items are collectable
        Collection.EnforceCollectionState(State)
        Scanner.ScanTetrominoItems(State, OnTetrominoCollected)
        return true -- stop after one execution
    end)
end)

-- ============================================================
-- Hook save game set — fires when the game instance receives
-- a new or loaded save game object. This is the authoritative
-- moment to re-acquire the progress object.
-- ============================================================
RegisterHook("/Script/Talos.TalosGameInstance:SetTalosSaveGameInstance", function(Context)
    Logging.LogInfo("Save game instance set on TalosGameInstance — refreshing progress")
    -- Pause loops during save game transition
    State.LevelTransitionCooldown = 50
    VisibilityApplied = {}
    GoalDetection.ResetGoalState()
    -- Delay slightly to let the engine finish wiring up
    LoopAsync(200, function()
        State.CurrentProgress = nil
        Progress.FindProgressObject(State, true)
        State.TrackedItems = {}
        State.CollectedThisSession = {}

        if State.CurrentProgress then
            Logging.LogInfo("=== SAVE FILE DUMP (on save game set) ===")
            Progress.DumpSaveFileContents(State)
        end
        return true
    end)
end)

-- ============================================================
-- Hook save game reload (Continue / Load from menu)
-- ============================================================
RegisterHook("/Script/Talos.TalosGameInstance:ReloadSaveGame", function(Context)
    Logging.LogInfo("ReloadSaveGame called — will re-acquire progress on player spawn")
    State.CurrentProgress = nil
    State.TrackedItems = {}
    State.LevelTransitionCooldown = 50
    VisibilityApplied = {}
    GoalDetection.ResetGoalState()
end)

-- ============================================================
-- Arranger (puzzle gate) detection — polling approach
-- Uses AArranger::bIsEditingPuzzle (bool at 0x0598) which is true
-- while the player is actively using the arranger's puzzle grid.
-- Previous approach using InteractingCharacter (TWeakObjectPtr) was
-- unreliable — :Get() returned stale non-nil values, permanently
-- blocking enforcement. bIsEditingPuzzle is a simple bool that
-- reads cleanly.
-- ============================================================
local previousArrangerActive = false

local function IsAnyArrangerActive()
    local ok, result = pcall(function()
        local arrangers = FindAllOf("Arranger")
        if not arrangers then return false end
        for _, arranger in ipairs(arrangers) do
            local editOk, editing = pcall(function()
                return arranger.bIsEditingPuzzle
            end)
            if editOk and editing then
                return true
            end
        end
        return false
    end)
    -- If the entire check errors, default to false (don't block enforcement)
    if not ok then return false end
    return result
end

-- ============================================================
-- Periodic polling loop — scan every 100ms for detection and tracking
-- Also enforces collection state (removes non-granted items from
-- CollectedTetrominos so they remain collectable).
-- ============================================================
local LoopCount = 0
local AP_SYNC_TIMEOUT = 300  -- 30 seconds (300 * 100ms) before enabling enforcement anyway

LoopAsync(100, function()
    LoopCount = LoopCount + 1

    -- Poll the Archipelago client (handles network I/O)
    APClient.Poll()

    -- AP sync timeout: if AP hasn't synced after 30s, enable enforcement
    -- using whatever grants we have (from disk cache or empty)
    if not Collection.APSynced and LoopCount >= AP_SYNC_TIMEOUT then
        local grantCount = 0
        for _ in pairs(Collection.GrantedItems) do grantCount = grantCount + 1 end
        Logging.LogWarning(string.format(
            "AP sync timeout (%ds) — enabling enforcement with %d cached grants",
            AP_SYNC_TIMEOUT / 10, grantCount))
        Collection.APSynced = true
    end

    -- Log AP connection status every 5 seconds until synced
    if not Collection.APSynced and LoopCount % 50 == 0 then
        Logging.LogInfo(string.format("AP status: %s (synced=%s, tick=%d/%d)",
            APClient.GetStatusString(), tostring(Collection.APSynced), LoopCount, AP_SYNC_TIMEOUT))
    end

    -- Decrement level transition cooldown — skip enforcement while
    -- the world is (un)loading actors to avoid null dereferences.
    if State.LevelTransitionCooldown > 0 then
        State.LevelTransitionCooldown = State.LevelTransitionCooldown - 1
        if State.LevelTransitionCooldown == 0 then
            Logging.LogInfo("Level transition cooldown expired — resuming enforcement")
        end
        return false
    end

    local ok, err = pcall(function()
        if not State.CurrentProgress or not State.CurrentProgress:IsValid() then
            Progress.FindProgressObject(State)
        end

        if State.CurrentProgress and State.CurrentProgress:IsValid() then
            -- Poll arranger state — skip TMap manipulation while any arranger is in use
            State.ArrangerActive = IsAnyArrangerActive()
            if State.ArrangerActive ~= previousArrangerActive then
                Logging.LogInfo(string.format("Arranger state changed: %s", tostring(State.ArrangerActive)))
                previousArrangerActive = State.ArrangerActive
            end
            if not State.ArrangerActive then
                -- Enforce: keep CollectedTetrominos in sync with Archipelago grants
                Collection.EnforceCollectionState(State)
            end
            
            -- Scan for pickup events
            Scanner.ScanTetrominoItems(State, OnTetrominoCollected)
            
            -- Goal detection (both endings are hook-driven, this is a no-op keep-alive)
            GoalDetection.CheckGoals(State)
        end
    end)

    if not ok then
        Logging.LogError(string.format("Loop error: %s", tostring(err)))
    end

    return false
end)

-- ============================================================
-- Fast visibility loop — every 5ms manage item visibility
-- Items that should be collectable: force visible + collision
-- Also temporarily removes them from TMap so the game's
-- IsTetrominoCollected check returns false, allowing pickup.
-- The enforce loop (100ms) re-adds granted items to TMap, so
-- they remain usable in arrangers most of the time.
--
-- IMPORTANT: We track which items have already been set to their
-- target state to avoid re-applying visibility every tick.
-- Constantly toggling rendering properties causes DLSS temporal
-- accumulation to corrupt, producing flickering artifacts
-- (especially visible during rain/particle effects).
-- ============================================================
local VisibilityApplied = {}  -- id -> "visible" | "hidden"

LoopAsync(5, function()
    -- Skip during level transitions to avoid accessing destroyed actors
    if State.LevelTransitionCooldown > 0 then
        return false
    end

    -- Skip TMap manipulation while arranger is active
    if State.ArrangerActive then
        return false
    end

    local ok, err = pcall(function()
        local items = FindAllOf("BP_TetrominoItem_C")
        if items then
            for _, item in ipairs(items) do
                if item and item:IsValid() then
                    local id = TetrominoUtils.GetTetrominoId(item)
                    if id then
                        if Collection.ShouldBeCollectable(id) then
                            -- Remove from TMap so IsTetrominoCollected returns false
                            -- This allows OnBeginOverlap to proceed with pickup
                            if State.CurrentProgress and State.CurrentProgress:IsValid() then
                                pcall(function()
                                    State.CurrentProgress.CollectedTetrominos:Remove(id)
                                end)
                            end
                            -- Only touch rendering state once
                            if VisibilityApplied[id] ~= "visible" then
                                Visibility.SetTetrominoVisible(item)
                                VisibilityApplied[id] = "visible"
                            end
                        elseif Collection.IsLocationChecked(id) and not Collection.IsGranted(id) then
                            -- Location was checked but item wasn't granted to us
                            -- (AP sent it to another player). Hide the actor so
                            -- it doesn't reappear, but do NOT add to TMap.
                            if VisibilityApplied[id] ~= "hidden" then
                                Visibility.SetTetrominoHidden(item)
                                VisibilityApplied[id] = "hidden"
                            end
                        end
                    end
                end
            end
        end
    end)

    if not ok then
        Logging.LogError(string.format("Visibility loop error: %s", tostring(err)))
    end

    return false
end)

-- ============================================================
-- Rain suppression loop — disable weather particles if configured
-- The UDW (Ultra Dynamic Weather) rain system uses Niagara particles
-- that can cause visual flickering with DLSS temporal accumulation.
-- ============================================================
if Config.disable_rain then
    Logging.LogInfo("Rain suppression enabled — weather particles will be disabled")
    local rainSuppressCount = 0
    LoopAsync(1000, function()
        rainSuppressCount = rainSuppressCount + 1
        local rainFound, snowFound = 0, 0

        -- Suppress rain
        pcall(function()
            local rainActors = FindAllOf("UDW_Rain_C")
            if rainActors then
                rainFound = #rainActors
                for _, rain in ipairs(rainActors) do
                    if rain and rain:IsValid() then
                        local ok1, e1 = pcall(function() rain:SetActorHiddenInGame(true) end)
                        local ok2, e2 = pcall(function() rain:SetActorTickEnabled(false) end)
                        local ok3, e3 = pcall(function() rain.RainSpawnRate = 0 end)
                        local ok4, e4 = pcall(function() rain["Splash Frequency"] = 0 end)
                        local ok5, e5 = pcall(function() rain["Enable Fog Particles"] = false end)
                        local ok6, e6 = pcall(function() rain["Fog Particles Active"] = false end)
                        local ok7, e7 = pcall(function()
                            if rain["Rain Particles"] and rain["Rain Particles"]:IsValid() then
                                rain["Rain Particles"]:Deactivate()
                                rain["Rain Particles"]:SetVisibility(false, true)
                            end
                        end)
                        -- Log failures on first tick
                        if rainSuppressCount <= 2 then
                            Logging.LogInfo(string.format(
                                "Rain suppress results: Hidden=%s(%s) Tick=%s(%s) Spawn=%s(%s) Splash=%s(%s) Fog=%s(%s) FogAct=%s(%s) Niagara=%s(%s)",
                                tostring(ok1), tostring(e1), tostring(ok2), tostring(e2),
                                tostring(ok3), tostring(e3), tostring(ok4), tostring(e4),
                                tostring(ok5), tostring(e5), tostring(ok6), tostring(e6),
                                tostring(ok7), tostring(e7)))
                            -- Also verify if properties actually changed
                            pcall(function()
                                Logging.LogInfo(string.format(
                                    "Rain verify: bHidden=%s RainSpawnRate=%s SplashFreq=%s EnableFog=%s FogActive=%s",
                                    tostring(rain.bHidden),
                                    tostring(rain.RainSpawnRate),
                                    tostring(rain["Splash Frequency"]),
                                    tostring(rain["Enable Fog Particles"]),
                                    tostring(rain["Fog Particles Active"])))
                            end)
                            pcall(function()
                                local rp = rain["Rain Particles"]
                                if rp and rp:IsValid() then
                                    Logging.LogInfo(string.format(
                                        "Rain Niagara: IsActive=%s bVisible=%s",
                                        tostring(rp:IsActive()), tostring(rp:IsVisible())))
                                else
                                    Logging.LogInfo("Rain Niagara: component nil or invalid")
                                end
                            end)
                        end
                    end
                end
            end
        end)

        -- Suppress snow
        pcall(function()
            local snowActors = FindAllOf("UDW_Snow_C")
            if snowActors then
                snowFound = #snowActors
                for _, snow in ipairs(snowActors) do
                    if snow and snow:IsValid() then
                        pcall(function() snow:SetActorHiddenInGame(true) end)
                        pcall(function() snow:SetActorTickEnabled(false) end)
                        pcall(function() snow.RainSpawnRate = 0 end)
                        pcall(function() snow["Splash Frequency"] = 0 end)
                        pcall(function() snow["Enable Fog Particles"] = false end)
                        pcall(function() snow["Fog Particles Active"] = false end)
                        pcall(function()
                            if snow["Rain Particles"] and snow["Rain Particles"]:IsValid() then
                                snow["Rain Particles"]:Deactivate()
                                snow["Rain Particles"]:SetVisibility(false, true)
                            end
                        end)
                    end
                end
            end
        end)

        -- Log diagnostics periodically (every 30s)
        if rainSuppressCount % 30 == 1 then
            Logging.LogDebug(string.format("Rain suppression tick %d: rain=%d snow=%d actors found",
                rainSuppressCount, rainFound, snowFound))
        end

        return false -- keep running
    end)
end

-- ============================================================
-- Debug keybinds
-- ============================================================

-- F6: Dump full state (collection state + inventory + progress)
RegisterKeyBind(Key.F6, function()
    Logging.LogInfo("=== F6: Full state dump ===")
    Progress.FindProgressObject(State, true)
    
    -- Collection module state
    Collection.DumpState()
    
    -- All progress objects
    local allProgress = FindAllOf("BP_TalosProgress_C")
    if allProgress then
        Logging.LogInfo(string.format("Found %d BP_TalosProgress_C objects in memory:", #allProgress))
        for i, prog in ipairs(allProgress) do
            if prog and prog:IsValid() then
                local addr = "unknown"
                pcall(function() addr = tostring(prog:GetAddress()) end)
                local slot = "?"
                pcall(function() slot = tostring(prog.TalosProgressSlot) end)
                local timePlayed = "?"
                pcall(function() timePlayed = tostring(prog.TimePlayed) end)
                local count = "?"
                pcall(function()
                    local c = 0
                    prog.CollectedTetrominos:ForEach(function() c = c + 1 end)
                    count = tostring(c)
                end)
                Logging.LogInfo(string.format("  [%d] addr=%s slot=%s time=%s tetrominos=%s", i, addr, slot, timePlayed, count))
            end
        end
    end
    
    Progress.DumpSaveFileContents(State)
end)

-- F8: Grant ALL gate items (Connector + Hexahedron + Fans + Playback + all gates through World C)
RegisterKeyBind(Key.F8, function()
    Logging.LogInfo("=== F8: Granting ALL gate items (full unlock) ===")
    Progress.FindProgressObject(State, true)
    local allGateItems = {
        -- World A1 (7)
        "DJ3",  "MT1",  "DZ1",  "DJ2",  "DJ1",  "ML1",  "DI1",
        -- World A2 (3)
        "ML2",  "DL1",  "DZ2",
        -- World A3 (4)
        "MT2",  "DZ3",  "NL1",  "MT3",
        -- World A4 (4)
        "MZ1",  "MZ2",  "MT4",  "MT5",
        -- World A5 (5)
        "NZ1",  "DI2",  "DT1",  "DT2",  "DL2",
        -- World A6 (4)
        "DZ4",  "NL2",  "NL3",  "NZ2",
        -- World A7 (5)
        "NL4",  "DL3",  "NT1",  "NO1",  "DT3",
        -- World B1 (5)
        "ML3",  "MZ3",  "MS1",  "MT6",  "MT7",
        -- World B2 (4)
        "NL5",  "MS2",  "MT8",  "MZ4",
        -- World B3 (3)
        "MT9",  "MJ1",  "NL6",
        -- World B4 (6)
        "NT3",  "NT4",  "DT4",  "DJ4",  "NL7",  "NL8",
        -- World B5 (5)
        "NI1",  "NL9",  "NS1",  "DJ5",  "NZ3",
        -- World B6 (3)
        "NI2",  "MT10", "ML4",
        -- World B7 (4)
        "NJ1",  "NI3",  "MO1",  "MI1",
        -- World C1 (4)
        "NZ4",  "NJ2",  "NI4",  "NT5",
        -- World C2 (4)
        "NZ5",  "NO2",  "NT6",  "NS2",
        -- World C3 (4)
        "NJ3",  "NO3",  "NZ6",  "NT7",
        -- World C4 (4)
        "NT8",  "NI5",  "NS3",  "NT9",
        -- World C5 (4)
        "NI6",  "NO4",  "NO5",  "NT10",
        -- World C6 (3)
        "NS4",  "NJ4",  "NO6",
        -- World C7 (4)
        "NT11", "NO7",  "NT12", "NL10"
    }
    for _, id in ipairs(allGateItems) do
        Collection.GrantItem(State, id)
    end
    Logging.LogInfo("ALL gates + tools unlocked (through World C)")
    Collection.DumpState()
end)

-- ============================================================
-- Export for external Archipelago client access
-- ============================================================
return {
    State = State,
    Collection = Collection,
    OnTetrominoCollected = OnTetrominoCollected
}
