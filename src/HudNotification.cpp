#include "headers/HudNotification.h"

#include <Unreal/UObjectGlobals.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/UFunction.hpp>
#include <Unreal/FProperty.hpp>
#include <Unreal/FText.hpp>
#include <Unreal/CoreUObject/UObject/Class.hpp>
#include <DynamicOutput/DynamicOutput.hpp>

#include <cstring>
#include <string>

using namespace RC;
using namespace RC::Unreal;

namespace TalosAP {

// ============================================================
// Param structs matching Unreal UMG function signatures
// These must match the exact memory layout expected by ProcessEvent.
// ============================================================

// UUserWidget::AddToViewport(int32 ZOrder)
struct Params_AddToViewport {
    int32_t ZOrder;
};

// UPanelWidget::RemoveChild(UWidget* Content) -> bool
struct Params_RemoveChild {
    UObject* Content;
    bool     ReturnValue;
};

// UCanvasPanel::AddChildToCanvas(UWidget* Content) -> UCanvasPanelSlot*
struct Params_AddChildToCanvas {
    UObject* Content;
    UObject* ReturnValue;
};

// UHorizontalBox::AddChildToHorizontalBox(UWidget* Content) -> UHorizontalBoxSlot*
struct Params_AddChildToHBox {
    UObject* Content;
    UObject* ReturnValue;
};

// UTextBlock::SetText(FText InText)
// FText is variable size; use a buffer approach
struct Params_SetText {
    FText InText;
};

// FSlateColor layout: { FLinearColor SpecifiedColor (16 bytes), uint8 ColorUseRule (1 byte) } = 0x14 total
// But ProcessEvent uses aligned param structs, so we use the raw layout.
struct FSlateColor {
    float R, G, B, A;           // FLinearColor SpecifiedColor at offset 0x0
    uint8_t ColorUseRule;       // ESlateColorStylingMode at offset 0x10
    uint8_t _pad[3];            // alignment padding
};

// UTextBlock::SetColorAndOpacity(FSlateColor InColorAndOpacity)
struct Params_SetColorAndOpacity {
    FSlateColor InColorAndOpacity;
};

// FVector2D in UE5 = 2 doubles (size 0x10)
struct FVec2D {
    double X, Y;
};

// UTextBlock::SetShadowOffset(FVector2D InShadowOffset)
struct Params_SetShadowOffset {
    FVec2D InShadowOffset;
};

// FLinearColor = 4 floats
struct FLinColor {
    float R, G, B, A;
};

// UTextBlock::SetShadowColorAndOpacity(FLinearColor InShadowColorAndOpacity)
struct Params_SetShadowColorAndOpacity {
    FLinColor InShadowColorAndOpacity;
};

// UCanvasPanelSlot::SetPosition(FVector2D InPosition)
struct Params_SetPosition {
    FVec2D InPosition;
};

// UCanvasPanelSlot::SetAutoSize(bool bInAutoSize)
struct Params_SetAutoSize {
    bool bInAutoSize;
};

// UWidget::SetVisibility(ESlateVisibility InVisibility)
struct Params_SetVisibility {
    uint8_t InVisibility;  // ESlateVisibility enum
};

// UUserWidget::GetIsVisible() -> bool
struct Params_GetIsVisible {
    bool ReturnValue;
};

// ============================================================
// ESlateVisibility values (from UMG_enums.hpp)
// ============================================================
static constexpr uint8_t ESV_SelfHitTestInvisible = 4;

// ============================================================
// CacheClasses — find UClass* for each UMG widget type
// ============================================================
bool HudNotification::CacheClasses()
{
    if (m_classesLoaded) return true;

    try {
        // UClass objects for UMG widgets live at /Script/UMG.<ClassName>
        m_userWidgetClass  = UObjectGlobals::StaticFindObject<UObject*>(nullptr, nullptr, STR("/Script/UMG.UserWidget"));
        m_widgetTreeClass  = UObjectGlobals::StaticFindObject<UObject*>(nullptr, nullptr, STR("/Script/UMG.WidgetTree"));
        m_canvasPanelClass = UObjectGlobals::StaticFindObject<UObject*>(nullptr, nullptr, STR("/Script/UMG.CanvasPanel"));
        m_textBlockClass   = UObjectGlobals::StaticFindObject<UObject*>(nullptr, nullptr, STR("/Script/UMG.TextBlock"));
        m_hboxClass        = UObjectGlobals::StaticFindObject<UObject*>(nullptr, nullptr, STR("/Script/UMG.HorizontalBox"));
    }
    catch (...) {
        Output::send<LogLevel::Error>(STR("[TalosAP-HUD] Exception finding UMG classes\n"));
        return false;
    }

    if (!m_userWidgetClass || !m_widgetTreeClass || !m_canvasPanelClass ||
        !m_textBlockClass  || !m_hboxClass) {
        Output::send<LogLevel::Warning>(STR("[TalosAP-HUD] One or more UMG classes not found\n"));
        return false;
    }

    m_classesLoaded = true;
    Output::send<LogLevel::Verbose>(STR("[TalosAP-HUD] UMG classes cached\n"));
    return true;
}

// ============================================================
// CacheFunctions — find UFunction* for all UMG methods we call
// ============================================================
bool HudNotification::CacheFunctions()
{
    if (m_fnAddToViewport) return true; // already cached

    try {
        m_fnAddToViewport    = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, STR("/Script/UMG.UserWidget:AddToViewport"));
        m_fnGetIsVisible     = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, STR("/Script/UMG.UserWidget:GetIsVisible"));
        m_fnRemoveFromParent = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, STR("/Script/UMG.Widget:RemoveFromParent"));
        m_fnAddChildToCanvas = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, STR("/Script/UMG.CanvasPanel:AddChildToCanvas"));
        m_fnRemoveChild      = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, STR("/Script/UMG.PanelWidget:RemoveChild"));
        m_fnAddChildToHBox   = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, STR("/Script/UMG.HorizontalBox:AddChildToHorizontalBox"));
        m_fnSetText          = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, STR("/Script/UMG.TextBlock:SetText"));
        m_fnSetColorAndOpacity = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, STR("/Script/UMG.TextBlock:SetColorAndOpacity"));
        m_fnSetShadowOffset  = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, STR("/Script/UMG.TextBlock:SetShadowOffset"));
        m_fnSetShadowColorAndOpacity = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, STR("/Script/UMG.TextBlock:SetShadowColorAndOpacity"));
        m_fnSetPosition      = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, STR("/Script/UMG.CanvasPanelSlot:SetPosition"));
        m_fnSetAutoSize      = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, STR("/Script/UMG.CanvasPanelSlot:SetAutoSize"));
        m_fnSetFont          = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, STR("/Script/UMG.TextBlock:SetFont"));
        m_fnSetVisibility    = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, STR("/Script/UMG.Widget:SetVisibility"));
    }
    catch (...) {
        Output::send<LogLevel::Error>(STR("[TalosAP-HUD] Exception finding UMG functions\n"));
        return false;
    }

    // Validate critical functions
    if (!m_fnAddToViewport || !m_fnAddChildToCanvas || !m_fnAddChildToHBox ||
        !m_fnSetText || !m_fnSetColorAndOpacity || !m_fnSetPosition ||
        !m_fnRemoveChild || !m_fnSetVisibility) {
        Output::send<LogLevel::Warning>(STR("[TalosAP-HUD] One or more UMG functions not found\n"));
        return false;
    }

    Output::send<LogLevel::Verbose>(STR("[TalosAP-HUD] UMG functions cached\n"));
    return true;
}

// ============================================================
// Helper: construct a UObject of a given UClass with a given outer
// ============================================================
static UObject* ConstructWidget(UObject* classObj, UObject* outer, const wchar_t* name)
{
    auto* cls = static_cast<UClass*>(classObj);
    FStaticConstructObjectParameters params(cls);
    params.Outer = outer;
    params.Name  = FName(name, FNAME_Add);
    return UObjectGlobals::StaticConstructObject(params);
}

// ============================================================
// CreateWidget — build the UUserWidget + WidgetTree + CanvasPanel
// ============================================================
bool HudNotification::CreateWidget()
{
    if (!CacheClasses()) return false;
    if (!CacheFunctions()) return false;

    // Find a suitable outer — use the GameInstance or transient package
    // In Lua the outer was GameInstance; in C++ we can get it via FindFirstOf.
    UObject* outer = UObjectGlobals::FindFirstOf(STR("GameInstance"));
    if (!outer) {
        Output::send<LogLevel::Warning>(STR("[TalosAP-HUD] GameInstance not found\n"));
        return false;
    }

    DestroyWidget();

    // 1. UserWidget
    m_hudWidget = ConstructWidget(m_userWidgetClass, outer, STR("APNotifWidget"));
    if (!m_hudWidget) {
        Output::send<LogLevel::Error>(STR("[TalosAP-HUD] Failed to construct UserWidget\n"));
        return false;
    }

    // 2. WidgetTree (must be set as the WidgetTree property on the UserWidget)
    UObject* widgetTree = ConstructWidget(m_widgetTreeClass, m_hudWidget, STR("APNotifTree"));
    if (!widgetTree) {
        Output::send<LogLevel::Error>(STR("[TalosAP-HUD] Failed to construct WidgetTree\n"));
        m_hudWidget = nullptr;
        return false;
    }

    // Set UserWidget.WidgetTree = widgetTree
    auto* wtPtr = m_hudWidget->GetValuePtrByPropertyNameInChain<UObject*>(STR("WidgetTree"));
    if (wtPtr) {
        *wtPtr = widgetTree;
    } else {
        Output::send<LogLevel::Error>(STR("[TalosAP-HUD] Could not find WidgetTree property\n"));
        m_hudWidget = nullptr;
        return false;
    }

    // 3. CanvasPanel (root widget of the tree)
    m_canvas = ConstructWidget(m_canvasPanelClass, widgetTree, STR("APNotifCanvas"));
    if (!m_canvas) {
        Output::send<LogLevel::Error>(STR("[TalosAP-HUD] Failed to construct CanvasPanel\n"));
        m_hudWidget = nullptr;
        return false;
    }

    // Set WidgetTree.RootWidget = canvas
    auto* rwPtr = widgetTree->GetValuePtrByPropertyNameInChain<UObject*>(STR("RootWidget"));
    if (rwPtr) {
        *rwPtr = m_canvas;
    } else {
        Output::send<LogLevel::Error>(STR("[TalosAP-HUD] Could not find RootWidget property\n"));
        m_hudWidget = nullptr;
        m_canvas = nullptr;
        return false;
    }

    m_widgetReady = true;
    m_entries.clear();
    m_entryCounter = 0;

    Output::send<LogLevel::Verbose>(STR("[TalosAP-HUD] Widget created\n"));
    return true;
}

// ============================================================
// DestroyWidget
// ============================================================
void HudNotification::DestroyWidget()
{
    if (m_hudWidget && m_fnRemoveFromParent) {
        try {
            m_hudWidget->ProcessEvent(m_fnRemoveFromParent, nullptr);
        } catch (...) {}
    }

    m_hudWidget   = nullptr;
    m_canvas      = nullptr;
    m_widgetReady = false;
    m_entries.clear();
    m_entryCounter = 0;
}

// ============================================================
// EnsureWidgetVisible — re-add to viewport if lost after level transition
// ============================================================
bool HudNotification::EnsureWidgetVisible()
{
    if (!m_widgetReady) {
        if (!CreateWidget()) return false;
    }

    // Check if widget is still valid and visible
    if (m_hudWidget) {
        try {
            if (m_fnGetIsVisible) {
                Params_GetIsVisible params{};
                m_hudWidget->ProcessEvent(m_fnGetIsVisible, &params);
                if (!params.ReturnValue) {
                    // Re-add to viewport
                    Params_AddToViewport vp{};
                    vp.ZOrder = WIDGET_ZORDER;
                    m_hudWidget->ProcessEvent(m_fnAddToViewport, &vp);
                }
            } else {
                // Can't check, just add
                Params_AddToViewport vp{};
                vp.ZOrder = WIDGET_ZORDER;
                m_hudWidget->ProcessEvent(m_fnAddToViewport, &vp);
            }
        }
        catch (...) {
            // Widget became invalid — recreate
            m_widgetReady = false;
            m_entries.clear();
            m_entryCounter = 0;
            if (!CreateWidget()) return false;
            // Add new widget to viewport
            Params_AddToViewport vp{};
            vp.ZOrder = WIDGET_ZORDER;
            m_hudWidget->ProcessEvent(m_fnAddToViewport, &vp);
        }
    } else {
        m_widgetReady = false;
        if (!CreateWidget()) return false;
        Params_AddToViewport vp{};
        vp.ZOrder = WIDGET_ZORDER;
        m_hudWidget->ProcessEvent(m_fnAddToViewport, &vp);
    }

    return true;
}

// ============================================================
// AddEntry — create a HorizontalBox with TextBlock per segment
// ============================================================
void HudNotification::AddEntry(const std::vector<TextSegment>& segments, float duration)
{
    if (!m_canvas || !m_fnAddChildToCanvas || !m_fnAddChildToHBox) return;

    ++m_entryCounter;
    std::wstring baseName = STR("APNotif_") + std::to_wstring(m_entryCounter);

    // 1. Construct HorizontalBox
    UObject* hbox = ConstructWidget(m_hboxClass, m_canvas, (baseName + STR("_HBox")).c_str());
    if (!hbox) {
        Output::send<LogLevel::Warning>(STR("[TalosAP-HUD] Failed to construct HorizontalBox\n"));
        return;
    }

    // Parent HBox to canvas → creates canvas slot
    Params_AddChildToCanvas canvasParams{};
    canvasParams.Content = hbox;
    canvasParams.ReturnValue = nullptr;
    m_canvas->ProcessEvent(m_fnAddChildToCanvas, &canvasParams);
    UObject* canvasSlot = canvasParams.ReturnValue;

    if (canvasSlot && m_fnSetAutoSize) {
        Params_SetAutoSize autoParams{};
        autoParams.bInAutoSize = true;
        canvasSlot->ProcessEvent(m_fnSetAutoSize, &autoParams);
    }

    // Set HBox visibility to SelfHitTestInvisible
    if (m_fnSetVisibility) {
        Params_SetVisibility visParams{};
        visParams.InVisibility = ESV_SelfHitTestInvisible;
        hbox->ProcessEvent(m_fnSetVisibility, &visParams);
    }

    // 2. For each segment, create a TextBlock
    int segIdx = 0;
    for (const auto& seg : segments) {
        ++segIdx;
        std::wstring tbName = baseName + STR("_Seg") + std::to_wstring(segIdx);

        UObject* tb = ConstructWidget(m_textBlockClass, hbox, tbName.c_str());
        if (!tb) continue;

        // Parent TextBlock to HBox
        Params_AddChildToHBox hboxParams{};
        hboxParams.Content = tb;
        hboxParams.ReturnValue = nullptr;
        hbox->ProcessEvent(m_fnAddChildToHBox, &hboxParams);

        // Set font size by reading existing Font struct, modifying Size, writing it back
        if (m_fnSetFont) {
            try {
                // FSlateFontInfo is at a known offset in UTextBlock (0x01E8, size 0x68)
                // We can read it via property name, modify Size at offset 0x50, and call SetFont
                auto* fontPtr = tb->GetValuePtrByPropertyNameInChain<uint8_t>(STR("Font"));
                if (fontPtr) {
                    // FSlateFontInfo.Size is a float at offset 0x50 within the struct
                    float* sizePtr = reinterpret_cast<float*>(fontPtr + 0x50);
                    *sizePtr = 16.0f;  // Font size 16

                    // Now call SetFont with the modified font
                    // FSlateFontInfo is 0x68 bytes — we pass the whole struct as the param
                    // The SetFont function takes FSlateFontInfo by value.
                    // We need to allocate the param buffer containing the struct.
                    uint8_t fontParamBuf[0x68];
                    std::memcpy(fontParamBuf, fontPtr, 0x68);
                    tb->ProcessEvent(m_fnSetFont, fontParamBuf);
                }
            }
            catch (...) {
                // Font setting failed, non-critical
            }
        }

        // SetText
        if (m_fnSetText) {
            try {
                Params_SetText textParams{};
                textParams.InText = FText(seg.text.c_str());
                tb->ProcessEvent(m_fnSetText, &textParams);
            }
            catch (...) {}
        }

        // SetShadowOffset
        if (m_fnSetShadowOffset) {
            try {
                Params_SetShadowOffset shadowParams{};
                shadowParams.InShadowOffset.X = SHADOW_OFFSET;
                shadowParams.InShadowOffset.Y = SHADOW_OFFSET;
                tb->ProcessEvent(m_fnSetShadowOffset, &shadowParams);
            }
            catch (...) {}
        }

        // SetShadowColorAndOpacity (black with 0.9 alpha)
        if (m_fnSetShadowColorAndOpacity) {
            try {
                Params_SetShadowColorAndOpacity shadowColorParams{};
                shadowColorParams.InShadowColorAndOpacity = { 0.0f, 0.0f, 0.0f, 0.9f };
                tb->ProcessEvent(m_fnSetShadowColorAndOpacity, &shadowColorParams);
            }
            catch (...) {}
        }

        // SetColorAndOpacity (segment color)
        if (m_fnSetColorAndOpacity) {
            try {
                Params_SetColorAndOpacity colorParams{};
                colorParams.InColorAndOpacity.R = seg.color.R;
                colorParams.InColorAndOpacity.G = seg.color.G;
                colorParams.InColorAndOpacity.B = seg.color.B;
                colorParams.InColorAndOpacity.A = seg.color.A;
                colorParams.InColorAndOpacity.ColorUseRule = 0; // UseColor_Specified
                tb->ProcessEvent(m_fnSetColorAndOpacity, &colorParams);
            }
            catch (...) {}
        }

        // SetVisibility to SelfHitTestInvisible
        if (m_fnSetVisibility) {
            Params_SetVisibility visParams{};
            visParams.InVisibility = ESV_SelfHitTestInvisible;
            tb->ProcessEvent(m_fnSetVisibility, &visParams);
        }
    }

    // 3. Append to entries
    Entry entry{};
    entry.hbox = hbox;
    entry.expireTime = m_timeAccum + duration;
    m_entries.push_back(entry);

    // If we exceed MAX_VISIBLE, remove the oldest
    while (static_cast<int>(m_entries.size()) > MAX_VISIBLE) {
        RemoveEntry(m_entries.front());
        m_entries.pop_front();
    }

    // Update all entry positions
    RepositionEntries();
}

// ============================================================
// RemoveEntry — detach a HorizontalBox from the canvas
// ============================================================
void HudNotification::RemoveEntry(const Entry& entry)
{
    if (!entry.hbox || !m_canvas || !m_fnRemoveChild) return;

    try {
        Params_RemoveChild params{};
        params.Content = entry.hbox;
        params.ReturnValue = false;
        m_canvas->ProcessEvent(m_fnRemoveChild, &params);
    }
    catch (...) {}
}

// ============================================================
// RepositionEntries — update Y positions for all visible entries
// ============================================================
void HudNotification::RepositionEntries()
{
    if (!m_fnSetPosition) return;

    int i = 0;
    for (auto& entry : m_entries) {
        if (!entry.hbox) { ++i; continue; }

        // Get the canvas slot for this hbox. The slot is stored as the
        // "Slot" property on the widget itself (UWidget.Slot -> UPanelSlot).
        try {
            auto* slotPtr = entry.hbox->GetValuePtrByPropertyNameInChain<UObject*>(STR("Slot"));
            if (slotPtr && *slotPtr) {
                Params_SetPosition posParams{};
                posParams.InPosition.X = START_X;
                posParams.InPosition.Y = START_Y + i * LINE_SPACING;
                (*slotPtr)->ProcessEvent(m_fnSetPosition, &posParams);
            }
        }
        catch (...) {}

        ++i;
    }
}

// ============================================================
// ExpireTick — remove entries whose time has passed
// ============================================================
void HudNotification::ExpireTick()
{
    bool changed = false;
    auto it = m_entries.begin();
    while (it != m_entries.end()) {
        if (m_timeAccum >= it->expireTime) {
            RemoveEntry(*it);
            it = m_entries.erase(it);
            changed = true;
        } else {
            ++it;
        }
    }
    if (changed) {
        RepositionEntries();
    }
}

// ============================================================
// Init — cache UMG class and function pointers
// ============================================================
bool HudNotification::Init()
{
    bool ok = CacheClasses() && CacheFunctions();
    if (ok) {
        Output::send<LogLevel::Verbose>(STR("[TalosAP-HUD] Initialized\n"));
    }
    return ok;
}

// ============================================================
// Notify — queue a multi-color notification
// ============================================================
void HudNotification::Notify(const std::vector<TextSegment>& segments, float duration)
{
    if (segments.empty()) return;

    // Log the full text
    std::wstring fullText;
    for (const auto& seg : segments) fullText += seg.text;
    Output::send<LogLevel::Verbose>(STR("[TalosAP-HUD] Notify: {}\n"), fullText);

    m_pendingQueue.push_back({ segments, duration });

    // Cap the pending queue
    while (static_cast<int>(m_pendingQueue.size()) > MAX_VISIBLE) {
        m_pendingQueue.pop_front();
    }
}

// ============================================================
// NotifySimple — queue a single-color notification
// ============================================================
void HudNotification::NotifySimple(const std::wstring& text, const LinearColor& color, float duration)
{
    Notify({ { text, color } }, duration);
}

// ============================================================
// Tick — called every game tick to drain queue and expire entries
// ============================================================
void HudNotification::Tick(float deltaTicks, float ticksPerSecond)
{
    if (!m_classesLoaded) return;

    m_timeAccum += deltaTicks / ticksPerSecond;

    // Only process HUD work every ~12 ticks (~200ms at 60fps) to match Lua's TICK_MS=200
    // But we need the time accumulator to advance every tick for accurate expiry.
    // Use a simple modulo on the integral tick count.
    // Actually, we can just process every call since the caller (dllmain) rate-limits us.

    if (!EnsureWidgetVisible()) return;

    // Drain pending queue
    while (!m_pendingQueue.empty()) {
        auto& notif = m_pendingQueue.front();
        try {
            AddEntry(notif.segments, notif.duration);
        }
        catch (...) {
            Output::send<LogLevel::Error>(STR("[TalosAP-HUD] AddEntry failed\n"));
        }
        m_pendingQueue.pop_front();
    }

    // Expire old entries
    try {
        ExpireTick();
    }
    catch (...) {}
}

// ============================================================
// Clear — remove all visible entries and pending queue
// ============================================================
void HudNotification::Clear()
{
    m_pendingQueue.clear();

    for (auto& entry : m_entries) {
        RemoveEntry(entry);
    }
    m_entries.clear();
}

} // namespace TalosAP
