-- ============================================================
-- Archipelago Client Module
--
-- Wraps lua-apclientpp to connect to an Archipelago server.
-- If the native DLL isn't present, falls back gracefully to
-- a disconnected state (local-only mode).
--
-- Usage:
--   local APClient = require("lib.ap_client")
--   APClient.Init(config, state, collection, itemMapping)
--   -- Then call APClient.Poll() every frame/tick
--   -- APClient.SendLocationCheck(tetrominoId) on pickup
-- ============================================================

local Logging = require("lib.logging")
local Config  = require("lib.config")

local M = {}

-- ============================================================
-- State
-- ============================================================
M.Connected     = false
M.SlotConnected = false
M.PlayerSlot    = nil
M.TeamNumber    = nil
M.SlotData      = nil
M.Players       = {}

-- External references (set via Init)
local GameState    = nil
local Collection   = nil
local ItemMapping  = nil

-- The native APClient object (nil if DLL not available)
local ap = nil

-- The native AP module (nil if DLL not available)
local AP = nil

-- Items handling flags: receive items from other worlds + own world + starting inv
local ITEMS_HANDLING = 7  -- 0b111

-- Track which items we've processed (index-based for sync)
local lastItemIndex = 0

-- Deferred connection: AP object must be created on the same Lua
-- coroutine state where poll() runs (UE4SS LoopAsync uses separate
-- coroutine states). We store the "want to connect" flag and do the
-- actual AP() constructor call inside the first Poll() invocation.
local pendingConnect = false

-- ============================================================
-- Try to load the native lua-apclientpp DLL
-- ============================================================
local function TryLoadNativeLib()
    local ok, lib = pcall(require, "lua-apclientpp")
    if ok and lib then
        Logging.LogInfo("lua-apclientpp native library loaded successfully")
        return lib
    else
        Logging.LogWarning("lua-apclientpp not available: " .. tostring(lib))
        Logging.LogWarning("To enable Archipelago connectivity:")
        Logging.LogWarning("  1. Download lua-apclientpp v0.6.4+ for Lua 5.4 Win64")
        Logging.LogWarning("     from: https://github.com/black-sliver/lua-apclientpp/releases")
        Logging.LogWarning("  2. Place lua-apclientpp.dll in the scripts/ folder")
        Logging.LogWarning("     (next to main.lua)")
        Logging.LogWarning("Running in LOCAL-ONLY mode (no multiworld sync)")
        return nil
    end
end

-- ============================================================
-- Handlers for AP server events
-- ============================================================

local function OnSocketConnected()
    Logging.LogInfo("AP: Socket connected to server")
    M.Connected = true
end

local function OnSocketError(msg)
    Logging.LogError("AP: Socket error: " .. tostring(msg))
end

local function OnSocketDisconnected()
    Logging.LogWarning("AP: Socket disconnected")
    M.Connected = false
    M.SlotConnected = false
end

local function OnRoomInfo()
    Logging.LogInfo("AP: Room info received, connecting slot...")
    if ap then
        ap:ConnectSlot(
            Config.slot_name,
            Config.password,
            ITEMS_HANDLING,
            {"Lua-APClientPP"},
            {0, 5, 1}  -- protocol version
        )
    end
end

local function OnSlotConnected(slot_data)
    M.SlotConnected = true
    M.SlotData = slot_data
    M.PlayerSlot = ap:get_player_number()
    M.TeamNumber = ap:get_team_number()

    Logging.LogInfo(string.format("AP: Slot connected! player=%d team=%d",
        M.PlayerSlot or -1, M.TeamNumber or -1))

    -- Log player list
    local players = ap:get_players()
    if players then
        M.Players = players
        for _, player in ipairs(players) do
            Logging.LogDebug(string.format("AP: Player %d: %s (%s)",
                player.slot, player.name, ap:get_player_game(player.slot) or "?"))
        end
    end

    -- Log checked/missing locations
    local checked = ap.checked_locations or {}
    local missing = ap.missing_locations or {}
    Logging.LogInfo(string.format("AP: %d checked, %d missing locations",
        #checked, #missing))

    -- Sync: send all locations we've already checked locally
    local localChecked = Collection.GetCheckedLocations()
    if #localChecked > 0 then
        local locationIds = {}
        for _, tetId in ipairs(localChecked) do
            local locId = ItemMapping.GetLocationId(tetId)
            if locId then
                table.insert(locationIds, locId)
            end
        end
        if #locationIds > 0 then
            Logging.LogInfo(string.format("AP: Sending %d locally checked locations to server", #locationIds))
            ap:LocationChecks(locationIds)
        end
    end

    -- Send playing status
    ap:StatusUpdate(20) -- CLIENT_PLAYING
end

local function OnSlotRefused(reasons)
    local msg = table.concat(reasons or {"unknown"}, ", ")
    Logging.LogError("AP: Connection refused: " .. msg)
    M.SlotConnected = false
end

local function OnItemsReceived(items)
    if not items then return end

    Logging.LogInfo(string.format("AP: Received %d items", #items))

    for _, item in ipairs(items) do
        local tetId = ItemMapping.GetItemName(item.item)
        if tetId then
            Logging.LogInfo(string.format("AP: Item received: %s (id=%d from player %d)",
                tetId, item.item, item.player or 0))
            -- Grant individually (additive) — never wipe previous grants
            if GameState and Collection then
                Collection.GrantItem(GameState, tetId)
            end
        else
            Logging.LogWarning(string.format("AP: Unknown item id %d from player %d",
                item.item, item.player or 0))
        end
    end
end

local function OnLocationChecked(locations)
    if not locations then return end
    Logging.LogDebug(string.format("AP: Server confirmed %d location checks", #locations))
end

local function OnPrintJson(msg, extra)
    if ap then
        local text = ap:render_json(msg, AP.RenderFormat.TEXT)
        if text and text ~= "" then
            Logging.LogInfo("AP: " .. text)
        end
    end
end

local function OnBounced(bounce)
    -- Handle DeathLink or other bounced messages
    if bounce and bounce.tags then
        for _, tag in ipairs(bounce.tags) do
            if tag == "DeathLink" then
                Logging.LogInfo("AP: DeathLink received from " .. tostring(bounce.data and bounce.data.source or "?"))
                -- TODO: Handle DeathLink (kill the player)
            end
        end
    end
end

-- ============================================================
-- Public API
-- ============================================================

--- Initialize the AP client.
--- @param config table The config module (with server, slot_name, etc.)
--- @param state table The shared game state
--- @param collection table The collection module
--- @param itemMapping table The item_mapping module
function M.Init(config, state, collection, itemMapping)
    GameState   = state
    Collection  = collection
    ItemMapping = itemMapping

    -- Update Config reference
    Config = config

    -- Try to load native lib
    AP = TryLoadNativeLib()
    if not AP then
        return false
    end

    return true
end

--- Connect to the AP server. Call after Init.
--- NOTE: The actual connection is deferred to the first Poll() call
--- so the AP object is created on the same Lua coroutine state.
function M.Connect()
    if not AP then
        Logging.LogWarning("AP: Cannot connect — native library not loaded")
        return false
    end

    local server = Config.server
    if not server or server == "" then
        Logging.LogWarning("AP: No server configured in config.json")
        return false
    end

    Logging.LogInfo(string.format("AP: Will connect to %s as '%s' (deferred to poll coroutine)", server, Config.slot_name))
    pendingConnect = true
    return true
end

--- Internal: actually create the AP object and register handlers.
--- Must be called from the same Lua state that will call poll().
local function DoConnect()
    pendingConnect = false

    local server = Config.server
    -- Ensure the server address has a WebSocket scheme prefix
    -- lua-apclientpp requires ws:// (or wss://) in the URI
    if server and not server:match("^wss?://") then
        server = "ws://" .. server
    end
    Logging.LogInfo(string.format("AP: Creating AP client on poll coroutine for %s...", server))

    local uuid = "" -- lua-apclientpp doesn't require UUID
    local ok, result = pcall(function()
        return AP(uuid, Config.game, server)
    end)

    if not ok then
        Logging.LogError("AP: Failed to create client: " .. tostring(result))
        return false
    end

    ap = result

    -- Register all handlers
    ap:set_socket_connected_handler(OnSocketConnected)
    ap:set_socket_error_handler(OnSocketError)
    ap:set_socket_disconnected_handler(OnSocketDisconnected)
    ap:set_room_info_handler(OnRoomInfo)
    ap:set_slot_connected_handler(OnSlotConnected)
    ap:set_slot_refused_handler(OnSlotRefused)
    ap:set_items_received_handler(OnItemsReceived)
    ap:set_location_checked_handler(OnLocationChecked)
    ap:set_print_json_handler(OnPrintJson)
    ap:set_bounced_handler(OnBounced)

    Logging.LogInfo("AP: Client created and handlers registered")
    return true
end

--- Poll the AP client. Call this every tick (~100ms or faster).
--- On the first call after Connect(), this creates the AP object
--- on the current coroutine state to avoid state mismatch errors.
function M.Poll()
    -- Deferred creation: build the AP object on THIS coroutine
    if pendingConnect then
        DoConnect()
    end

    if ap then
        local ok, err = pcall(function()
            ap:poll()
        end)
        if not ok then
            Logging.LogError("AP: Poll error: " .. tostring(err))
        end
    end
end

--- Send a location check to the server when the player picks up an item.
--- @param tetrominoId string The tetromino ID (e.g. "DJ3")
function M.SendLocationCheck(tetrominoId)
    local locId = ItemMapping.GetLocationId(tetrominoId)
    if not locId then
        Logging.LogWarning(string.format("AP: No location ID mapping for '%s'", tetrominoId))
        return false
    end

    if ap and M.SlotConnected then
        Logging.LogInfo(string.format("AP: Sending location check: %s (id=%d)", tetrominoId, locId))
        ap:LocationChecks({locId})
        return true
    else
        Logging.LogDebug(string.format("AP: Queued location check (offline): %s", tetrominoId))
        return false
    end
end

--- Send goal completion status to the server.
function M.SendGoalComplete()
    if ap and M.SlotConnected then
        Logging.LogInfo("AP: Sending goal completion!")
        ap:StatusUpdate(30) -- CLIENT_GOAL
        return true
    end
    return false
end

--- Send a chat message.
--- @param text string The message to send
function M.Say(text)
    if ap and M.SlotConnected then
        ap:Say(text)
    end
end

--- Disconnect from the server.
function M.Disconnect()
    pendingConnect = false
    if ap then
        Logging.LogInfo("AP: Disconnecting...")
        ap = nil
        collectgarbage("collect")
        M.Connected = false
        M.SlotConnected = false
    end
end

--- Check if the native library is available.
function M.IsAvailable()
    return AP ~= nil
end

--- Check if fully connected and authenticated.
function M.IsConnected()
    return M.SlotConnected
end

--- Get connection status string for display.
function M.GetStatusString()
    if not AP then
        return "LOCAL MODE (no lua-apclientpp.dll)"
    elseif M.SlotConnected then
        return string.format("Connected to %s as %s", Config.server, Config.slot_name)
    elseif M.Connected then
        return "Authenticating..."
    else
        return "Disconnected"
    end
end

return M
