-- ============================================================
-- Goal Detection Module
--
-- Tracks completion of Archipelago goals by hooking the actual
-- in-game ending triggers:
--
--   Transcendence: Fires when the Ending_Transcendence level
--     sequence plays (SequenceEvent_0 on the director BP).
--     This is the cutscene that plays after collecting all
--     tetrominos and opening the World C door.
--
--   Ascension: Fires when the Bink movie player opens
--     "Ending_Ascension_01.bk2". The Ascension ending is a
--     pre-rendered movie (not a level sequence), so we hook
--     UBinkMediaPlayer:OpenUrl and match the filename.
-- ============================================================

local Logging = require("lib.logging")

local M = {}

-- Goal state tracking
M.GoalCompleted = false
M.CompletedGoalName = nil

-- Callback set by main.lua — called when a goal is achieved
M.OnGoalCompleted = nil

-- ============================================================
-- Register hooks for ending detection
-- Called once during mod initialization
-- ============================================================
function M.RegisterHooks()
    -- ---------------------------------------------------------
    -- Transcendence ending hook
    -- The Ending_Transcendence_DirectorBP_C is a LevelSequenceDirector
    -- that controls the Transcendence ending cutscene. Its
    -- SequenceEvent_0 fires when the cutscene actually starts.
    -- ---------------------------------------------------------
    local transcendenceHooked = pcall(function()
        RegisterHook("/Game/Maps/Talos/Endings/Ending_Transcendence/Ending_Transcendence_DirectorBP.Ending_Transcendence_DirectorBP_C:SequenceEvent_0", function(Context)
            if M.GoalCompleted then return end
            
            Logging.LogInfo("======================================")
            Logging.LogInfo("GOAL: TRANSCENDENCE ACHIEVED!")
            Logging.LogInfo("Ending_Transcendence sequence triggered")
            Logging.LogInfo("======================================")
            
            M.GoalCompleted = true
            M.CompletedGoalName = "Transcendence"
            
            if M.OnGoalCompleted then
                M.OnGoalCompleted("Transcendence")
            end
        end)
    end)
    
    if transcendenceHooked then
        Logging.LogInfo("Transcendence ending hook registered")
    else
        Logging.LogWarning("Could not hook Transcendence ending — will fall back to polling")
    end

    -- ---------------------------------------------------------
    -- Ascension ending hooks
    -- The Ascension ending plays pre-rendered Bink movies via
    -- SequentialMediaPlayer_Secondary. The engine sets the URL
    -- property directly in C++ (bypassing OpenUrl), so we use
    -- multiple detection strategies.
    -- ---------------------------------------------------------

    -- Approach 1: Hook OpenUrl (catches movies opened via Blueprint)
    local openUrlHooked = pcall(function()
        RegisterHook("/Script/BinkMediaPlayer.BinkMediaPlayer:OpenUrl", function(Context, NewUrl)
            if M.GoalCompleted then return end
            local url = NewUrl:get():ToString()
            Logging.LogInfo(string.format("BinkMediaPlayer:OpenUrl — %s", url))
            if url:find("Ending_Ascension") then
                M._FireGoal("Ascension", "BinkMediaPlayer:OpenUrl — " .. url)
            end
        end)
    end)
    if openUrlHooked then
        Logging.LogInfo("Ascension hook 1/2 registered (BinkMediaPlayer:OpenUrl)")
    else
        Logging.LogWarning("Could not hook BinkMediaPlayer:OpenUrl")
    end

    -- Approach 2: Hook OnBinkMediaPlayerMediaOpened delegate callback.
    -- This delegate fires whenever media is opened on ANY BinkMediaPlayer,
    -- even when the engine sets the URL directly. The FString parameter
    -- comes through the hook system so :get():ToString() works.
    local mediaOpenedHooked = pcall(function()
        RegisterHook("/Script/BinkMediaPlayer.BinkMediaPlayer:OnBinkMediaPlayerMediaOpened", function(Context, OpenedUrl)
            if M.GoalCompleted then return end
            local url = OpenedUrl:get():ToString()
            Logging.LogInfo(string.format("OnBinkMediaPlayerMediaOpened — %s", url))
            if url:find("Ending_Ascension") then
                M._FireGoal("Ascension", "OnMediaOpened — " .. url)
            end
        end)
    end)
    if mediaOpenedHooked then
        Logging.LogInfo("Ascension hook 2/2 registered (OnBinkMediaPlayerMediaOpened)")
    else
        Logging.LogWarning("Could not hook OnBinkMediaPlayerMediaOpened")
    end

end

-- ============================================================
-- Internal: fire goal completion (deduplicated)
-- ============================================================
function M._FireGoal(goalName, source)
    if M.GoalCompleted then return end

    Logging.LogInfo("======================================")
    Logging.LogInfo(string.format("GOAL: %s ACHIEVED!", goalName:upper()))
    Logging.LogInfo(string.format("Source: %s", source))
    Logging.LogInfo("======================================")

    M.GoalCompleted = true
    M.CompletedGoalName = goalName

    if M.OnGoalCompleted then
        M.OnGoalCompleted(goalName)
    end
end

-- ============================================================
-- Polling fallback (called from main 100ms loop)
--
-- Primary Ascension detection: poll the URL property on the
-- SequentialMediaPlayer_Secondary BinkMediaPlayer object. The
-- engine sets this property directly (bypassing OpenUrl), so
-- hooking doesn't work. When the URL contains "Ending_Ascension"
-- we know the ending movie sequence is playing.
--
-- Secondary fallback: poll TalosSaveSubsystem:IsGameCompleted()
-- to catch any ending that slipped through both hooks and the
-- URL poll above.
--
-- IMPORTANT: We delay polling for ~10 seconds (100 ticks at 100ms)
-- after mod load because native C++ calls can crash if invoked
-- before subsystems are fully initialized. pcall cannot catch
-- C++-level crashes.
-- ============================================================
local previousGameCompleted = false
local pollWarmup = 100  -- skip first 100 calls (~10 seconds)
local customPropertyWarmup = 100  -- register custom property after 100 ticks (~10 seconds)
local customPropertyRegistered = false
M._lastPolledUrl = ""
M._playersDumped = false

function M.CheckGoals(state)
    if M.GoalCompleted then return false end

    -- Wait for engine to stabilize before touching native subsystems
    if pollWarmup > 0 then
        pollWarmup = pollWarmup - 1
        return false
    end

    -- Register custom property after 10-second delay to avoid startup crash
    if not customPropertyRegistered then
        if customPropertyWarmup > 0 then
            customPropertyWarmup = customPropertyWarmup - 1
            return false
        end
        pcall(function()
            RegisterCustomProperty({
                Name = "URL_AP",
                Type = PropertyTypes.StrProperty,
                BelongsToClass = "/Script/BinkMediaPlayer.BinkMediaPlayer",
                OffsetInternal = 0x0098,
            })
            Logging.LogInfo("Registered custom property URL_AP on BinkMediaPlayer at offset 0x0098")
        end)
        customPropertyRegistered = true
    end

    -- Poll SequentialMediaPlayer_Secondary for Ascension ending movies.
    -- Try the custom property URL_AP first (registered at offset 0x0098
    -- via RegisterCustomProperty). If that fails, fall back to IsPlaying().
    pcall(function()
        -- FindObject may not work reliably for third-party plugin classes.
        -- Use FindAllOf and match by name instead.
        local allPlayers = FindAllOf("BinkMediaPlayer")
        if not allPlayers then
            Logging.LogDebug("[Goal] No BinkMediaPlayer objects found")
            return
        end

        for _, player in ipairs(allPlayers) do
            if not player or not player:IsValid() then goto continue end

            local nameOk, fullName = pcall(function() return player:GetFullName() end)
            if not nameOk then goto continue end

            -- Log all players once for diagnostics
            if not M._playersDumped then
                Logging.LogInfo(string.format("[Goal] Found BinkMediaPlayer: %s", tostring(fullName)))
            end

            if not fullName:find("SequentialMediaPlayer_Secondary") then goto continue end

            -- Found the ending player — try reading URL via custom property
            local urlOk, urlVal = pcall(function()
                local raw = player.URL_AP
                if raw == nil then return nil end
                if type(raw) == "string" then return raw end
                return raw:ToString()
            end)

            if urlOk and urlVal and type(urlVal) == "string" and urlVal ~= "" then
                if urlVal ~= M._lastPolledUrl then
                    M._lastPolledUrl = urlVal
                    Logging.LogInfo(string.format("[Goal] SequentialMediaPlayer_Secondary URL: %s", urlVal))
                    if urlVal:find("Ending_Ascension") then
                        M._FireGoal("Ascension", "URL_AP poll — " .. urlVal)
                        return
                    end
                end
                M._playersDumped = true
                return
            end

            M._playersDumped = true
            ::continue::
        end

        if not M._playersDumped then
            M._playersDumped = true
        end
    end)

    -- Secondary fallback: IsGameCompleted
    local completed = false
    pcall(function()
        local subsystem = FindFirstOf("TalosSaveSubsystem")
        if subsystem and subsystem:IsValid() then
            completed = subsystem:IsGameCompleted()
        end
    end)

    if completed and not previousGameCompleted then
        M._FireGoal("Unknown (polling fallback)", "TalosSaveSubsystem:IsGameCompleted")
    end
    previousGameCompleted = completed
    return false
end

-- ============================================================
-- Reset goal state (for new game / slot switch)
-- ============================================================
function M.ResetGoalState()
    M.GoalCompleted = false
    M.CompletedGoalName = nil
    Logging.LogInfo("Goal state reset")
end

return M
