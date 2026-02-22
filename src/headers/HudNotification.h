#pragma once

#include <Unreal/UObject.hpp>

#include <string>
#include <vector>
#include <deque>
#include <cstdint>

namespace TalosAP {

// ============================================================
// FLinearColor (matching UE5 memory layout: 4 floats = 16 bytes)
// ============================================================
struct LinearColor {
    float R = 1.0f, G = 1.0f, B = 1.0f, A = 1.0f;
};

// ============================================================
// Color Constants (matching Lua HUD colors)
// ============================================================
namespace HudColors {
    inline constexpr LinearColor WHITE       { 1.0f,  1.0f,  1.0f,  1.0f };
    inline constexpr LinearColor PLAYER      { 0.4f,  0.9f,  1.0f,  1.0f };  // cyan
    inline constexpr LinearColor ITEM        { 0.5f,  1.0f,  0.5f,  1.0f };  // green (filler)
    inline constexpr LinearColor PROGRESSION { 0.75f, 0.53f, 1.0f,  1.0f };  // purple
    inline constexpr LinearColor USEFUL      { 0.4f,  0.6f,  1.0f,  1.0f };  // blue
    inline constexpr LinearColor TRAP        { 1.0f,  0.4f,  0.4f,  1.0f };  // red
    inline constexpr LinearColor LOCATION    { 1.0f,  0.9f,  0.4f,  1.0f };  // gold
    inline constexpr LinearColor ENTRANCE    { 0.4f,  0.7f,  1.0f,  1.0f };  // steel blue
    inline constexpr LinearColor SERVER      { 0.93f, 0.93f, 0.82f, 1.0f };  // warm white
}

/// Returns the HUD color for an AP item flags value.
/// flags: 0=filler, 1=progression, 2=useful, 4=trap
inline LinearColor ColorForFlags(int flags) {
    switch (flags) {
        case 1:  return HudColors::PROGRESSION;
        case 2:  return HudColors::USEFUL;
        case 4:  return HudColors::TRAP;
        default: return HudColors::ITEM;
    }
}

// ============================================================
// TextSegment — one colored piece of a notification line
// ============================================================
struct TextSegment {
    std::wstring text;
    LinearColor  color = HudColors::WHITE;
};

// ============================================================
// HudNotification — UMG scrolling-log overlay
//
// Creates a UUserWidget with a CanvasPanel root. Each notification
// is a HorizontalBox containing TextBlock children for colored
// segments. Max 12 visible lines, 6-second expiry, auto-scroll.
//
// CRITICAL: No UObject* is cached across ticks. The widget is
// re-created if lost (e.g. after level transitions).
//
// Public API:
//   Init()                             — cache UMG UClass pointers
//   Notify(segments, duration)         — queue a multi-color line
//   NotifySimple(text, color, duration)— queue a single-color line
//   Tick(deltaTicks)                   — drain queue, expire entries
//   Clear()                            — remove all entries
// ============================================================
class HudNotification {
public:
    static constexpr int   MAX_VISIBLE    = 15;
    static constexpr float DEFAULT_DURATION = 6.0f;   // seconds
    static constexpr float START_X        = 40.0f;
    static constexpr float START_Y        = 400.0f;
    static constexpr float LINE_SPACING   = 34.0f;
    static constexpr int   WIDGET_ZORDER  = 100;
    static constexpr float SHADOW_OFFSET  = 2.0f;

    /// Cache UMG class pointers. Call once from on_unreal_init.
    bool Init();

    /// Queue a notification with multiple colored segments.
    void Notify(const std::vector<TextSegment>& segments,
                float duration = DEFAULT_DURATION);

    /// Queue a single-color notification.
    void NotifySimple(const std::wstring& text,
                      const LinearColor& color = HudColors::WHITE,
                      float duration = DEFAULT_DURATION);

    /// Called every tick from on_update. Manages widget lifecycle,
    /// drains pending queue, and expires old entries.
    /// ticksPerSecond: approximate tick rate (default 60).
    void Tick(float deltaTicks = 1.0f, float ticksPerSecond = 60.0f);

    /// Remove all visible entries and clear the pending queue.
    void Clear();

    /// Check if the HUD system is initialized.
    bool IsInitialized() const { return m_classesLoaded; }

private:
    // ---- UMG class pointers (cached, safe — UClass objects are persistent) ----
    RC::Unreal::UObject* m_userWidgetClass    = nullptr;
    RC::Unreal::UObject* m_widgetTreeClass    = nullptr;
    RC::Unreal::UObject* m_canvasPanelClass   = nullptr;
    RC::Unreal::UObject* m_textBlockClass     = nullptr;
    RC::Unreal::UObject* m_hboxClass          = nullptr;
    bool m_classesLoaded = false;

    // ---- UFunction pointers (cached, safe — UFunction objects are persistent) ----
    RC::Unreal::UFunction* m_fnAddToViewport       = nullptr;
    RC::Unreal::UFunction* m_fnGetIsVisible        = nullptr;
    RC::Unreal::UFunction* m_fnRemoveFromParent    = nullptr;
    RC::Unreal::UFunction* m_fnAddChildToCanvas    = nullptr;
    RC::Unreal::UFunction* m_fnRemoveChild         = nullptr;
    RC::Unreal::UFunction* m_fnAddChildToHBox      = nullptr;
    RC::Unreal::UFunction* m_fnSetText             = nullptr;
    RC::Unreal::UFunction* m_fnSetColorAndOpacity  = nullptr;
    RC::Unreal::UFunction* m_fnSetShadowOffset     = nullptr;
    RC::Unreal::UFunction* m_fnSetShadowColorAndOpacity = nullptr;
    RC::Unreal::UFunction* m_fnSetPosition         = nullptr;
    RC::Unreal::UFunction* m_fnSetAutoSize         = nullptr;
    RC::Unreal::UFunction* m_fnSetFont             = nullptr;
    RC::Unreal::UFunction* m_fnSetVisibility       = nullptr;

    // ---- Widget state (recreated per session, not cached across ticks) ----
    // We store the FName of the widget so we can look it up each tick.
    // However, since we create and manage the widget ourselves, we track
    // it by raw pointer but validate it before use.
    RC::Unreal::UObject* m_hudWidget = nullptr;  // UUserWidget
    RC::Unreal::UObject* m_canvas    = nullptr;  // UCanvasPanel (root)
    bool m_widgetReady = false;

    // ---- Entry tracking ----
    struct Entry {
        RC::Unreal::UObject* hbox = nullptr; // UHorizontalBox (NOT cached across ticks in theory,
                                              // but we own it and manage its lifetime)
        float expireTime = 0.0f;              // timeAccum at which this expires
    };
    std::deque<Entry> m_entries;
    int m_entryCounter = 0;
    float m_timeAccum  = 0.0f;

    // ---- Pending queue ----
    struct PendingNotification {
        std::vector<TextSegment> segments;
        float duration;
    };
    std::deque<PendingNotification> m_pendingQueue;

    // ---- Internal helpers ----
    bool CacheClasses();
    bool CacheFunctions();
    bool CreateWidget();
    void DestroyWidget();
    bool EnsureWidgetVisible();
    void AddEntry(const std::vector<TextSegment>& segments, float duration);
    void RemoveEntry(const Entry& entry);
    void RepositionEntries();
    void ExpireTick();
};

} // namespace TalosAP
