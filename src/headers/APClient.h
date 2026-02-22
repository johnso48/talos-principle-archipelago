#pragma once

#include "Config.h"
#include "ModState.h"
#include "ItemMapping.h"
#include "HudNotification.h"

#include <string>
#include <memory>
#include <functional>

namespace TalosAP {

/// Wraps the apclientpp library to communicate with an Archipelago server.
///
/// apclientpp is single-threaded: all callbacks fire from within poll().
/// Since poll() is called from the game thread (on_update), the callbacks
/// queue items into ModState for the game thread to process safely.
class APClientWrapper {
public:
    APClientWrapper();
    ~APClientWrapper();

    /// Initialize the AP client with configuration.
    /// Returns true if the client was created successfully.
    bool Init(const Config& config, ModState& state, ItemMapping& itemMapping,
              HudNotification* hud = nullptr);

    /// Poll the AP client for network events. Must be called regularly
    /// (e.g. every tick in on_update). All callbacks fire within this call.
    void Poll();

    /// Send a location check to the AP server.
    void SendLocationCheck(int64_t locationId);

    /// Send goal completion status to the AP server.
    void SendGoalComplete();

    /// Check if the socket is connected.
    bool IsConnected() const { return m_connected; }

    /// Check if the slot is connected (authenticated).
    bool IsSlotConnected() const { return m_slotConnected; }

    /// Get a human-readable status string.
    std::string GetStatusString() const;

    /// Get the player's slot number (valid after slot connect).
    int GetPlayerSlot() const { return m_playerSlot; }

    /// Get a player's display name by slot number.
    std::string GetPlayerName(int slot) const;

private:
    // Forward declare the impl to keep apclientpp out of the header
    struct Impl;
    std::unique_ptr<Impl> m_impl;

    ModState*    m_state       = nullptr;
    ItemMapping* m_itemMapping = nullptr;
    HudNotification* m_hud    = nullptr;
    Config       m_config;

    bool m_connected     = false;
    bool m_slotConnected = false;
    int  m_playerSlot    = -1;
    int  m_teamNumber    = -1;
};

} // namespace TalosAP
