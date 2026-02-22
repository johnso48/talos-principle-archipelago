// Include wswrap + websocketpp backend before apclientpp
#include <wswrap.hpp>

// apclientpp (header-only Archipelago client)
#include <apclient.hpp>
#include <apuuid.hpp>

#include "headers/APClient.h"

#include <DynamicOutput/DynamicOutput.hpp>
#include <nlohmann/json.hpp>

#include <list>
#include <set>
#include <unordered_map>

using namespace RC;
using json = nlohmann::json;

// ============================================================
// Map AP named-color strings to HUD LinearColors
// (mirrors the Lua AP_NAMED_COLORS table)
// ============================================================
static const std::unordered_map<std::string, TalosAP::LinearColor> AP_NAMED_COLORS = {
    {"red",       TalosAP::HudColors::TRAP},
    {"green",     TalosAP::HudColors::ITEM},
    {"blue",      TalosAP::HudColors::USEFUL},
    {"slateblue", TalosAP::HudColors::USEFUL},
    {"magenta",   TalosAP::HudColors::PROGRESSION},
    {"purple",    TalosAP::HudColors::PROGRESSION},
    {"plum",      TalosAP::HudColors::PROGRESSION},
    {"yellow",    TalosAP::HudColors::LOCATION},
    {"cyan",      TalosAP::HudColors::PLAYER},
    {"salmon",    TalosAP::HudColors::TRAP},
    {"white",     TalosAP::HudColors::WHITE},
    {"black",     TalosAP::HudColors::WHITE},  // don't render invisible text
};

namespace TalosAP {

// ============================================================
// Impl — hides the APClient (from apclientpp) from the header
// ============================================================
struct APClientWrapper::Impl {
    std::unique_ptr<APClient> ap;
};

// ============================================================
// Construction / Destruction
// ============================================================

APClientWrapper::APClientWrapper() = default;

APClientWrapper::~APClientWrapper()
{
    // Impl destructor destroys the APClient, cleaning up the socket
    m_impl.reset();
}

// ============================================================
// Init
// ============================================================

bool APClientWrapper::Init(const Config& config, ModState& state, ItemMapping& itemMapping,
                          HudNotification* hud)
{
    m_config      = config;
    m_state       = &state;
    m_itemMapping = &itemMapping;
    m_hud         = hud;

    m_impl = std::make_unique<Impl>();

    try {
        // Generate or load a persistent UUID for this client
        std::string uuid = ap_get_uuid("talos_ap_uuid.txt");

        Output::send<LogLevel::Verbose>(STR("[TalosAP] Creating AP client: game='{}', server='{}'\n"),
            std::wstring(config.game_str.begin(), config.game_str.end()),
            std::wstring(config.server_str.begin(), config.server_str.end()));

        m_impl->ap = std::make_unique<APClient>(uuid, config.game_str, config.server_str);
    }
    catch (const std::exception& e) {
        Output::send<LogLevel::Error>(STR("[TalosAP] Failed to create AP client: {}\n"),
            std::wstring(e.what(), e.what() + strlen(e.what())));
        m_impl.reset();
        return false;
    }

    auto& ap = *m_impl->ap;

    // ============================================================
    // Register event handlers
    // All callbacks fire from within poll() on the game thread.
    // ============================================================

    ap.set_socket_connected_handler([this]() {
        m_connected = true;
        Output::send<LogLevel::Verbose>(STR("[TalosAP] Socket connected to server\n"));
        if (m_hud) {
            m_hud->NotifySimple(L"Connected to AP server", HudColors::SERVER);
        }
    });

    ap.set_socket_disconnected_handler([this]() {
        m_connected = false;
        m_slotConnected = false;
        Output::send<LogLevel::Warning>(STR("[TalosAP] Socket disconnected\n"));
        if (m_hud) {
            m_hud->NotifySimple(L"Disconnected from AP server", HudColors::TRAP);
        }
    });

    ap.set_socket_error_handler([this](const std::string& msg) {
        Output::send<LogLevel::Error>(STR("[TalosAP] Socket error: {}\n"),
            std::wstring(msg.begin(), msg.end()));
    });

    ap.set_room_info_handler([this]() {
        Output::send<LogLevel::Verbose>(STR("[TalosAP] Room info received, connecting slot '{}'\n"),
            m_config.slot_name);

        if (m_impl && m_impl->ap) {
            m_impl->ap->ConnectSlot(
                m_config.slot_name_str,
                m_config.password_str,
                7,  // items_handling: receive from all sources (0b111)
                {"AP"},
                {0, 5, 1}  // AP protocol version
            );
        }
    });

    ap.set_slot_connected_handler([this](const json& slotData) {
        m_slotConnected = true;

        if (m_impl && m_impl->ap) {
            m_playerSlot = m_impl->ap->get_player_number();
            m_teamNumber = m_impl->ap->get_team_number();
        }

        Output::send<LogLevel::Verbose>(STR("[TalosAP] Slot connected! player={} team={}\n"),
            m_playerSlot, m_teamNumber);

        // Reset item counters for a clean replay of items
        m_itemMapping->ResetItemCounters();
        m_state->GrantedItems.clear();

        // Restore checked locations from the server
        if (m_impl && m_impl->ap) {
            auto serverChecked = m_impl->ap->get_checked_locations();
            int restoredCount = 0;
            for (int64_t locId : serverChecked) {
                std::string tetId = m_itemMapping->GetLocationName(locId);
                if (!tetId.empty()) {
                    m_state->MarkLocationChecked(tetId);
                    ++restoredCount;
                }
            }
            if (restoredCount > 0) {
                Output::send<LogLevel::Verbose>(STR("[TalosAP] Restored {} checked locations from server\n"),
                    restoredCount);
            }

            // Send locally-checked locations the server doesn't know about
            auto serverCheckedSet = m_impl->ap->get_checked_locations();
            std::list<int64_t> toSend;
            for (const auto& tetId : m_state->CheckedLocations) {
                int64_t locId = m_itemMapping->GetLocationId(tetId);
                if (locId >= 0 && serverCheckedSet.count(locId) == 0) {
                    toSend.push_back(locId);
                }
            }
            if (!toSend.empty()) {
                Output::send<LogLevel::Verbose>(STR("[TalosAP] Sending {} locally checked locations to server\n"),
                    toSend.size());
                m_impl->ap->LocationChecks(toSend);
            }
        }

        // Read slot_data settings
        if (slotData.contains("reusable_tetrominos")) {
            int reusable = slotData["reusable_tetrominos"].get<int>();
            m_state->ReusableTetrominos = (reusable != 0);
            Output::send<LogLevel::Verbose>(STR("[TalosAP] reusable_tetrominos = {}\n"),
                m_state->ReusableTetrominos ? L"true" : L"false");
        }

        // Mark AP as synced — enforcement can now begin
        m_state->APSynced = true;
        Output::send<LogLevel::Verbose>(STR("[TalosAP] APSynced = true — enforcement enabled\n"));

        // Send playing status
        if (m_impl && m_impl->ap) {
            m_impl->ap->StatusUpdate(APClient::ClientStatus::PLAYING);
        }

        // HUD notification
        if (m_hud) {
            m_hud->NotifySimple(L"Slot connected — game synced!", HudColors::SERVER);
        }
    });

    ap.set_slot_refused_handler([this](const std::list<std::string>& reasons) {
        m_slotConnected = false;
        std::string msg;
        for (const auto& r : reasons) {
            if (!msg.empty()) msg += ", ";
            msg += r;
        }
        Output::send<LogLevel::Error>(STR("[TalosAP] Connection refused: {}\n"),
            std::wstring(msg.begin(), msg.end()));
        if (m_hud) {
            std::wstring wMsg(msg.begin(), msg.end());
            m_hud->Notify({
                { L"Connection refused: ", HudColors::TRAP },
                { wMsg,                    HudColors::WHITE },
            });
        }
    });

    ap.set_items_received_handler([this](const std::list<APClient::NetworkItem>& items) {
        Output::send<LogLevel::Verbose>(STR("[TalosAP] Received {} items\n"), items.size());

        int grantedCount = 0;
        int nonTetrominoCount = 0;

        for (const auto& item : items) {
            auto tetId = m_itemMapping->ResolveNextItem(item.item);

            // Resolve display name: prefer our local mapping, fall back to AP data package
            std::string displayName;
            if (tetId.has_value()) {
                displayName = m_itemMapping->GetDisplayName(item.item);
                if (displayName.empty()) displayName = tetId.value();
            }
            if (displayName.empty() && m_impl && m_impl->ap) {
                // Use AP library to look up item name from the data package
                try {
                    std::string game = m_impl->ap->get_player_game(m_impl->ap->get_player_number());
                    displayName = m_impl->ap->get_item_name(item.item, game);
                    if (displayName == "Unknown") displayName.clear();
                } catch (...) {}
            }
            if (displayName.empty()) {
                displayName = "Item #" + std::to_string(item.item);
            }

            if (tetId.has_value()) {
                // Grant the tetromino — add to GrantedItems set.
                m_state->GrantedItems.insert(tetId.value());
                ++grantedCount;
            } else {
                // Non-tetromino item (e.g. trap, filler, progression unlock)
                ++nonTetrominoCount;
                Output::send<LogLevel::Verbose>(STR("[TalosAP] Non-tetromino item received: {} (0x{:X}) = {}\n"),
                    item.item, item.item,
                    std::wstring(displayName.begin(), displayName.end()));
            }

            // Notifications are shown for ALL items, not just tetrominoes
            bool isSelf = (item.player == m_playerSlot);
            if (!isSelf) {
                std::string senderName = GetPlayerName(item.player);
                Output::send<LogLevel::Verbose>(STR("[TalosAP] {} sent you {}\n"),
                    std::wstring(senderName.begin(), senderName.end()),
                    std::wstring(displayName.begin(), displayName.end()));

                if (m_hud) {
                    int flags = item.flags;
                    LinearColor itemColor = ColorForFlags(flags);
                    std::wstring wSender(senderName.begin(), senderName.end());
                    std::wstring wDisplay(displayName.begin(), displayName.end());
                    m_hud->Notify({
                        { wSender,          HudColors::PLAYER },
                        { L" sent you ",    HudColors::WHITE  },
                        { wDisplay,         itemColor         },
                    });
                }
            } else {
                Output::send<LogLevel::Verbose>(STR("[TalosAP] You found {}\n"),
                    std::wstring(displayName.begin(), displayName.end()));

                if (m_hud) {
                    int flags = item.flags;
                    LinearColor itemColor = ColorForFlags(flags);
                    std::wstring wDisplay(displayName.begin(), displayName.end());
                    m_hud->Notify({
                        { L"You found ",  HudColors::WHITE },
                        { wDisplay,       itemColor        },
                    });
                }
            }
        }

        Output::send<LogLevel::Verbose>(STR("[TalosAP] Processed items: {} tetrominoes, {} other\n"),
            grantedCount, nonTetrominoCount);

        // Ensure APSynced is set
        m_state->APSynced = true;
    });

    ap.set_location_checked_handler([this](const std::list<int64_t>& locations) {
        Output::send<LogLevel::Verbose>(STR("[TalosAP] Server confirmed {} location checks\n"),
            locations.size());

        for (int64_t locId : locations) {
            std::string tetId = m_itemMapping->GetLocationName(locId);
            if (!tetId.empty()) {
                m_state->MarkLocationChecked(tetId);
            }
        }
    });

    // ============================================================
    // PrintJSON — other-player activity, hints, chat, countdown, etc.
    // This is how we see messages like "PlayerX found ItemY at LocationZ"
    // for other players in the multiworld session.
    // ============================================================
    ap.set_print_json_handler([this](const APClient::PrintJSONArgs& args) {
        if (!m_impl || !m_impl->ap) return;

        // Suppress self-to-self ItemSend — our items_received_handler
        // already shows "You found ..." for those.
        if (args.type == "ItemSend"
            && args.receiving && *args.receiving == m_playerSlot
            && args.item && args.item->player == m_playerSlot) {
            return;
        }

        // Build colored segments from the TextNode list
        std::vector<TextSegment> segments;
        std::string plainText;

        for (const auto& node : args.data) {
            std::string text;
            LinearColor color = HudColors::WHITE;

            if (node.type == "player_id") {
                int slot = 0;
                try { slot = std::stoi(node.text); } catch (...) {}
                text = GetPlayerName(slot);
                color = HudColors::PLAYER;
            }
            else if (node.type == "item_id") {
                int64_t id = 0;
                try { id = std::stoll(node.text); } catch (...) {}
                try {
                    std::string game = m_impl->ap->get_player_game(node.player);
                    text = m_impl->ap->get_item_name(id, game);
                } catch (...) { text = "Unknown Item"; }
                color = ColorForFlags(node.flags);
            }
            else if (node.type == "item_name") {
                text = node.text;
                color = ColorForFlags(node.flags);
            }
            else if (node.type == "location_id") {
                int64_t id = 0;
                try { id = std::stoll(node.text); } catch (...) {}
                try {
                    std::string game = m_impl->ap->get_player_game(node.player);
                    text = m_impl->ap->get_location_name(id, game);
                } catch (...) { text = "Unknown Location"; }
                color = HudColors::LOCATION;
            }
            else if (node.type == "location_name") {
                text = node.text;
                color = HudColors::LOCATION;
            }
            else if (node.type == "entrance_name") {
                text = node.text;
                color = HudColors::ENTRANCE;
            }
            else if (node.type == "color") {
                text = node.text;
                auto it = AP_NAMED_COLORS.find(node.color);
                color = (it != AP_NAMED_COLORS.end()) ? it->second : HudColors::WHITE;
            }
            else {
                // "text" type or unknown — plain white
                text = node.text;
            }

            if (!text.empty()) {
                plainText += text;
                std::wstring wText(text.begin(), text.end());
                segments.push_back({ wText, color });
            }
        }

        if (segments.empty()) return;

        // Log the plain text
        Output::send<LogLevel::Verbose>(STR("[TalosAP][Chat] {}\n"),
            std::wstring(plainText.begin(), plainText.end()));

        // Show on HUD
        if (m_hud) {
            m_hud->Notify(segments);
        }
    });

    Output::send<LogLevel::Verbose>(STR("[TalosAP] AP client initialized, connection will start on poll()\n"));
    return true;
}

// ============================================================
// Poll
// ============================================================

void APClientWrapper::Poll()
{
    if (!m_impl || !m_impl->ap) return;

    try {
        m_impl->ap->poll();
    }
    catch (const std::exception& e) {
        Output::send<LogLevel::Error>(STR("[TalosAP] Poll exception: {}\n"),
            std::wstring(e.what(), e.what() + strlen(e.what())));
    }
}

// ============================================================
// Send actions
// ============================================================

void APClientWrapper::SendLocationCheck(int64_t locationId)
{
    if (!m_impl || !m_impl->ap || !m_slotConnected) {
        Output::send<LogLevel::Warning>(STR("[TalosAP] Cannot send location check — not connected\n"));
        return;
    }

    m_impl->ap->LocationChecks({locationId});
    Output::send<LogLevel::Verbose>(STR("[TalosAP] Sent location check: {}\n"), locationId);
}

void APClientWrapper::SendGoalComplete()
{
    if (!m_impl || !m_impl->ap || !m_slotConnected) {
        Output::send<LogLevel::Warning>(STR("[TalosAP] Cannot send goal — not connected\n"));
        return;
    }

    m_impl->ap->StatusUpdate(APClient::ClientStatus::GOAL);
    Output::send<LogLevel::Verbose>(STR("[TalosAP] Sent goal completion!\n"));
}

// ============================================================
// Status
// ============================================================

std::string APClientWrapper::GetStatusString() const
{
    if (!m_impl || !m_impl->ap) return "not initialized";
    auto state = m_impl->ap->get_state();
    switch (state) {
        case APClient::State::DISCONNECTED:       return "disconnected";
        case APClient::State::SOCKET_CONNECTING:  return "connecting";
        case APClient::State::SOCKET_CONNECTED:   return "socket connected";
        case APClient::State::ROOM_INFO:          return "room info received";
        case APClient::State::SLOT_CONNECTED:     return "slot connected";
        default:                                  return "unknown";
    }
}

std::string APClientWrapper::GetPlayerName(int slot) const
{
    if (slot == 0) return "Server";
    if (m_impl && m_impl->ap) {
        try {
            std::string alias = m_impl->ap->get_player_alias(slot);
            if (!alias.empty()) return alias;
        } catch (...) {}
    }
    return "Player " + std::to_string(slot);
}

} // namespace TalosAP
