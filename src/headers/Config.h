#pragma once

#include <string>

namespace TalosAP {

struct Config {
    std::wstring server    = L"archipelago.gg:38281";
    std::wstring slot_name = L"Player1";
    std::wstring password  = L"";
    std::wstring game      = L"The Talos Principle Reawakened";
    bool offline_mode      = false;

    // Narrow-string versions for apclientpp (which uses std::string)
    std::string server_str;
    std::string slot_name_str;
    std::string password_str;
    std::string game_str;

    /// Load configuration from config.json located relative to the mod DLL.
    /// Falls back to defaults if the file is not found or malformed.
    void Load(const std::wstring& modDir);

private:
    /// Synchronize narrow-string copies from wide-string fields.
    void SyncNarrowStrings();
};

} // namespace TalosAP
