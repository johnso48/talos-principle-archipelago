#define NOMINMAX
#include <windows.h>

#include <Mod/CppUserModBase.hpp>
#include <DynamicOutput/DynamicOutput.hpp>
#include <Input/Handler.hpp>
#include <Unreal/UObjectGlobals.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/UFunction.hpp>

#include "src/headers/Config.h"
#include "src/headers/ModState.h"
#include "src/headers/ItemMapping.h"
#include "src/headers/APClient.h"
#include "src/headers/InventorySync.h"
#include "src/headers/LevelTransitionHandler.h"
#include "src/headers/SaveGameHandler.h"
#include "src/headers/VisibilityManager.h"
#include "src/headers/HudNotification.h"

#include <filesystem>

using namespace RC;
using namespace RC::Unreal;

class TalosPrincipleArchipelagoMod : public RC::CppUserModBase
{
public:
    TalosPrincipleArchipelagoMod() : CppUserModBase()
    {
        ModName = STR("TalosPrincipleArchipelago");
        ModVersion = STR("0.1.0");
        ModDescription = STR("Archipelago multiworld integration for The Talos Principle Reawakened");
        ModAuthors = STR("Froddo");

        Output::send<LogLevel::Verbose>(STR("[TalosAP] Mod constructed\n"));
    }

    ~TalosPrincipleArchipelagoMod() override
    {
        // Signal on_update to stop all UObject work immediately.
        // During engine teardown UObjects are freed while our tick
        // is still running — any FindAllOf / FindFirstOf call will
        // crash with an access violation (SEH, not catchable by C++).
        m_shuttingDown = true;
    }

    // ============================================================
    // on_unreal_init — Unreal Engine is ready, safe to use UE types
    // ============================================================
    auto on_unreal_init() -> void override
    {
        Output::send<LogLevel::Verbose>(STR("[TalosAP] on_unreal_init — initializing...\n"));

        // Load configuration
        // Try to find the mod directory (where the DLL lives)
        std::wstring modDir;
        try {
            wchar_t dllPath[MAX_PATH];
            HMODULE hModule = nullptr;
            // Use a static dummy variable whose address lives inside this DLL
            static const int s_anchor = 0;
            GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                               GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                               reinterpret_cast<LPCWSTR>(&s_anchor),
                               &hModule);
            if (hModule) {
                GetModuleFileNameW(hModule, dllPath, MAX_PATH);
                std::filesystem::path p(dllPath);
                // DLL is in Mods/<ModName>/dlls/main.dll, config is in Mods/<ModName>/
                modDir = p.parent_path().parent_path().wstring();
            }
        }
        catch (...) {}

        m_config.Load(modDir);
        Output::send<LogLevel::Verbose>(STR("[TalosAP] Config loaded\n"));

        // Initialize item mapping
        m_itemMapping = std::make_unique<TalosAP::ItemMapping>();
        Output::send<LogLevel::Verbose>(STR("[TalosAP] Item mappings built\n"));

        // Initialize HUD notification overlay
        m_hud = std::make_unique<TalosAP::HudNotification>();
        if (m_hud->Init()) {
            Output::send<LogLevel::Verbose>(STR("[TalosAP] HUD notification system initialized\n"));
        } else {
            Output::send<LogLevel::Warning>(STR("[TalosAP] HUD init deferred — UMG classes not yet available\n"));
        }

        // Initialize AP client (unless offline mode)
        if (!m_config.offline_mode) {
            m_apClient = std::make_unique<TalosAP::APClientWrapper>();
            bool ok = m_apClient->Init(m_config, m_state, *m_itemMapping, m_hud.get());
            if (ok) {
                Output::send<LogLevel::Verbose>(STR("[TalosAP] AP client initialized — connection will start on poll\n"));
            } else {
                Output::send<LogLevel::Error>(STR("[TalosAP] AP client initialization failed\n"));
                m_apClient.reset();
            }
        } else {
            Output::send<LogLevel::Verbose>(STR("[TalosAP] Offline mode — AP client disabled\n"));
            m_state.APSynced = true; // Enable enforcement immediately in offline mode
        }

        // ============================================================
        // Register debug key bindings
        // ============================================================
        register_keydown_event(Input::Key::F6, [this]() {
            m_state.PendingInventoryDump.store(true);
        });

        // F9: Test HUD notifications — fires one of each color type
        register_keydown_event(Input::Key::F9, [this]() {
            m_state.PendingHudTest.store(true);
        });

        // ============================================================
        // Register hooks
        // ============================================================
        m_levelTransitionHandler.RegisterHooks(m_state);
        m_saveGameHandler.RegisterHooks(m_state);

        Output::send<LogLevel::Verbose>(STR("[TalosAP] Initialization complete\n"));
    }

    // ============================================================
    // on_update — called every tick from the game thread
    // ============================================================
    auto on_update() -> void override
    {
        // Bail immediately if the engine is tearing down.
        // UObjects may already be freed — any FindAllOf/FindFirstOf
        // call would be an access violation.
        if (m_shuttingDown) return;

        ++m_tickCount;

        // Poll AP client for network events
        if (m_apClient) {
            m_apClient->Poll();
        }

        // Tick HUD notification system (~12 ticks = 200ms)
        if (m_hud && (m_tickCount % 12 == 0)) {
            m_hud->Tick(12.0f, 60.0f);
        }

        // Decrement level transition cooldown
        if (m_state.LevelTransitionCooldown > 0) {
            --m_state.LevelTransitionCooldown;
            if (m_state.LevelTransitionCooldown == 0) {
                Output::send<LogLevel::Verbose>(STR("[TalosAP] Level transition cooldown expired — resuming\n"));
            }
            return; // Skip all game-thread work during transitions
        }

        // Deferred progress refresh
        if (m_state.NeedsProgressRefresh) {
            m_state.NeedsProgressRefresh = false;
            TalosAP::InventorySync::FindProgressObject(m_state, true);
            if (m_state.CurrentProgress) {
                Output::send<LogLevel::Verbose>(STR("[TalosAP] Deferred progress refresh complete\n"));
            }
        }

        // F6: inventory dump
        if (m_state.PendingInventoryDump.exchange(false)) {
            Output::send<LogLevel::Verbose>(STR("[TalosAP] === F6 Inventory Dump ===\n"));
            TalosAP::InventorySync::FindProgressObject(m_state);
            TalosAP::InventorySync::DumpCollectedTetrominos(m_state);
            m_visibilityManager.DumpTracked();
            m_visibilityManager.DumpFenceMap();
        }

        // F9: HUD notification test
        if (m_state.PendingHudTest.exchange(false) && m_hud) {
            Output::send<LogLevel::Verbose>(STR("[TalosAP] === F9: HUD notification test ===\n"));
            m_hud->Notify({
                { L"Alice",         TalosAP::HudColors::PLAYER },
                { L" sent you ",   TalosAP::HudColors::WHITE  },
                { L"Red L",         TalosAP::HudColors::TRAP   },
            });
            m_hud->Notify({
                { L"Bob",           TalosAP::HudColors::PLAYER },
                { L" sent you ",   TalosAP::HudColors::WHITE  },
                { L"Golden T",      TalosAP::HudColors::PROGRESSION },
            });
            m_hud->Notify({
                { L"You found ",   TalosAP::HudColors::WHITE  },
                { L"Green J",       TalosAP::HudColors::ITEM   },
            });
            m_hud->NotifySimple(L"AP Connected to server", TalosAP::HudColors::SERVER);
        }

        // ============================================================
        // Tetromino scan — run once after level transitions
        // ============================================================
        if (m_state.NeedsTetrominoScan) {
            m_state.NeedsTetrominoScan = false;
            m_visibilityManager.ResetCache();
            m_visibilityManager.ScanLevel(m_state);
        }

        // ============================================================
        // Visibility enforcement + proximity pickup (every 5 ticks)
        // Rate-limited: EnforceVisibility calls FindAllOf + iterates
        // all actors, too expensive to run every frame. 5 ticks at
        // 60fps ≈ 12 Hz, still responsive for player proximity.
        // ============================================================
        if (m_state.APSynced && m_itemMapping && (m_tickCount % 5 == 0)) {
            m_visibilityManager.EnforceVisibility(m_state, *m_itemMapping,
                [this](int64_t locationId) {
                    if (m_apClient) {
                        m_apClient->SendLocationCheck(locationId);
                    }
                });
        }

        // ============================================================
        // Periodic full visibility refresh (every ~60 ticks / ~1s)
        // Re-discovers actors, rebuilds tracked positions, reapplies
        // visibility. Keeps tracking data current after items arrive.
        // ============================================================
        if (m_tickCount % 60 == 0) {
            m_visibilityManager.RefreshVisibility(m_state);
        }

        // ============================================================
        // Process pending fence opens (every ~6 ticks / ~100ms)
        // Retries ALoweringFence::Open() with 100ms spacing, up to 10x
        // ============================================================
        if (m_tickCount % 6 == 0) {
            m_visibilityManager.ProcessPendingFenceOpens();
        }

        // Enforce collection state every ~60 ticks
        if (m_tickCount % 60 == 0) {
            // Always re-acquire the progress object — cached UObject* can go
            // stale at any time due to Unreal GC.
            TalosAP::InventorySync::FindProgressObject(m_state);
            if (m_state.CurrentProgress) {
                TalosAP::InventorySync::EnforceCollectionState(m_state);
            }
        }
    }

private:
    TalosAP::Config                            m_config;
    TalosAP::ModState                          m_state;
    std::unique_ptr<TalosAP::ItemMapping>      m_itemMapping;
    std::unique_ptr<TalosAP::APClientWrapper>  m_apClient;
    std::unique_ptr<TalosAP::HudNotification>  m_hud;
    TalosAP::LevelTransitionHandler            m_levelTransitionHandler;
    TalosAP::SaveGameHandler                   m_saveGameHandler;
    TalosAP::VisibilityManager                 m_visibilityManager;
    uint64_t                                   m_tickCount = 0;
    bool                                       m_shuttingDown = false;
};

// ============================================================
// DLL Exports
// ============================================================
#define TALOS_AP_MOD_API __declspec(dllexport)
extern "C"
{
    TALOS_AP_MOD_API RC::CppUserModBase* start_mod()
    {
        return new TalosPrincipleArchipelagoMod();
    }

    TALOS_AP_MOD_API void uninstall_mod(RC::CppUserModBase* mod)
    {
        delete mod;
    }
}
