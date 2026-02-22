#include "headers/VisibilityManager.h"

#include <Unreal/UObjectGlobals.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/UFunction.hpp>
#include <Unreal/FProperty.hpp>
#include <Unreal/NameTypes.hpp>
#include <DynamicOutput/DynamicOutput.hpp>

#include <vector>
#include <cmath>

using namespace RC;
using namespace RC::Unreal;

namespace TalosAP {

// ============================================================
// Type/Shape → Letter lookups
// ============================================================

char VisibilityManager::TypeToLetter(uint8_t type)
{
    switch (type) {
        case 1:  return 'D'; // Door
        case 2:  return 'M'; // Mechanic
        case 4:  return 'N'; // Nexus
        case 8:  return 'S'; // Secret
        case 16: return 'E'; // AlternativeEnding
        case 32: return 'A'; // Arcade
        case 64: return 'H'; // Help
        default: return '?';
    }
}

char VisibilityManager::ShapeToLetter(uint8_t shape)
{
    switch (shape) {
        case 1:  return 'I';
        case 2:  return 'J';
        case 4:  return 'L';
        case 8:  return 'O';
        case 16: return 'S';
        case 32: return 'T';
        case 64: return 'Z';
        default: return '?';
    }
}

std::string VisibilityManager::FormatTetrominoId(uint8_t typeVal, uint8_t shapeVal, int32_t number)
{
    char tl = TypeToLetter(typeVal);
    char sl = ShapeToLetter(shapeVal);
    if (tl == '?' || sl == '?') return "";
    return std::string(1, tl) + std::string(1, sl) + std::to_string(number);
}

// ============================================================
// InstanceInfo reading
// ============================================================

// FTetrominoInstanceInfo layout (from CXX header dump):
//   struct FTetrominoInstanceInfo {
//       ETetrominoPieceType  Type;    // offset 0x0, size 0x1
//       ETetrominoPieceShape Shape;   // offset 0x1, size 0x1
//       int32                Number;  // offset 0x4, size 0x4
//   };                               // total size: 0x8

bool VisibilityManager::ReadInstanceInfo(UObject* actor, uint8_t& outType, uint8_t& outShape, int32_t& outNumber)
{
    if (!actor) return false;

    try {
        // InstanceInfo is a struct property on BP_TetrominoItem_C.
        // In the Talos header dump, "class ATetrominoItem" doesn't exist directly—
        // BP_TetrominoItem_C is an Angelscript-generated Blueprint class.
        // The InstanceInfo property holds FTetrominoInstanceInfo which is:
        //   Type (uint8), Shape (uint8), padding, Number (int32) = 8 bytes total.
        //
        // GetValuePtrByPropertyNameInChain returns a pointer to the first byte
        // of the struct's storage.
        auto* infoPtr = actor->GetValuePtrByPropertyNameInChain<uint8_t>(STR("InstanceInfo"));
        if (!infoPtr) return false;

        // Read the fields at their known offsets within the struct
        outType  = infoPtr[0];   // offset 0x0
        outShape = infoPtr[1];   // offset 0x1
        // offset 0x4 (int32, after 2 bytes of padding)
        outNumber = *reinterpret_cast<int32_t*>(infoPtr + 4);

        return (outType != 0 && outShape != 0 && outNumber > 0);
    }
    catch (...) {
        return false;
    }
}

// ============================================================
// Actor position reading
// ============================================================

bool VisibilityManager::ReadActorPosition(UObject* actor, float& outX, float& outY, float& outZ)
{
    if (!actor) return false;

    try {
        // AActor has a RootComponent (USceneComponent*) which has RelativeLocation (FVector).
        // In UE4SS, we can chain through the property names.
        auto* rootCompPtr = actor->GetValuePtrByPropertyNameInChain<UObject*>(STR("RootComponent"));
        if (!rootCompPtr || !*rootCompPtr) return false;

        UObject* rootComp = *rootCompPtr;

        // RelativeLocation is an FVector — in UE5 this is 3 doubles (24 bytes),
        // NOT 3 floats. Reading as float gives garbage from misaligned half-values.
        auto* locPtr = rootComp->GetValuePtrByPropertyNameInChain<double>(STR("RelativeLocation"));
        if (!locPtr) return false;

        outX = static_cast<float>(locPtr[0]);
        outY = static_cast<float>(locPtr[1]);
        outZ = static_cast<float>(locPtr[2]);
        return true;
    }
    catch (...) {
        return false;
    }
}

// ============================================================
// Player position
// ============================================================

bool VisibilityManager::GetPlayerPosition(float& outX, float& outY, float& outZ)
{
    try {
        auto* pc = UObjectGlobals::FindFirstOf(STR("PlayerController"));
        if (!pc) return false;

        auto* pawnPtr = pc->GetValuePtrByPropertyNameInChain<UObject*>(STR("Pawn"));
        if (!pawnPtr || !*pawnPtr) return false;

        UObject* pawn = *pawnPtr;
        return ReadActorPosition(pawn, outX, outY, outZ);
    }
    catch (...) {
        return false;
    }
}

// ============================================================
// Visibility control
// ============================================================

void VisibilityManager::SetActorVisible(UObject* actor)
{
    if (!actor) return;

    try {
        auto* rootCompPtr = actor->GetValuePtrByPropertyNameInChain<UObject*>(STR("RootComponent"));
        if (!rootCompPtr || !*rootCompPtr) return;
        UObject* rootComp = *rootCompPtr;

        // SetVisibility(true) — root only, do NOT propagate to children.
        // Propagation interferes with the game's animation system and
        // collection sequence (mesh fade, particle despawn).
        auto* setVisFunc = rootComp->GetFunctionByNameInChain(STR("SetVisibility"));
        if (setVisFunc) {
            struct { bool bNewVisibility; bool bPropagateToChildren; } params{};
            params.bNewVisibility = true;
            params.bPropagateToChildren = true;
            rootComp->ProcessEvent(setVisFunc, &params);
        }

        // SetHiddenInGame(false) — root only, do NOT propagate.
        auto* setHiddenFunc = rootComp->GetFunctionByNameInChain(STR("SetHiddenInGame"));
        if (setHiddenFunc) {
            struct { bool NewHidden; bool bPropagateToChildren; } params{};
            params.NewHidden = false;
            params.bPropagateToChildren = true;
            rootComp->ProcessEvent(setHiddenFunc, &params);
        }
    }
    catch (...) {
        // Silently fail — actor may have been GC'd
    }
}

void VisibilityManager::SetActorHidden(UObject* actor)
{
    if (!actor) return;

    try {
        auto* rootCompPtr = actor->GetValuePtrByPropertyNameInChain<UObject*>(STR("RootComponent"));
        if (!rootCompPtr || !*rootCompPtr) return;
        UObject* rootComp = *rootCompPtr;

        auto* setVisFunc = rootComp->GetFunctionByNameInChain(STR("SetVisibility"));
        if (setVisFunc) {
            struct { bool bNewVisibility; bool bPropagateToChildren; } params{};
            params.bNewVisibility = false;
            params.bPropagateToChildren = false;
            rootComp->ProcessEvent(setVisFunc, &params);
        }

        auto* setHiddenFunc = rootComp->GetFunctionByNameInChain(STR("SetHiddenInGame"));
        if (setHiddenFunc) {
            struct { bool NewHidden; bool bPropagateToChildren; } params{};
            params.NewHidden = true;
            params.bPropagateToChildren = false;
            rootComp->ProcessEvent(setHiddenFunc, &params);
        }
    }
    catch (...) {
        // Silently fail
    }
}

bool VisibilityManager::IsActorHidden(UObject* actor)
{
    if (!actor) return false;

    try {
        // Check Root SceneComponent visibility state (matches our SetActorVisible/Hidden).
        // bVisible=false or bHiddenInGame=true means the item is hidden.
        auto* rootCompPtr = actor->GetValuePtrByPropertyNameInChain<UObject*>(STR("RootComponent"));
        if (!rootCompPtr || !*rootCompPtr) return false;
        UObject* rootComp = *rootCompPtr;

        auto* visiblePtr = rootComp->GetValuePtrByPropertyNameInChain<bool>(STR("bVisible"));
        if (visiblePtr && !*visiblePtr) return true;

        auto* hiddenPtr = rootComp->GetValuePtrByPropertyNameInChain<bool>(STR("bHiddenInGame"));
        if (hiddenPtr && *hiddenPtr) return true;

        return false;
    }
    catch (...) {
        return false;
    }
}

// ============================================================
// ScanLevel — full discovery of tetrominos
// ============================================================

void VisibilityManager::ScanLevel(ModState& state)
{
    m_tracked.clear();

    std::vector<UObject*> items;
    try {
        UObjectGlobals::FindAllOf(STR("BP_TetrominoItem_C"), items);
    }
    catch (...) {
        Output::send<LogLevel::Warning>(STR("[TalosAP] Visibility: FindAllOf BP_TetrominoItem_C failed\n"));
        return;
    }

    if (items.empty()) {
        Output::send<LogLevel::Verbose>(STR("[TalosAP] Visibility: no tetromino items found in level\n"));
        return;
    }

    int count = 0;
    for (auto* item : items) {
        if (!item) continue;

        uint8_t type = 0, shape = 0;
        int32_t number = 0;
        if (!ReadInstanceInfo(item, type, shape, number)) continue;

        std::string tetId = FormatTetrominoId(type, shape, number);
        if (tetId.empty()) continue;

        TrackedTetromino tt;
        tt.id = tetId;
        tt.hasPosition = ReadActorPosition(item, tt.x, tt.y, tt.z);

        // Apply initial visibility
        if (state.ShouldBeCollectable(tetId)) {
            SetActorVisible(item);
            tt.visRetries = VISIBILITY_RETRY_COUNT;
        } else if (state.IsLocationChecked(tetId)) {
            SetActorHidden(item);
        }

        m_tracked[tetId] = tt;
        ++count;
    }

    Output::send<LogLevel::Verbose>(STR("[TalosAP] Visibility: scanned {} tetromino items\n"), count);

    // Log tracked items
    for (const auto& [id, tt] : m_tracked) {
        if (tt.hasPosition) {
            Output::send<LogLevel::Verbose>(STR("[TalosAP]   {} @ ({:.1f}, {:.1f}, {:.1f})\n"),
                std::wstring(id.begin(), id.end()), tt.x, tt.y, tt.z);
        } else {
            Output::send<LogLevel::Verbose>(STR("[TalosAP]   {} (no position)\n"),
                std::wstring(id.begin(), id.end()));
        }
    }

    // Build fence map (tetId → LoweringFence actor) for this level
    BuildFenceMap();
}

// ============================================================
// RefreshVisibility — periodic re-discovery
// ============================================================

void VisibilityManager::RefreshVisibility(ModState& state)
{
    std::vector<UObject*> items;
    try {
        UObjectGlobals::FindAllOf(STR("BP_TetrominoItem_C"), items);
    }
    catch (...) {
        return;
    }

    if (items.empty()) return;

    // Rebuild tracked data, preserving reported state
    std::unordered_map<std::string, TrackedTetromino> newTracked;

    for (auto* item : items) {
        if (!item) continue;

        uint8_t type = 0, shape = 0;
        int32_t number = 0;
        if (!ReadInstanceInfo(item, type, shape, number)) continue;

        std::string tetId = FormatTetrominoId(type, shape, number);
        if (tetId.empty()) continue;

        TrackedTetromino tt;
        tt.id = tetId;
        tt.hasPosition = ReadActorPosition(item, tt.x, tt.y, tt.z);

        // Preserve existing tracking state
        auto it = m_tracked.find(tetId);
        if (it != m_tracked.end()) {
            tt.reported = it->second.reported;
            // If we failed to read position this time, keep old position
            if (!tt.hasPosition && it->second.hasPosition) {
                tt.x = it->second.x;
                tt.y = it->second.y;
                tt.z = it->second.z;
                tt.hasPosition = true;
            }
        }

        // Apply visibility
        if (state.ShouldBeCollectable(tetId)) {
            SetActorVisible(item);
            tt.visRetries = 10; // lighter retries on refresh (~0.17s)
        } else if (state.IsLocationChecked(tetId)) {
            // Already checked — hide regardless of grant state
            SetActorHidden(item);
        }

        newTracked[tetId] = tt;
    }

    m_tracked = std::move(newTracked);
}

// ============================================================
// EnforceVisibility — per-tick enforcement + proximity pickup
// ============================================================

void VisibilityManager::EnforceVisibility(
    ModState& state,
    const ItemMapping& itemMapping,
    const std::function<void(int64_t)>& locationCheckCallback)
{
    if (m_tracked.empty()) return;

    // Re-discover actors each enforcement tick so we have fresh UObject*.
    // This is necessary because Unreal GC can invalidate any cached pointer.
    std::vector<UObject*> items;
    try {
        UObjectGlobals::FindAllOf(STR("BP_TetrominoItem_C"), items);
    }
    catch (...) {
        return;
    }

    // Build a temporary ID → actor map for this tick
    std::unordered_map<std::string, UObject*> idToActor;
    for (auto* item : items) {
        if (!item) continue;

        uint8_t type = 0, shape = 0;
        int32_t number = 0;
        if (!ReadInstanceInfo(item, type, shape, number)) continue;

        std::string tetId = FormatTetrominoId(type, shape, number);
        if (!tetId.empty()) {
            idToActor[tetId] = item;
        }
    }

    // Get player position for proximity detection
    float playerX = 0, playerY = 0, playerZ = 0;
    bool hasPlayerPos = GetPlayerPosition(playerX, playerY, playerZ);

    // Enforce visibility and detect proximity pickups
    for (auto& [id, tt] : m_tracked) {
        auto actorIt = idToActor.find(id);
        if (actorIt == idToActor.end()) continue;

        UObject* actor = actorIt->second;

        if (state.ShouldBeCollectable(id)) {
            // Item should be visible and collectable.
            // Only enforce visibility while retries remain — once they expire,
            // stop fighting the game so animations and collection work normally.
            // Retries are set at scan/refresh time, NOT reset here.
            if (tt.visRetries > 0) {
                if (IsActorHidden(actor)) {
                    SetActorVisible(actor);
                }
                --tt.visRetries;
            }

            // Proximity pickup detection — only when item is confirmed visible.
            // Without this guard, proximity fires on invisible items (e.g. items
            // the game hid because they're in the CollectedTetrominos TMap).
            if (hasPlayerPos && tt.hasPosition && !tt.reported && !IsActorHidden(actor)) {
                float dx = playerX - tt.x;
                float dy = playerY - tt.y;
                float dz = playerZ - tt.z;
                float distSq = dx * dx + dy * dy + dz * dz;

                if (distSq < PICKUP_RADIUS_SQ) {
                    Output::send<LogLevel::Verbose>(STR("[TalosAP] Proximity pickup: {} (dist={:.0f})\n"),
                        std::wstring(id.begin(), id.end()), std::sqrt(distSq));

                    tt.reported = true;
                    SetActorHidden(actor);

                    // Mark location as checked in state
                    state.MarkLocationChecked(id);

                    // Notify AP server
                    if (locationCheckCallback) {
                        int64_t locId = itemMapping.GetLocationId(id);
                        if (locId >= 0) {
                            locationCheckCallback(locId);
                        }
                    }

                    // Open puzzle exit fence if one is mapped
                    OpenFenceForTetromino(id);
                }
            }
        } else if (state.IsLocationChecked(id)) {
            // Location has been checked — hide the actor regardless of grant state.
            // If granted to us: we already have it, no need to show the world item.
            // If granted to another player: same, hide it.
            SetActorHidden(actor);
        }
    }
}

// ============================================================
// ResetCache
// ============================================================

void VisibilityManager::ResetCache()
{
    m_tracked.clear();
    m_fenceMap.clear();
    m_pendingFenceOpens.clear();
}

// ============================================================
// DumpTracked
// ============================================================

void VisibilityManager::DumpTracked() const
{
    Output::send<LogLevel::Verbose>(STR("[TalosAP] === Tracked Tetrominos ({}) ===\n"), m_tracked.size());
    for (const auto& [id, tt] : m_tracked) {
        Output::send<LogLevel::Verbose>(STR("[TalosAP]   {} pos=({:.1f},{:.1f},{:.1f}) reported={} retries={}\n"),
            std::wstring(id.begin(), id.end()),
            tt.x, tt.y, tt.z,
            tt.reported ? STR("yes") : STR("no"),
            tt.visRetries);
    }
}

// ============================================================
// BuildFenceMap — discover LoweringFenceWhenTetrominoIsPickedUpScript
// actors and map each tetromino ID to its exit fence.
// ============================================================

void VisibilityManager::BuildFenceMap()
{
    m_fenceMap.clear();

    int count = 0;
    int skipped = 0;

    // ----------------------------------------------------------------
    // Source 1: LoweringFenceWhenTetrominoIsPickedUp(Base)Script
    //   Layout: Tetromino @ 0x0330, LoweringFence @ 0x0388
    // ----------------------------------------------------------------
    {
        std::vector<UObject*> scripts;
        try { UObjectGlobals::FindAllOf(STR("LoweringFenceWhenTetrominoIsPickedUpBaseScript"), scripts); } catch (...) {}
        try {
            std::vector<UObject*> derived;
            UObjectGlobals::FindAllOf(STR("LoweringFenceWhenTetrominoIsPickedUpScript"), derived);
            for (auto* s : derived) {
                bool dup = false;
                for (auto* e : scripts) { if (e == s) { dup = true; break; } }
                if (!dup) scripts.push_back(s);
            }
        } catch (...) {}

        Output::send<LogLevel::Verbose>(STR("[TalosAP] FenceMap: {} LoweringFenceWhenTetromino script actors\n"), scripts.size());

        for (auto* script : scripts) {
            if (!script) continue;
            try {
                uint8_t* base = reinterpret_cast<uint8_t*>(script);
                UObject* tet   = *reinterpret_cast<UObject**>(base + 0x0330);
                UObject* fence = *reinterpret_cast<UObject**>(base + 0x0388);

                // Property-name fallback
                if (!tet || !fence) {
                    auto* tp = script->GetValuePtrByPropertyNameInChain<UObject*>(STR("Tetromino"));
                    if (tp && *tp) tet = *tp;
                    auto* fp = script->GetValuePtrByPropertyNameInChain<UObject*>(STR("LoweringFence"));
                    if (fp && *fp) fence = *fp;
                }

                if (!tet) { ++skipped; continue; }

                // Read tetromino ID early for logging
                uint8_t type = 0, shape = 0; int32_t number = 0;
                if (!ReadInstanceInfo(tet, type, shape, number)) { ++skipped; continue; }
                std::string tetId = FormatTetrominoId(type, shape, number);
                if (tetId.empty()) { ++skipped; continue; }

                // ---------------------------------------------------------
                // EntityPointers fallback: when offset 0x0388 is null,
                // the AngelScript runtime did not resolve the entity ref.
                // Read the EntityPointers TArray inside LoweringFenceInfo
                // to get EntityIDs, then match against fence actors' Tags.
                //
                // LoweringFenceInfo starts at 0x0338 (FTalosOneScriptVariableInfo):
                //   +0x40 = 0x0378: TArray<FTalosOneEntityPointerInfo> EntityPointers
                //     TArray layout: Data*(8) + Num(4) + Max(4)
                //   Each FTalosOneEntityPointerInfo (0x28 bytes):
                //     +0x00: FString ClassName  (0x10)
                //     +0x10: int32   EntityID   (0x04)
                //     +0x18: FString EntityName (0x10)
                // ---------------------------------------------------------
                if (!fence) {
                    uint8_t* epData = *reinterpret_cast<uint8_t**>(base + 0x0378);
                    int32_t  epNum  = *reinterpret_cast<int32_t*>(base + 0x0380);

                    if (epData && epNum > 0 && epNum < 100) {
                        Output::send<LogLevel::Verbose>(
                            STR("[TalosAP] FenceMap: {} — fence null, resolving via {} EntityPointers\n"),
                            std::wstring(tetId.begin(), tetId.end()), epNum);

                        // Collect EntityIDs from the array
                        std::vector<int32_t> entityIds;
                        for (int32_t i = 0; i < epNum; i++) {
                            uint8_t* entry = epData + i * 0x28;
                            int32_t eid = *reinterpret_cast<int32_t*>(entry + 0x10);
                            entityIds.push_back(eid);
                            Output::send<LogLevel::Verbose>(
                                STR("[TalosAP]   EntityPointers[{}]: EntityID={}\n"), i, eid);
                        }

                        // Find matching fence by EntityID in Tags
                        std::vector<UObject*> allFences;
                        try { UObjectGlobals::FindAllOf(STR("BP_LoweringFence_C"), allFences); } catch (...) {}

                        for (auto* candidate : allFences) {
                            if (!candidate || fence) continue;
                            try {
                                // AActor::Tags is TArray<FName>
                                // With case-preserving names, sizeof(FName) = 12
                                auto* tagsRaw = candidate->GetValuePtrByPropertyNameInChain<uint8_t>(STR("Tags"));
                                if (!tagsRaw) continue;

                                uint8_t* tagData = *reinterpret_cast<uint8_t**>(tagsRaw);
                                int32_t  tagNum  = *reinterpret_cast<int32_t*>(tagsRaw + sizeof(void*));
                                if (!tagData || tagNum <= 0 || tagNum > 100) continue;

                                constexpr size_t FNAME_GAME_SIZE = sizeof(FName);

                                for (int32_t ti = 0; ti < tagNum && !fence; ti++) {
                                    try {
                                        FName* fn = reinterpret_cast<FName*>(tagData + ti * FNAME_GAME_SIZE);
                                        auto tagStr = fn->ToString();

                                        // Look for "EntityID:XXXX"
                                        auto colonPos = tagStr.find(STR(":"));
                                        if (colonPos == std::wstring::npos) continue;

                                        auto key = tagStr.substr(0, colonPos);
                                        if (key != STR("EntityID")) continue;

                                        int32_t feid = std::stoi(tagStr.substr(colonPos + 1));
                                        for (int32_t target : entityIds) {
                                            if (feid == target) {
                                                fence = candidate;
                                                Output::send<LogLevel::Verbose>(
                                                    STR("[TalosAP] FenceMap: {} — resolved via EntityID {} tag: {}\n"),
                                                    std::wstring(tetId.begin(), tetId.end()), feid,
                                                    candidate->GetFullName());
                                                break;
                                            }
                                        }
                                    } catch (...) {}
                                }
                            } catch (...) {}
                        }
                    }

                    if (!fence) {
                        Output::send<LogLevel::Warning>(
                            STR("[TalosAP] FenceMap: {} — could not resolve fence, skipped\n"),
                            std::wstring(tetId.begin(), tetId.end()));
                        ++skipped;
                        continue;
                    }
                }

                m_fenceMap[tetId] = fence->GetFullName();
                ++count;
                Output::send<LogLevel::Verbose>(STR("[TalosAP] FenceMap: {} -> {}\n"),
                    std::wstring(tetId.begin(), tetId.end()), fence->GetFullName());
            } catch (...) { ++skipped; }
        }
    }

    // ----------------------------------------------------------------
    // Source 2: EclipseScript
    //   Layout: Tetromino @ 0x02E0, Fence @ 0x02E8
    //   Some levels use this class instead of LoweringFenceWhenTetromino
    // ----------------------------------------------------------------
    {
        std::vector<UObject*> eclipses;
        try { UObjectGlobals::FindAllOf(STR("EclipseScript"), eclipses); } catch (...) {}

        if (!eclipses.empty()) {
            Output::send<LogLevel::Verbose>(STR("[TalosAP] FenceMap: {} EclipseScript actors\n"), eclipses.size());
        }

        for (auto* script : eclipses) {
            if (!script) continue;
            try {
                uint8_t* base = reinterpret_cast<uint8_t*>(script);
                UObject* tet   = *reinterpret_cast<UObject**>(base + 0x02E0);
                UObject* fence = *reinterpret_cast<UObject**>(base + 0x02E8);

                // Property-name fallback
                if (!tet || !fence) {
                    auto* tp = script->GetValuePtrByPropertyNameInChain<UObject*>(STR("Tetromino"));
                    if (tp && *tp) tet = *tp;
                    auto* fp = script->GetValuePtrByPropertyNameInChain<UObject*>(STR("Fence"));
                    if (fp && *fp) fence = *fp;
                }

                if (!tet) { ++skipped; continue; }
                if (!fence) {
                    uint8_t t = 0, s = 0; int32_t n = 0;
                    std::string id = "(unknown)";
                    if (ReadInstanceInfo(tet, t, s, n)) id = FormatTetrominoId(t, s, n);
                    Output::send<LogLevel::Warning>(
                        STR("[TalosAP] FenceMap: EclipseScript for {} — fence ptr null, skipped\n"),
                        std::wstring(id.begin(), id.end()));
                    ++skipped;
                    continue;
                }

                uint8_t type = 0, shape = 0; int32_t number = 0;
                if (!ReadInstanceInfo(tet, type, shape, number)) { ++skipped; continue; }
                std::string tetId = FormatTetrominoId(type, shape, number);
                if (tetId.empty()) { ++skipped; continue; }

                // Don't overwrite if LoweringFenceWhenTetromino already found it
                if (m_fenceMap.find(tetId) == m_fenceMap.end()) {
                    m_fenceMap[tetId] = fence->GetFullName();
                    ++count;
                    Output::send<LogLevel::Verbose>(STR("[TalosAP] FenceMap: {} -> {} (via EclipseScript)\n"),
                        std::wstring(tetId.begin(), tetId.end()), fence->GetFullName());
                }
            } catch (...) { ++skipped; }
        }
    }

    Output::send<LogLevel::Verbose>(STR("[TalosAP] FenceMap: {} entries built, {} skipped\n"), count, skipped);
}

// ============================================================
// OpenFenceForTetromino — queue a fence open for the given tetromino
// ============================================================

void VisibilityManager::OpenFenceForTetromino(const std::string& tetId)
{
    auto it = m_fenceMap.find(tetId);
    if (it == m_fenceMap.end()) return;

    PendingFenceOpen entry;
    entry.tetId = tetId;
    entry.fenceFullName = it->second;
    entry.attempts = 0;
    m_pendingFenceOpens.push_back(entry);

    Output::send<LogLevel::Verbose>(STR("[TalosAP] FenceMap: queued fence open for {}\n"),
        std::wstring(tetId.begin(), tetId.end()));
}

// ============================================================
// ProcessPendingFenceOpens — retry loop for fence::Open()
// Called every ~6 ticks (~100ms at 60fps) from on_update.
// ============================================================

void VisibilityManager::ProcessPendingFenceOpens()
{
    if (m_pendingFenceOpens.empty()) return;

    // Cache the ALoweringFence::Open UFunction on first use
    if (!m_fnFenceOpen) {
        try {
            m_fnFenceOpen = UObjectGlobals::StaticFindObject<UFunction*>(
                nullptr, nullptr, STR("/Script/Angelscript.LoweringFence:Open"));
        }
        catch (...) {}

        if (!m_fnFenceOpen) {
            Output::send<LogLevel::Warning>(STR("[TalosAP] FenceMap: could not find LoweringFence::Open UFunction\n"));
            // Don't clear the queue — we'll retry next tick
            return;
        }
    }

    std::deque<PendingFenceOpen> remaining;

    for (auto& entry : m_pendingFenceOpens) {
        bool opened = false;

        try {
            // Re-discover the fence actor by iterating all LoweringFence instances
            // and matching by full name. This avoids caching stale UObject*.
            std::vector<UObject*> fences;
            UObjectGlobals::FindAllOf(STR("LoweringFence"), fences);

            for (auto* fence : fences) {
                if (!fence) continue;
                try {
                    if (fence->GetFullName() == entry.fenceFullName) {
                        // Found the fence — call Open()
                        fence->ProcessEvent(m_fnFenceOpen, nullptr);
                        opened = true;
                        break;
                    }
                }
                catch (...) {}
            }
        }
        catch (...) {}

        if (opened) {
            Output::send<LogLevel::Verbose>(STR("[TalosAP] FenceMap: opened fence for {} (attempt {})\n"),
                std::wstring(entry.tetId.begin(), entry.tetId.end()),
                entry.attempts + 1);
        } else {
            ++entry.attempts;
            if (entry.attempts < 10) {
                remaining.push_back(entry);
                Output::send<LogLevel::Verbose>(STR("[TalosAP] FenceMap: retry {}/10 for {}\n"),
                    entry.attempts, std::wstring(entry.tetId.begin(), entry.tetId.end()));
            } else {
                Output::send<LogLevel::Warning>(STR("[TalosAP] FenceMap: gave up opening fence for {} after 10 attempts\n"),
                    std::wstring(entry.tetId.begin(), entry.tetId.end()));
            }
        }
    }

    m_pendingFenceOpens = std::move(remaining);
}

// ============================================================
// DumpFenceMap
// ============================================================

void VisibilityManager::DumpFenceMap() const
{
    Output::send<LogLevel::Verbose>(STR("[TalosAP] === FenceMap ({}) ===\n"), m_fenceMap.size());
    for (const auto& [tetId, fenceName] : m_fenceMap) {
        Output::send<LogLevel::Verbose>(STR("[TalosAP]   {} -> {}\n"),
            std::wstring(tetId.begin(), tetId.end()), fenceName);
    }
}

} // namespace TalosAP
