-- ============================================================
-- Tetromino visibility and collision management
-- ============================================================

local Logging = require("lib.logging")

-- Show a tetromino item (worker-thread safe).
-- Uses SetActorHiddenInGame(false) + per-component visibility restore
-- + Capsule collision restore.
--
-- IMPORTANT: SetActorHiddenInGame only sets the actor-level bHidden flag.
-- The game's HideTetromino() also hides individual components (TetrominoMesh,
-- Particles) via component-level flags (bVisible, bHiddenInGame).  We must
-- restore those too, using the C++ UFunctions SetVisibility() and
-- SetHiddenInGame() on USceneComponent, and Activate() on UActorComponent.
local function SetTetrominoVisible(item)
    if not item or not item:IsValid() then 
        return false
    end

    local ok, err = pcall(function()
        ExecuteInGameThread (function () 
            item:UnhideTetromino()
        end)
    end)
    
    local success = false
    
    -- SetActorHiddenInGame is a C++ Engine UFunction — safe from LoopAsync.
    -- It marks render state dirty so the actor actually appears on screen.
    pcall(function()
        item:SetActorHiddenInGame(false)
        success = true
    end)
    
    -- Restore component-level visibility on the skeletal mesh.
    -- SetVisibility(bNewVisibility, bPropagateToChildren) and
    -- SetHiddenInGame(NewHidden, bPropagateToChildren) are C++ UFunctions
    -- on USceneComponent — safe from LoopAsync.
    pcall(function()
        if item.TetrominoMesh and item.TetrominoMesh:IsValid() then
            item.TetrominoMesh:SetVisibility(true, true)
            item.TetrominoMesh:SetHiddenInGame(false, true)
        end
    end)
    
    -- Restore the Niagara particle system (the floating glow effect).
    pcall(function()
        if item.Particles and item.Particles:IsValid() then
            item.Particles:SetVisibility(true, false)
            item.Particles:SetHiddenInGame(false, false)
            -- Activate is a C++ UFunction on UActorComponent.
            -- bReset=true restarts the particle effect from scratch.
            item.Particles:Activate(true)
        end
    end)
    
    -- Clear stale animation state
    pcall(function()
        item.bIsAnimating = false
    end)
    
    -- Enable the Capsule overlap trigger so the player can walk into the item.
    pcall(function()
        if item.Capsule and item.Capsule:IsValid() then
            item.Capsule.CollisionEnabled = 1  -- QueryOnly
            item.Capsule.bGenerateOverlapEvents = true
        end
    end)
    
    return success
end

-- Hide a tetromino item (worker-thread safe).
-- Uses SetActorHiddenInGame(true) + per-component visibility disable
-- + Capsule collision disable.
local function SetTetrominoHidden(item)
    if not item or not item:IsValid() then
        return false
    end

    local ok, err = pcall(function()
        ExecuteInGameThread (function () 
            item:HideTetromino()
        end)
    end)

    local success = false

    pcall(function()
        item:SetActorHiddenInGame(true)
        success = true
    end)

    -- Hide individual components so they don't render even if bHidden
    -- is later cleared by some other code path.
    pcall(function()
        if item.TetrominoMesh and item.TetrominoMesh:IsValid() then
            item.TetrominoMesh:SetVisibility(false, true)
            item.TetrominoMesh:SetHiddenInGame(true, true)
        end
    end)
    
    -- Deactivate particles so they stop emitting.
    pcall(function()
        if item.Particles and item.Particles:IsValid() then
            item.Particles:SetVisibility(false, false)
            item.Particles:SetHiddenInGame(true, false)
            item.Particles:Deactivate()
        end
    end)

    -- Disable Capsule so the player can't re-trigger overlap
    pcall(function()
        if item.Capsule and item.Capsule:IsValid() then
            item.Capsule.CollisionEnabled = 0  -- NoCollision
            item.Capsule.bGenerateOverlapEvents = false
        end
    end)

    return success
end

return {
    SetTetrominoVisible = SetTetrominoVisible,
    SetTetrominoHidden = SetTetrominoHidden
}
