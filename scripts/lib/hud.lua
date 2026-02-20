-- ============================================================
-- HUD Notification Module (Colored Segments)
--
-- Displays on-screen messages using a UMG widget tree with
-- individually-colored text segments per message line.
--
-- Usage:
--   local HUD = require("lib.hud")
--   HUD.Init()
--   -- Plain white text (backward compatible):
--   HUD.ShowMessage("Hello world!", 5000)
--   -- Colored segments:
--   HUD.ShowMessage({
--       {text = "Player2", color = HUD.COLORS.PLAYER},
--       {text = " sent you ", color = HUD.COLORS.WHITE},
--       {text = "Green J-Piece!", color = HUD.COLORS.ITEM},
--   }, 5000)
--
-- The widget is automatically recreated after level transitions
-- when Init() is called again.
-- ============================================================

local Logging = require("lib.logging")

local M = {}

-- ============================================================
-- Configuration
-- ============================================================
local MAX_VISIBLE_LINES = 6       -- max messages shown at once
local MAX_SEGMENTS      = 8       -- max colored segments per line
local DEFAULT_DURATION  = 10000   -- ms before a message fades
local TICK_INTERVAL     = 50      -- ms between cleanup ticks
local VIEWPORT_Z_ORDER  = 99      -- widget layer priority
local DRAIN_PER_TICK    = 1       -- queued messages to promote per tick

-- ============================================================
-- Color Constants (exported for use by other modules)
-- ============================================================
M.COLORS = {
    WHITE       = {R = 1.0,  G = 1.0,  B = 1.0,  A = 1.0},
    PLAYER      = {R = 0.4,  G = 0.9,  B = 1.0,  A = 1.0},  -- cyan
    ITEM        = {R = 0.5,  G = 1.0,  B = 0.5,  A = 1.0},  -- green (filler)
    PROGRESSION = {R = 0.75, G = 0.53, B = 1.0,  A = 1.0},  -- purple
    USEFUL      = {R = 0.4,  G = 0.6,  B = 1.0,  A = 1.0},  -- blue
    TRAP        = {R = 1.0,  G = 0.4,  B = 0.4,  A = 1.0},  -- red
    LOCATION    = {R = 1.0,  G = 0.9,  B = 0.4,  A = 1.0},  -- gold
    ENTRANCE    = {R = 0.4,  G = 0.7,  B = 1.0,  A = 1.0},  -- steel blue
    SERVER      = {R = 0.93, G = 0.93, B = 0.82, A = 1.0},  -- warm white
}

-- ============================================================
-- Internal state
-- ============================================================
local widget      = nil   -- the UserWidget
local vertBox     = nil   -- the VerticalBox container
local canvasPanel = nil   -- the CanvasPanel (root of widget tree)
local rowBoxes    = {}    -- [i] = HorizontalBox for row i (1..MAX_VISIBLE_LINES)
local segBlocks   = {}    -- [i][j] = TextBlock for row i, segment j

local enabled      = false -- when false, all public API calls are no-ops
local messages     = {}   -- array of {segments={{text,color},...}, expireAt=number}
local pendingQueue = {}   -- buffered messages waiting to be promoted
local tickCount    = 0    -- monotonic counter incremented by TICK_INTERVAL
local initialized  = false
local widgetCreationFailed = false
local creationPending      = false
local hadMessages          = false
local displayDirty         = true   -- force update on first tick

-- ============================================================
-- Widget helpers
-- ============================================================

--- Apply standard styling to a TextBlock.
local function StyleTextBlock(tb)
    pcall(function() tb:SetText(FText("")) end)
    pcall(function() tb:SetAutoWrapText(false) end)
    pcall(function()
        local fi = tb.Font
        if fi then
            fi.Size = 16
            tb:SetFont(fi)
        end
    end)
    -- Disable per-segment wrap; messages flow horizontally in HorizontalBox
    pcall(function() tb.WrapTextAt = 0 end)
    pcall(function() tb:SetJustification(0) end) -- Left-justify
    -- Strong drop shadow for contrast
    pcall(function() tb:SetShadowOffset({X = 2.0, Y = 2.0}) end)
    pcall(function() tb:SetShadowColorAndOpacity({R = 0, G = 0, B = 0, A = 1.0}) end)
    -- Default white
    pcall(function()
        tb:SetColorAndOpacity({
            SpecifiedColor = {R = 1.0, G = 1.0, B = 1.0, A = 1.0},
            ColorUseRule   = 0,
        })
    end)
end

-- ============================================================
-- Widget lifecycle
-- ============================================================

--- Destroy the current widget and clear all references.
local function DestroyWidget()
    if widget then
        pcall(function() widget:RemoveFromViewport() end)
        widget      = nil
        vertBox     = nil
        canvasPanel = nil
        rowBoxes    = {}
        segBlocks   = {}
    end
end

--- Create (or recreate) the UMG widget tree.
--- Layout: Canvas > VerticalBox > HorizontalBox rows > TextBlock segments.
local function CreateWidget()
    if widget then creationPending = false; return end
    creationPending = false
    widgetCreationFailed = false

    local ok, err = pcall(function()
        -- Find UMG classes
        local userWidgetClass    = StaticFindObject("/Script/UMG.UserWidget")
        local widgetTreeClass    = StaticFindObject("/Script/UMG.WidgetTree")
        local canvasPanelClass   = StaticFindObject("/Script/UMG.CanvasPanel")
        local textBlockClass     = StaticFindObject("/Script/UMG.TextBlock")
        local verticalBoxClass   = StaticFindObject("/Script/UMG.VerticalBox")
        local horizontalBoxClass = StaticFindObject("/Script/UMG.HorizontalBox")

        if not userWidgetClass or not widgetTreeClass or not textBlockClass
           or not verticalBoxClass or not horizontalBoxClass then
            Logging.LogWarning("HUD: Missing UMG classes — colored HUD unavailable")
            widgetCreationFailed = true
            return
        end

        local gi = FindFirstOf("GameInstance")
        if not gi or not gi:IsValid() then
            Logging.LogWarning("HUD: No GameInstance — deferring widget creation")
            return
        end

        -- Construct UserWidget
        local w = StaticConstructObject(userWidgetClass, gi, FName("AP_NotificationWidget"))
        if not w or not w:IsValid() then
            Logging.LogWarning("HUD: Failed to construct UserWidget")
            widgetCreationFailed = true
            return
        end

        -- Construct WidgetTree (required by UserWidget)
        local tree = StaticConstructObject(widgetTreeClass, w, FName("AP_NotifTree"))
        if not tree or not tree:IsValid() then
            Logging.LogWarning("HUD: Failed to construct WidgetTree")
            widgetCreationFailed = true
            return
        end
        w.WidgetTree = tree

        -- Construct VerticalBox as the message container
        local vbox = StaticConstructObject(verticalBoxClass, tree, FName("AP_VBox"))
        if not vbox or not vbox:IsValid() then
            Logging.LogWarning("HUD: Failed to construct VerticalBox")
            widgetCreationFailed = true
            return
        end

        -- Try CanvasPanel layout for proper bottom-left anchoring
        local useCanvas = false
        if canvasPanelClass then
            local canvasOk, canvasErr = pcall(function()
                local canvas = StaticConstructObject(canvasPanelClass, tree, FName("AP_NotifCanvas"))
                if canvas and canvas:IsValid() then
                    tree.RootWidget = canvas
                    canvasPanel = canvas

                    local slot = canvas:AddChildToCanvas(vbox)
                    if slot then
                        pcall(function()
                            slot:SetAnchors({Minimum = {X = 0, Y = 1}, Maximum = {X = 0, Y = 1}})
                        end)
                        pcall(function()
                            slot:SetAlignment({X = 0, Y = 1})
                        end)
                        pcall(function()
                            slot:SetAutoSize(true)
                        end)
                        pcall(function()
                            slot:SetPosition({X = 15, Y = -300})
                        end)
                        useCanvas = true
                        Logging.LogInfo("HUD: Using CanvasPanel layout (bottom-left anchored)")
                    end
                end
            end)
            if not canvasOk then
                Logging.LogDebug("HUD: CanvasPanel layout failed: " .. tostring(canvasErr))
            end
        end

        if not useCanvas then
            tree.RootWidget = vbox
            Logging.LogInfo("HUD: Using fallback layout (absolute positioning)")
        end

        -- Pre-allocate rows (HorizontalBoxes) and segments (TextBlocks)
        rowBoxes  = {}
        segBlocks = {}
        for i = 1, MAX_VISIBLE_LINES do
            local hbox = StaticConstructObject(horizontalBoxClass, tree,
                FName("AP_Row" .. i))
            if hbox and hbox:IsValid() then
                vbox:AddChildToVerticalBox(hbox)
                pcall(function() hbox:SetVisibility(1) end)  -- Collapsed initially

                rowBoxes[i]  = hbox
                segBlocks[i] = {}
                for j = 1, MAX_SEGMENTS do
                    local tb = StaticConstructObject(textBlockClass, tree,
                        FName("AP_S" .. i .. "_" .. j))
                    if tb and tb:IsValid() then
                        hbox:AddChildToHorizontalBox(tb)
                        StyleTextBlock(tb)
                        pcall(function() tb:SetVisibility(1) end) -- Collapsed initially
                        segBlocks[i][j] = tb
                    end
                end
            end
        end

        vertBox = vbox

        -- Widget-level settings
        pcall(function() w.bIsFocusable = false end)
        w:AddToViewport(VIEWPORT_Z_ORDER)

        -- Click-through: SelfHitTestInvisible (4) on the UserWidget,
        -- HitTestInvisible (3) on containers so they pass input through.
        pcall(function() w:SetVisibility(4) end)
        if canvasPanel then
            pcall(function() canvasPanel:SetVisibility(3) end)
        end
        pcall(function() vbox:SetVisibility(3) end)

        -- Start hidden; RefreshDisplay shows via render opacity when messages arrive
        pcall(function() w:SetRenderOpacity(0) end)

        -- Fallback absolute positioning if no canvas layout
        if not useCanvas then
            pcall(function()
                w:SetAlignmentInViewport({X = 0, Y = 1})
                w:SetPositionInViewport({X = 30, Y = 1030}, false)
            end)
        end

        widget = w
        displayDirty = true
        Logging.LogInfo("HUD: Colored notification widget created (" ..
            MAX_VISIBLE_LINES .. " rows x " .. MAX_SEGMENTS .. " segments)")
    end)

    if not ok then
        Logging.LogError("HUD: Widget creation error: " .. tostring(err))
        widgetCreationFailed = true
        widget      = nil
        vertBox     = nil
        canvasPanel = nil
        rowBoxes    = {}
        segBlocks   = {}
    end
end

-- ============================================================
-- Message management
-- ============================================================

--- Drain pending messages into the active list (rate-limited).
local function DrainPendingQueue()
    for _ = 1, DRAIN_PER_TICK do
        if #pendingQueue == 0 then break end
        local entry = table.remove(pendingQueue, 1)
        entry.expireAt = tickCount + math.ceil(entry.duration / TICK_INTERVAL)
        table.insert(messages, entry)
        displayDirty = true
    end
end

--- Update the pre-allocated widget pool to reflect the current message list.
local function RefreshDisplay()
    if not vertBox then return end

    -- Promote buffered messages
    DrainPendingQueue()

    -- Remove expired messages
    local now    = tickCount
    local active = {}
    for _, msg in ipairs(messages) do
        if msg.expireAt > now then
            table.insert(active, msg)
        end
    end
    if #active ~= #messages then displayDirty = true end
    messages = active

    -- Skip updating widgets if nothing changed
    if not displayDirty then return end
    displayDirty = false

    -- Select the most recent MAX_VISIBLE_LINES messages
    local startIdx = math.max(1, #messages - MAX_VISIBLE_LINES + 1)
    local visible  = {}
    for i = startIdx, #messages do
        table.insert(visible, messages[i])
    end

    -- Update pre-allocated widget pool
    for i = 1, MAX_VISIBLE_LINES do
        local msg  = visible[i]
        local hbox = rowBoxes[i]
        if hbox then
            if msg and msg.segments then
                -- Show this row
                pcall(function() hbox:SetVisibility(3) end) -- HitTestInvisible

                for j = 1, MAX_SEGMENTS do
                    local tb = segBlocks[i] and segBlocks[i][j]
                    if tb then
                        local seg = msg.segments[j]
                        if seg then
                            pcall(function() tb:SetText(FText(seg.text or "")) end)
                            pcall(function()
                                local c = seg.color or M.COLORS.WHITE
                                tb:SetColorAndOpacity({SpecifiedColor = c, ColorUseRule = 0})
                            end)
                            pcall(function() tb:SetVisibility(3) end) -- visible
                        else
                            pcall(function() tb:SetText(FText("")) end)
                            pcall(function() tb:SetVisibility(1) end) -- Collapsed
                        end
                    end
                end
            else
                -- Hide this row
                pcall(function() hbox:SetVisibility(1) end) -- Collapsed
            end
        end
    end

    -- Show/hide the entire widget via render opacity
    local w = widget
    if w then
        pcall(function()
            if w:IsValid() then
                w:SetRenderOpacity(#visible > 0 and 1 or 0)
            end
        end)
    end
end

-- ============================================================
-- Request widget creation (deduped, async-safe)
-- ============================================================
local function RequestCreateWidget()
    if creationPending or widget then return end
    creationPending = true
    ExecuteInGameThread(function()
        CreateWidget()
    end)
end

-- ============================================================
-- Public API
-- ============================================================

--- Initialize or re-initialize the HUD widget.
--- Safe to call multiple times (e.g. after level transitions).
function M.Init()
    if not enabled then return end
    widget      = nil
    vertBox     = nil
    canvasPanel = nil
    rowBoxes    = {}
    segBlocks   = {}
    widgetCreationFailed = false
    creationPending      = false
    displayDirty         = true

    RequestCreateWidget()

    -- Start the cleanup/refresh loop only once
    if not initialized then
        initialized = true
        LoopAsync(TICK_INTERVAL, function()
            tickCount = tickCount + 1

            local hasContent = #messages > 0 or #pendingQueue > 0
            if hasContent or hadMessages then
                hadMessages = hasContent

                -- Validate the widget is still alive
                if widget then
                    local alive = false
                    pcall(function() alive = widget:IsValid() end)
                    if not alive then
                        widget      = nil
                        vertBox     = nil
                        canvasPanel = nil
                        rowBoxes    = {}
                        segBlocks   = {}
                    end
                end

                -- Recreate if needed
                if hasContent and not widget and not widgetCreationFailed then
                    RequestCreateWidget()
                end

                RefreshDisplay()
            end

            return false  -- keep running
        end)
    end
end

--- Display a message on screen.
--- @param textOrSegments string|table  Plain string (white) OR array of {text=, color=}
--- @param duration number|nil          Duration in ms (default 5000)
function M.ShowMessage(textOrSegments, duration)
    if not enabled then return end
    if not textOrSegments then return end
    duration = duration or DEFAULT_DURATION

    local segments
    if type(textOrSegments) == "string" then
        if textOrSegments == "" then return end
        segments = { {text = textOrSegments, color = M.COLORS.WHITE} }
    elseif type(textOrSegments) == "table" then
        segments = textOrSegments
        if #segments == 0 then return end
    else
        return
    end

    table.insert(pendingQueue, {
        segments = segments,
        duration = duration,
        expireAt = 0,  -- set when promoted
    })

    -- Build plain text for debug log
    local plain = ""
    for _, s in ipairs(segments) do plain = plain .. (s.text or "") end
    Logging.LogDebug(string.format("HUD: Buffered message (%d pending): %s",
        #pendingQueue, plain))

    if not widget and not widgetCreationFailed then
        RequestCreateWidget()
    end
end

--- Remove all messages and clear the display.
function M.Clear()
    if not enabled then return end
    messages     = {}
    pendingQueue = {}
    displayDirty = true
    if vertBox then
        ExecuteInGameThread(function()
            for i = 1, MAX_VISIBLE_LINES do
                local hbox = rowBoxes[i]
                if hbox then
                    pcall(function() hbox:SetVisibility(1) end) -- Collapsed
                end
            end
        end)
    end
end

--- Tear down the widget entirely.
function M.Shutdown()
    if not enabled then return end
    M.Clear()
    ExecuteInGameThread(function()
        DestroyWidget()
    end)
end

--- Check whether the widget is alive.
function M.IsReady()
    return enabled and widget ~= nil and not widgetCreationFailed
end

--- Enable or disable the HUD entirely.
--- When disabled, all public API calls become no-ops.
--- @param value boolean
function M.SetEnabled(value)
    enabled = value == true
end

--- Return whether the HUD is currently enabled.
function M.IsEnabled()
    return enabled
end

return M
