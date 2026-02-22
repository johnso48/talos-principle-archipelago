#pragma once

#include <Unreal/UObject.hpp>
#include <unordered_map>
#include <unordered_set>
#include <string>
#include <mutex>
#include <atomic>

namespace TalosAP {

/// Shared mod state, accessible from all modules.
/// All UObject pointers MUST be validated with IsValid() before use.
/// Nulled on level transitions via ResetForLevelTransition().
struct ModState {
    /// The active UTalosProgress object. Holds CollectedTetrominos TMap.
    /// Re-acquired after each level load via FindProgressObject().
    RC::Unreal::UObject* CurrentProgress = nullptr;

    /// Level transition cooldown (in ticks). While > 0, enforcement
    /// and UObject access are skipped to avoid stale pointer crashes.
    int LevelTransitionCooldown = 30;

    /// Items granted by the AP server (tetromino ID → true).
    /// Source of truth for what should be in the CollectedTetrominos TMap.
    std::unordered_set<std::string> GrantedItems;

    /// Locations physically picked up this session (tetromino ID → true).
    /// Items here stay hidden so the player doesn't see respawn spam.
    std::unordered_set<std::string> CheckedLocations;

    /// Whether Archipelago has synced items at least once this session.
    /// EnforceCollectionState is BLOCKED until this is true.
    bool APSynced = false;

    /// When true, tetrominos are reusable: enforcement resets the "used"
    /// TMap boolean so pieces can be placed into arrangers again.
    bool ReusableTetrominos = false;

    /// Deferred flags — set by hooks, processed by the update loop.
    bool NeedsProgressRefresh = true;

    /// When true, the VisibilityManager should rescan all tetromino actors.
    /// Set on level transitions and save loads.
    bool NeedsTetrominoScan = true;

    /// Set by the F6 key handler; cleared after DumpCollectedTetrominos fires.
    std::atomic<bool> PendingInventoryDump = false;

    /// Set by the F9 key handler; cleared after test notifications are queued.
    std::atomic<bool> PendingHudTest = false;

    /// Mutex to protect state accessed from AP callback thread.
    /// AP callbacks push to pending queues under this lock;
    /// the game-thread update loop drains the queues.
    std::mutex Mutex;

    /// Pending items received from AP (to be processed on game thread).
    struct PendingItem {
        int64_t apItemId;
        int     playerSlot;
        int     flags;
    };
    std::vector<PendingItem> PendingItems;

    /// Pending checked locations confirmed by server.
    std::vector<int64_t> PendingCheckedLocations;

    /// Flag indicating AP connection is now established and items are ready.
    bool PendingAPSyncComplete = false;

    /// Reset all cached UObject pointers and state for a level transition.
    void ResetForLevelTransition(int cooldownTicks = 50) {
        CurrentProgress = nullptr;
        LevelTransitionCooldown = cooldownTicks;
        NeedsProgressRefresh = true;
        NeedsTetrominoScan = true;
    }

    /// Reset checked locations (e.g. on new session or reconnect).
    void ResetCheckedLocations() {
        CheckedLocations.clear();
    }

    /// Mark a location as checked.
    void MarkLocationChecked(const std::string& tetrominoId) {
        CheckedLocations.insert(tetrominoId);
    }

    /// Check if a location has been checked this session.
    bool IsLocationChecked(const std::string& tetrominoId) const {
        return CheckedLocations.count(tetrominoId) > 0;
    }

    /// Check if an item has been granted by AP.
    bool IsGranted(const std::string& tetrominoId) const {
        return GrantedItems.count(tetrominoId) > 0;
    }

    /// Whether a tetromino should be collectable in-world.
    /// True if the location has NOT been checked.
    bool ShouldBeCollectable(const std::string& tetrominoId) const {
        return !IsLocationChecked(tetrominoId);
    }
};

} // namespace TalosAP
