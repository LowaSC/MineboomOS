-- Launcher PocketOS: полноэкранный список приложений с поиском и
-- сворачиваемыми категориями (как папки). По умолчанию все категории
-- свёрнуты — тап по заголовку раскрывает/сворачивает. Состояние
-- expanded хранится в desktop.expandedCategories. При активном поиске
-- все категории форсированно раскрыты, чтобы фильтр был виден.
local Launcher = {}

local TITLE_H  = 1
local SEARCH_H = 1
local FOOTER_H = 1

local CATEGORY_LABEL = {
    automation = "Automation",
    network    = "Network",
    games      = "Games",
    system     = "System",
    other      = "Other",
}

local CATEGORY_ORDER = {"automation", "network", "games", "system", "other"}

-- Fallback по id — один в один с os/apps/apps.lua и os/apps/admin.lua, чтобы
-- приложение без валидного поля category попадало в ту же категорию во всех
-- экранах (Apps, Пуск, Admin Manage/Perms), а не в «Other» только тут.
local CATEGORY_FALLBACK = {
    factory = "automation", storage = "automation", rtc = "automation",
    hub = "network",
    apps = "system", files = "system", settings = "system",
    logs = "system", os_update = "system", terminal = "system", admin = "system",
    minesweeper = "games", snake = "games", ["2048"] = "games",
}

local function appCategory(def)
    local cat = def and def.category
    if not cat or not CATEGORY_LABEL[cat] then cat = CATEGORY_FALLBACK[def and def.id] end
    if not cat or not CATEGORY_LABEL[cat] then cat = "other" end
    return cat
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function padR(s, n)
    s = tostring(s or "")
    if #s >= n then return string.sub(s, 1, n) end
    return s .. string.rep(" ", n - #s)
end

local function clip(s, n)
    s = tostring(s or "")
    if #s > n then return string.sub(s, 1, n) end
    return s
end

local function iconText(def)
    local s = def.icon or string.sub(def.name or def.id or "?", 1, 2)
    s = tostring(s)
    if #s < 2 then s = s .. " " end
    return string.sub(s, 1, 2)
end

local function lower(s) return string.lower(tostring(s or "")) end

local function matches(def, queryLow)
    if not queryLow or queryLow == "" then return true end
    if string.find(lower(def.name or ""),     queryLow, 1, true) then return true end
    if string.find(lower(def.id or ""),       queryLow, 1, true) then return true end
    if string.find(lower(def.category or ""), queryLow, 1, true) then return true end
    return false
end

local function runIndex(running, def)
    for i, r in ipairs(running or {}) do
        if r.def and r.def.id == def.id then return i end
    end
    return 0
end

-- Возвращает плоский список «row» элементов:
--   {type = "header", cat = "automation", text = "Automation",
--    count = 3, expanded = true}
--   {type = "app",    def = ..., runIdx = N}
-- При непустом query поиск форсит expanded=true для всех категорий.
local function buildRows(apps, running, query, expanded)
    local q = lower(query)
    local searching = q ~= ""
    expanded = expanded or {}

    local buckets = {}
    for _, def in ipairs(apps or {}) do
        if matches(def, q) then
            local cat = appCategory(def)
            buckets[cat] = buckets[cat] or {}
            table.insert(buckets[cat], def)
        end
    end

    for _, list in pairs(buckets) do
        table.sort(list, function(a, b)
            return (a.name or a.id) < (b.name or b.id)
        end)
    end

    local rows = {}
    for _, cat in ipairs(CATEGORY_ORDER) do
        local list = buckets[cat]
        if list and #list > 0 then
            local isOpen = searching or (expanded[cat] == true)
            table.insert(rows, {
                type = "header", cat = cat,
                text = CATEGORY_LABEL[cat] or cat,
                count = #list, expanded = isOpen,
            })
            if isOpen then
                for _, def in ipairs(list) do
                    table.insert(rows, {type = "app", def = def,
                                        runIdx = runIndex(running, def)})
                end
            end
        end
    end
    return rows
end

local function listBodyH(AH)
    return AH - TITLE_H - SEARCH_H - FOOTER_H
end

-- ── Отрисовка ─────────────────────────────────────────────────────────────────

local function drawAppRow(workArea, y, row, W, theme, focusedIdx)
    local def = row.def
    local foc = row.runIdx > 0 and row.runIdx == focusedIdx
    local runs = row.runIdx > 0
    local iconBg = def.iconBg or theme.accentBg or colors.cyan
    local iconFg = def.iconFg or colors.black
    local mu = theme.mutedFg or colors.lightGray
    local bg = theme.pageBg or colors.black

    workArea.setCursorPos(1, y)
    workArea.setBackgroundColor(iconBg)
    workArea.setTextColor(iconFg)
    workArea.write(" " .. iconText(def) .. "  ")

    local nameW = W - 5 - 5
    workArea.setBackgroundColor(bg)
    workArea.setTextColor(colors.white)
    workArea.write(padR(" " .. (def.name or def.id), nameW))

    local badge, badgeFg = "     ", mu
    if foc        then badge = " FOC "; badgeFg = colors.yellow
    elseif runs   then badge = " RUN "; badgeFg = colors.lime
    end
    workArea.setBackgroundColor(bg)
    workArea.setTextColor(badgeFg)
    workArea.write(badge)
end

local function drawHeaderRow(workArea, y, row, W, theme)
    local hb = theme.sectionBg or colors.gray
    local hf = theme.sectionFg or colors.white
    workArea.setCursorPos(1, y)
    workArea.setBackgroundColor(hb)
    workArea.setTextColor(hf)
    local arrow = row.expanded and "v" or ">"
    local label = " " .. arrow .. " " .. row.text
    local count = "(" .. tostring(row.count) .. ")"
    local left = clip(label, W - #count - 1)
    workArea.write(padR(left, W - #count - 1))
    workArea.setTextColor(theme.mutedFg or colors.lightGray)
    workArea.write(count .. " ")
end

local function drawSearch(workArea, y, query, W, theme)
    local bg = colors.lightGray
    local fg = colors.black
    workArea.setCursorPos(1, y)
    workArea.setBackgroundColor(bg)
    workArea.setTextColor(fg)
    workArea.write(" /")
    local field = clip(query or "", W - 4)
    workArea.write(padR(field, W - 4))
    workArea.setBackgroundColor(colors.red)
    workArea.setTextColor(colors.white)
    workArea.write(" x")
end

function Launcher.draw(apps, running, focusedIdx, scroll, query, expanded,
                       theme, workArea, W, AH, userName)
    local bg = theme.pageBg or colors.black
    local hb = theme.headerBg or colors.blue
    local hf = theme.headerFg or colors.white
    local mu = theme.mutedFg or colors.lightGray

    workArea.setBackgroundColor(bg)
    workArea.clear()

    -- Title bar: " Apps" слева, имя пользователя по центру/справа, [x] в конце
    workArea.setCursorPos(1, 1)
    workArea.setBackgroundColor(hb)
    workArea.setTextColor(hf)
    local leftLabel = " Apps"
    if type(userName) == "string" and userName ~= "" then
        local userStr = clip(userName, W - #leftLabel - 4)
        local mid = padR(leftLabel, W - #userStr - 3)
        workArea.write(mid)
        workArea.setTextColor(mu)
        workArea.write(userStr)
    else
        workArea.write(padR(leftLabel, W - 3))
    end
    workArea.setBackgroundColor(colors.red)
    workArea.setTextColor(colors.white)
    workArea.write("[x]")

    drawSearch(workArea, 2, query, W, theme)

    local rows = buildRows(apps, running, query, expanded)
    local bodyH = listBodyH(AH)
    local first = math.max(1, (scroll or 0) + 1)
    local last  = math.min(#rows, first + bodyH - 1)

    local y = TITLE_H + SEARCH_H + 1
    for i = first, last do
        if y > AH - FOOTER_H then break end
        local row = rows[i]
        if row.type == "header" then
            drawHeaderRow(workArea, y, row, W, theme)
        else
            drawAppRow(workArea, y, row, W, theme, focusedIdx)
        end
        y = y + 1
    end

    if #rows == 0 then
        workArea.setCursorPos(1, TITLE_H + SEARCH_H + 1)
        workArea.setBackgroundColor(bg)
        workArea.setTextColor(mu)
        workArea.write(padR(query and query ~= "" and " No matches" or " No apps installed", W))
    end

    -- Footer: кнопки Logout / Reboot + опциональная подсказка
    workArea.setCursorPos(1, AH)
    workArea.setBackgroundColor(colors.red)
    workArea.setTextColor(colors.white)
    workArea.write("[Logout]")

    workArea.setBackgroundColor(colors.orange or colors.yellow)
    workArea.setTextColor(colors.black)
    workArea.write("[Reboot]")

    workArea.setBackgroundColor(colors.gray)
    workArea.setTextColor(colors.white)
    workArea.write("[Lock]")

    workArea.setBackgroundColor(hb)
    workArea.setTextColor(mu)
    local hint = ""
    if #rows > bodyH then
        hint = string.format(" %d-%d/%d", first, last, #rows)
    elseif query and query ~= "" then
        hint = " Esc to clear"
    end
    workArea.write(padR(hint, W - 22))
end

-- ── Hit-test ──────────────────────────────────────────────────────────────────

-- Возвращает: "close" | ("app", def) | ("toggle_category", catId)
-- | "clear_query" | "search" | nil
function Launcher.hit(apps, running, scroll, query, expanded, x, y, W, AH)
    if y < 1 or y > AH then return nil end

    if y == 1 then
        if x >= W - 2 then return "close", nil end
        return nil, nil
    end

    if y == 2 then
        if x >= W - 1 then return "clear_query", nil end
        return "search", nil
    end

    if y == AH then
        if x >= 1  and x <= 8  then return "logout",  nil end
        if x >= 9  and x <= 16 then return "reboot",  nil end
        if x >= 17 and x <= 22 then return "lock_now", nil end
        return nil, nil
    end

    local rows = buildRows(apps, running, query, expanded)
    local first = math.max(1, (scroll or 0) + 1)
    local idx = first + (y - TITLE_H - SEARCH_H - 1)
    local row = rows[idx]
    if row then
        if row.type == "header" then
            return "toggle_category", row.cat
        elseif row.type == "app" then
            return "app", row.def
        end
    end
    return nil, nil
end

function Launcher.scrollBy(apps, running, query, expanded, scroll, dir, AH)
    local rows = buildRows(apps, running, query, expanded)
    local bodyH = listBodyH(AH)
    local maxScroll = math.max(0, #rows - bodyH)
    return math.max(0, math.min(maxScroll, (scroll or 0) + dir))
end

-- Кламп скролла под текущий expanded (после сворачивания категорий).
function Launcher.clampScroll(apps, running, query, expanded, scroll, AH)
    local rows = buildRows(apps, running, query, expanded)
    local bodyH = listBodyH(AH)
    local maxScroll = math.max(0, #rows - bodyH)
    return math.max(0, math.min(maxScroll, scroll or 0))
end

Launcher.bodyHeight = listBodyH
Launcher.TITLE_H    = TITLE_H
Launcher.SEARCH_H   = SEARCH_H
Launcher.FOOTER_H   = FOOTER_H

return Launcher
