#include "headers/ItemMapping.h"

#include <algorithm>
#include <regex>
#include <DynamicOutput/DynamicOutput.hpp>

using namespace RC;

namespace TalosAP {

// ============================================================
// All tetrominoes in the game (from BotPuzzleDatabase.csv)
// Order matters — location IDs are assigned sequentially.
// ============================================================
static const std::vector<std::string> ALL_TETROMINOES = {
    // World A1 (7)
    "DJ3",  "MT1",  "DZ1",  "DJ2",  "DJ1",  "ML1",  "DI1",
    // World A2 (3)
    "ML2",  "DL1",  "DZ2",
    // World A3 (4)
    "MT2",  "DZ3",  "NL1",  "MT3",
    // World A4 (4)
    "MZ1",  "MZ2",  "MT4",  "MT5",
    // World A5 (5)
    "NZ1",  "DI2",  "DT1",  "DT2",  "DL2",
    // World A6 (4)
    "DZ4",  "NL2",  "NL3",  "NZ2",
    // World A7 (5)
    "NL4",  "DL3",  "NT1",  "NO1",  "DT3",
    // World B1 (5)
    "ML3",  "MZ3",  "MS1",  "MT6",  "MT7",
    // World B2 (4)
    "NL5",  "MS2",  "MT8",  "MZ4",
    // World B3 (4)
    "MT9",  "MJ1",  "NT2",  "NL6",
    // World B4 (6)
    "NT3",  "NT4",  "DT4",  "DJ4",  "NL7",  "NL8",
    // World B5 (5)
    "NI1",  "NL9",  "NS1",  "DJ5",  "NZ3",
    // World B6 (3)
    "NI2",  "MT10", "ML4",
    // World B7 (4)
    "NJ1",  "NI3",  "MO1",  "MI1",
    // World C1 (4)
    "NZ4",  "NJ2",  "NI4",  "NT5",
    // World C2 (4)
    "NZ5",  "NO2",  "NT6",  "NS2",
    // World C3 (4)
    "NJ3",  "NO3",  "NZ6",  "NT7",
    // World C4 (4)
    "NT8",  "NI5",  "NS3",  "NT9",
    // World C5 (4)
    "NI6",  "NO4",  "NO5",  "NT10",
    // World C6 (3)
    "NS4",  "NJ4",  "NO6",
    // World C7 (4)
    "NT11", "NO7",  "NT12", "NL10",
};

// ============================================================
// Stars (puzzle code → star ID)
// ============================================================
struct StarEntry {
    std::string puzzleCode;
    std::string starId;
};

static const std::vector<StarEntry> ALL_STARS = {
    {"SCentralArea_Chapter", "Star5"},
    {"SCloud_1_02",          "Star2"},
    {"S015",                 "Star1"},
    {"SCloud_1_03",          "Star3"},
    {"S202b",                "Star4"},
    {"S201",                 "Star7"},
    {"S244",                 "Star6"},
    {"SCloud_1_06",          "Star8"},
    {"S209",                 "Star9"},
    {"S205",                 "Star10"},
    {"S213",                 "Star11"},
    {"S300a",                "Star12"},
    {"SCloud_2_04",          "Star24"},
    {"S215",                 "Star13"},
    {"SCloud_2_05",          "Star14"},
    {"S301",                 "Star16"},
    {"SCloud_2_07",          "Star15"},
    {"SCloud_3_01",          "Star17"},
    {"SIslands_01",          "Star26"},
    {"SLevel05_Elevator",    "Star25"},
    {"S403",                 "Star18"},
    {"S318",                 "Star19"},
    {"S408",                 "Star21"},
    {"S405",                 "Star20"},
    {"S328",                 "Star23"},
    {"S404",                 "Star27"},
    {"S309",                 "Star22"},
    {"SNexus",               "Star28"},
    {"S234",                 "Star29"},
    {"S308",                 "Star30"},
};

// ============================================================
// Extract the letter prefix from a tetromino ID (e.g. "DJ3" → "DJ")
// ============================================================
static std::string ExtractPrefix(const std::string& tetId)
{
    size_t i = 0;
    while (i < tetId.size() && std::isalpha(static_cast<unsigned char>(tetId[i]))) {
        ++i;
    }
    return tetId.substr(0, i);
}

// Extract the numeric suffix from a tetromino ID (e.g. "DJ3" → 3)
static int ExtractNumber(const std::string& tetId)
{
    size_t i = 0;
    while (i < tetId.size() && std::isalpha(static_cast<unsigned char>(tetId[i]))) {
        ++i;
    }
    if (i < tetId.size()) {
        return std::stoi(tetId.substr(i));
    }
    return 0;
}

// ============================================================
// Construction
// ============================================================
ItemMapping::ItemMapping()
{
    // AP item ID → prefix (19 types)
    m_apItemIdToPrefix = {
        {0x540000, "DJ"},  // Green J
        {0x540001, "DZ"},  // Green Z
        {0x540002, "DI"},  // Green I
        {0x540003, "DL"},  // Green L
        {0x540004, "DT"},  // Green T
        {0x540005, "MT"},  // Golden T
        {0x540006, "ML"},  // Golden L
        {0x540007, "MZ"},  // Golden Z
        {0x540008, "MS"},  // Golden S
        {0x540009, "MJ"},  // Golden J
        {0x54000A, "MO"},  // Golden O
        {0x54000B, "MI"},  // Golden I
        {0x54000C, "NL"},  // Red L
        {0x54000D, "NZ"},  // Red Z
        {0x54000E, "NT"},  // Red T
        {0x54000F, "NI"},  // Red I
        {0x540010, "NJ"},  // Red J
        {0x540011, "NO"},  // Red O
        {0x540012, "NS"},  // Red S
    };

    // Display names
    m_prefixDisplayNames = {
        {"DJ", "Green J"},  {"DZ", "Green Z"},  {"DI", "Green I"},
        {"DL", "Green L"},  {"DT", "Green T"},
        {"MT", "Golden T"}, {"ML", "Golden L"}, {"MZ", "Golden Z"},
        {"MS", "Golden S"}, {"MJ", "Golden J"}, {"MO", "Golden O"},
        {"MI", "Golden I"},
        {"NL", "Red L"},    {"NZ", "Red Z"},    {"NT", "Red T"},
        {"NI", "Red I"},    {"NJ", "Red J"},    {"NO", "Red O"},
        {"NS", "Red S"},
    };

    BuildTables();
}

void ItemMapping::BuildSequences()
{
    m_tetrominoSequences.clear();

    for (const auto& tetId : ALL_TETROMINOES) {
        std::string prefix = ExtractPrefix(tetId);
        if (!prefix.empty()) {
            m_tetrominoSequences[prefix].push_back(tetId);
        }
    }

    // Sort each sequence by embedded number
    for (auto& [prefix, seq] : m_tetrominoSequences) {
        std::sort(seq.begin(), seq.end(), [](const std::string& a, const std::string& b) {
            return ExtractNumber(a) < ExtractNumber(b);
        });
    }
}

void ItemMapping::BuildTables()
{
    BuildSequences();

    int64_t idx = 0;

    // Tetromino locations (sequential IDs)
    for (const auto& tetId : ALL_TETROMINOES) {
        int64_t locId = BASE_LOCATION_ID + idx;
        m_locationNameToId[tetId] = locId;
        m_locationIdToName[locId] = tetId;
        ++idx;
    }

    // Star locations (continue sequential IDs after tetrominoes)
    for (const auto& entry : ALL_STARS) {
        int64_t locId = BASE_LOCATION_ID + idx;
        m_locationNameToId[entry.starId] = locId;
        m_locationIdToName[locId] = entry.starId;
        ++idx;
    }

    Output::send<LogLevel::Verbose>(STR("[TalosAP] Mappings built: {} locations, {} item types\n"),
                                    idx, m_apItemIdToPrefix.size());
}

// ============================================================
// Item resolution
// ============================================================

std::optional<std::string> ItemMapping::ResolveNextItem(int64_t apItemId)
{
    auto it = m_apItemIdToPrefix.find(apItemId);
    if (it == m_apItemIdToPrefix.end()) {
        Output::send<LogLevel::Warning>(STR("[TalosAP] Unknown AP item ID: {} (0x{:X})\n"),
                                        apItemId, apItemId);
        return std::nullopt;
    }

    const std::string& prefix = it->second;
    auto seqIt = m_tetrominoSequences.find(prefix);
    if (seqIt == m_tetrominoSequences.end() || seqIt->second.empty()) {
        Output::send<LogLevel::Warning>(STR("[TalosAP] No tetromino sequence for prefix: {}\n"),
                                        std::wstring(prefix.begin(), prefix.end()));
        return std::nullopt;
    }

    const auto& seq = seqIt->second;
    int& count = m_receivedCounts[prefix];
    ++count;

    if (count > static_cast<int>(seq.size())) {
        Output::send<LogLevel::Warning>(STR("[TalosAP] Received more {} items ({}) than exist ({}) — ignoring\n"),
                                        std::wstring(prefix.begin(), prefix.end()),
                                        count, seq.size());
        return std::nullopt;
    }

    const std::string& tetId = seq[count - 1];
    Output::send<LogLevel::Verbose>(STR("[TalosAP] Resolved AP item {} (0x{:X}) -> {} [{} {}/{}]\n"),
                                    apItemId, apItemId,
                                    std::wstring(tetId.begin(), tetId.end()),
                                    std::wstring(prefix.begin(), prefix.end()),
                                    count, seq.size());
    return tetId;
}

void ItemMapping::ResetItemCounters()
{
    m_receivedCounts.clear();
    Output::send<LogLevel::Verbose>(STR("[TalosAP] Item received counters reset\n"));
}

// ============================================================
// Location queries
// ============================================================

int64_t ItemMapping::GetLocationId(const std::string& tetrominoId) const
{
    auto it = m_locationNameToId.find(tetrominoId);
    return (it != m_locationNameToId.end()) ? it->second : -1;
}

std::string ItemMapping::GetLocationName(int64_t locationId) const
{
    auto it = m_locationIdToName.find(locationId);
    return (it != m_locationIdToName.end()) ? it->second : "";
}

std::string ItemMapping::GetDisplayName(int64_t apItemId) const
{
    auto it = m_apItemIdToPrefix.find(apItemId);
    if (it == m_apItemIdToPrefix.end()) return "";
    auto nameIt = m_prefixDisplayNames.find(it->second);
    return (nameIt != m_prefixDisplayNames.end()) ? nameIt->second : "";
}

std::string ItemMapping::GetDisplayNameForTetromino(const std::string& tetrominoId) const
{
    std::string prefix = ExtractPrefix(tetrominoId);
    auto nameIt = m_prefixDisplayNames.find(prefix);
    return (nameIt != m_prefixDisplayNames.end()) ? nameIt->second : "";
}

std::string ItemMapping::GetItemPrefix(int64_t apItemId) const
{
    auto it = m_apItemIdToPrefix.find(apItemId);
    return (it != m_apItemIdToPrefix.end()) ? it->second : "";
}

std::vector<int64_t> ItemMapping::GetAllLocationIds() const
{
    std::vector<int64_t> ids;
    ids.reserve(m_locationIdToName.size());
    for (const auto& [id, name] : m_locationIdToName) {
        ids.push_back(id);
    }
    std::sort(ids.begin(), ids.end());
    return ids;
}

std::vector<int64_t> ItemMapping::GetAllItemIds() const
{
    std::vector<int64_t> ids;
    ids.reserve(m_apItemIdToPrefix.size());
    for (const auto& [id, prefix] : m_apItemIdToPrefix) {
        ids.push_back(id);
    }
    std::sort(ids.begin(), ids.end());
    return ids;
}

} // namespace TalosAP
