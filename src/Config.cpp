#include "headers/Config.h"

#include <fstream>
#include <filesystem>
#include <nlohmann/json.hpp>
#include <DynamicOutput/DynamicOutput.hpp>

using json = nlohmann::json;
namespace fs = std::filesystem;

namespace TalosAP {

// Convert wide string to narrow UTF-8 string
static std::string WideToNarrow(const std::wstring& wide)
{
    if (wide.empty()) return {};
    std::string result;
    result.reserve(wide.size());
    for (wchar_t ch : wide) {
        if (ch < 0x80) {
            result.push_back(static_cast<char>(ch));
        } else if (ch < 0x800) {
            result.push_back(static_cast<char>(0xC0 | (ch >> 6)));
            result.push_back(static_cast<char>(0x80 | (ch & 0x3F)));
        } else {
            result.push_back(static_cast<char>(0xE0 | (ch >> 12)));
            result.push_back(static_cast<char>(0x80 | ((ch >> 6) & 0x3F)));
            result.push_back(static_cast<char>(0x80 | (ch & 0x3F)));
        }
    }
    return result;
}

// Convert narrow UTF-8 string to wide string
static std::wstring NarrowToWide(const std::string& narrow)
{
    if (narrow.empty()) return {};
    std::wstring result;
    result.reserve(narrow.size());
    for (size_t i = 0; i < narrow.size(); ) {
        unsigned char c = narrow[i];
        if (c < 0x80) {
            result.push_back(static_cast<wchar_t>(c));
            i += 1;
        } else if ((c >> 5) == 0x6) {
            wchar_t wc = (c & 0x1F) << 6;
            if (i + 1 < narrow.size()) wc |= (narrow[i + 1] & 0x3F);
            result.push_back(wc);
            i += 2;
        } else if ((c >> 4) == 0xE) {
            wchar_t wc = (c & 0x0F) << 12;
            if (i + 1 < narrow.size()) wc |= (narrow[i + 1] & 0x3F) << 6;
            if (i + 2 < narrow.size()) wc |= (narrow[i + 2] & 0x3F);
            result.push_back(wc);
            i += 3;
        } else {
            result.push_back(L'?');
            i += 1;
        }
    }
    return result;
}

void Config::SyncNarrowStrings()
{
    server_str    = WideToNarrow(server);
    slot_name_str = WideToNarrow(slot_name);
    password_str  = WideToNarrow(password);
    game_str      = WideToNarrow(game);
}

void Config::Load(const std::wstring& modDir)
{
    using namespace RC;

    // Build search paths
    std::vector<fs::path> searchPaths;
    if (!modDir.empty()) {
        searchPaths.push_back(fs::path(modDir) / L"config.json");
    }
    searchPaths.push_back(fs::path(L"Mods") / L"TalosPrincipleArchipelagoClient" / L"config.json");
    searchPaths.push_back(fs::path(L"config.json"));

    std::string fileContent;
    fs::path foundPath;

    for (const auto& path : searchPaths) {
        std::ifstream file(path);
        if (file.is_open()) {
            fileContent.assign(std::istreambuf_iterator<char>(file),
                               std::istreambuf_iterator<char>());
            foundPath = path;
            break;
        }
    }

    if (fileContent.empty()) {
        Output::send<LogLevel::Warning>(STR("[TalosAP] config.json not found — using defaults\n"));
        SyncNarrowStrings();
        return;
    }

    try {
        auto j = json::parse(fileContent);

        if (j.contains("server") && j["server"].is_string()) {
            auto val = j["server"].get<std::string>();
            if (!val.empty()) server = NarrowToWide(val);
        }
        if (j.contains("slot_name") && j["slot_name"].is_string()) {
            auto val = j["slot_name"].get<std::string>();
            if (!val.empty()) slot_name = NarrowToWide(val);
        }
        if (j.contains("password") && j["password"].is_string()) {
            password = NarrowToWide(j["password"].get<std::string>());
        }
        if (j.contains("game") && j["game"].is_string()) {
            auto val = j["game"].get<std::string>();
            if (!val.empty()) game = NarrowToWide(val);
        }
        if (j.contains("offline_mode") && j["offline_mode"].is_string()) {
            auto val = j["offline_mode"].get<std::string>();
            offline_mode = (val == "true" || val == "1");
        }
    }
    catch (const json::exception& e) {
        Output::send<LogLevel::Warning>(STR("[TalosAP] config.json parse error: {}\n"),
                                        NarrowToWide(e.what()));
    }

    SyncNarrowStrings();

    Output::send<LogLevel::Verbose>(STR("[TalosAP] Config loaded from {}\n"), foundPath.wstring());
    Output::send<LogLevel::Verbose>(STR("[TalosAP]   server    = {}\n"), server);
    Output::send<LogLevel::Verbose>(STR("[TalosAP]   slot_name = {}\n"), slot_name);
    Output::send<LogLevel::Verbose>(STR("[TalosAP]   password  = {}\n"),
                                    password.empty() ? L"(none)" : L"****");
    Output::send<LogLevel::Verbose>(STR("[TalosAP]   game      = {}\n"), game);
    if (offline_mode) {
        Output::send<LogLevel::Verbose>(STR("[TalosAP]   offline_mode = true\n"));
    }
}

} // namespace TalosAP
