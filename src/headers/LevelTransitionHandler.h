#pragma once

#include "ModState.h"

#include <vector>
#include <utility>

namespace TalosAP {

/// Hooks level-transition events and applies a cooldown to ModState
/// so that stale UObject* pointers are not accessed mid-transition.
///
/// Hooked functions:
///   PlayerController::ClientRestart
///   TalosGameInstance::OpenLevel
///   TalosGameInstance::OpenLevelBySoftObjectPtr
class LevelTransitionHandler {
public:
    /// Register all level-transition hooks. Must be called after
    /// Unreal is initialised (i.e. inside on_unreal_init).
    void RegisterHooks(ModState& state);

private:
    std::vector<std::pair<int, int>> m_hookIds;
};

} // namespace TalosAP
