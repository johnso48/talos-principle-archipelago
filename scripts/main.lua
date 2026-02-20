-- ============================================================
-- Archipelago Mod for The Talos Principle Reawakened
-- Main initialization and coordination
-- ============================================================

-- Load modules
local Logging = require("lib.logging")
local TetrominoUtils = require("lib.tetromino_utils")
local Visibility = require("lib.visibility")
local Progress = require("lib.progress")
local Inventory = require("lib.inventory")
local Collection = require("lib.collection")
local Config = require("lib.config")
local ItemMapping = require("lib.item_mapping")
local APClient = require("lib.ap_client")
local GoalDetection = require("lib.goal_detection")
local HUD = require("lib.hud")

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
    -- Start with a moderate cooldown so the 100ms loop doesn't touch UObjects
    -- while the game engine is still initializing during startup.
    -- Hooks (ClientRestart, SetTalosSaveGame) will reset this once the
    -- game world is actually ready.
    LevelTransitionCooldown = 30,
    LastAddedTetrominoId = nil,
    ArrangerActive = false,  -- true while player is using an arranger/gate
    NeedsProgressRefresh = true,  -- deferred flag: find progress on next loop iteration
    NeedsHUDInit = true,          -- deferred flag: init HUD on next loop iteration
    NeedsTetrominoScan = true     -- deferred flag: snapshot tetromino positions on next safe tick
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
-- Initialize HUD notification overlay
-- Deferred: actual UMG widget creation happens in the main loop
-- after the initial startup cooldown expires (State.NeedsHUDInit).
-- ============================================================
-- HUD.Init() called after cooldown — see NeedsHUDInit flag

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
    
    -- Delayed UI refresh: the enforce loop will remove the item from TMap
    -- but the HUD won't update until we explicitly tell it to.
    -- Guard: skip if a level transition started while we were waiting.
    LoopAsync(5000, function()
        if State.LevelTransitionCooldown <= 0 then
            Collection.RefreshUI()
        end
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
    Logging.LogDebug("Player spawned - setting deferred refresh flags")
    
    -- Do NOT access UObjects synchronously in this hook.
    -- During save loading, UObjects may be partially initialized and
    -- UE4SS crashes in its own error handling if an access fails.
    -- Instead: set flags and let the 100ms loop handle it safely
    -- after the cooldown expires.
    State.CurrentProgress = nil
    State.TrackedItems = {}
    State.LevelTransitionCooldown = 15
    State.NeedsProgressRefresh = true
    State.NeedsHUDInit = true
    State.NeedsTetrominoScan = true
end)

-- ============================================================
-- Hook save game set — fires when the game instance receives
-- a new or loaded save game object. This is the authoritative
-- moment to re-acquire the progress object.
-- ============================================================
RegisterHook("/Script/Talos.TalosGameInstance:SetTalosSaveGameInstance", function(Context)
    Logging.LogInfo("Save game instance set on TalosGameInstance — setting deferred refresh")
    -- Pause loops during save game transition.
    -- Do NOT access UObjects here — just set flags for the main loop.
    State.LevelTransitionCooldown = 15
    State.CurrentProgress = nil
    State.TrackedItems = {}
    State.CollectedThisSession = {}
    State.NeedsProgressRefresh = true
    State.NeedsTetrominoScan = true
    GoalDetection.ResetGoalState()
end)

-- ============================================================
-- Hook save game reload (Continue / Load from menu)
-- ============================================================
RegisterHook("/Script/Talos.TalosGameInstance:ReloadSaveGame", function(Context)
    Logging.LogInfo("ReloadSaveGame called — will re-acquire progress on player spawn")
    State.CurrentProgress = nil
    State.TrackedItems = {}
    State.LevelTransitionCooldown = 20
    State.NeedsProgressRefresh = true
    State.NeedsTetrominoScan = true
    GoalDetection.ResetGoalState()
end)

-- ============================================================
-- Hook level OPEN — fires at the START of a level transition,
-- before actors are destroyed. This is critical: the other hooks
-- (ClientRestart, SetTalosSaveGameInstance) only fire AFTER the
-- new level has loaded. Without this, the 100ms enforcement loop
-- continues accessing actors and TMap references that are being
-- destroyed mid-transition.
-- ============================================================
pcall(function()
    RegisterHook("/Script/Talos.TalosGameInstance:OpenLevel", function(Context)
        Logging.LogInfo("OpenLevel called — pausing all loops for level transition")
        State.LevelTransitionCooldown = 50
        State.CurrentProgress = nil
        State.TrackedItems = {}
    end)
end)

pcall(function()
    RegisterHook("/Script/Talos.TalosGameInstance:OpenLevelBySoftObjectPtr", function(Context)
        Logging.LogInfo("OpenLevelBySoftObjectPtr called — pausing all loops for level transition")
        State.LevelTransitionCooldown = 50
        State.CurrentProgress = nil
        State.TrackedItems = {}
    end)
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
local AP_SYNC_TIMEOUT = 0  -- 2 seconds (20 * 100ms) before enabling enforcement anyway

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

    -- Handle deferred initialization flags set by hook callbacks.
    -- These run AFTER cooldown expires, when the world is stable.
    if State.NeedsProgressRefresh then
        State.NeedsProgressRefresh = false
        pcall(function()
            Progress.FindProgressObject(State, true)
            if State.CurrentProgress and State.CurrentProgress:IsValid() then
                local timePlayed = 0
                local level = "?"
                pcall(function() timePlayed = State.CurrentProgress.TimePlayed end)
                pcall(function() level = State.CurrentProgress.LastPlayedPersistentLevel end)
                Logging.LogInfo(string.format("Deferred progress refresh: timePlayed=%.0f, level=%s",
                    timePlayed, tostring(level)))
                Progress.DumpSaveFileContents(State)
            end
        end)
    end
    if State.NeedsHUDInit then
        State.NeedsHUDInit = false
        pcall(function()
            HUD.Init()
            Logging.LogDebug("Deferred HUD init complete")
        end)
    end

    -- ============================================================
    -- One-time tetromino snapshot: find all BP_TetrominoItem_C actors
    -- in the level and cache their positions. This replaces the old
    -- Scanner module that polled every 100ms. Positions are static
    -- (tetrominos don't move) so we only need to do this once after
    -- each level load / save reload.
    -- ============================================================
    if State.NeedsTetrominoScan then
        State.NeedsTetrominoScan = false
        pcall(function()
            local items = FindAllOf("BP_TetrominoItem_C")
            if items then
                local count = 0
                for _, item in ipairs(items) do
                    if item and item:IsValid() then
                        local tetrominoId = TetrominoUtils.GetTetrominoId(item)
                        if tetrominoId then
                            local ix, iy, iz = nil, nil, nil
                            pcall(function()
                                local loc = item.Root.RelativeLocation
                                ix = loc.X
                                iy = loc.Y
                                iz = loc.Z
                            end)
                            local addr = tostring(item:GetAddress())
                            -- Apply initial visibility state
                            local visRetries = 0
                            if Collection.ShouldBeCollectable(tetrominoId) then
                                Visibility.SetTetrominoVisible(item)
                                visRetries = 30  -- keep retrying for ~3s
                            elseif Collection.IsLocationChecked(tetrominoId) and not Collection.IsGranted(tetrominoId) then
                                Visibility.SetTetrominoHidden(item)
                            end

                            State.TrackedItems[addr] = {
                                id = tetrominoId,
                                item = item,
                                x = ix,
                                y = iy,
                                z = iz,
                                reported = false,
                                visRetries = visRetries
                            }
                            count = count + 1
                        end
                    end
                end
                Logging.LogInfo(string.format("Tetromino snapshot: cached %d items with positions", count))
            end
        end)
    end

    local ok, err = pcall(function()
        if not State.CurrentProgress or not State.CurrentProgress:IsValid() then
            Progress.FindProgressObject(State)
        end

        -- Re-check after find — still in transition if nil
        if not State.CurrentProgress or not State.CurrentProgress:IsValid() then
            return
        end

        if State.CurrentProgress and State.CurrentProgress:IsValid() then
            -- Poll arranger state — skip TMap manipulation while any arranger is in use
            State.ArrangerActive = IsAnyArrangerActive()
            if State.ArrangerActive ~= previousArrangerActive then
                Logging.LogInfo(string.format("Arranger state changed: %s", tostring(State.ArrangerActive)))
                previousArrangerActive = State.ArrangerActive
            end
            if not State.ArrangerActive then
                -- Enforce: keep CollectedTetrominos in sync with Archipelago grants.
                -- All granted items stay in TMap (inventory). Non-granted items are removed.
                Collection.EnforceCollectionState(State)
            end

            -- ============================================================
            -- Visibility enforcement + proximity-based pickup detection
            -- ============================================================
            -- Uses the cached TrackedItems snapshot (positions read once on
            -- level load). Every 100ms we:
            --   1. Enforce visibility (show collectable items, hide checked ones)
            --   2. Compare player position against cached item positions for pickup
            -- ============================================================
            if not State.ArrangerActive then
                -- Get player position once per tick
                local playerX, playerY, playerZ = nil, nil, nil
                pcall(function()
                    local pc = FindFirstOf("PlayerController")
                    if pc and pc:IsValid() and pc.Pawn and pc.Pawn:IsValid() then
                        local root = pc.Pawn.RootComponent
                        if root and root:IsValid() then
                            local loc = root.RelativeLocation
                            playerX = loc.X
                            playerY = loc.Y
                            playerZ = loc.Z
                        end
                    end
                end)

                local PICKUP_RADIUS_SQ = 250 * 250  -- 250 units (~2.5m) squared

                for addr, info in pairs(State.TrackedItems) do
                    if info.item and info.id then
                        local itemValid = false
                        pcall(function() itemValid = info.item:IsValid() end)
                        if itemValid then
                            -- Visibility enforcement
                            if Collection.ShouldBeCollectable(info.id) then
                                local needsRestore = false
                                pcall(function()
                                    if info.item.bHidden == true then
                                        needsRestore = true
                                    elseif info.item.TetrominoMesh and info.item.TetrominoMesh:IsValid() then
                                        if info.item.TetrominoMesh.bVisible == false then
                                            needsRestore = true
                                        elseif info.item.TetrominoMesh.bHiddenInGame == true then
                                            needsRestore = true
                                        end
                                    end
                                end)
                                local VISIBILITY_RETRY_COUNT = 30  -- ~3 seconds at 100ms
                                if needsRestore then
                                    info.visRetries = VISIBILITY_RETRY_COUNT
                                end
                                if info.visRetries > 0 then
                                    Visibility.SetTetrominoVisible(info.item)
                                    info.visRetries = info.visRetries - 1
                                end

                                -- Proximity pickup (only for collectable items)
                                if playerX and info.x and not info.reported then
                                    local dx = playerX - info.x
                                    local dy = playerY - info.y
                                    local dz = playerZ - info.z
                                    local distSq = dx*dx + dy*dy + dz*dz

                                    if distSq < PICKUP_RADIUS_SQ then
                                        Logging.LogInfo(string.format(
                                            "Proximity pickup: %s (dist=%.0f)",
                                            info.id, math.sqrt(distSq)))
                                        info.reported = true
                                        Visibility.SetTetrominoHidden(info.item)
                                        OnTetrominoCollected(info.id)
                                    end
                                end
                            elseif Collection.IsLocationChecked(info.id) and not Collection.IsGranted(info.id) then
                                -- Checked-but-not-granted → hide (sent to another player)
                                Visibility.SetTetrominoHidden(info.item)
                            end
                        end
                    end
                end
            end

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
        -- World B3 (4)
        "MT9",  "MJ1",  "NT2", "NL6",
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
