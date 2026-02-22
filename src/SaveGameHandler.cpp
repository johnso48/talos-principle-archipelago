#include "headers/SaveGameHandler.h"

#include <Unreal/UObjectGlobals.hpp>
#include <DynamicOutput/DynamicOutput.hpp>

using namespace RC;
using namespace RC::Unreal;

namespace TalosAP {

void SaveGameHandler::RegisterHooks(ModState& state)
{
    // Hook: TalosGameInstance::SetTalosSaveGameInstance — save loaded
    try {
        auto hookId = UObjectGlobals::RegisterHook(
            STR("/Script/Talos.TalosGameInstance:SetTalosSaveGameInstance"),
            [](UnrealScriptFunctionCallableContext& ctx, void* data) {
                auto* st = static_cast<ModState*>(data);
                Output::send<LogLevel::Verbose>(STR("[TalosAP] Hook: SetTalosSaveGameInstance\n"));
                st->ResetForLevelTransition(15);
                st->CheckedLocations.clear();
            },
            {},
            &state
        );
        m_hookIds.push_back(hookId);
        Output::send<LogLevel::Verbose>(STR("[TalosAP] Hooked: SetTalosSaveGameInstance\n"));
    }
    catch (...) {
        Output::send<LogLevel::Warning>(STR("[TalosAP] Failed to hook SetTalosSaveGameInstance\n"));
    }

    // Hook: TalosGameInstance::ReloadSaveGame — Continue/Load
    try {
        auto hookId = UObjectGlobals::RegisterHook(
            STR("/Script/Talos.TalosGameInstance:ReloadSaveGame"),
            [](UnrealScriptFunctionCallableContext& ctx, void* data) {
                auto* st = static_cast<ModState*>(data);
                Output::send<LogLevel::Verbose>(STR("[TalosAP] Hook: ReloadSaveGame\n"));
                st->ResetForLevelTransition(20);
                st->CheckedLocations.clear();
            },
            {},
            &state
        );
        m_hookIds.push_back(hookId);
        Output::send<LogLevel::Verbose>(STR("[TalosAP] Hooked: ReloadSaveGame\n"));
    }
    catch (...) {
        Output::send<LogLevel::Warning>(STR("[TalosAP] Failed to hook ReloadSaveGame\n"));
    }
}

} // namespace TalosAP
