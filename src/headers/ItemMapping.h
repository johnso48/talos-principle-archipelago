#pragma once

#include <string>
#include <vector>
#include <unordered_map>
#include <cstdint>
#include <optional>

namespace TalosAP {

/// Maps between Archipelago item/location IDs and in-game tetromino IDs.
///
/// AP uses 19 item types (one per shape+color combo). Each type maps to a
/// prefix (e.g. "DJ" = Green J). When duplicates are received, they resolve
/// to the next tetromino in sequence (DJ1, DJ2, DJ3...).
///
/// Locations are 1:1 with physical tetrominos and stars in the game world.
class ItemMapping {
public:
    static constexpr int64_t BASE_ITEM_ID     = 0x540000; // 5505024
    static constexpr int64_t BASE_LOCATION_ID = 0x540000; // 5505024

    ItemMapping();

    /// Resolve the next concrete tetromino for a received AP item.
    /// Increments per-prefix counter. Returns empty if exhausted/unknown.
    std::optional<std::string> ResolveNextItem(int64_t apItemId);

    /// Reset received-item counters. Must be called on (re)connect before
    /// the AP server replays all received items.
    void ResetItemCounters();

    /// Get the AP location ID for a tetromino ID. Returns -1 if unknown.
    int64_t GetLocationId(const std::string& tetrominoId) const;

    /// Get the tetromino ID for an AP location ID. Returns empty if unknown.
    std::string GetLocationName(int64_t locationId) const;

    /// Get the human-readable display name for an AP item ID (e.g. "Green J").
    std::string GetDisplayName(int64_t apItemId) const;

    /// Get the display name for a tetromino ID string (e.g. "DJ3" → "Green J").
    std::string GetDisplayNameForTetromino(const std::string& tetrominoId) const;

    /// Get the shape+color prefix for an AP item ID (e.g. 0x540000 → "DJ").
    std::string GetItemPrefix(int64_t apItemId) const;

    /// Get all location IDs as a sorted vector.
    std::vector<int64_t> GetAllLocationIds() const;

    /// Get all 19 AP item type IDs.
    std::vector<int64_t> GetAllItemIds() const;

private:
    /// AP item ID → prefix (e.g. 0x540000 → "DJ")
    std::unordered_map<int64_t, std::string> m_apItemIdToPrefix;

    /// Prefix → display name (e.g. "DJ" → "Green J")
    std::unordered_map<std::string, std::string> m_prefixDisplayNames;

    /// Prefix → ordered sequence of tetromino IDs (e.g. "DJ" → {"DJ1","DJ2","DJ3","DJ4","DJ5"})
    std::unordered_map<std::string, std::vector<std::string>> m_tetrominoSequences;

    /// Tetromino/star ID → AP location ID
    std::unordered_map<std::string, int64_t> m_locationNameToId;

    /// AP location ID → tetromino/star ID
    std::unordered_map<int64_t, std::string> m_locationIdToName;

    /// Per-prefix received count (how many of each type AP has sent)
    std::unordered_map<std::string, int> m_receivedCounts;

    void BuildTables();
    void BuildSequences();
};

} // namespace TalosAP
