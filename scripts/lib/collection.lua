-- ============================================================
-- Decoupled collection system for Archipelago integration
--
-- Two independent concepts:
--   "Location checked" = player physically picked up the item in-world
--   "Item granted"     = Archipelago says the player owns the item
--
-- TMap management strategy:
--   Granted items → added to TMap (usable in arrangers/doors)
--   Checked items → kept in TMap (persist after pickup)
--   Neither       → removed from TMap
--
-- The fast visibility loop (10ms) temporarily removes granted-but-
-- unchecked items from TMap when their physical actor is present in
-- the level, so the game's OnBeginOverlap → IsTetrominoCollected
-- check returns false and pickup can proceed. The enforce loop (100ms)
-- re-adds them, so they're usable ~90% of the time.
-- ============================================================

local Logging = require("lib.logging")
local TetrominoUtils = require("lib.tetromino_utils")

local M = {}

-- ============================================================
-- TMap helpers
-- ============================================================

-- Add an item to the CollectedTetrominos TMap only if it is not
-- already present.  The boolean value in the TMap tracks whether
-- the tetromino has been used in a door; blindly calling
-- :Add(id, false) would reset that flag on every sync cycle.
local function TMapAddPreserving(tmap, id)
    local exists = false
    pcall(function()
        local val = tmap:Find(id)
        -- val is the stored boolean; nil means key not found.
        if val ~= nil then
            exists = true
        end
    end)
    if not exists then
        tmap:Add(id, false)
    end
end

-- ============================================================
-- State
-- ============================================================

-- Items Archipelago has granted to the player.
-- Key: tetromino ID string (e.g. "DJ3"), Value: true
M.GrantedItems = {}

-- Locations physically picked up this session.
-- Key: tetromino ID string, Value: true
-- Items here stay hidden so the player doesn't see respawn spam.
-- Cleared on level transition or session restart.
M.CheckedLocations = {}

-- Whether AP has synced items at least once this session.
-- EnforceCollectionState is BLOCKED until this is true, so we
-- don't wipe the player's TMap before AP can repopulate grants.
M.APSynced = false

-- ============================================================
-- Collection state enforcement
-- ============================================================

-- Keep CollectedTetrominos TMap in sync with our collection state.
-- Rules:
--   Granted items → keep in TMap (usable in arrangers/doors)
--   Checked items → keep in TMap (already picked up, stay collected)
--   Neither granted nor checked → remove from TMap
-- Note: Granted-but-unchecked items that have physical actors in the
-- level are temporarily removed from TMap by the visibility loop so
-- OnBeginOverlap's IsTetrominoCollected check allows pickup.
function M.EnforceCollectionState(state)
    if not state.CurrentProgress or not state.CurrentProgress:IsValid() then
        return
    end

    -- Block enforcement until AP has synced items (or timeout).
    -- Without this, we'd wipe the TMap on every mod load before
    -- the AP server has a chance to repopulate GrantedItems.
    if not M.APSynced then
        return
    end

    local toRemove = {}

    -- Find items in TMap that are NOT granted by Archipelago.
    -- Only granted items belong in the TMap (they count as inventory).
    -- Checked-but-not-granted items must be removed — the player
    -- checked the location but AP gave the item to someone else.
    pcall(function()
        local tmap = state.CurrentProgress.CollectedTetrominos
        if not tmap then return end

        tmap:ForEach(function(keyParam, valueParam)
            local key = nil
            pcall(function() key = keyParam:get():ToString() end)
            if key and not M.GrantedItems[key] then
                table.insert(toRemove, key)
            end
        end)
    end)

    -- Remove non-granted items from TMap
    if #toRemove > 0 then
        for _, id in ipairs(toRemove) do
            pcall(function()
                if state.CurrentProgress and state.CurrentProgress:IsValid() then
                    state.CurrentProgress.CollectedTetrominos:Remove(id)
                end
            end)
        end
        Logging.LogDebug(string.format("Enforced: removed %d non-granted items from TMap", #toRemove))
    end

    -- Ensure all granted items are in TMap (usable in arrangers/doors)
    -- Use TMapAddPreserving so we don't reset the door-usage flag.
    for id, _ in pairs(M.GrantedItems) do
        pcall(function()
            if state.CurrentProgress and state.CurrentProgress:IsValid() then
                TMapAddPreserving(state.CurrentProgress.CollectedTetrominos, id)
            end
        end)
    end
end

-- Returns true if the item should be visible and have collision in-world.
-- An item is collectable if its LOCATION has NOT been checked this session.
-- Grant status is irrelevant here — in Archipelago, the location must be
-- physically checked regardless of whether the corresponding item is owned.
function M.ShouldBeCollectable(tetrominoId)
    return not M.CheckedLocations[tetrominoId]
end

-- ============================================================
-- Location checking (physical pickup in-world)
-- ============================================================

-- Mark a location as checked. Called when the player physically
-- picks up an item. The item stays hidden for the rest of the session.
function M.MarkLocationChecked(tetrominoId)
    if not M.CheckedLocations[tetrominoId] then
        M.CheckedLocations[tetrominoId] = true
        Logging.LogInfo(string.format("Location checked: %s", tetrominoId))
    end
end

-- Check if a location has been checked this session
function M.IsLocationChecked(tetrominoId)
    return M.CheckedLocations[tetrominoId] == true
end

-- Reset all checked locations. Useful on:
--   - Level transition (items should reappear in new level context)
--   - Connection loss (need to re-check unconfirmed locations)
--   - New session start
function M.ResetCheckedLocations()
    M.CheckedLocations = {}
    Logging.LogInfo("All checked locations reset")
end

-- Reset a specific checked location (make it re-pickable)
function M.ResetLocation(tetrominoId)
    M.CheckedLocations[tetrominoId] = nil
    Logging.LogDebug(string.format("Location reset: %s", tetrominoId))
end

-- ============================================================
-- Archipelago item grants (inventory management)
-- ============================================================

-- Refresh the in-game tetromino UI (HUD counter, arranger screens).
--
-- NOTE ON CLASS HIERARCHY:
--   UTalosHUD is an AngelScript class — it does NOT appear in
--   UE4SS Live View.  The Blueprint widget that extends it is
--   UWBP_TalosUserWidget_C, which IS visible and findable.
--
-- Safe refresh approach (avoids the TMap crash):
--   1. FindFirstOf("WBP_TalosUserWidget_C") → the live HUD widget
--      .ArrangerInfo → UArrangerInfoPanel
--        :UpdateInventory()  ← refreshes tetromino piece counters
--   2. OnScriptTetrominoCollected_BP on BP_Arranger_C instances
--      ← notifies each arranger about a newly collected piece
--   3. PerformWidgetUpdates() on the specific ATetrominoItem
--      ← the game's own method called during natural pickup flow
--
-- UNSAFE (removed): UpdateExplorationMode() on UTalosHUD
--   This method internally iterates CollectedTetrominos TMap.
--   The 5ms visibility loop constantly mutates that same TMap,
--   causing "ArrayNum exceeds ArrayMax" crashes.  The exploration
--   mode overlay already updates itself via UTalosHUD::Tick()
--   every frame, so we don't need to force it.

local _uiRefreshPending = false

local function RefreshTetrominoUI(tetrominoId)
    Logging.LogDebug("RefreshTetrominoUI called for: " .. tostring(tetrominoId))

    -- === Notify arrangers (safe — doesn't touch TMap) ===
    if tetrominoId then
        local targetItem = TetrominoUtils.FindTetrominoItemById(tetrominoId)
        if targetItem then
            -- Call the game's own PerformWidgetUpdates on the item
            pcall(function()
                targetItem:PerformWidgetUpdates()
                Logging.LogDebug("  PerformWidgetUpdates() called on " .. tetrominoId)
            end)

            -- Notify each arranger in the level
            pcall(function()
                local arrangers = FindAllOf("BP_Arranger_C")
                if arrangers then
                    Logging.LogDebug(string.format("  Found %d BP_Arranger_C actors", #arrangers))
                    for _, arranger in ipairs(arrangers) do
                        if arranger and arranger:IsValid() then
                            pcall(function() arranger:OnScriptTetrominoCollected_BP(targetItem) end)
                        end
                    end
                end
            end)
        end
    end

    -- === Debounced HUD counter refresh ===
    if _uiRefreshPending then
        Logging.LogDebug("  UI refresh already pending, skipping duplicate")
        return
    end
    _uiRefreshPending = true

    LoopAsync(500, function()
        _uiRefreshPending = false

        ExecuteInGameThread(function()
            pcall(function()
                -- Find the HUD widget directly by its Blueprint class name.
                -- UWBP_TalosUserWidget_C extends UTalosHUD extends UTalosUserWidget.
                -- This is visible in UE4SS Live View (unlike the AngelScript parent).
                local hudWidget = FindFirstOf("WBP_TalosUserWidget_C")
                if not hudWidget or not hudWidget:IsValid() then
                    Logging.LogDebug("  No WBP_TalosUserWidget_C found")
                    return
                end

                -- ArrangerInfo:UpdateInventory — refreshes piece counters
                pcall(function()
                    local arrangerInfo = hudWidget.ArrangerInfo
                    if arrangerInfo then
                        local aiValid = false
                        pcall(function() aiValid = arrangerInfo:IsValid() end)
                        if aiValid then
                            arrangerInfo:UpdateInventory()
                            Logging.LogDebug("  ArrangerInfo:UpdateInventory() called")
                        end
                    else
                        Logging.LogDebug("  ArrangerInfo is nil on HUD widget")
                    end
                end)
            end)
        end)

        return true -- run once
    end)
end

-- Grant an item — Archipelago says the player owns this.
-- Adds to TMap immediately so it's usable in arrangers/doors.
-- The visibility loop will temporarily remove it from TMap when
-- the physical actor is in the current level, allowing pickup.
function M.GrantItem(state, tetrominoId)
    local wasNew = not M.GrantedItems[tetrominoId]
    M.GrantedItems[tetrominoId] = true
    if wasNew then
        Logging.LogInfo(string.format("Item granted: %s", tetrominoId))
    end

    -- Add to TMap for immediate usability (preserve door-usage flag)
    if state.CurrentProgress and state.CurrentProgress:IsValid() then
        pcall(function()
            TMapAddPreserving(state.CurrentProgress.CollectedTetrominos, tetrominoId)
        end)
    end

    if wasNew then
        RefreshTetrominoUI(tetrominoId)
    end
end

-- Revoke an item — remove from GrantedItems and TMap.
function M.RevokeItem(state, tetrominoId)
    M.GrantedItems[tetrominoId] = nil
    M.CheckedLocations[tetrominoId] = nil -- also uncheck so it reappears
    Logging.LogInfo(string.format("Item revoked: %s", tetrominoId))

    -- Remove from TMap
    if state.CurrentProgress and state.CurrentProgress:IsValid() then
        pcall(function()
            state.CurrentProgress.CollectedTetrominos:Remove(tetrominoId)
        end)
    end

end

-- Bulk grant — set a list of granted items (e.g. on Archipelago connect/sync)
function M.SetGrantedItems(state, itemIds)
    M.GrantedItems = {}
    for _, id in ipairs(itemIds) do
        M.GrantedItems[id] = true
    end
    Logging.LogInfo(string.format("Bulk granted %d items", #itemIds))

    -- Add all to TMap for immediate usability (preserve door-usage flags)
    if state.CurrentProgress and state.CurrentProgress:IsValid() then
        for _, id in ipairs(itemIds) do
            pcall(function()
                TMapAddPreserving(state.CurrentProgress.CollectedTetrominos, id)
            end)
        end
    end

    RefreshTetrominoUI(nil)
end

-- ============================================================
-- Query functions
-- ============================================================

function M.IsGranted(tetrominoId)
    return M.GrantedItems[tetrominoId] == true
end

function M.GetGrantedItems()
    local items = {}
    for id, _ in pairs(M.GrantedItems) do
        table.insert(items, id)
    end
    return items
end

function M.GetCheckedLocations()
    local items = {}
    for id, _ in pairs(M.CheckedLocations) do
        table.insert(items, id)
    end
    return items
end

-- Debug: dump current state
function M.DumpState()
    local granted = M.GetGrantedItems()
    local checked = M.GetCheckedLocations()
    table.sort(granted)
    table.sort(checked)
    Logging.LogInfo(string.format("=== Collection State ==="))
    Logging.LogInfo(string.format("  Granted items (%d): %s", #granted, table.concat(granted, ", ")))
    Logging.LogInfo(string.format("  Checked locations (%d): %s", #checked, table.concat(checked, ", ")))
end

-- Expose UI refresh for external callers
function M.RefreshUI()
    RefreshTetrominoUI(nil)
end

-- Get granted items table for goal detection
function M.GetGrantedItems()
    return M.GrantedItems
end

return M
