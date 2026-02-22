#pragma once

#include "ModState.h"

#include <vector>
#include <utility>

namespace TalosAP {

/// Hooks save-game lifecycle events and resets the relevant ModState
/// fields so that the inventory sync re-acquires fresh data.
///
/// Hooked functions:
///   TalosGameInstance::SetTalosSaveGameInstance
///   TalosGameInstance::ReloadSaveGame
class SaveGameHandler {
public:
    /// Register all save-game hooks. Must be called after
    /// Unreal is initialised (i.e. inside on_unreal_init).
    void RegisterHooks(ModState& state);

private:
    std::vector<std::pair<int, int>> m_hookIds;
};

} // namespace TalosAP
