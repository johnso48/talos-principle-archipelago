#pragma once

#include "ModState.h"
#include "ItemMapping.h"
#include "APClient.h"

#include <Unreal/UObject.hpp>

#include <string>
#include <unordered_map>
#include <vector>
#include <deque>
#include <functional>
#include <cstdint>

namespace TalosAP {

/// Manages tetromino actor visibility and proximity-based pickup detection.
///
/// On level load (NeedsTetrominoScan), discovers all BP_TetrominoItem_C actors
/// and builds a TrackedTetromino cache keyed by tetromino ID. Each tick, enforces
/// visibility rules (show collectable, hide non-granted checked) and detects
/// proximity-based pickups via player distance to cached item positions.
///
/// CRITICAL: Never caches UObject* across ticks. Every scan/refresh re-discovers
/// actors via FindAllOf. TrackedTetromino stores positional data but the actor
/// pointer is only valid during the scan tick.
class VisibilityManager {
public:
    /// Squared radius for proximity pickup detection (250 units ≈ 2.5m).
    static constexpr float PICKUP_RADIUS_SQ = 250.0f * 250.0f;

    /// Number of ticks to keep retrying SetVisible after game re-hides an item.
    /// Set at scan/refresh time. NOT reset during enforcement — allows the game's
    /// animation and collection systems to take over once our retries expire.
    static constexpr int VISIBILITY_RETRY_COUNT = 10;

    /// Per-tetromino tracking data. Positions are cached at scan time;
    /// actor pointers are NOT stored (stale pointer risk).
    struct TrackedTetromino {
        std::string id;             ///< e.g. "DJ1", "MT3"
        float x = 0.0f;            ///< World position X
        float y = 0.0f;            ///< World position Y
        float z = 0.0f;            ///< World position Z
        bool  reported = false;     ///< True if proximity pickup already sent
        int   visRetries = 0;       ///< Remaining retries to force visibility
        bool  hasPosition = false;  ///< Whether position was successfully read
    };

    /// Scan the current level for all BP_TetrominoItem_C actors.
    /// Builds the tracked tetromino cache and applies initial visibility.
    /// Call when NeedsTetrominoScan is true (after level transitions).
    void ScanLevel(ModState& state);

    /// Full visibility refresh: re-discovers actors, rebuilds cache,
    /// re-applies visibility. More expensive than EnforceVisibility.
    /// Call periodically (e.g. every ~180 ticks / 3 seconds).
    void RefreshVisibility(ModState& state);

    /// Per-tick visibility enforcement and proximity pickup detection.
    /// Uses the cached TrackedTetromino data. Lightweight.
    /// locationCheckCallback is called when a proximity pickup is detected,
    /// with the AP location ID as the argument.
    void EnforceVisibility(
        ModState& state,
        const ItemMapping& itemMapping,
        const std::function<void(int64_t)>& locationCheckCallback
    );

    /// Clear all cached data. Call on level transitions.
    void ResetCache();

    /// Get the number of tracked tetrominos.
    size_t GetTrackedCount() const { return m_tracked.size(); }

    /// Debug dump of tracked tetrominos to log.
    void DumpTracked() const;

    /// Open the puzzle exit fence for a tetromino (if one exists).
    /// Queues the open for retry processing.
    void OpenFenceForTetromino(const std::string& tetId);

    /// Process pending fence opens. Call every ~6 ticks from on_update.
    /// Retries each fence::Open() up to 10 times with ~100ms spacing.
    void ProcessPendingFenceOpens();

    /// Dump fence map to log.
    void DumpFenceMap() const;

private:
    /// Build tetromino ID from InstanceInfo property values.
    /// Returns empty string if invalid.
    static std::string FormatTetrominoId(uint8_t typeVal, uint8_t shapeVal, int32_t number);

    /// Type enum value → single letter.
    static char TypeToLetter(uint8_t type);

    /// Shape enum value → single letter.
    static char ShapeToLetter(uint8_t shape);

    /// Set an actor visible (show).
    static void SetActorVisible(RC::Unreal::UObject* actor);

    /// Set an actor hidden (hide).
    static void SetActorHidden(RC::Unreal::UObject* actor);

    /// Check if an actor is currently hidden.
    static bool IsActorHidden(RC::Unreal::UObject* actor);

    /// Read the InstanceInfo struct from a BP_TetrominoItem_C actor.
    /// Returns true and fills out type/shape/number on success.
    static bool ReadInstanceInfo(RC::Unreal::UObject* actor,
                                 uint8_t& outType, uint8_t& outShape, int32_t& outNumber);

    /// Read actor world position. Returns true on success.
    static bool ReadActorPosition(RC::Unreal::UObject* actor,
                                  float& outX, float& outY, float& outZ);

    /// Get the player's current position. Returns true on success.
    static bool GetPlayerPosition(float& outX, float& outY, float& outZ);

    /// Build the fence map from LoweringFenceWhenTetrominoIsPickedUpScript actors.
    /// Maps tetromino ID → index into m_fenceActorNames for re-lookup.
    void BuildFenceMap();

    /// Tracked tetrominos: keyed by tetromino ID (e.g. "DJ1").
    std::unordered_map<std::string, TrackedTetromino> m_tracked;

    // ---- Fence map: tetromino ID → fence actor full name ----
    // We store fence actor full-names (not raw UObject*) so we can
    // safely re-discover them each time we need to call Open().
    std::unordered_map<std::string, std::wstring> m_fenceMap;  // tetId → fence full name

    // ---- Pending fence opens (retry queue) ----
    struct PendingFenceOpen {
        std::string tetId;
        std::wstring fenceFullName;
        int attempts = 0;
    };
    std::deque<PendingFenceOpen> m_pendingFenceOpens;

    // ---- Cached UFunction* for ALoweringFence::Open() ----
    RC::Unreal::UFunction* m_fnFenceOpen = nullptr;
};

} // namespace TalosAP
