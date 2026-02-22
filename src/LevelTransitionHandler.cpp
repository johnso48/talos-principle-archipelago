#include "headers/LevelTransitionHandler.h"

#include <Unreal/UObjectGlobals.hpp>
#include <DynamicOutput/DynamicOutput.hpp>

using namespace RC;
using namespace RC::Unreal;

namespace TalosAP {

void LevelTransitionHandler::RegisterHooks(ModState& state)
{
    // Hook: PlayerController::ClientRestart — player spawned
    try {
        auto hookId = UObjectGlobals::RegisterHook(
            STR("/Script/Engine.PlayerController:ClientRestart"),
            [](UnrealScriptFunctionCallableContext& ctx, void* data) {
                auto* st = static_cast<ModState*>(data);
                Output::send<LogLevel::Verbose>(STR("[TalosAP] Hook: ClientRestart\n"));
                st->ResetForLevelTransition(15);
            },
            {},
            &state
        );
        m_hookIds.push_back(hookId);
        Output::send<LogLevel::Verbose>(STR("[TalosAP] Hooked: ClientRestart\n"));
    }
    catch (...) {
        Output::send<LogLevel::Warning>(STR("[TalosAP] Failed to hook ClientRestart\n"));
    }

    // Hook: TalosGameInstance::OpenLevel — level transition start
    try {
        auto hookId = UObjectGlobals::RegisterHook(
            STR("/Script/Talos.TalosGameInstance:OpenLevel"),
            [](UnrealScriptFunctionCallableContext& ctx, void* data) {
                auto* st = static_cast<ModState*>(data);
                Output::send<LogLevel::Verbose>(STR("[TalosAP] Hook: OpenLevel\n"));
                st->ResetForLevelTransition(50);
            },
            {},
            &state
        );
        m_hookIds.push_back(hookId);
        Output::send<LogLevel::Verbose>(STR("[TalosAP] Hooked: OpenLevel\n"));
    }
    catch (...) {
        Output::send<LogLevel::Warning>(STR("[TalosAP] Failed to hook OpenLevel\n"));
    }

    // Hook: TalosGameInstance::OpenLevelBySoftObjectPtr — alternate level transition
    try {
        auto hookId = UObjectGlobals::RegisterHook(
            STR("/Script/Talos.TalosGameInstance:OpenLevelBySoftObjectPtr"),
            [](UnrealScriptFunctionCallableContext& ctx, void* data) {
                auto* st = static_cast<ModState*>(data);
                Output::send<LogLevel::Verbose>(STR("[TalosAP] Hook: OpenLevelBySoftObjectPtr\n"));
                st->ResetForLevelTransition(50);
            },
            {},
            &state
        );
        m_hookIds.push_back(hookId);
        Output::send<LogLevel::Verbose>(STR("[TalosAP] Hooked: OpenLevelBySoftObjectPtr\n"));
    }
    catch (...) {
        Output::send<LogLevel::Warning>(STR("[TalosAP] Failed to hook OpenLevelBySoftObjectPtr\n"));
    }
}

} // namespace TalosAP
