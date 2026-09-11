local Scrollbar = dofile("/os/lib/scrollbar.lua")
local Users     = dofile("/os/lib/users.lua")

local M = {}

M.id       = "files"
M.name     = "Files"
M.icon     = "Fi"
M.iconBg   = colors.blue
M.iconFg   = colors.white
M.version  = 5
M.system   = true
M.category = "system"

local FsUtil = nil

local HEADER_H = 3

local function fsutil()
    if not FsUtil then FsUtil = dofile("/os/lib/fsutil.lua") end
    return FsUtil
end

local function padR(s, w)
    s = tostring(s or "")
    if #s >= w then return string.sub(s, 1, w) end
    return s .. string.rep(" ", w - #s)
end

local function basename(path)
    if path == "/" then return "/" end
    return string.match(path, "([^/]+)$") or path
end

local function parentDir(path)
    if path == "/" then return "/" end
    local d = fs.getDir(path)
    if d == "" then return "/" end
    if string.sub(d, 1, 1) == "/" then return d end
    return "/" .. d
end

local function absPath(base, name)
    if type(name) ~= "string" or name == "" then return base end
    local p
    if string.sub(name, 1, 1) == "/" then
        p = fs.combine("/", string.sub(name, 2))
    else
        p = fs.combine(base == "/" and "" or base, name)
    end
    if p == "" then return "/" end
    if string.sub(p, 1, 1) == "/" then return p end
    return "/" .. p
end

-- ── Границы доступа ──────────────────────────────────────────────────────────
-- Обычный пользователь видит только свою папку данных (ctx.dataRoot) и не
-- может подняться выше. Администратор видит всё, но каталоги и файлы, которыми
-- управляет сама ОС, из Files менять нельзя никому: их правит установщик и
-- OTA, а случайное удаление делает машину незагружаемой.

local SYSTEM_PATHS = {"/os", "/startup.lua", "/data/system", "/rom"}

local function isSystemPath(path)
    for _, sys in ipairs(SYSTEM_PATHS) do
        if path == sys or string.sub(path, 1, #sys + 1) == sys .. "/" then return true end
    end
    -- Служебные файлы в корне: /.mineboom_source, /.os_journal и т.п.
    if string.match(path, "^/%.[^/]+$") then return true end
    return false
end

local function within(root, path)
    if root == "/" then return true end
    return path == root or string.sub(path, 1, #root + 1) == root .. "/"
end

local function isAdmin(st)
    local u = st.ctx and st.ctx.currentUser
    return u and u.isAdmin or false
end

-- Имя новой записи: без разделителей и переходов вверх, иначе через New/Rename
-- можно было бы выйти за корень или переместить файл в другой каталог.
local function validName(name)
    if type(name) ~= "string" or name == "" then return false end
    if string.find(name, "[/\\\n\r]") then return false end
    if name == "." or name == ".." then return false end
    return true
end

-- Можно ли менять (создавать, переименовывать, удалять) по этому пути.
-- Возвращает true либо false и причину.
local function canModify(st, path)
    if not within(st.root, path) then return false, "Outside your folder" end
    if isSystemPath(path) then return false, "System files are managed by the OS" end
    return true
end

local function canRead(st, path)
    if not within(st.root, path) then return false, "Outside your folder" end
    return true
end

-- Путь для заголовка: своя папка показывается как ~, чтобы влезать в 26 колонок.
local function displayPath(st, path)
    if st.root == "/" then return path end
    if path == st.root then return "~" end
    return "~" .. string.sub(path, #st.root + 1)
end

local function shortSize(path)
    if fs.isDir(path) then return "<DIR>" end
    local ok, size = pcall(fs.getSize, path)
    if not ok or type(size) ~= "number" then return "?" end
    if size >= 1024 * 1024 then return string.format("%.1fM", size / (1024 * 1024)) end
    if size >= 1024 then return string.format("%.1fk", size / 1024) end
    return tostring(size)
end

local function writeAt(win, x, y, text, fg, bg)
    win.setCursorPos(x, y)
    win.setTextColor(fg or colors.white)
    win.setBackgroundColor(bg or colors.black)
    win.write(tostring(text or ""))
end

local function fillLine(win, y, bg, fg)
    local W = win.getSize()
    writeAt(win, 1, y, string.rep(" ", W), fg or colors.white, bg)
end

local function drawButton(win, st, id, x, y, label, fg, bg)
    local W = win.getSize()
    if x > W then return x end
    local text = " " .. label .. " "
    if x + #text - 1 > W then text = string.sub(text, 1, W - x + 1) end
    writeAt(win, x, y, text, fg, bg)
    table.insert(st.buttons, {id = id, x = x, y = y, w = #text})
    return x + #text + 1
end

local function setStatus(st, msg, level)
    st.status = tostring(msg or "")
    st.statusLevel = level or "info"
end

local function readDir(st)
    st.entries = {}
    if not within(st.root, st.path) or not fs.exists(st.path) then
        st.path = st.root
    end
    if st.path ~= st.root then
        table.insert(st.entries, {name = "..", path = parentDir(st.path), dir = true, up = true})
    end

    local ok, list = pcall(fs.list, st.path)
    if not ok or type(list) ~= "table" then
        setStatus(st, "Cannot read: " .. st.path, "error")
        return
    end

    table.sort(list, function(a, b)
        local ap = absPath(st.path, a)
        local bp = absPath(st.path, b)
        local ad = fs.isDir(ap)
        local bd = fs.isDir(bp)
        if ad ~= bd then return ad end
        return string.lower(a) < string.lower(b)
    end)

    for _, name in ipairs(list) do
        local path = absPath(st.path, name)
        table.insert(st.entries, {
            name = name,
            path = path,
            dir = fs.isDir(path),
            readonly = fs.isReadOnly and fs.isReadOnly(path) or false,
            size = shortSize(path),
        })
    end

    if st.selected > #st.entries then st.selected = #st.entries end
    if st.selected < 1 then st.selected = math.min(1, #st.entries) end
end

local function selectedEntry(st)
    return st.entries and st.entries[st.selected] or nil
end

local function visibleRows(win)
    local _, H = win.getSize()
    return math.max(1, H - HEADER_H - 1)
end

local function ensureVisible(st, win)
    local rows = visibleRows(win)
    if st.selected <= st.scroll then
        st.scroll = math.max(0, st.selected - 1)
    elseif st.selected > st.scroll + rows then
        st.scroll = st.selected - rows
    end
end

local function openFile(st, entry)
    local okRead, why = canRead(st, entry.path)
    if not okRead then setStatus(st, why, "error"); return end
    local data, err = fsutil().readFile(entry.path)
    if not data then
        setStatus(st, tostring(err), "error")
        return
    end

    st.mode = "view"
    st.viewPath = entry.path
    st.viewLines = {}
    st.viewScroll = 0
    st.viewHScroll = 0
    st.viewMaxLen = 0
    data = string.gsub(data, "\r\n", "\n")
    data = string.gsub(data, "\r", "\n")
    for line in string.gmatch(data .. "\n", "(.-)\n") do
        table.insert(st.viewLines, line)
        if #line > st.viewMaxLen then st.viewMaxLen = #line end
        if #st.viewLines >= 2000 then
            table.insert(st.viewLines, "... truncated ...")
            break
        end
    end
    setStatus(st, "Viewing " .. basename(entry.path), "info")
end

local function enterEntry(st)
    local e = selectedEntry(st)
    if not e then return end
    if e.dir then
        if not within(st.root, e.path) then setStatus(st, "Outside your folder", "error"); return end
        st.path = e.path
        st.selected = 1
        st.scroll = 0
        st.mode = "list"
        readDir(st)
    else
        openFile(st, e)
    end
end

local function prompt(st, kind, title, value)
    st.mode = "prompt"
    st.promptKind = kind
    st.promptTitle = title
    st.promptValue = value or ""
    st.promptCursor = #st.promptValue + 1
end

local function confirm(st, kind, title, target)
    st.mode = "confirm"
    st.confirmKind = kind
    st.confirmTitle = title
    st.confirmTarget = target
end

local function createFile(st, name)
    if not Users.can(st.ctx.currentUser, "editFiles") then
        setStatus(st, "No permission to create files", "error"); return
    end
    if not validName(name) then setStatus(st, "Invalid name", "error"); return end
    local path = absPath(st.path, name)
    local allowed, why = canModify(st, path)
    if not allowed then setStatus(st, why, "error"); return end
    if fs.exists(path) then setStatus(st, "Already exists: " .. name, "error"); return end
    local ok, err = fsutil().atomicWrite(path, "")
    if ok then
        setStatus(st, "Created file: " .. name, "success")
        readDir(st)
    else
        setStatus(st, tostring(err), "error")
    end
end

local function createDir(st, name)
    if not Users.can(st.ctx.currentUser, "editFiles") then
        setStatus(st, "No permission to create folders", "error"); return
    end
    if not validName(name) then setStatus(st, "Invalid name", "error"); return end
    local path = absPath(st.path, name)
    local allowed, why = canModify(st, path)
    if not allowed then setStatus(st, why, "error"); return end
    if fs.exists(path) then setStatus(st, "Already exists: " .. name, "error"); return end
    local ok, err = pcall(fs.makeDir, path)
    if ok then
        setStatus(st, "Created folder: " .. name, "success")
        readDir(st)
    else
        setStatus(st, "Cannot create folder: " .. tostring(err), "error")
    end
end

local function renameEntry(st, name)
    if not Users.can(st.ctx.currentUser, "editFiles") then
        setStatus(st, "No permission to rename", "error"); return
    end
    local e = selectedEntry(st)
    if not e or e.up then return end
    if not validName(name) then setStatus(st, "Invalid name", "error"); return end
    local dest = absPath(st.path, name)
    local allowed, why = canModify(st, e.path)
    if allowed then allowed, why = canModify(st, dest) end
    if not allowed then setStatus(st, why, "error"); return end
    if fs.exists(dest) then setStatus(st, "Already exists: " .. name, "error"); return end
    local ok, err = pcall(fs.move, e.path, dest)
    if ok then
        setStatus(st, "Renamed to: " .. name, "success")
        readDir(st)
    else
        setStatus(st, "Rename failed: " .. tostring(err), "error")
    end
end

local function deleteEntry(st)
    if not Users.can(st.ctx.currentUser, "deleteFiles") then
        setStatus(st, "No permission to delete", "error"); return
    end
    local e = st.confirmTarget
    if not e or e.up then return end
    if e.path == "/" or e.path == st.root then setStatus(st, "Cannot delete root", "error"); return end
    local allowed, why = canModify(st, e.path)
    if not allowed then setStatus(st, why, "error"); return end
    local ok, err = pcall(fs.delete, e.path)
    if ok then
        setStatus(st, "Deleted: " .. e.name, "success")
        readDir(st)
    else
        setStatus(st, "Delete failed: " .. tostring(err), "error")
    end
end

local function runLua(st)
    if not isAdmin(st) then
        setStatus(st, "Only admins can run scripts", "error")
        return
    end
    local e = selectedEntry(st)
    if not e or e.dir then return end
    local okRead, why = canRead(st, e.path)
    if not okRead then setStatus(st, why, "error"); return end
    if string.sub(e.name, -4) ~= ".lua" then
        setStatus(st, "Only .lua files can be run", "error")
        return
    end

    local oldTerm = term.current()
    term.redirect(st.win)
    local ok, err = pcall(os.run, {}, e.path)
    term.redirect(oldTerm)
    setStatus(st, ok and ("Ran: " .. e.name) or ("Run failed: " .. tostring(err)),
              ok and "success" or "error")
end

function M.init(win, ctx)
    local user = ctx and ctx.currentUser
    local root = "/"
    if not (user and user.isAdmin) then
        root = (ctx and ctx.dataRoot) or "/data"
        if root ~= "/" then root = string.gsub(root, "/+$", "") end
        if root == "" then root = "/" end
        pcall(fsutil().ensureDir, root)
    end
    local st = {
        win = win,
        ctx = ctx,
        root = root,
        path = root,
        entries = {},
        selected = 1,
        scroll = 0,
        viewScroll = 0,
        viewHScroll = 0,
        viewLines = {},
        viewMaxLen = 0,
        mode = "list",
        status = "Enter/open, Backspace/up, N file, D folder, R rename, X delete",
        statusLevel = "info",
        buttons = {},
        sb = Scrollbar.create({thumbBg = colors.blue, thumbFg = colors.white}),
        sbH = Scrollbar.create({
            orientation = "horizontal",
            thumbBg = colors.blue, thumbFg = colors.white,
        }),
    }
    readDir(st)
    return st
end

local function drawList(st, win)
    local W, H = win.getSize()
    st.buttons = {}
    win.setBackgroundColor(colors.black)
    win.clear()

    fillLine(win, 1, colors.gray, colors.white)
    writeAt(win, 1, 1, padR(" FILES  " .. displayPath(st, st.path), W), colors.white, colors.gray)

    -- Контекстные кнопки: показываем только релевантные для текущего выбора,
    -- чтобы всё помещалось на узком экране карманного компьютера (W=26).
    local sel = st.entries[st.selected]
    local hasEntry = sel and not sel.up   -- выбран реальный файл/папка
    local hasFile  = hasEntry and not sel.dir

    local x = 1
    if st.path ~= st.root then
        x = drawButton(win, st, "up", x, 2, "Up", colors.white, colors.gray)
    end
    if hasEntry then
        if hasFile and isAdmin(st) then
            x = drawButton(win, st, "run",    x, 2, "Run",    colors.white, colors.blue)
        end
        if canModify(st, sel.path) then
            x = drawButton(win, st, "rename", x, 2, "Rename", colors.black, colors.yellow)
            x = drawButton(win, st, "delete", x, 2, "Del",    colors.white, colors.red)
        end
    elseif canModify(st, st.path == "/" and "/new" or st.path .. "/new") then
        x = drawButton(win, st, "new_file", x, 2, "File", colors.black, colors.lime)
        x = drawButton(win, st, "new_dir",  x, 2, "Dir",  colors.black, colors.cyan)
    end
    writeAt(win, x, 2, string.rep(" ", math.max(0, W - x + 1)), colors.white, colors.black)

    -- Резервируем колонку W под scrollbar — сжимаем SIZE до 10 символов.
    fillLine(win, 3, colors.black, colors.lightGray)
    writeAt(win, 1, 3, padR("NAME", math.max(1, W - 13)), colors.lightGray, colors.black)
    writeAt(win, math.max(1, W - 10), 3, padR("SIZE", 10), colors.lightGray, colors.black)

    ensureVisible(st, win)
    local rows = visibleRows(win)
    local y = HEADER_H + 1
    for i = st.scroll + 1, math.min(#st.entries, st.scroll + rows) do
        local e = st.entries[i]
        local bg = (i == st.selected) and colors.blue or ((i % 2 == 0) and colors.gray or colors.black)
        local fg = e.up and colors.yellow or (e.dir and colors.cyan or colors.white)
        fillLine(win, y, bg, fg)
        local mark = e.dir and "/" or " "
        local label = (e.up and ".." or (mark .. " " .. e.name))
        writeAt(win, 1, y, padR(label, math.max(1, W - 13)), fg, bg)
        writeAt(win, math.max(1, W - 10), y, padR(e.size or "", 10), colors.lightGray, bg)
        y = y + 1
    end

    -- Scrollbar справа на области строк.
    st.sb:setBounds(W, HEADER_H + 1, H - 1)
    st.sb:setContent(rows, #st.entries)
    st.sb:setScroll(st.scroll)
    st.sb:draw(win)

    local sfg = colors.lightGray
    if st.statusLevel == "error" then sfg = colors.red
    elseif st.statusLevel == "success" then sfg = colors.lime
    elseif st.statusLevel == "warn" then sfg = colors.orange end
    fillLine(win, H, colors.gray, sfg)
    writeAt(win, 1, H, padR(" " .. st.status, W), sfg, colors.gray)
end

local function drawView(st, win)
    local W, H = win.getSize()
    st.buttons = {}
    win.setBackgroundColor(colors.black)
    win.clear()
    fillLine(win, 1, colors.gray, colors.white)
    writeAt(win, 1, 1, padR(" VIEW  " .. tostring(st.viewPath), W), colors.white, colors.gray)
    drawButton(win, st, "back", 1, 2, "Back", colors.white, colors.gray)

    -- Резервируем колонку W для vertical sb. Дополнительно резервируем
    -- строку H-1 под horizontal sb, если есть, что скроллить по горизонтали.
    local lineW = W - 1
    local needH = st.viewMaxLen > lineW
    local hRow  = needH and (H - 1) or nil
    local rowsTop = 3
    local rowsBottom = needH and (H - 2) or (H - 1)
    local rows = math.max(0, rowsBottom - rowsTop + 1)

    st.viewHScroll = math.max(0,
        math.min(math.max(0, st.viewMaxLen - lineW), st.viewHScroll or 0))

    for i = st.viewScroll + 1, math.min(#st.viewLines, st.viewScroll + rows) do
        local y = rowsTop + (i - st.viewScroll - 1)
        local raw = st.viewLines[i] or ""
        local slice = string.sub(raw, st.viewHScroll + 1, st.viewHScroll + lineW)
        writeAt(win, 1, y, padR(slice, lineW), colors.white, colors.black)
    end

    -- Vertical scrollbar (только когда нужен; иначе колонка остаётся чёрной).
    st.sb:setBounds(W, rowsTop, rowsBottom)
    st.sb:setContent(rows, #st.viewLines)
    st.sb:setScroll(st.viewScroll)
    st.sb:draw(win)

    -- Horizontal scrollbar внизу, если строки шире viewport.
    if needH then
        st.sbH:setBounds(hRow, 1, lineW)
        st.sbH:setContent(lineW, st.viewMaxLen)
        st.sbH:setScroll(st.viewHScroll)
        st.sbH:draw(win)
    end

    fillLine(win, H, colors.gray, colors.lightGray)
    local hint = needH and "Scroll, Shift+wheel horizontal, Back" or "Scroll or Backspace"
    writeAt(win, 1, H, padR(" Lines: " .. #st.viewLines .. "  " .. hint, W), colors.lightGray, colors.gray)
end

local function drawPrompt(st, win)
    local W, H = win.getSize()
    drawList(st, win)
    local y = math.max(4, math.floor(H / 2) - 1)
    fillLine(win, y, colors.blue, colors.white)
    fillLine(win, y + 1, colors.black, colors.white)
    fillLine(win, y + 2, colors.gray, colors.lightGray)
    writeAt(win, 2, y, padR(" " .. st.promptTitle, W - 2), colors.white, colors.blue)
    writeAt(win, 2, y + 1, padR("> " .. st.promptValue, W - 2), colors.white, colors.black)
    writeAt(win, 2, y + 2, padR(" Enter OK  Esc cancel", W - 2), colors.lightGray, colors.gray)
end

local function drawConfirm(st, win)
    local W, H = win.getSize()
    drawList(st, win)
    local y = math.max(4, math.floor(H / 2) - 1)
    fillLine(win, y, colors.red, colors.white)
    fillLine(win, y + 1, colors.black, colors.white)
    fillLine(win, y + 2, colors.gray, colors.lightGray)
    writeAt(win, 2, y, padR(" " .. st.confirmTitle, W - 2), colors.white, colors.red)
    writeAt(win, 2, y + 1, padR(" " .. ((st.confirmTarget and st.confirmTarget.path) or ""), W - 2), colors.white, colors.black)
    writeAt(win, 2, y + 2, padR(" Y confirm  Esc/N cancel", W - 2), colors.lightGray, colors.gray)
end

function M.draw(st, win)
    st.win = win
    if st.mode == "view" then
        drawView(st, win)
    elseif st.mode == "prompt" then
        drawPrompt(st, win)
    elseif st.mode == "confirm" then
        drawConfirm(st, win)
    else
        drawList(st, win)
    end
end

local function hitButton(st, x, y)
    for _, b in ipairs(st.buttons or {}) do
        if y == b.y and x >= b.x and x < b.x + b.w then return b.id end
    end
    return nil
end

local function handleAction(st, id)
    if id == "up" then
        if st.path == st.root then return end
        st.path = parentDir(st.path); st.selected = 1; st.scroll = 0; readDir(st)
    elseif id == "new_file" then
        prompt(st, "file", "New file name", "new.lua")
    elseif id == "new_dir" then
        prompt(st, "dir", "New folder name", "folder")
    elseif id == "rename" then
        local e = selectedEntry(st)
        if e and not e.up then prompt(st, "rename", "Rename " .. e.name, e.name) end
    elseif id == "delete" then
        local e = selectedEntry(st)
        if e and not e.up then confirm(st, "delete", "Delete?", e) end
    elseif id == "run" then
        runLua(st)
    elseif id == "back" then
        st.mode = "list"
    end
end

local function submitPrompt(st)
    local value = st.promptValue
    st.mode = "list"
    if value == "" or string.find(value, "[\n\r]") then
        setStatus(st, "Invalid name", "error")
        return
    end
    if st.promptKind == "file" then createFile(st, value)
    elseif st.promptKind == "dir" then createDir(st, value)
    elseif st.promptKind == "rename" then renameEntry(st, value)
    end
end

-- Синхронизация sb bounds/content под текущий режим, перед обработкой клика.
local function syncSb(st)
    local W, H = st.win.getSize()
    if st.mode == "view" then
        local lineW = W - 1
        local needH = (st.viewMaxLen or 0) > lineW
        local rowsTop = 3
        local rowsBottom = needH and (H - 2) or (H - 1)
        local rows = math.max(1, rowsBottom - rowsTop + 1)
        st.sb:setBounds(W, rowsTop, rowsBottom)
        st.sb:setContent(rows, #st.viewLines)
        st.sb:setScroll(st.viewScroll)
        if needH then
            st.sbH:setBounds(H - 1, 1, lineW)
            st.sbH:setContent(lineW, st.viewMaxLen)
            st.sbH:setScroll(st.viewHScroll or 0)
        else
            st.sbH:setBounds(0, 1, 0)
        end
    elseif st.mode == "list" then
        local rows = visibleRows(st.win)
        st.sb:setBounds(W, HEADER_H + 1, H - 1)
        st.sb:setContent(rows, #st.entries)
        st.sb:setScroll(st.scroll)
        st.sbH:setBounds(0, 1, 0)
    else
        st.sb:setBounds(0, 1, 0)
        st.sbH:setBounds(0, 1, 0)
    end
end

function M.onEvent(st, event, p1, p2, p3, p4)
    if event == "mouse_click" or event == "monitor_touch" then
        local x, y = p2, p3

        if st.mode == "view" or st.mode == "list" then
            syncSb(st)
            if st.sb:onClick(x, y) then
                if st.mode == "view" then st.viewScroll = st.sb.scroll
                else st.scroll = st.sb.scroll end
                return st, true
            end
            if st.mode == "view" and st.sbH:onClick(x, y) then
                st.viewHScroll = st.sbH.scroll
                return st, true
            end
        end

        if st.mode == "view" then
            local id = hitButton(st, x, y)
            if id then handleAction(st, id); return st, true end
            return st, false
        elseif st.mode == "list" then
            local id = hitButton(st, x, y)
            if id then handleAction(st, id); return st, true end
            if y > HEADER_H then
                local idx = st.scroll + (y - HEADER_H)
                if st.entries[idx] then
                    if st.selected == idx then
                        enterEntry(st)
                    else
                        st.selected = idx
                    end
                    return st, true
                end
            end
        end
        return st, false
    end

    if event == "mouse_drag" then
        if st.mode == "view" or st.mode == "list" then
            syncSb(st)
            if st.sb:onDrag(p2, p3) then
                if st.mode == "view" then st.viewScroll = st.sb.scroll
                else st.scroll = st.sb.scroll end
                return st, true
            end
            if st.mode == "view" and st.sbH:onDrag(p2, p3) then
                st.viewHScroll = st.sbH.scroll
                return st, true
            end
        end
        return st, false
    end

    if event == "mouse_scroll" then
        local dir = p1
        local shift = p4
        if st.mode == "view" then
            syncSb(st)
            if shift then
                st.sbH:scrollBy(dir)
                st.viewHScroll = st.sbH.scroll
            else
                st.sb:scrollBy(dir)
                st.viewScroll = st.sb.scroll
            end
        elseif st.mode == "list" then
            st.selected = math.max(1, math.min(#st.entries, st.selected + dir))
            ensureVisible(st, st.win)
        end
        return st, true
    end

    if event == "char" and st.mode == "prompt" then
        if type(p1) == "string" and #p1 == 1 then
            st.promptValue = st.promptValue .. p1
            return st, true
        end
    elseif event == "paste" and st.mode == "prompt" then
        st.promptValue = st.promptValue .. tostring(p1 or "")
        return st, true
    elseif event == "key" then
        if st.mode == "prompt" then
            if p1 == keys.enter then submitPrompt(st); return st, true end
            if p1 == keys.escape then st.mode = "list"; return st, true end
            if p1 == keys.backspace and #st.promptValue > 0 then
                st.promptValue = string.sub(st.promptValue, 1, -2)
                return st, true
            end
        elseif st.mode == "confirm" then
            if p1 == keys.y then
                local kind = st.confirmKind
                st.mode = "list"
                if kind == "delete" then deleteEntry(st) end
                return st, true
            elseif p1 == keys.escape or p1 == keys.n then
                st.mode = "list"
                return st, true
            end
        elseif st.mode == "view" then
            if p1 == keys.backspace or p1 == keys.escape then st.mode = "list"; return st, true end
            if p1 == keys.up then st.viewScroll = math.max(0, st.viewScroll - 1); return st, true end
            if p1 == keys.down then st.viewScroll = st.viewScroll + 1; return st, true end
            if p1 == keys.left then st.viewHScroll = math.max(0, (st.viewHScroll or 0) - 1); return st, true end
            if p1 == keys.right then st.viewHScroll = (st.viewHScroll or 0) + 1; return st, true end
        else
            if p1 == keys.enter then enterEntry(st); return st, true end
            if p1 == keys.backspace then handleAction(st, "up"); return st, true end
            if p1 == keys.up then st.selected = math.max(1, st.selected - 1); ensureVisible(st, st.win); return st, true end
            if p1 == keys.down then st.selected = math.min(#st.entries, st.selected + 1); ensureVisible(st, st.win); return st, true end
            if p1 == keys.n then handleAction(st, "new_file"); return st, true end
            if p1 == keys.d then handleAction(st, "new_dir"); return st, true end
            if p1 == keys.r then handleAction(st, "rename"); return st, true end
            if p1 == keys.x or p1 == keys.delete then handleAction(st, "delete"); return st, true end
            if p1 == keys.f5 then readDir(st); setStatus(st, "Refreshed", "success"); return st, true end
            if p1 == keys.f9 then runLua(st); return st, true end
        end
    end

    return st, false
end

return M
