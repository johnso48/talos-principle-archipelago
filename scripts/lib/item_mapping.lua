-- ============================================================
-- Archipelago Item & Location ID Mappings
--
-- Items: The AP server uses 19 item IDs, one per shape+color
-- combination. When a duplicate is received, we grant the next
-- tetromino in sequence for that shape+color.
--   Golden = M{shape}{n}   Green = D{shape}{n}   Red = N{shape}{n}
--
-- Locations: Each physical tetromino / star is still its own
-- location with a unique sequential AP location ID.
--
-- NOTE: These IDs must match the AP world definition for
-- "The Talos Principle Reawakened".
-- ============================================================

local Logging = require("lib.logging")

local M = {}

-- ============================================================
-- Base ID offsets (must match AP world definition)
-- AP convention: each game gets a range. These are placeholders.
-- ============================================================
M.BASE_ITEM_ID     = 0x540000  -- 5505024
M.BASE_LOCATION_ID = 0x540000  -- 5505024

-- ============================================================
-- AP Item IDs → Shape+Color prefix
-- The AP server sends one of 19 item types. Each type maps to a
-- prefix (colour+shape). Multiple copies grant sequential pieces.
-- ============================================================
local AP_ITEM_IDS = {
    [0x540000] = "DJ",  -- Green J
    [0x540001] = "DZ",  -- Green Z
    [0x540002] = "DI",  -- Green I
    [0x540003] = "DL",  -- Green L
    [0x540004] = "DT",  -- Green T
    [0x540005] = "MT",  -- Golden T
    [0x540006] = "ML",  -- Golden L
    [0x540007] = "MZ",  -- Golden Z
    [0x540008] = "MS",  -- Golden S
    [0x540009] = "MJ",  -- Golden J
    [0x54000A] = "MO",  -- Golden O
    [0x54000B] = "MI",  -- Golden I
    [0x54000C] = "NL",  -- Red L
    [0x54000D] = "NZ",  -- Red Z
    [0x54000E] = "NT",  -- Red T
    [0x54000F] = "NI",  -- Red I
    [0x540010] = "NJ",  -- Red J
    [0x540011] = "NO",  -- Red O
    [0x540012] = "NS",  -- Red S
}

-- ============================================================
-- All tetrominoes in the game (from BotPuzzleDatabase.csv)
-- ============================================================
local ALL_TETROMINOES = {
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
    "NT11", "NO7",  "NT12", "NL10",
}

-- ============================================================
-- Stars (collectible stars, mapped separately)
-- Format: ** followed by number from BotPuzzleDatabase.csv
-- We map these as additional items/locations
-- ============================================================
local ALL_STARS = {
    { "SCentralArea_Chapter", "Star5"  },
    { "SCloud_1_02",          "Star2"  },
    { "S015",                 "Star1"  },
    { "SCloud_1_03",          "Star3"  },
    { "S202b",                "Star4"  },
    { "S201",                 "Star7"  },
    { "S244",                 "Star6"  },
    { "SCloud_1_06",          "Star8"  },
    { "S209",                 "Star9"  },
    { "S205",                 "Star10" },
    { "S213",                 "Star11" },
    { "S300a",                "Star12" },
    { "SCloud_2_04",          "Star24" },
    { "S215",                 "Star13" },
    { "SCloud_2_05",          "Star14" },
    { "S301",                 "Star16" },
    { "SCloud_2_07",          "Star15" },
    { "SCloud_3_01",          "Star17" },
    { "SIslands_01",          "Star26" },
    { "SLevel05_Elevator",    "Star25" },
    { "S403",                 "Star18" },
    { "S318",                 "Star19" },
    { "S408",                 "Star21" },
    { "S405",                 "Star20" },
    { "S328",                 "Star23" },
    { "S404",                 "Star27" },
    { "S309",                 "Star22" },
    { "SNexus",               "Star28" },
    { "S234",                 "Star29" },
    { "S308",                 "Star30" },
}

-- ============================================================
-- Tetromino sequences by prefix
-- Built dynamically from ALL_TETROMINOES, sorted numerically.
-- e.g. TETROMINO_SEQUENCES["DJ"] = {"DJ1", "DJ2", "DJ3", "DJ4", "DJ5"}
-- ============================================================
local TETROMINO_SEQUENCES = {}

-- Counter tracking: how many of each prefix have been received from AP
local ReceivedCounts = {}

-- ============================================================
-- Build lookup tables
-- ============================================================

-- tetrominoId -> AP location ID
M.LocationNameToId = {}
-- AP location ID -> tetrominoId
M.LocationIdToName = {}
-- puzzleCode -> starId
M.PuzzleToTetromino = {}

local function BuildSequences()
    TETROMINO_SEQUENCES = {}
    for _, tetId in ipairs(ALL_TETROMINOES) do
        local prefix = tetId:match("^(%a+)%d+$")
        if prefix then
            if not TETROMINO_SEQUENCES[prefix] then
                TETROMINO_SEQUENCES[prefix] = {}
            end
            table.insert(TETROMINO_SEQUENCES[prefix], tetId)
        end
    end
    -- Sort each sequence by embedded number
    for prefix, seq in pairs(TETROMINO_SEQUENCES) do
        table.sort(seq, function(a, b)
            return tonumber(a:match("%d+$")) < tonumber(b:match("%d+$"))
        end)
    end
    -- Log sequences
    for prefix, seq in pairs(TETROMINO_SEQUENCES) do
        Logging.LogDebug(string.format("Tetromino sequence %s (%d): %s",
            prefix, #seq, table.concat(seq, ", ")))
    end
end

local function BuildTables()
    local idx = 0

    -- Build tetromino sequences for item resolution
    BuildSequences()

    -- Locations: each tetromino is a unique location
    for _, tetId in ipairs(ALL_TETROMINOES) do
        local locId = M.BASE_LOCATION_ID + idx
        M.LocationNameToId[tetId] = locId
        M.LocationIdToName[locId] = tetId
        idx = idx + 1
    end

    -- Stars: also unique locations
    for _, entry in ipairs(ALL_STARS) do
        local puzzleCode = entry[1]
        local starId = entry[2]
        local locId = M.BASE_LOCATION_ID + idx
        M.LocationNameToId[starId] = locId
        M.LocationIdToName[locId]  = starId
        M.PuzzleToTetromino[puzzleCode] = starId
        idx = idx + 1
    end

    local seqCount = 0
    for _ in pairs(TETROMINO_SEQUENCES) do seqCount = seqCount + 1 end
    Logging.LogInfo(string.format("Mappings built: %d locations, %d item types (sequences)",
        idx, seqCount))
end

-- ============================================================
-- Item resolution (AP item ID → concrete tetromino)
-- ============================================================

--- Get the shape+color prefix for an AP item ID.
--- @param apItemId number The AP item ID
--- @return string|nil The prefix (e.g. "DJ", "MT") or nil if unknown
function M.GetItemPrefix(apItemId)
    return AP_ITEM_IDS[apItemId]
end

--- Resolve the next concrete tetromino for a received AP item.
--- Increments the internal counter for the shape+color and returns
--- the next tetromino in sequence (e.g. "DJ1", then "DJ2", ...).
--- @param apItemId number The AP item ID
--- @return string|nil The concrete tetromino ID, or nil if exhausted/unknown
function M.ResolveNextItem(apItemId)
    local prefix = AP_ITEM_IDS[apItemId]
    if not prefix then
        Logging.LogWarn(string.format("Unknown AP item ID: %d (0x%X)", apItemId, apItemId))
        return nil
    end

    local seq = TETROMINO_SEQUENCES[prefix]
    if not seq or #seq == 0 then
        Logging.LogWarn(string.format("No tetromino sequence for prefix: %s", prefix))
        return nil
    end

    -- Increment counter for this prefix
    ReceivedCounts[prefix] = (ReceivedCounts[prefix] or 0) + 1
    local count = ReceivedCounts[prefix]

    if count > #seq then
        Logging.LogWarn(string.format("Received more %s items (%d) than exist (%d) — ignoring",
            prefix, count, #seq))
        return nil
    end

    local tetId = seq[count]
    Logging.LogInfo(string.format("Resolved AP item %d (0x%X) -> %s [%s %d/%d]",
        apItemId, apItemId, tetId, prefix, count, #seq))
    return tetId
end

--- Reset received-item counters. Must be called on (re)connect before
--- the AP server replays all received items.
function M.ResetItemCounters()
    ReceivedCounts = {}
    Logging.LogInfo("Item received counters reset")
end

-- ============================================================
-- Query helpers (locations)
-- ============================================================

function M.GetLocationId(tetrominoId)
    return M.LocationNameToId[tetrominoId]
end

function M.GetLocationName(apLocationId)
    return M.LocationIdToName[apLocationId]
end

-- Get all location IDs as a flat list
function M.GetAllLocationIds()
    local ids = {}
    for id, _ in pairs(M.LocationIdToName) do
        table.insert(ids, id)
    end
    table.sort(ids)
    return ids
end

-- Get all AP item IDs (the 19 shape+color types)
function M.GetAllItemIds()
    local ids = {}
    for id, _ in pairs(AP_ITEM_IDS) do
        table.insert(ids, id)
    end
    table.sort(ids)
    return ids
end

-- Initialize
BuildTables()

return M
