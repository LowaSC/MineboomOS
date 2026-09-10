local Loader    = dofile("/os/lib/loader.lua")
local Updater   = Loader.require("/os/lib/updater.lua")
local Scrollbar = Loader.require("/os/lib/scrollbar.lua")

local M = {}
M.id       = "os_update"
M.name     = "OS Update"
M.icon     = "Up"
M.iconBg   = colors.green
M.iconFg   = colors.white
M.version  = 8
M.system   = true
M.category = "system"

local MANIFEST = Loader.require("/os/manifest.lua")

local ok_cl, Changelog = pcall(Loader.require, "/os/changelog.lua")
if not ok_cl then Changelog = {} end

local function pad(s, n)
    s = tostring(s or "")
    if #s >= n then return string.sub(s, 1, n) end
    return s .. string.rep(" ", n - #s)
end

local function detectChannel(source, cfg)
    if not source or source == "" then return "custom" end
    local dev = cfg and cfg.osSourceUrlDev
    if dev and dev ~= "" and source == dev then return "dev" end
    local stable = cfg and cfg.osSourceUrl
    if stable and stable ~= "" and source == stable then return "stable" end
    return "custom"
end

-- Channels must be configured explicitly: arbitrary release URLs cannot be
-- turned into another channel by replacing a path segment.
local function getChannelUrls(cfg)
    local st = cfg and cfg.osSourceUrl    and cfg.osSourceUrl    ~= "" and cfg.osSourceUrl    or nil
    local dv = cfg and cfg.osSourceUrlDev and cfg.osSourceUrlDev ~= "" and cfg.osSourceUrlDev or nil
    return st or "", dv or ""
end

local function doCheck(st)
    if not st.source or st.source == "" then
        st.status = "Source not configured"; return
    end
    local rm, err = Updater.fetchManifest(st.source)
    if rm then
        st.remoteVer = rm.version
        local compatible, why = Updater.compatible(rm)
        st.incompatible = not compatible
        st.status = compatible and ((rm.version == MANIFEST.version) and "Up to date" or "Update available") or why
    else
        st.remoteVer = nil
        st.incompatible = false
        st.status = "Failed: " .. tostring(err)
    end
end

local function startCheck(st)
    if st.busy then return end
    st.busy = true
    st.status = "Checking..."
    st.ctx.spawn(function()
        local ok, err = pcall(doCheck, st)
        if not ok then st.status = "Failed: " .. tostring(err) end
        st.busy = false
        st.ctx.refresh()
    end, "os_update")
end

-- ── Word wrap ─────────────────────────────────────────────────────────────────

local function wrapLine(text, maxW)
    text = tostring(text or "")
    if #text <= maxW then return {text} end
    local lines = {}
    while #text > maxW do
        local bi = maxW
        for i = maxW, 1, -1 do
            if string.sub(text, i, i) == " " then bi = i; break end
        end
        local seg = string.sub(text, 1, bi)
        -- Убрать пробел в конце если разбили по пробелу
        seg = string.gsub(seg, "%s+$", "")
        table.insert(lines, seg)
        text = string.gsub(string.sub(text, bi + 1), "^%s+", "")
    end
    if #text > 0 then table.insert(lines, text) end
    return lines
end

-- Строит плоский список строк для changelog.
-- Версии сворачиваются/разворачиваются по expanded[version] == true.
-- kind = "header" | "item" | "item_cont" | "blank"
local function buildChangelogRows(W, expanded)
    local contentW = W - 1
    local itemW    = contentW - 4
    local rows = {}
    local entries = type(Changelog) == "table" and Changelog or {}
    for _, entry in ipairs(entries) do
        local ver    = entry.version or "?"
        local isOpen = expanded and expanded[ver]
        local arrow  = isOpen and "v " or "> "
        local hdr    = arrow .. "v" .. ver .. "  " .. (entry.date or "")
        table.insert(rows, {kind = "header", version = ver, text = hdr})
        if isOpen then
            for _, change in ipairs(entry.changes or {}) do
                local wrapped = wrapLine(tostring(change), itemW)
                for i, line in ipairs(wrapped) do
                    if i == 1 then
                        table.insert(rows, {kind = "item",      text = "  * " .. line})
                    else
                        table.insert(rows, {kind = "item_cont", text = "    " .. line})
                    end
                end
            end
            table.insert(rows, {kind = "blank", text = ""})
        end
    end
    return rows
end

-- ── Changelog sub-screen ──────────────────────────────────────────────────────

local function drawChangelog(st, win, W, H)
    local bg    = colors.black
    local bodyH = H - 1   -- строка 1 = header, 2..H = content

    win.setBackgroundColor(bg); win.clear()

    -- Header
    win.setCursorPos(1, 1)
    win.setBackgroundColor(colors.blue); win.setTextColor(colors.white)
    win.write(pad(" CHANGELOG ", W - 6))
    win.setBackgroundColor(colors.gray); win.write("[Back]")
    win.setBackgroundColor(bg)

    local rows   = buildChangelogRows(W, st.clExpanded)
    local scroll = st.clSb.scroll
    local first  = scroll + 1
    local last   = math.min(#rows, first + bodyH - 1)

    local y = 2
    for i = first, last do
        win.setCursorPos(1, y); win.setBackgroundColor(bg)
        local row = rows[i]
        if row.kind == "header" then
            win.setTextColor(colors.cyan)
            win.write(pad(row.text, W - 1))
        elseif row.kind == "blank" then
            win.write(string.rep(" ", W - 1))
        else
            win.setTextColor(colors.white)
            win.write(pad(row.text, W - 1))
        end
        y = y + 1
    end

    -- Scrollbar
    st.clSb:setBounds(W, 2, H)
    st.clSb:setContent(bodyH, #rows)
    st.clSb:draw(win)
end

-- ── Main screen ───────────────────────────────────────────────────────────────

function M.init(win, ctx)
    local cfg    = ctx.config
    local source = Updater.readSource() or (cfg and cfg.osSourceUrl) or ""
    return {
        win         = win,
        ctx         = ctx,
        source      = source,
        channel     = detectChannel(source, cfg),
        status      = "",
        remoteVer   = nil,
        needsReboot = false,
        updated     = false,
        initialTimer = os.startTimer(0),
        subMode     = nil,
        clExpanded  = {},
        clSb        = Scrollbar.create({thumbBg = colors.cyan, thumbFg = colors.black}),
    }
end

function M.draw(st, win)
    local W, H  = win.getSize()
    local isDev = (st.channel == "dev")

    if st.subMode == "changelog" then
        drawChangelog(st, win, W, H); return
    end

    win.setBackgroundColor(colors.black); win.clear()

    win.setCursorPos(1, 1); win.setBackgroundColor(colors.gray); win.setTextColor(colors.white)
    win.write(pad(" OS UPDATE ", W))
    win.setBackgroundColor(colors.black)

    win.setCursorPos(1, 3); win.setTextColor(colors.lightGray); win.write("Installed:")
    win.setCursorPos(1, 4); win.setTextColor(colors.white); win.write(pad(tostring(MANIFEST.version), W))

    win.setCursorPos(1, 6); win.setTextColor(colors.lightGray); win.write("Channel:")
    win.setCursorPos(1, 7)
    win.setBackgroundColor(isDev and colors.cyan or colors.gray)
    win.setTextColor(isDev and colors.black or colors.white)
    win.write(pad(" dev ", 8))
    win.setBackgroundColor(st.channel == "stable" and colors.cyan or colors.gray)
    win.setTextColor(st.channel == "stable" and colors.black or colors.white)
    win.write(pad(" stable ", 9))
    win.setBackgroundColor(colors.black)
    if st.channel == "custom" then
        win.setCursorPos(1, 8); win.setTextColor(colors.lightGray)
        win.write(pad("Using installation source", W))
    end

    win.setCursorPos(1, 9);  win.setTextColor(colors.lightGray); win.write("Available:")
    win.setCursorPos(1, 10); win.setTextColor(colors.white); win.write(pad(st.remoteVer or "—", W))

    if st.status ~= "" then
        local fc = colors.lightGray
        if     st.status == "Up to date"       then fc = colors.lime
        elseif st.status == "Update available" then fc = colors.yellow
        elseif string.find(st.status, "ailed", 1, true) then fc = colors.red
        elseif st.updated                      then fc = colors.lime
        end
        win.setCursorPos(1, 12); win.setTextColor(fc); win.write(pad(st.status, W))
    end

    win.setCursorPos(1, H - 2); win.setBackgroundColor(colors.black)
    win.setTextColor(colors.lightGray); win.write("> ")
    win.setTextColor(colors.white); win.write("Changelog")

    if st.needsReboot then
        win.setCursorPos(1, H); win.setBackgroundColor(colors.lime); win.setTextColor(colors.black)
        win.write(pad("  Reboot to apply update", W))
    else
        win.setCursorPos(1, H)
        win.setBackgroundColor(colors.blue);  win.setTextColor(colors.white); win.write(" Check  ")
        win.setBackgroundColor(colors.green); win.setTextColor(colors.black); win.write(" Update ")
        win.setBackgroundColor(colors.black); win.setTextColor(colors.black)
        win.write(string.rep(" ", math.max(0, W - 24)))
        win.setCursorPos(W - 7, H)
        win.setBackgroundColor(colors.red); win.setTextColor(colors.white); win.write(" Reboot ")
    end
end

-- ── События ───────────────────────────────────────────────────────────────────

function M.onEvent(st, event, p1, p2, p3)
    local W, H = st.win.getSize()
    if event == "timer" and p1 == st.initialTimer then
        st.initialTimer = nil
        startCheck(st)
        return st, true
    end

    -- Скролл колёсиком — обрабатываем для обоих sub-screen и main
    if event == "mouse_scroll" and st.subMode == "changelog" then
        st.clSb:scrollBy(p1)
        return st, true
    end

    -- Drag scrollbar в changelog
    if event == "mouse_drag" and st.subMode == "changelog" then
        if st.clSb:onDrag(p2, p3) then return st, true end
        return st, false
    end

    if event ~= "mouse_click" and event ~= "monitor_touch" then return st, false end
    local x, y = p2, p3

    -- Changelog sub-screen
    if st.subMode == "changelog" then
        if y == 1 and x >= W - 5 then
            st.subMode = nil; return st, true
        end
        if st.clSb:onClick(x, y) then return st, true end
        -- Клик по строке контента — проверяем, не header ли это
        if y >= 2 and y <= H and not st.clSb:contains(x, y) then
            local rowIdx = st.clSb.scroll + (y - 1)  -- y=2 → rows[scroll+1]
            local rows = buildChangelogRows(W, st.clExpanded)
            local row  = rows[rowIdx]
            if row and row.kind == "header" then
                st.clExpanded[row.version] = not st.clExpanded[row.version]
                -- Пересчитать maxScroll после сворачивания
                local newRows = buildChangelogRows(W, st.clExpanded)
                st.clSb:setContent(H - 1, #newRows)
                return st, true
            end
        end
        return st, false
    end

    if st.needsReboot then
        if y == H then os.reboot() end
        return st, false
    end

    -- Переключатель канала (строка 7)
    if y == 7 then
        if st.busy then return st, false end
        local cfg = st.ctx.config
        local stUrl, devUrl = getChannelUrls(cfg)
        local newUrl, newCh
        if x >= 1 and x <= 8  then newUrl = devUrl; newCh = "dev"    end
        if x >= 9 and x <= 17 then newUrl = stUrl;  newCh = "stable" end
        if newUrl == "" then
            st.status = "Channel not configured"
            return st, true
        end
        if newUrl and newUrl ~= "" and newCh ~= st.channel then
            local ok, err = Updater.writeSource(newUrl)
            if not ok then st.status = "Error: " .. tostring(err); return st, true end
            st.source    = newUrl
            st.channel   = newCh
            st.remoteVer = nil
            st.incompatible = false
            startCheck(st)
            return st, true
        end
        return st, false
    end

    -- Ссылка на changelog (строка H-2)
    if y == H - 2 and x >= 1 and x <= 11 then
        st.clSb:setScroll(0)
        st.subMode = "changelog"; return st, true
    end

    -- Footer (строка H). Check/Update уносим в фоновую корутину (ctx.spawn),
    -- чтобы скачивание ~40 файлов не морозило UI: часы тикают, экран
    -- перерисовывается по ходу через ctx.refresh().
    if y == H then
        if st.busy then return st, false end
        local ctx = st.ctx
        if x >= 1 and x <= 8 then
            startCheck(st)
            return st, true
        end
        if x >= 9 and x <= 16 then
            if st.incompatible then return st, false end
            st.busy   = true
            st.status = "Updating..."
            ctx.spawn(function()
                local upOk, msg = Updater.updateConfigured(MANIFEST,
                    {osSourceUrl = st.source, role = ctx.config and ctx.config.role},
                    function(done, total)
                        st.status = "Updating " .. done .. "/" .. total .. "..."
                        ctx.refresh()
                    end)
                st.updated = upOk
                st.status  = upOk and msg or ("Error: " .. tostring(msg))
                if upOk then
                    local rm = Updater.fetchManifest(st.source)
                    if rm then st.remoteVer = rm.version end
                    if msg ~= "already up to date" then st.needsReboot = true end
                end
                st.busy = false
                ctx.refresh()
            end, "os_update")
            return st, true
        end
        if x >= W - 7 then os.reboot() end
    end

    return st, false
end

return M
