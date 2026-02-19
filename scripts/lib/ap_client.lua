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
local HUD     = require("lib.hud")

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

    -- Reset item counters and granted items for a clean replay.
    -- OnItemsReceived will replay all items from index 0 and rebuild grants.
    ItemMapping.ResetItemCounters()
    if Collection then
        Collection.GrantedItems = {}
    end

    -- Log player list
    local players = ap:get_players()
    if players then
        M.Players = players
        for _, player in ipairs(players) do
            Logging.LogDebug(string.format("AP: Player %d: %s (%s)",
                player.slot, player.name, ap:get_player_game(player.slot) or "?"))
        end
    end

    -- Log checked/missing locations from the server
    local serverChecked = ap.checked_locations or {}
    local serverMissing = ap.missing_locations or {}
    Logging.LogInfo(string.format("AP: %d checked, %d missing locations (from server)",
        #serverChecked, #serverMissing))

    -- Restore checked locations from the AP server.
    -- The server tracks which location IDs have been checked — this is
    -- the source of truth. Convert back to tetromino IDs.
    local restoredCount = 0
    for _, locId in ipairs(serverChecked) do
        local tetId = ItemMapping.GetLocationName(locId)
        if tetId then
            Collection.MarkLocationChecked(tetId)
            restoredCount = restoredCount + 1
        end
    end
    if restoredCount > 0 then
        Logging.LogInfo(string.format("AP: Restored %d checked locations from server", restoredCount))
    end

    -- Also send any locally-checked locations the server doesn't know about yet
    -- (e.g. picked up this session before reconnecting)
    local localChecked = Collection.GetCheckedLocations()
    if type(localChecked) == "table" then
        local toSend = {}
        -- Build a set of server-checked IDs for fast lookup
        local serverCheckedSet = {}
        for _, locId in ipairs(serverChecked) do
            serverCheckedSet[locId] = true
        end
        for _, tetId in ipairs(localChecked) do
            local locId = ItemMapping.GetLocationId(tetId)
            if locId and not serverCheckedSet[locId] then
                table.insert(toSend, locId)
            end
        end
        if #toSend > 0 then
            Logging.LogInfo(string.format("AP: Sending %d locally checked locations to server", #toSend))
            ap:LocationChecks(toSend)
        end
    end

    -- Mark as synced — items_received fires separately but we know the connection is live.
    Collection.APSynced = true
    Logging.LogInfo("AP: APSynced = true — enforcement is now enabled")

    -- Send playing status
    ap:StatusUpdate(20) -- CLIENT_PLAYING
end

local function OnSlotRefused(reasons)
    local msg = table.concat(reasons or {"unknown"}, ", ")
    Logging.LogError("AP: Connection refused: " .. msg)
    M.SlotConnected = false
end

--- Look up a player's display name by slot number.
--- Falls back to "Player <slot>" if not found.
local function GetPlayerName(slot)
    if not slot or slot == 0 then return "Server" end
    if ap then
        -- Try the ap library helper first
        local ok, name = pcall(function()
            return ap:get_player_alias(slot)
        end)
        if ok and name and name ~= "" then return name end
    end
    -- Fallback to cached player list
    if M.Players then
        for _, p in ipairs(M.Players) do
            if p.slot == slot then return p.name end
        end
    end
    return "Player " .. tostring(slot)
end

local function OnItemsReceived(items)
    if not items then return end

    Logging.LogInfo(string.format("AP: Received %d items", #items))

    local grantedCount = 0
    local unknownCount = 0
    for _, item in ipairs(items) do
        local tetId = ItemMapping.ResolveNextItem(item.item)
        if tetId then
            Logging.LogDebug(string.format("AP: Item received: %s (ap_id=%d from player %d)",
                tetId, item.item, item.player or 0))
            -- Grant individually (additive) — never wipe previous grants
            if GameState and Collection then
                Collection.GrantItem(GameState, tetId)
                grantedCount = grantedCount + 1
            end

            -- Show on-screen notification with colored segments
            local senderName = GetPlayerName(item.player)
            local isSelf = (item.player == M.PlayerSlot)
            if not isSelf then
                local displayName = ItemMapping.GetDisplayName(item.item) or tetId
                local flags = item.flags or 0
                local itemColor = HUD.COLORS.ITEM
                if flags & 4 ~= 0 then     itemColor = HUD.COLORS.TRAP
                elseif flags & 1 ~= 0 then itemColor = HUD.COLORS.PROGRESSION
                elseif flags & 2 ~= 0 then itemColor = HUD.COLORS.USEFUL
                end
                HUD.ShowMessage({
                    {text = senderName,    color = HUD.COLORS.PLAYER},
                    {text = " sent you ", color = HUD.COLORS.WHITE},
                    {text = displayName,   color = itemColor},
                })
            end
        else
            local prefix = ItemMapping.GetItemPrefix(item.item)
            if prefix then
                Logging.LogWarning(string.format("AP: %s item exhausted (ap_id=%d from player %d)",
                    prefix, item.item, item.player or 0))
            else
                Logging.LogWarning(string.format("AP: Unknown item id %d from player %d",
                    item.item, item.player or 0))
            end
            unknownCount = unknownCount + 1
        end
    end

    Logging.LogInfo(string.format("AP: Processed items — %d granted, %d skipped/unknown", grantedCount, unknownCount))

    -- Ensure APSynced is set
    if Collection then
        Collection.APSynced = true
    end
end

local function OnLocationChecked(locations)
    if not locations then return end
    Logging.LogDebug(string.format("AP: Server confirmed %d location checks", #locations))
end

--- Determine the HUD color for an item based on its classification flags.
local function ItemColorFromFlags(flags)
    flags = flags or 0
    if flags & 4 ~= 0 then return HUD.COLORS.TRAP end
    if flags & 1 ~= 0 then return HUD.COLORS.PROGRESSION end
    if flags & 2 ~= 0 then return HUD.COLORS.USEFUL end
    return HUD.COLORS.ITEM
end

--- Try to build an array of colored segments from the raw AP message parts.
--- Uses render_json on each individual part so the library resolves all IDs
--- (including cross-game items), while we determine the color from part type.
--- Returns nil on failure (caller should fall back to render_json on the whole msg).
local function BuildColoredSegments(msg)
    if type(msg) ~= "table" or #msg == 0 then return nil end

    local segs = {}
    for _, part in ipairs(msg) do
        local ptype = part.type or "text"
        local color = HUD.COLORS.WHITE

        -- Determine color from part type
        if ptype == "player_id" or ptype == "player_name" then
            color = HUD.COLORS.PLAYER
        elseif ptype == "item_id" or ptype == "item_name" then
            color = ItemColorFromFlags(part.flags)
        elseif ptype == "location_id" or ptype == "location_name" then
            color = HUD.COLORS.LOCATION
        elseif ptype == "entrance_name" then
            color = HUD.COLORS.ENTRANCE
        end

        -- Render this single part via the library so it resolves IDs properly
        local text = nil
        pcall(function()
            text = ap:render_json({part}, AP.RenderFormat.TEXT)
        end)

        -- Fallback: use the raw text field
        if not text or text == "" then
            text = tostring(part.text or "")
        end

        if text ~= "" then
            table.insert(segs, {text = text, color = color})
        end
    end

    return #segs > 0 and segs or nil
end

-- Deduplication: track recently shown messages to prevent spam.
-- Key = plain text, value = tickCount when it was last shown.
local recentMessages = {}
local DEDUP_WINDOW   = 5   -- seconds; ignore identical messages within this window

local function OnPrintJson(msg, extra)
    if not ap then return end

    -- Try colored segments from raw message parts
    local segments = nil
    pcall(function() segments = BuildColoredSegments(msg) end)

    -- Fallback: render as plain white text via the library
    if not segments then
        local text = ap:render_json(msg, AP.RenderFormat.TEXT)
        if text and text ~= "" then
            segments = { {text = text, color = HUD.COLORS.WHITE} }
        end
    end

    if segments then
        local plain = ""
        for _, s in ipairs(segments) do plain = plain .. s.text end

        -- Deduplicate: skip if we showed the exact same text recently
        local now = os.clock()
        local lastSeen = recentMessages[plain]
        if lastSeen and (now - lastSeen) < DEDUP_WINDOW then
            Logging.LogDebug("AP: Suppressed duplicate: " .. plain)
            return
        end
        recentMessages[plain] = now

        -- Periodic cleanup of the dedup cache (keep it small)
        local staleKeys = {}
        for k, t in pairs(recentMessages) do
            if (now - t) >= DEDUP_WINDOW * 2 then
                table.insert(staleKeys, k)
            end
        end
        for _, k in ipairs(staleKeys) do recentMessages[k] = nil end

        Logging.LogInfo("AP: " .. plain)
        HUD.ShowMessage(segments, 10000)
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
    -- Use ws:// for localhost and 127.0.0.1 addresses, wss:// otherwise
    if server and not server:match("^wss?://") then
        if server:match("^localhost") or server:match("^127%.0%.0%.1") then
            server = "ws://" .. server
        else
            server = "wss://" .. server
        end
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
