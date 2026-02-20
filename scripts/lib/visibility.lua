-- ============================================================
-- Tetromino visibility and collision management
-- ============================================================
--
-- CRITICAL: BP_TetrominoItem_C actors are Angelscript-derived.
-- UE4SS's __index/__newindex metamethods crash on ANY property
-- access with "Array failed invariants check, ArrayNum exceeds
-- ArrayMax". This means we CANNOT safely access:
--   item.TetrominoMesh, item.Particles, item.Capsule, item.Root,
--   item.bHidden, item.bIsAnimating, item:UnhideTetromino(),
--   item:HideTetromino(), item:SetActorHiddenInGame()
--
-- SAFE methods (on Lua metatable, don't traverse UE reflection):
--   GetFullName(), IsValid(), GetAddress(), GetClass(), GetFName()
--
-- APPROACH: Find each actor's Root SceneComponent by string-matching
-- GetFullName() paths. SceneComponent is a native engine type where
-- __index works safely. SetVisibility()/SetHiddenInGame() with
-- propagation=true cascades to ALL children (TetrominoMesh,
-- Particles, Capsule, AkComponent, etc.)
-- ============================================================

local Logging = require("lib.logging")

-- Cache: actorPath -> SceneComponent (Root)
local _componentCache = {}

-- ============================================================
-- Path extraction
-- ============================================================

--- Extract actor path from GetFullName().
--- "BP_TetrominoItem_C /Game/Maps/.../ActorName" -> "/Game/Maps/.../ActorName"
--- Safe to call on Angelscript actors.
local function ExtractActorPath(item)
    local path = nil
    pcall(function()
        if item:IsValid() then
            local fullName = item:GetFullName()
            path = fullName:match("^%S+%s+(.+)$")
        end
    end)
    return path
end

-- ============================================================
-- Component cache
-- ============================================================

--- Build the Root SceneComponent cache for a set of actor paths.
--- Searches all SceneComponent instances in the world and matches
--- their GetFullName() against "actorPath.Root".
---
--- This is ADDITIVE: it only searches for paths not already cached.
--- Safe to call repeatedly (e.g. on a retry timer) without losing
--- existing valid entries. Pass fullRebuild=true to clear and rescan.
---
--- @param actorPaths table  Set of actor path strings (keys = paths, values = true)
--- @param fullRebuild boolean|nil  If true, clears the entire cache first
local function BuildComponentCache(actorPaths, fullRebuild)
    if fullRebuild then
        _componentCache = {}
    end

    -- Determine which paths still need a cached component
    local missingPaths = {}
    local missingCount = 0
    local totalCount = 0
    for path in pairs(actorPaths) do
        totalCount = totalCount + 1
        if not _componentCache[path] then
            missingPaths[path] = true
            missingCount = missingCount + 1
        else
            -- Validate existing entry is still alive
            local alive = false
            pcall(function() alive = _componentCache[path]:IsValid() end)
            if not alive then
                _componentCache[path] = nil
                missingPaths[path] = true
                missingCount = missingCount + 1
            end
        end
    end

    if missingCount == 0 then return end  -- cache is already complete

    local components = nil
    pcall(function() components = FindAllOf("SceneComponent") end)
    if not components then
        Logging.LogWarning("BuildComponentCache: no SceneComponents found in world")
        return
    end

    local matched = 0
    for _, comp in ipairs(components) do
        if missingCount <= 0 then break end  -- all found
        pcall(function()
            local compFullName = comp:GetFullName()
            for actorPath in pairs(missingPaths) do
                if compFullName:find(actorPath .. ".Root", 1, true) then
                    _componentCache[actorPath] = comp
                    missingPaths[actorPath] = nil
                    missingCount = missingCount - 1
                    matched = matched + 1
                    break
                end
            end
        end)
    end

    local cachedTotal = 0
    for _ in pairs(_componentCache) do cachedTotal = cachedTotal + 1 end

    Logging.LogInfo(string.format(
        "Visibility cache: found %d new, %d/%d total cached (%d components searched)",
        matched, cachedTotal, totalCount, #components))
end

-- ============================================================
-- Position reading from cached Root SceneComponent (SAFE)
-- ============================================================

--- Read position from the cached Root SceneComponent.
--- Returns x, y, z or nil, nil, nil if not cached/invalid.
local function GetPositionFromCache(actorPath)
    if not actorPath then return nil, nil, nil end
    local comp = _componentCache[actorPath]
    if not comp then return nil, nil, nil end

    local x, y, z = nil, nil, nil
    pcall(function()
        if comp:IsValid() then
            local loc = comp.RelativeLocation
            x = loc.X
            y = loc.Y
            z = loc.Z
        end
    end)
    return x, y, z
end

-- ============================================================
-- Visibility checks on cached native SceneComponent (SAFE)
-- ============================================================

--- Check if an actor's Root component is currently hidden.
--- Returns true (hidden), false (visible), or nil (unknown/not cached).
local function IsHiddenByPath(actorPath)
    if not actorPath then return nil end
    local comp = _componentCache[actorPath]
    if not comp then return nil end

    local hidden = nil
    pcall(function()
        if comp:IsValid() then
            if comp.bVisible == false or comp.bHiddenInGame == true then
                hidden = true
            else
                hidden = false
            end
        end
    end)
    return hidden
end

-- ============================================================
-- Visibility control via Root SceneComponent with propagation
-- ============================================================

--- Show a tetromino by setting its Root SceneComponent visible.
--- Propagation cascades to all children (TetrominoMesh, Particles,
--- Capsule, AkComponent, etc.)
---
--- @param actorPath string  Actor path from ExtractActorPath()
--- @return boolean  true if visibility was set successfully
local function SetTetrominoVisible(actorPath)
    if not actorPath then return false end
    local comp = _componentCache[actorPath]
    if not comp then return false end

    local success = false
    pcall(function()
        if comp:IsValid() then
            comp:SetVisibility(true, true)
            comp:SetHiddenInGame(false, true)
            success = true
        end
    end)
    return success
end

--- Hide a tetromino by setting its Root SceneComponent hidden.
--- Propagation cascades to all children.
---
--- @param actorPath string  Actor path from ExtractActorPath()
--- @return boolean  true if visibility was set successfully
local function SetTetrominoHidden(actorPath)
    if not actorPath then return false end
    local comp = _componentCache[actorPath]
    if not comp then return false end

    local success = false
    pcall(function()
        if comp:IsValid() then
            comp:SetVisibility(false, true)
            comp:SetHiddenInGame(true, true)
            success = true
        end
    end)
    return success
end

--- Return cache statistics.
--- @return number cached  Number of actor paths with a cached Root component
--- @return number total   Total number of actor paths we've been asked about
local function GetCacheStats(actorPaths)
    local cached, total = 0, 0
    for path in pairs(actorPaths) do
        total = total + 1
        if _componentCache[path] then
            local alive = false
            pcall(function() alive = _componentCache[path]:IsValid() end)
            if alive then cached = cached + 1 end
        end
    end
    return cached, total
end

--- Clear the component cache (call on level transitions).
local function ResetDiagnostics()
    _componentCache = {}
end

return {
    ExtractActorPath = ExtractActorPath,
    BuildComponentCache = BuildComponentCache,
    GetCacheStats = GetCacheStats,
    GetPositionFromCache = GetPositionFromCache,
    IsHiddenByPath = IsHiddenByPath,
    SetTetrominoVisible = SetTetrominoVisible,
    SetTetrominoHidden = SetTetrominoHidden,
    ResetDiagnostics = ResetDiagnostics,
}
