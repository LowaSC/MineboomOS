-- Scrollbar — переиспользуемый одно-полосный скроллбар для PocketOS.
-- Поддерживает обе ориентации:
--
--   * "vertical"   — узкая колонка справа от контента. Стрелки ^ v.
--   * "horizontal" — узкая строка под контентом. Стрелки < >.
--
-- Дизайн взят из RTC (gray track, цветной thumb), плюс улучшения:
--   * стрелки тускнеют, если в эту сторону нельзя скроллить;
--   * клик по треку выше/ниже thumb прыгает на страницу
--     (классическое десктоп-поведение);
--   * захват thumb и drag — thumb не дёргается к центру курсора,
--     dragOffset запоминается на click.
--
-- Использование (vertical):
--
--   local Scrollbar = dofile("/os/lib/scrollbar.lua")
--   st.sb = Scrollbar.create({thumbBg = colors.cyan})
--   -- в draw:
--   st.sb:setBounds(W, topY, bottomY)  -- (колонка, верх, низ)
--   st.sb:setContent(viewH, #items)
--   st.sb:setScroll(st.scroll)
--   st.sb:draw(win)
--   -- в onEvent:
--   if st.sb:onClick(x, y) then st.scroll = st.sb.scroll; return st, true end
--   if st.sb:onDrag(x, y)  then st.scroll = st.sb.scroll; return st, true end
--   st.sb:scrollBy(p1)
--
-- Использование (horizontal):
--
--   st.sbH = Scrollbar.create({orientation = "horizontal", thumbBg = colors.cyan})
--   -- в draw:
--   st.sbH:setBounds(H - 1, 1, W)      -- (строка, левый край, правый край)
--   st.sbH:setContent(viewW, contentW) -- содержимое в символах
--   st.sbH:setScroll(st.hScroll)
--   st.sbH:draw(win)
--   -- в onEvent: те же onClick/onDrag/scrollBy.

local Scrollbar = {}
Scrollbar.__index = Scrollbar

local DEFAULTS = {
    trackBg     = colors.gray,
    thumbBg     = colors.cyan,
    thumbFg     = colors.black,
    arrowFg     = colors.white,
    arrowDimFg  = colors.lightGray,
    showArrows  = true,
    minThumbH   = 1,
    orientation = "vertical",  -- "vertical" | "horizontal"
}

function Scrollbar.create(opts)
    opts = opts or {}
    local s = setmetatable({}, Scrollbar)
    for k, v in pairs(DEFAULTS) do
        s[k] = (opts[k] ~= nil) and opts[k] or v
    end
    -- cross — фиксированная координата на перпендикулярной оси:
    -- для vertical это x (колонка), для horizontal это y (строка).
    -- lo/hi — диапазон по главной оси (y для vertical, x для horizontal).
    s.cross    = 1
    s.lo       = 1
    s.hi       = 1
    s.scroll    = 0
    s.maxScroll = 0
    s.viewH     = 1
    s.dragOffset = nil
    return s
end

function Scrollbar:isVertical()
    return self.orientation ~= "horizontal"
end

-- Привязка к экрану:
--   vertical:   setBounds(x, topY, bottomY)
--   horizontal: setBounds(y, leftX, rightX)
function Scrollbar:setBounds(cross, lo, hi)
    self.cross, self.lo, self.hi = cross, lo, hi
end

-- Размеры контента (в той же единице, что и lo/hi):
--   viewH — сколько помещается видимой области (по главной оси);
--   contentH — общая длина контента (#items, #chars и т.п.).
function Scrollbar:setContent(viewH, contentH)
    self.viewH = math.max(1, viewH or 1)
    self.maxScroll = math.max(0, (contentH or 0) - self.viewH)
    if self.scroll > self.maxScroll then self.scroll = self.maxScroll end
end

function Scrollbar:setScroll(v)
    self.scroll = math.max(0, math.min(self.maxScroll, v or 0))
end

function Scrollbar:scrollBy(dir)
    self:setScroll(self.scroll + (dir or 1))
end

-- Возвращает (innerLo, innerHi, innerLen) — диапазон по главной оси без стрелок.
local function innerRange(s)
    local lo = s.lo + (s.showArrows and 1 or 0)
    local hi = s.hi - (s.showArrows and 1 or 0)
    if hi < lo then return lo, lo - 1, 0 end
    return lo, hi, hi - lo + 1
end

-- Возвращает (thumbStart, thumbEnd, thumbLen) или nil.
local function thumbRange(s)
    local _, _, ilen = innerRange(s)
    if ilen <= 0 then return nil end
    local ilo = s.lo + (s.showArrows and 1 or 0)
    local ihi = s.hi - (s.showArrows and 1 or 0)
    if s.maxScroll <= 0 then return ilo, ihi, ilen end
    local thumbLen = math.max(s.minThumbH,
        math.floor(ilen * ilen / (ilen + s.maxScroll)))
    if thumbLen > ilen then thumbLen = ilen end
    local ts = ilo + math.floor((ilen - thumbLen) * s.scroll / s.maxScroll + 0.5)
    local te = math.min(ihi, ts + thumbLen - 1)
    return ts, te, thumbLen
end

function Scrollbar:thumbRange() return thumbRange(self) end

-- ── Render ───────────────────────────────────────────────────────────────────

-- Точечное письмо в нужную позицию с учётом ориентации.
-- pri — позиция вдоль главной оси; sec нам не нужен, он = cross.
local function setAt(s, win, pri)
    if s:isVertical() then
        win.setCursorPos(s.cross, pri)
    else
        win.setCursorPos(pri, s.cross)
    end
end

function Scrollbar:draw(win)
    local len = self.hi - self.lo + 1
    if len <= 0 then return end

    -- Track
    win.setBackgroundColor(self.trackBg)
    if self:isVertical() then
        for y = self.lo, self.hi do
            win.setCursorPos(self.cross, y)
            win.write(" ")
        end
    else
        win.setCursorPos(self.lo, self.cross)
        win.write(string.rep(" ", len))
    end

    -- Arrows (тускнеют если нельзя скроллить).
    if self.showArrows and len >= 1 then
        local canBack = self.scroll > 0
        setAt(self, win, self.lo)
        win.setBackgroundColor(self.trackBg)
        win.setTextColor(canBack and self.arrowFg or self.arrowDimFg)
        win.write(self:isVertical() and "^" or "<")
    end
    if self.showArrows and len >= 2 then
        local canFwd = self.scroll < self.maxScroll
        setAt(self, win, self.hi)
        win.setBackgroundColor(self.trackBg)
        win.setTextColor(canFwd and self.arrowFg or self.arrowDimFg)
        win.write(self:isVertical() and "v" or ">")
    end

    -- Thumb (только если есть что скроллить).
    if self.maxScroll > 0 then
        local ts, te = thumbRange(self)
        if ts then
            win.setBackgroundColor(self.thumbBg)
            win.setTextColor(self.thumbFg)
            if self:isVertical() then
                for y = ts, te do
                    win.setCursorPos(self.cross, y)
                    win.write(" ")
                end
            else
                win.setCursorPos(ts, self.cross)
                win.write(string.rep(" ", te - ts + 1))
            end
        end
    end
end

-- ── Hit-test ─────────────────────────────────────────────────────────────────

-- Главная координата клика для текущей ориентации.
local function primary(s, x, y)
    if s:isVertical() then return y, x else return x, y end
end

function Scrollbar:contains(x, y)
    local pri, sec = primary(self, x, y)
    return sec == self.cross and pri >= self.lo and pri <= self.hi
end

-- Возвращает: "arrow_up"/"arrow_left" | "arrow_down"/"arrow_right"
-- | "thumb" | "track_above"/"track_before" | "track_below"/"track_after" | nil.
-- Для упрощения вызывающего кода используем единые имена:
--   "arrow_back" / "arrow_fwd" / "thumb" / "track_back" / "track_fwd"
function Scrollbar:hitZone(x, y)
    if not self:contains(x, y) then return nil end
    local pri = self:isVertical() and y or x
    if self.showArrows then
        if pri == self.lo then return "arrow_back" end
        if pri == self.hi then return "arrow_fwd" end
    end
    local ts, te = thumbRange(self)
    if not ts then return "track_back" end
    if pri < ts then return "track_back" end
    if pri > te then return "track_fwd" end
    return "thumb"
end

-- Обработка клика. Возвращает true если scrollbar его «съел»
-- (даже если позиция не изменилась — например, тап по dimmed стрелке).
function Scrollbar:onClick(x, y)
    local zone = self:hitZone(x, y)
    if not zone then return false end
    self.dragOffset = nil
    local pri = self:isVertical() and y or x

    if zone == "arrow_back" then
        self:scrollBy(-1)
    elseif zone == "arrow_fwd" then
        self:scrollBy(1)
    elseif zone == "thumb" then
        local ts = thumbRange(self)
        self.dragOffset = ts and (pri - ts) or 0
    elseif zone == "track_back" then
        self:scrollBy(-math.max(1, self.viewH - 1))
    elseif zone == "track_fwd" then
        self:scrollBy(math.max(1, self.viewH - 1))
    end
    return true
end

-- Обработка drag. Если предварительный onClick не был на thumb (dragOffset
-- = nil), всё равно работаем: thumb центрируется под курсором.
function Scrollbar:onDrag(x, y)
    local pri, sec = primary(self, x, y)
    if sec ~= self.cross then return false end
    if self.maxScroll <= 0 then return false end

    local ilo = self.lo + (self.showArrows and 1 or 0)
    local ihi = self.hi - (self.showArrows and 1 or 0)
    local ilen = ihi - ilo + 1
    if ilen <= 1 then return false end

    local _, _, thumbLen = thumbRange(self)
    thumbLen = thumbLen or 1
    local maxThumbStart = ihi - thumbLen + 1
    local trackRange = maxThumbStart - ilo
    if trackRange <= 0 then
        self:setScroll(0)
        return true
    end

    local offset = self.dragOffset or 0
    local desiredStart = pri - offset
    if desiredStart < ilo then desiredStart = ilo end
    if desiredStart > maxThumbStart then desiredStart = maxThumbStart end

    local rel = (desiredStart - ilo) / trackRange
    self:setScroll(math.floor(rel * self.maxScroll + 0.5))
    return true
end

function Scrollbar:endDrag()
    self.dragOffset = nil
end

return Scrollbar
