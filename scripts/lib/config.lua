-- ============================================================
-- Configuration loader
-- Reads config.json from the mod's scripts directory.
-- Falls back to defaults if the file is missing or malformed.
-- ============================================================

local Logging = require("lib.logging")

local M = {}

-- Defaults
M.server    = "archipelago.gg:38281"
M.slot_name = "Player1"
M.password  = ""
M.game      = "The Talos Principle Reawakened"
M.offline_mode = false

-- ============================================================
-- Minimal JSON parser (handles flat objects with string values)
-- ============================================================
local function parse_json_flat(str)
    local result = {}
    -- Match "key": "value" or "key": number patterns
    for key, value in str:gmatch('"([^"]+)"%s*:%s*"([^"]*)"') do
        result[key] = value
    end
    return result
end

-- ============================================================
-- Load config from file
-- ============================================================
function M.Load()
    -- Determine the scripts directory from the module path.
    -- debug.getinfo(1) gives us the path to THIS file (lib/config.lua),
    -- so we go up one level to reach the scripts/ directory where config.json lives.
    local scriptDir = nil
    pcall(function()
        local info = debug.getinfo(1, "S")
        if info and info.source then
            local src = info.source:gsub("^@", "")
            -- src is something like .../scripts/lib/config.lua
            -- First strip the filename to get .../scripts/lib
            local libDir = src:match("(.+)[/\\][^/\\]+$")
            -- Then strip "lib" to get .../scripts
            if libDir then
                scriptDir = libDir:match("(.+)[/\\][^/\\]+$")
            end
        end
    end)

    -- Build search paths: scripts dir first, then UE4SS working directory fallback
    local paths = {}
    if scriptDir then
        table.insert(paths, scriptDir .. "\\config.json")
        table.insert(paths, scriptDir .. "/config.json")
    end
    -- Fallback: try relative to UE4SS working dir (Talos1/Binaries/Win64)
    table.insert(paths, "Mods\\ArchipelagoMod\\scripts\\config.json")
    table.insert(paths, "config.json")

    local configContent = nil
    local configPath = nil

    for _, path in ipairs(paths) do
        local f = io.open(path, "r")
        if f then
            configContent = f:read("*a")
            f:close()
            configPath = path
            break
        end
    end

    if not configContent then
        Logging.LogWarning("config.json not found — using defaults. Create config.json with server/slot_name/password.")
        return M
    end

    local parsed = parse_json_flat(configContent)

    if parsed.server and parsed.server ~= "" then
        M.server = parsed.server
    end
    if parsed.slot_name and parsed.slot_name ~= "" then
        M.slot_name = parsed.slot_name
    end
    if parsed.password then
        M.password = parsed.password
    end
    if parsed.game and parsed.game ~= "" then
        M.game = parsed.game
    end
    if parsed.offline_mode then
        M.offline_mode = (parsed.offline_mode == "true" or parsed.offline_mode == "1")
    end

    Logging.LogInfo(string.format("Config loaded from %s", configPath))
    Logging.LogInfo(string.format("  server    = %s", M.server))
    Logging.LogInfo(string.format("  slot_name = %s", M.slot_name))
    Logging.LogInfo(string.format("  password  = %s", M.password ~= "" and "****" or "(none)"))
    Logging.LogInfo(string.format("  game      = %s", M.game))
    if M.offline_mode then
        Logging.LogInfo("  offline_mode = true (AP communication disabled)")
    end

    return M
end

return M
