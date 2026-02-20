-- ============================================================
-- HUD Notification Module (UMG Widget Overlay) — Scrolling Log
--
-- Displays on-screen notifications as a scrolling log. Up to
-- MAX_VISIBLE lines are shown at once. New messages appear at
-- the bottom; old messages scroll up and expire after a timeout.
--
-- TextBlocks are created on-demand when a notification arrives
-- and destroyed when they expire or are pushed out.
--
-- Usage:
--   local HUD = require("lib.hud")
--   HUD.Init()
--   HUD.Notify({
--       { text = "Alice",        color = HUD.COLORS.PLAYER },
--       { text = " sent you ",  color = HUD.COLORS.WHITE  },
--       { text = "Red L",        color = HUD.COLORS.TRAP   },
--   })
--   HUD.NotifySimple("Hello world", HUD.COLORS.WHITE)
-- ============================================================

local Logging = require("lib.logging")
local UEHelpers = require("UEHelpers")

local M = {}

-- ============================================================
-- Configuration
-- ============================================================
local enabled           = true
local MAX_VISIBLE       = 12      -- max lines shown at once
local DEFAULT_DURATION  = 6.0    -- seconds a notification stays visible
local START_X           = 40     -- left margin
local START_Y           = 400    -- top of the log area
local LINE_SPACING      = 34     -- vertical gap between lines
local SHADOW_OFFSET_X   = 2.0
local SHADOW_OFFSET_Y   = 2.0
local SHADOW_COLOR      = { R = 0, G = 0, B = 0, A = 0.9 }
local WIDGET_ZORDER     = 100

-- ESlateVisibility enum values (from UMG_enums.hpp)
local ESlateVisibility = {
    Visible              = 0,
    Collapsed            = 1,
    Hidden               = 2,
    HitTestInvisible     = 3,
    SelfHitTestInvisible = 4,
}

-- ============================================================
-- Color Constants (exported for use by other modules)
-- ============================================================
M.COLORS = {
    WHITE       = { R = 1.0,  G = 1.0,  B = 1.0,  A = 1.0 },
    PLAYER      = { R = 0.4,  G = 0.9,  B = 1.0,  A = 1.0 },  -- cyan
    ITEM        = { R = 0.5,  G = 1.0,  B = 0.5,  A = 1.0 },  -- green (filler)
    PROGRESSION = { R = 0.75, G = 0.53, B = 1.0,  A = 1.0 },  -- purple
    USEFUL      = { R = 0.4,  G = 0.6,  B = 1.0,  A = 1.0 },  -- blue
    TRAP        = { R = 1.0,  G = 0.4,  B = 0.4,  A = 1.0 },  -- red
    LOCATION    = { R = 1.0,  G = 0.9,  B = 0.4,  A = 1.0 },  -- gold
    ENTRANCE    = { R = 0.4,  G = 0.7,  B = 1.0,  A = 1.0 },  -- steel blue
    SERVER      = { R = 0.93, G = 0.93, B = 0.82, A = 1.0 },  -- warm white
}

-- ============================================================
-- AP item-flag → color mapping
-- Archipelago item flags: 0=filler, 1=progression, 2=useful, 4=trap
-- ============================================================
M.FLAG_COLORS = {
    [0] = M.COLORS.ITEM,        -- filler      → green
    [1] = M.COLORS.PROGRESSION, -- progression → purple
    [2] = M.COLORS.USEFUL,      -- useful      → blue
    [4] = M.COLORS.TRAP,        -- trap        → red
}

--- Return the color for an AP item-flags value.
function M.ColorForFlags(flags)
    return M.FLAG_COLORS[flags or 0] or M.COLORS.WHITE
end

-- ============================================================
-- UMG class references (cached on first use)
-- ============================================================
local UserWidgetClass  = nil
local WidgetTreeClass  = nil
local CanvasPanelClass = nil
local TextBlockClass   = nil

local function CacheClasses()
    if UserWidgetClass then return true end
    local ok, err = pcall(function()
        UserWidgetClass  = StaticFindObject("/Script/UMG.UserWidget")
        WidgetTreeClass  = StaticFindObject("/Script/UMG.WidgetTree")
        CanvasPanelClass = StaticFindObject("/Script/UMG.CanvasPanel")
        TextBlockClass   = StaticFindObject("/Script/UMG.TextBlock")
    end)
    if not ok then
        Logging.LogError("HUD: Failed to find UMG classes: " .. tostring(err))
        return false
    end
    if not UserWidgetClass or not WidgetTreeClass
       or not CanvasPanelClass or not TextBlockClass then
        Logging.LogWarning("HUD: One or more UMG classes not found")
        return false
    end
    return true
end

-- ============================================================
-- Internal helpers
-- ============================================================

--- Wrap a FLinearColor table as FSlateColor for SetColorAndOpacity.
local function FSlateColor(c)
    return { SpecifiedColor = c, ColorUseRule = 0 }
end

--- Pick the most prominent (first non-white) color from segments.
local function DominantColor(segments)
    -- for _, seg in ipairs(segments) do
    --     local c = seg.color
    --     if c and c ~= M.COLORS.WHITE and c ~= M.COLORS.SERVER then
    --         return c
    --     end
    -- end
    return M.COLORS.WHITE
end

--- Concatenate all segment texts.
local function ConcatSegments(segments)
    local parts = {}
    for _, seg in ipairs(segments) do
        table.insert(parts, seg.text or "")
    end
    return table.concat(parts)
end

-- ============================================================
-- Widget state
-- ============================================================
local hudWidget    = nil   -- the UUserWidget overlay
local canvas       = nil   -- root CanvasPanel
local widgetReady  = false
local loopStarted  = false
local pendingQueue = {}    -- notifications queued before widget is ready
local timeAccum    = 0     -- accumulated seconds (from tick loop)

-- Scrolling log: ordered list, oldest first.
-- Each entry: { textBlock = UTextBlock, canvasSlot = UCanvasPanelSlot, expireTime = number }
local entries      = {}
local entryCounter = 0     -- monotonic counter for unique FName

--- Destroy existing widget if still valid, so we can recreate cleanly.
local function DestroyWidget()
    if hudWidget and hudWidget:IsValid() then
        pcall(function() hudWidget:RemoveFromParent() end)
    end
    hudWidget    = nil
    canvas       = nil
    entries      = {}
    entryCounter = 0
    widgetReady  = false
end

--- Create the bare UMG container (UserWidget + WidgetTree + CanvasPanel).
--- TextBlocks are NOT pre-created; they are added on-demand.
--- MUST be called from the game thread.
local function CreateWidget()
    if not CacheClasses() then return false end

    local gi = UEHelpers.GetGameInstance()
    if not gi or not gi:IsValid() then
        Logging.LogWarning("HUD: GameInstance not available yet")
        return false
    end

    DestroyWidget()

    -- 1. UserWidget (outer = GameInstance)
    hudWidget = StaticConstructObject(UserWidgetClass, gi, FName("APNotifWidget"))
    if not hudWidget or not hudWidget:IsValid() then
        Logging.LogError("HUD: Failed to construct UserWidget")
        return false
    end

    -- 2. WidgetTree (outer = UserWidget)
    hudWidget.WidgetTree = StaticConstructObject(WidgetTreeClass, hudWidget, FName("APNotifTree"))

    -- 3. Root CanvasPanel (outer = WidgetTree)
    hudWidget.WidgetTree.RootWidget = StaticConstructObject(
        CanvasPanelClass, hudWidget.WidgetTree, FName("APNotifCanvas")
    )
    canvas = hudWidget.WidgetTree.RootWidget

    widgetReady = true
    Logging.LogInfo("HUD: UMG container created and added to viewport")
    return true
end

-- ============================================================
-- Entry lifecycle
-- ============================================================

--- Remove a single entry: detach its TextBlock from the canvas.
local function RemoveEntry(entry)
    pcall(function() canvas:RemoveChild(entry.textBlock) end)
end

--- Reposition all live entries so they form a top-to-bottom log.
--- Oldest entry at the top (smallest Y), newest at the bottom.
local function RepositionEntries()
    for i, entry in ipairs(entries) do
        pcall(function()
            entry.canvasSlot:SetPosition({
                X = START_X,
                Y = START_Y + (i - 1) * LINE_SPACING,
            })
        end)
    end
end

--- Create a new TextBlock, parent it to the canvas, configure it,
--- and append it to the entries list.  MUST be on the game thread.
local function AddEntry(text, color, duration)
    entryCounter = entryCounter + 1
    local name = "APNotif_" .. entryCounter

    -- Construct the TextBlock (outer = canvas for proper GC)
    local tb = StaticConstructObject(TextBlockClass, canvas, FName(name))
    if not tb or not tb:IsValid() then
        Logging.LogError("HUD: Failed to construct TextBlock " .. name)
        return
    end

    -- Parent to canvas FIRST — this creates the Slate widget and the
    -- UCanvasPanelSlot, which initialises the internal TArrays that
    -- would otherwise trip the UE4SS invariant checks.
    local canvasSlot = canvas:AddChildToCanvas(tb)
    pcall(function() canvasSlot:SetAutoSize(true) end)

    -- Configure text, color and shadow — each in pcall for resilience.
    -- Safe to read tb.Font here because AddChildToCanvas above has fully
    -- initialised the Slate widget, so FSlateFontInfo's internal TArrays exist.
    pcall(function()
        local fi = tb.Font
        if fi then
            fi.Size = 16
            tb:SetFont(fi)
        end
    end)
    pcall(function() tb:SetText(FText(text)) end)
    pcall(function() tb:SetShadowOffset({ X = SHADOW_OFFSET_X, Y = SHADOW_OFFSET_Y }) end)
    pcall(function() tb:SetShadowColorAndOpacity(SHADOW_COLOR) end)
    pcall(function() tb:SetColorAndOpacity(FSlateColor(color)) end)
    pcall(function() tb:SetVisibility(ESlateVisibility.SelfHitTestInvisible) end)

    -- Append to log (newest at the end)
    local entry = {
        textBlock  = tb,
        canvasSlot = canvasSlot,
        expireTime = timeAccum + duration,
    }
    table.insert(entries, entry)

    -- If we exceed MAX_VISIBLE, remove the oldest entries
    while #entries > MAX_VISIBLE do
        RemoveEntry(entries[1])
        table.remove(entries, 1)
    end

    -- Update positions of all visible entries
    RepositionEntries()
end

--- Expire old entries whose time has passed.
local function ExpireTick()
    local changed = false
    local i = 1
    while i <= #entries do
        if timeAccum >= entries[i].expireTime then
            RemoveEntry(entries[i])
            table.remove(entries, i)
            changed = true
        else
            i = i + 1
        end
    end
    if changed then
        RepositionEntries()
    end
end

-- ============================================================
-- Drain loop: processes pending queue and expires old entries
-- ============================================================
local function DrainPending()
    -- Create the container widget if it doesn't exist yet
    if not widgetReady then
        if not CreateWidget() then return end
    end

    -- Re-add to viewport if it was lost (e.g., level transition)
    if hudWidget and hudWidget:IsValid() then
        local ok, inVP = pcall(function() return hudWidget:GetIsVisible() end)
        if ok and not inVP then
            pcall(function() hudWidget:AddToViewport(WIDGET_ZORDER) end)
        end
    else
        widgetReady = false
        entries = {}
        entryCounter = 0
        if not CreateWidget() then return end
    end

    -- Process pending notifications
    local i = 1
    while i <= #pendingQueue do
        local notif = pendingQueue[i]
        local ok, err = pcall(AddEntry, notif.text, notif.color, notif.duration)
        if not ok then
            Logging.LogError("HUD: AddEntry failed: " .. tostring(err))
        end
        table.remove(pendingQueue, i)
        -- don't increment i — table.remove shifts the array
    end

    -- Expire old entries
    pcall(ExpireTick)
end

local TICK_MS = 200  -- poll interval

local function StartTickLoop()
    if loopStarted then return end
    loopStarted = true

    LoopAsync(TICK_MS, function()
        timeAccum = timeAccum + (TICK_MS / 1000.0)

        ExecuteInGameThread(function()
            DrainPending()
        end)

        return false  -- keep looping forever
    end)
end

-- ============================================================
-- Public API
-- ============================================================

--- Initialize the HUD system (idempotent).
function M.Init()
    StartTickLoop()
    Logging.LogInfo("HUD: Initialized (UMG scrolling-log overlay)")
end

--- Queue a notification made of colored text segments.
--- All segment texts are concatenated; the dominant (first non-white)
--- color is used for the entire line (UMG TextBlock is single-color).
function M.Notify(segments, duration)
    if not enabled then return end
    if not segments or #segments == 0 then return end

    duration = duration or DEFAULT_DURATION

    local clean = {}
    for _, seg in ipairs(segments) do
        if type(seg.text) == "string" and seg.text ~= "" then
            table.insert(clean, { text = seg.text, color = seg.color or M.COLORS.WHITE })
        end
    end
    if #clean == 0 then return end

    local text  = ConcatSegments(clean)
    local color = DominantColor(clean)

    Logging.LogInfo("HUD notify: " .. text)

    table.insert(pendingQueue, { text = text, color = color, duration = duration })
    -- Cap the queue so it doesn't grow unbounded
    while #pendingQueue > MAX_VISIBLE do
        table.remove(pendingQueue, 1)
    end
end

--- Queue a single-color notification.
function M.NotifySimple(text, color, duration)
    M.Notify({ { text = text, color = color or M.COLORS.WHITE } }, duration)
end

--- Clear all visible notifications and the pending queue.
function M.Clear()
    pendingQueue = {}
    if widgetReady then
        ExecuteInGameThread(function()
            for _, entry in ipairs(entries) do
                RemoveEntry(entry)
            end
            entries = {}
        end)
    end
end

--- Enable or disable the HUD overlay.
function M.SetEnabled(value)
    enabled = value
    if not value then
        M.Clear()
    end
end

return M