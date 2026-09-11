-- Admin panel: управление пользователями. Видно только isAdmin == true.
local M = {}
M.id       = "admin"
M.name     = "Admin"
M.icon     = "Adm"
M.iconBg   = colors.red
M.iconFg   = colors.white
M.version  = 8
M.system   = true
M.category = "system"
M.hidden   = false
M.protocols = {"pocket_store"}  -- слушаем каталог App Store для экрана perms

local Loader = dofile("/os/lib/loader.lua")
local AppMeta = dofile("/os/lib/appmeta.lua")
local FsUtil = dofile("/os/lib/fsutil.lua")
local Scrollbar = dofile("/os/lib/scrollbar.lua")

-- Отступ сеткой
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

-- ── Категории приложений (один в один с os/apps/apps.lua) ─────────────────────
-- Категория берётся из статических полей M.* в исходнике приложения.
-- Если файл не содержит нужных полей, остаётся fallback по id.
local CATEGORY_LABEL = {
    automation = "Automation",
    network    = "Network",
    games      = "Games",
    system     = "System",
    other      = "Other",
}
local CATEGORY_ORDER = {"automation", "network", "games", "system", "other"}
local CATEGORY_FALLBACK = {
    factory = "automation", storage = "automation", rtc = "automation",
    hub = "network",
    apps = "system", files = "system", settings = "system",
    logs = "system", os_update = "system", terminal = "system", admin = "system",
    minesweeper = "games", snake = "games", ["2048"] = "games",
}

local function appCategory(def, id)
    local cat = def and def.category
    if not cat or not CATEGORY_LABEL[cat] then cat = CATEGORY_FALLBACK[id] end
    if not cat or not CATEGORY_LABEL[cat] then cat = "other" end
    return cat
end

-- Безопасно читаем метаданные приложения: статически парсим M.*-поля без
-- выполнения самого файла.
local function readAppMeta(path)
    return AppMeta.read(path)
end

-- Плоский список строк для perms: заголовки категорий + приложения.
--   {type="header", cat=..., text=..., count=N, expanded=bool}
--   {type="app", app={id, name, category}}
local function buildPermRows(apps, expanded)
    expanded = expanded or {}
    local buckets = {}
    for _, app in ipairs(apps or {}) do
        local cat = app.category or "other"
        buckets[cat] = buckets[cat] or {}
        table.insert(buckets[cat], app)
    end
    local rows = {}
    for _, cat in ipairs(CATEGORY_ORDER) do
        local list = buckets[cat]
        if list and #list > 0 then
            local open = expanded[cat] == true
            table.insert(rows, {type = "header", cat = cat,
                                text = CATEGORY_LABEL[cat], count = #list, expanded = open})
            if open then
                for _, app in ipairs(list) do
                    table.insert(rows, {type = "app", app = app})
                end
            end
        end
    end
    return rows
end

-- ── Числовая клавиатура (для пароля) ─────────────────────────────────────────

local KEYPAD = {{7,8,9},{4,5,6},{1,2,3},{"X",0,"OK"}}
local BTN_W  = 3

local function drawKeypad(win, x0, y0, theme)
    local ac = theme.accentBg or colors.cyan
    for row, keys in ipairs(KEYPAD) do
        local y = y0 + (row - 1) * 2
        for col, k in ipairs(keys) do
            local x = x0 + (col - 1) * (BTN_W + 1)
            local bg = (k == "OK") and colors.green or (k == "X") and colors.red or ac
            local fg = (bg == colors.red or bg == colors.green) and colors.white or colors.black
            win.setCursorPos(x, y)
            win.setBackgroundColor(bg); win.setTextColor(fg)
            local ks = tostring(k)
            local pad = math.floor((BTN_W - #ks) / 2)
            win.write(string.rep(" ", pad) .. ks .. string.rep(" ", BTN_W - #ks - pad))
        end
    end
end

local function keypadHit(x, y, x0, y0)
    for row, keys in ipairs(KEYPAD) do
        local ky = y0 + (row - 1) * 2
        if y == ky then
            for col, k in ipairs(keys) do
                local kx = x0 + (col - 1) * (BTN_W + 1)
                if x >= kx and x < kx + BTN_W then
                    if k == "X"  then return "backspace" end
                    if k == "OK" then return "ok" end
                    return "digit", k
                end
            end
        end
    end
end

local function isDigitChar(ch)
    return type(ch) == "string" and string.match(ch, "^%d$") ~= nil
end

local function isEnterKey(k)
    return k == keys.enter or k == keys.space or (keys.numPadEnter and k == keys.numPadEnter)
end

local saveEditUser

local function editPasswordAction(st, action, data)
    if action == "digit" then
        local d = tostring(data)
        if st.editField == "pass" then
            st.editPass = st.editPass .. d
        elseif st.editField == "confirm" then
            st.editConfirm = st.editConfirm .. d
        end
        st.editError = ""
    elseif action == "backspace" then
        if st.editField == "pass" and #st.editPass > 0 then
            st.editPass = string.sub(st.editPass, 1, -2)
        elseif st.editField == "confirm" and #st.editConfirm > 0 then
            st.editConfirm = string.sub(st.editConfirm, 1, -2)
        end
    elseif action == "ok" then
        if st.editField == "name" then
            st.editField = "pass"
        elseif st.editField == "pass" then
            if #st.editPass > 0 then st.editField = "confirm" end
        elseif st.editField == "confirm" then
            if saveEditUser(st) then st.mode = "list" end
        end
    end
end

-- ── Состояния экрана ─────────────────────────────────────────────────────────
-- mode: "list" | "edit" | "new" | "perms"

local LOCK_OPTIONS = {
    {label = "Never",  value = 0},
    {label = "1 min",  value = 60},
    {label = "5 min",  value = 300},
    {label = "10 min", value = 600},
    {label = "30 min", value = 1800},
}

local function lockLabel(v)
    for _, o in ipairs(LOCK_OPTIONS) do
        if o.value == v then return o.label end
    end
    return tostring(v) .. "s"
end

-- ── init ─────────────────────────────────────────────────────────────────────

function M.init(win, ctx)
    if not ctx.currentUser or not ctx.currentUser.isAdmin then
        return {win = win, ctx = ctx, denied = true}
    end
    local Users = ctx.users or dofile("/os/lib/users.lua")
    return {
        win    = win,
        ctx    = ctx,
        Users  = Users,
        mode   = "list",
        scroll = 0,
        status = "",
        -- общий скроллбар для списка юзеров и экрана perms (геометрия задаётся в draw)
        sb     = Scrollbar.create({thumbBg = colors.cyan, thumbFg = colors.black}),
        -- App Store: полный каталог приложений для perms (включая не установленные)
        storeComputer = ctx.config and ctx.config.storeComputer,
        storeProtocol = ctx.config and ctx.config.storeProtocol,
        catalog       = nil,   -- кеш каталога после первого ответа сервера
        -- edit / new
        editUser   = nil,   -- копия записи пользователя при редактировании
        editField  = "name",-- "name"|"pass"|"confirm"
        editPass   = "",
        editConfirm= "",
        editError  = "",
        -- perms
        permUser   = nil,   -- id пользователя для перм-экрана
        allApps    = {},    -- список {id, name} всех приложений
    }
end

-- ── Список пользователей ──────────────────────────────────────────────────────

local HDR_H = 2  -- строки заголовка

local function drawList(st, win, W, H, theme)
    local hb = theme.headerBg or colors.blue
    local hf = theme.headerFg or colors.white
    local bg = theme.pageBg   or colors.black
    local ac = theme.accentBg or colors.cyan
    local sf = theme.rowFg or colors.white
    local mf = theme.mutedFg  or colors.lightGray

    win.setBackgroundColor(bg); win.clear()

    -- Резервируем правую колонку под scrollbar.
    local lw = W - 1

    -- Заголовок
    win.setCursorPos(1, 1); win.setBackgroundColor(hb); win.setTextColor(hf)
    win.write(padR(" ADMIN - Users", W))

    -- Кнопка New
    win.setCursorPos(W - 4, 1)
    win.setBackgroundColor(colors.green); win.setTextColor(colors.black)
    win.write("[New]")

    local users = st.Users.list()
    local ROW_H = 3
    local visRows = math.floor((H - HDR_H) / ROW_H)
    local first = st.scroll + 1
    local last  = math.min(#users, first + visRows - 1)

    local y = HDR_H + 1
    for i = first, last do
        local u = users[i]
        win.setCursorPos(1, y)
        win.setBackgroundColor(bg); win.setTextColor(sf)
        local badge = u.isAdmin and "[A]" or "   "
        local nameStr = padR(badge .. " " .. (u.name or u.id), lw - 12)
        win.write(nameStr)
        -- Edit
        win.setCursorPos(lw - 11, y)
        win.setBackgroundColor(ac); win.setTextColor(colors.black)
        win.write(" Edit ")
        -- Perms
        win.setBackgroundColor(colors.purple or colors.magenta); win.setTextColor(colors.white)
        win.write(" Perms")

        win.setCursorPos(1, y + 1)
        win.setBackgroundColor(bg); win.setTextColor(mf)
        local lockStr = "Lock: " .. lockLabel(u.lockTimeout or 600)
        win.write(padR(lockStr, lw - 8))
        -- Del
        win.setCursorPos(lw - 7, y + 1)
        win.setBackgroundColor(colors.red); win.setTextColor(colors.white)
        win.write(" Del  ")

        -- Разделитель
        win.setCursorPos(1, y + 2)
        win.setBackgroundColor(bg); win.setTextColor(colors.gray)
        win.write(string.rep("-", lw))

        y = y + ROW_H
    end

    -- Scrollbar справа (единица прокрутки — индекс пользователя).
    st.sb:setBounds(W, HDR_H + 1, H - 1)
    st.sb:setContent(visRows, #users)
    st.sb:setScroll(st.scroll)
    st.sb:draw(win)

    -- Статус
    win.setCursorPos(1, H)
    win.setBackgroundColor(bg); win.setTextColor(mf)
    win.write(padR(st.status, lw))
end

local function hitList(st, x, y, W, H)
    -- Кнопка New
    if y == 1 and x >= W - 4 then return "new" end
    if y <= HDR_H then return nil end

    -- Кнопки сдвинуты влево на 1 колонку — правый край занят scrollbar.
    local lw = W - 1
    local ROW_H = 3
    local row = math.floor((y - HDR_H - 1) / ROW_H)
    local rowY = (y - HDR_H - 1) % ROW_H
    local users = st.Users.list()
    local idx   = st.scroll + 1 + row
    local u     = users[idx]
    if not u then return nil end

    if rowY == 0 then
        if x >= lw - 11 and x < lw - 5 then return "edit", u end
        if x >= lw - 5  then return "perms", u end
    elseif rowY == 1 then
        if x >= lw - 7 then return "del", u end
    end
    return nil
end

-- ── Edit / New экран ─────────────────────────────────────────────────────────

local function drawEdit(st, win, W, H, theme)
    local hb = theme.headerBg or colors.blue
    local hf = theme.headerFg or colors.white
    local bg = theme.pageBg   or colors.black
    local ac = theme.accentBg or colors.cyan
    local sf = theme.rowFg or colors.white
    local mf = theme.mutedFg  or colors.lightGray

    win.setBackgroundColor(bg); win.clear()
    win.setCursorPos(1, 1); win.setBackgroundColor(hb); win.setTextColor(hf)
    local title = st.mode == "new" and " NEW USER" or " EDIT: " .. (st.editUser.name or st.editUser.id)
    win.write(padR(title, W - 5))
    win.setBackgroundColor(colors.gray); win.setTextColor(colors.white)
    win.write("[Back]")

    local eu = st.editUser
    local y = 3

    -- Имя
    win.setCursorPos(1, y); win.setBackgroundColor(bg)
    win.setTextColor(st.editField == "name" and sf or mf)
    win.write("Name: " .. clip(eu.name or "", W - 7))
    y = y + 1

    -- Admin toggle
    win.setCursorPos(1, y)
    win.setTextColor(sf)
    local admBox = eu.isAdmin and "[x]" or "[ ]"
    win.write(admBox .. " Admin")
    y = y + 1

    -- Lock timeout
    win.setCursorPos(1, y); win.setTextColor(sf)
    win.write("Lock: ")
    win.setBackgroundColor(ac); win.setTextColor(colors.black)
    win.write("< " .. lockLabel(eu.lockTimeout or 600) .. " >")
    win.setBackgroundColor(bg)
    y = y + 1

    -- Права доступа (только для не-admin)
    if not eu.isAdmin then
        local p = eu.permissions or {}
        win.setCursorPos(1, y); win.setTextColor(mf)
        win.write((p.editFiles   and "[x]" or "[ ]") .. " Edit files")
        y = y + 1
        win.setCursorPos(1, y)
        win.write((p.deleteFiles and "[x]" or "[ ]") .. " Delete files")
        y = y + 1
        win.setCursorPos(1, y)
        win.write((p.installApps and "[x]" or "[ ]") .. " Install apps")
        y = y + 1
    end

    -- Пароль
    win.setCursorPos(1, y); win.setTextColor(st.editField == "pass" and sf or mf)
    win.write("New pass: " .. string.rep("*", #st.editPass))
    y = y + 1

    if #st.editPass > 0 then
        win.setCursorPos(1, y); win.setTextColor(st.editField == "confirm" and sf or mf)
        win.write("Confirm:  " .. string.rep("*", #st.editConfirm))
        y = y + 1
    end

    -- Ошибка
    if st.editError ~= "" then
        win.setCursorPos(1, y); win.setTextColor(colors.red)
        win.write(clip(st.editError, W)); y = y + 1
    end

    -- Клавиатура
    local kx = math.floor((W - 11) / 2) + 1
    local ky = y
    drawKeypad(win, kx, ky, theme)

    -- Кнопка Save всегда в последней строке экрана
    win.setCursorPos(math.floor((W - 8) / 2) + 1, H)
    win.setBackgroundColor(colors.green); win.setTextColor(colors.black)
    win.write(" Save  ")
end

local function lockTimeoutCycle(current, dir)
    local cur = current or 600
    for i, o in ipairs(LOCK_OPTIONS) do
        if o.value == cur then
            local ni = i + dir
            if ni < 1 then ni = #LOCK_OPTIONS elseif ni > #LOCK_OPTIONS then ni = 1 end
            return LOCK_OPTIONS[ni].value
        end
    end
    return 600
end

function saveEditUser(st)
    local eu = st.editUser
    if not eu.name or eu.name == "" then
        st.editError = "Name required"; return false
    end
    if #st.editPass > 0 then
        if st.editPass ~= st.editConfirm then
            st.editError = "Passwords differ"; st.editConfirm = ""; return false
        end
    end
    local db = st.Users.load()
    if st.mode == "new" then
        local newId = string.lower(eu.name):gsub("[^%w]", "_")
        if st.Users.find(newId) then
            st.editError = "User exists"; return false
        end
        st.Users.create(db, newId, eu.name, st.editPass ~= "" and st.editPass or "1", eu.isAdmin)
        for _, u in ipairs(db.users) do
            if u.id == newId then
                u.lockTimeout = eu.lockTimeout or 600
                u.permissions = eu.permissions or {editFiles=false, deleteFiles=false, installApps=false}
                break
            end
        end
    else
        for _, u in ipairs(db.users) do
            if u.id == eu.id then
                u.name        = eu.name
                u.isAdmin     = eu.isAdmin
                u.lockTimeout = eu.lockTimeout or 600
                u.permissions = eu.permissions or {editFiles=false, deleteFiles=false, installApps=false}
                if #st.editPass > 0 then
                    u.passHash = st.Users.hashPassword(st.editPass)
                end
                break
            end
        end
    end
    st.Users.save(db)
    st.status = "Saved: " .. eu.name
    return true
end

-- ── Perms экран ──────────────────────────────────────────────────────────────

-- Сканируем /os/apps и парсим метаданные каждого приложения. Скрытые
-- (hidden=true) пропускаем — их не видит ни пользователь, ни этот экран.
-- Это только ЛОКАЛЬНЫЕ приложения: системные + установленные на этой машине
-- user-приложения. Полный список достраивается каталогом App Store (mergeCatalog).
local function collectLocalApps()
    local apps = {}
    local dir = "/os/apps"
    if not fs.exists(dir) then return apps end
    for _, fname in ipairs(fs.list(dir)) do
        if string.sub(fname, -4) == ".lua" then
            local id  = string.sub(fname, 1, -5)
            local def = readAppMeta(dir .. "/" .. fname)
            -- Скрытые и adminOnly-приложения (Terminal) в perms не показываем:
            -- adminOnly доступно только администратору и не выдаётся через права.
            if not (def and (def.hidden == true or def.adminOnly == true)) then
                table.insert(apps, {
                    id       = id,
                    name     = (def and def.name) or id,
                    category = appCategory(def, id),
                })
            end
        end
    end
    return apps
end

-- Объединяем локальные приложения с каталогом App Store, чтобы в perms были видны
-- ВСЕ приложения (включая те, что не установлены на этом компьютере). Иначе при
-- переходе «All apps → явный whitelist» приложения, которых нет на диске, молча
-- блокировались бы для пользователя на всех компьютерах.
local function mergeCatalog(localApps, catalog)
    local byId = {}
    local out  = {}
    for _, app in ipairs(localApps or {}) do
        if app.id and not byId[app.id] then
            byId[app.id] = true
            table.insert(out, app)
        end
    end
    for _, entry in ipairs(catalog or {}) do
        if entry and entry.id and not byId[entry.id]
           and not (entry.hidden == true or entry.adminOnly == true) then
            byId[entry.id] = true
            table.insert(out, {
                id       = entry.id,
                name     = entry.name or entry.id,
                category = appCategory(entry, entry.id),
            })
        end
    end
    table.sort(out, function(a, b) return (a.name or a.id) < (b.name or b.id) end)
    return out
end

-- Собираем список приложений для perms: локальные + (если уже получен) каталог.
local function collectAllApps(st)
    local apps = collectLocalApps()
    if st and st.catalog then apps = mergeCatalog(apps, st.catalog) end
    return apps
end

-- Просим сервер App Store прислать полный каталог (ответ придёт rednet-событием).
local function requestCatalog(st)
    if st.storeComputer and st.ctx and st.ctx.send then
        st.ctx.send(st.storeComputer, {type = "store_request_index"}, st.storeProtocol)
    end
end

-- Состояние категории для пользователя: "all" | "none" | "some".
local function categoryState(st, cat)
    local u = st.permUser
    local total, on = 0, 0
    for _, app in ipairs(st.allApps) do
        if (app.category or "other") == cat then
            total = total + 1
            if u.allowedApps == nil then
                on = on + 1
            else
                for _, a in ipairs(u.allowedApps) do
                    if a == app.id then on = on + 1; break end
                end
            end
        end
    end
    if total == 0 or on == 0 then return "none" end
    if on == total then return "all" end
    return "some"
end

-- Геометрия окна подтверждения очистки прав (общая для draw и обработчика).
local function confirmClearLayout(W, H)
    local top = math.max(2, math.floor(H / 2) - 2)
    return {
        x1 = 2, x2 = W - 1,
        top = top,
        btnY = top + 3,
        yesX1 = 4,     yesX2 = 10,
        noX1  = W - 8, noX2  = W - 3,
    }
end

local function drawPerms(st, win, W, H, theme)
    local hb = theme.headerBg or colors.blue
    local hf = theme.headerFg or colors.white
    local bg = theme.pageBg   or colors.black
    local ac = theme.accentBg or colors.cyan
    local sf = theme.rowFg or colors.white
    local mf = theme.mutedFg  or colors.lightGray

    win.setBackgroundColor(bg); win.clear()
    win.setCursorPos(1, 1); win.setBackgroundColor(hb); win.setTextColor(hf)
    win.write(padR(" PERMS: " .. (st.permUser.name or st.permUser.id), W - 5))
    win.setBackgroundColor(colors.gray); win.setTextColor(colors.white)
    win.write("[Back]")

    win.setCursorPos(1, 2); win.setBackgroundColor(bg); win.setTextColor(mf)
    local allStr = (st.permUser.allowedApps == nil) and "[x]" or "[ ]"
    win.write(allStr .. " All apps")
    -- Кнопка очистки прав (правый край строки).
    win.setCursorPos(W - 6, 2)
    win.setBackgroundColor(colors.red); win.setTextColor(colors.white)
    win.write("[Clear]")

    local allowed = st.permUser.allowedApps  -- nil = all
    local function isAllowed(id)
        if allowed == nil then return true end
        for _, a in ipairs(allowed) do if a == id then return true end end
        return false
    end

    -- Резервируем правую колонку под scrollbar.
    local lw = W - 1
    local rows  = buildPermRows(st.allApps, st.permExpanded)
    local visH  = H - 3
    local first = (st.scroll or 0) + 1
    local last  = math.min(#rows, first + visH - 1)
    local y = 3
    for i = first, last do
        local row = rows[i]
        if row.type == "header" then
            win.setCursorPos(1, y)
            win.setBackgroundColor(theme.sectionBg or colors.gray)
            win.setTextColor(theme.sectionFg or colors.white)
            local arrow = row.expanded and "v" or ">"
            local cstate = categoryState(st, row.cat)
            local box   = (cstate == "all") and "[x]" or (cstate == "some") and "[~]" or "[ ]"
            local count = "(" .. tostring(row.count) .. ")"
            local left  = " " .. arrow .. " " .. box .. " " .. row.text
            win.write(padR(clip(left, lw - #count - 1), lw - #count - 1))
            win.setTextColor(mf)
            win.write(count .. " ")
        else
            local app = row.app
            local checked = isAllowed(app.id)
            win.setCursorPos(1, y); win.setBackgroundColor(bg)
            win.setTextColor(checked and sf or mf)
            local box = checked and "[x]" or "[ ]"
            win.write(padR("   " .. box .. " " .. (app.name or app.id), lw))
        end
        y = y + 1
    end

    -- Scrollbar справа (единица прокрутки — строка списка).
    st.sb:setBounds(W, 3, H - 1)
    st.sb:setContent(visH, #rows)
    st.sb:setScroll(st.scroll or 0)
    st.sb:draw(win)

    win.setCursorPos(1, H); win.setBackgroundColor(bg); win.setTextColor(mf)
    win.write(padR(st.status, lw))

    -- Окно подтверждения очистки прав поверх списка.
    if st.confirmClear then
        local L = confirmClearLayout(W, H)
        for yy = L.top, L.top + 4 do
            win.setCursorPos(L.x1, yy)
            win.setBackgroundColor(colors.gray); win.setTextColor(colors.white)
            win.write(string.rep(" ", L.x2 - L.x1 + 1))
        end
        win.setCursorPos(L.x1 + 1, L.top + 1)
        win.setBackgroundColor(colors.gray); win.setTextColor(colors.white)
        win.write(clip("Clear all permissions?", L.x2 - L.x1 - 1))
        win.setCursorPos(L.yesX1, L.btnY)
        win.setBackgroundColor(colors.red); win.setTextColor(colors.white)
        win.write("[ Yes ]")
        win.setCursorPos(L.noX1, L.btnY)
        win.setBackgroundColor(colors.green); win.setTextColor(colors.white)
        win.write("[ No ]")
    end
end

local function hitPerms(st, x, y, W, H)
    if y == 1 and x >= W - 5 then return "back" end
    if y == 2 then
        if x >= W - 6 then return "clear_perms" end
        return "toggle_all"
    end
    local rows = buildPermRows(st.allApps, st.permExpanded)
    local idx  = (y - 3) + (st.scroll or 0) + 1
    local row  = rows[idx]
    if not row then return nil end
    if row.type == "header" then
        -- Чекбокс категории занимает колонки 4..6 (" v " + "[x]"); остальное — раскрытие.
        if x >= 4 and x <= 6 then return "toggle_cat_perm", row.cat end
        return "toggle_cat", row.cat
    end
    return "toggle_app", row.app.id
end

local function togglePermApp(st, id)
    local u  = st.permUser
    if u.allowedApps == nil then
        -- Был All: переходим к explicit list без этого приложения
        local list = {}
        for _, app in ipairs(st.allApps) do
            if app.id ~= id then table.insert(list, app.id) end
        end
        u.allowedApps = list
    else
        local found = false
        local list  = {}
        for _, a in ipairs(u.allowedApps) do
            if a == id then found = true else table.insert(list, a) end
        end
        if not found then
            table.insert(list, id)
            table.sort(list)
        end
        u.allowedApps = list
    end
    -- Сохраняем
    local db = st.Users.load()
    for _, u2 in ipairs(db.users) do
        if u2.id == u.id then u2.allowedApps = u.allowedApps; break end
    end
    st.Users.save(db)
end

-- Включить/выключить ВСЕ приложения категории целиком.
local function setCategoryAllowed(st, cat, enable)
    local u = st.permUser
    -- Текущее множество разрешённых (nil = все приложения разрешены).
    local allow = {}
    if u.allowedApps == nil then
        for _, app in ipairs(st.allApps) do allow[app.id] = true end
    else
        for _, a in ipairs(u.allowedApps) do allow[a] = true end
    end
    for _, app in ipairs(st.allApps) do
        if (app.category or "other") == cat then
            allow[app.id] = enable and true or nil
        end
    end
    -- Пересобираем отсортированный список id из allow-set, а НЕ из st.allApps:
    -- иначе разрешённые приложения, которых сейчас нет в st.allApps (каталог
    -- App Store ещё не пришёл по rednet или приложение установлено на другом
    -- устройстве), молча выпадали бы из whitelist и исчезали у пользователя из
    -- «Пуска» (хотя в Apps числятся установленными).
    local list = {}
    for id in pairs(allow) do table.insert(list, id) end
    table.sort(list)
    u.allowedApps = list
    -- Сохраняем
    local db = st.Users.load()
    for _, u2 in ipairs(db.users) do
        if u2.id == u.id then u2.allowedApps = u.allowedApps; break end
    end
    st.Users.save(db)
end

-- ── draw ─────────────────────────────────────────────────────────────────────

local Shell = nil
local function getShell()
    if not Shell then Shell = dofile("/os/lib/pocketos/shell.lua") end
    return Shell
end

function M.draw(st, win)
    if st.denied then
        win.setBackgroundColor(colors.black); win.clear()
        win.setCursorPos(1, 1); win.setTextColor(colors.red)
        win.write("Access denied")
        return
    end
    local W, H = win.getSize()
    local theme = getShell().getTheme(st.ctx.desktop.themeIndex)
    if st.mode == "list" then
        drawList(st, win, W, H, theme)
    elseif st.mode == "edit" or st.mode == "new" then
        drawEdit(st, win, W, H, theme)
    elseif st.mode == "perms" then
        drawPerms(st, win, W, H, theme)
    end
end

-- ── onEvent ──────────────────────────────────────────────────────────────────

function M.onEvent(st, event, p1, p2, p3)
    if st.denied then return st, false end

    local W, H = st.win.getSize()

    -- Ответ App Store с полным каталогом приложений.
    if event == "rednet_message" then
        local msg = p2
        if type(msg) == "table" and msg.type == "store_index"
           and st.storeComputer ~= nil and p1 == st.storeComputer
           and p3 == st.storeProtocol then
            st.catalog = msg.apps or {}
            if st.mode == "perms" then
                st.allApps = mergeCatalog(st.allApps, st.catalog)
                st.status  = (#st.allApps) .. " apps (incl. store)"
                return st, true
            end
        end
        return st, false
    end

    if event == "mouse_click" or event == "monitor_touch" then
        local x, y = p2, p3

        if st.mode == "list" then
            if st.sb:onClick(x, y) then st.scroll = st.sb.scroll; return st, true end
            local action, u = hitList(st, x, y, W, H)
            if action == "new" then
                st.editUser    = {id="", name="", isAdmin=false, lockTimeout=600,
                                   permissions={editFiles=false,deleteFiles=false,installApps=false}}
                st.editPass    = ""
                st.editConfirm = ""
                st.editError   = ""
                st.editField   = "name"
                st.mode        = "new"
            elseif action == "edit" and u then
                local up = u.permissions or {}
                st.editUser = {id=u.id, name=u.name, isAdmin=u.isAdmin,
                               lockTimeout=u.lockTimeout or 600,
                               permissions={
                                   editFiles   = up.editFiles   == true,
                                   deleteFiles = up.deleteFiles == true,
                                   installApps = up.installApps == true,
                               }}
                st.editPass    = ""
                st.editConfirm = ""
                st.editError   = ""
                st.editField   = "name"
                st.mode        = "edit"
            elseif action == "perms" and u then
                st.permUser = {id=u.id, name=u.name, allowedApps=u.allowedApps}
                st.prevAllowed = nil  -- бэкап выбора перед нажатием "All apps"
                st.confirmClear = false
                st.allApps  = collectAllApps(st)
                st.permExpanded = {automation=true, network=true, games=true,
                                   system=true, other=true}
                st.scroll   = 0
                st.mode     = "perms"
                st.status   = "Loading store catalog..."
                requestCatalog(st)
            elseif action == "del" and u then
                if u.id == (st.ctx.currentUser and st.ctx.currentUser.id) then
                    st.status = "Cannot delete yourself"
                else
                    local db = st.Users.load()
                    st.Users.delete(db, u.id)
                    st.Users.save(db)
                    st.status = "Deleted: " .. (u.name or u.id)
                end
            end
            return st, true

        elseif st.mode == "edit" or st.mode == "new" then
            -- Back
            if y == 1 and x >= W - 5 then st.mode = "list"; return st, true end
            -- Admin toggle
            if y == 4 then
                st.editUser.isAdmin = not st.editUser.isAdmin; return st, true
            end
            -- Lock cycle
            if y == 5 then
                local eu = st.editUser
                if x >= 7 then
                    local dir = (x < 7 + 2) and -1 or 1
                    eu.lockTimeout = lockTimeoutCycle(eu.lockTimeout, dir)
                end
                return st, true
            end
            -- Permissions toggles (строки 6,7,8 — только для не-admin)
            if not st.editUser.isAdmin then
                local p = st.editUser.permissions
                if not p then p = {}; st.editUser.permissions = p end
                if y == 6 then p.editFiles   = not p.editFiles;   return st, true end
                if y == 7 then p.deleteFiles = not p.deleteFiles; return st, true end
                if y == 8 then p.installApps = not p.installApps; return st, true end
            end
            -- Field select
            if y == 3 then st.editField = "name"; return st, true end

            -- Вычисляем позицию клавиатуры так же как в drawEdit
            local kx = math.floor((W - 11) / 2) + 1
            local ky
            do
                local _y = 6  -- после строк name(3)+admin(4)+lock(5)
                if not st.editUser.isAdmin then _y = _y + 3 end  -- permissions
                _y = _y + 1   -- password
                if #st.editPass > 0 then _y = _y + 1 end        -- confirm
                if st.editError ~= "" then _y = _y + 1 end      -- error
                ky = _y
            end
            local kAction, kData = keypadHit(x, y, kx, ky)

            if kAction then
                editPasswordAction(st, kAction, kData)
                return st, true
            end

            -- Save button всегда в строке H
            if y == H then
                if saveEditUser(st) then st.mode = "list" end
                return st, true
            end
            return st, true

        elseif st.mode == "perms" then
            -- Окно подтверждения очистки прав перехватывает клики.
            if st.confirmClear then
                local L = confirmClearLayout(W, H)
                if y == L.btnY and x >= L.yesX1 and x <= L.yesX2 then
                    local u2 = st.permUser
                    st.prevAllowed = {}
                    u2.allowedApps = {}
                    local db = st.Users.load()
                    for _, uu in ipairs(db.users) do
                        if uu.id == u2.id then uu.allowedApps = u2.allowedApps; break end
                    end
                    st.Users.save(db)
                    st.status = "Permissions cleared"
                end
                st.confirmClear = false
                return st, true
            end
            if st.sb:onClick(x, y) then st.scroll = st.sb.scroll; return st, true end
            local action, data = hitPerms(st, x, y, W, H)
            if action == "back" then
                st.mode   = "list"
                st.status = ""
                st.scroll = 0
            elseif action == "toggle_all" then
                local u2 = st.permUser
                if u2.allowedApps == nil then
                    -- Был ALL → выключаем: возвращаем выбор, что был до включения.
                    u2.allowedApps = st.prevAllowed or {}
                    st.status = "Restored previous selection"
                else
                    -- Включаем ALL → запоминаем текущий явный выбор.
                    st.prevAllowed = u2.allowedApps
                    u2.allowedApps = nil
                    st.status = "All apps allowed"
                end
                local db = st.Users.load()
                for _, uu in ipairs(db.users) do
                    if uu.id == u2.id then uu.allowedApps = u2.allowedApps; break end
                end
                st.Users.save(db)
            elseif action == "clear_perms" then
                -- Сначала спрашиваем подтверждение (окно рисует drawPerms).
                st.confirmClear = true
            elseif action == "toggle_cat" and data then
                st.permExpanded[data] = not st.permExpanded[data]
                st.scroll = 0
            elseif action == "toggle_cat_perm" and data then
                local enable = categoryState(st, data) ~= "all"
                setCategoryAllowed(st, data, enable)
                st.status = (CATEGORY_LABEL[data] or data) .. (enable and ": all on" or ": all off")
            elseif action == "toggle_app" and data then
                togglePermApp(st, data)
                st.status = "Saved"
            end
            return st, true
        end
    end

    -- Char: ввод имени в режиме new/edit (поле name)
    if (event == "char") and (st.mode == "edit" or st.mode == "new") then
        if st.editField == "name" then
            st.editUser.name = (st.editUser.name or "") .. p1
            st.editError = ""
            return st, true
        elseif (st.editField == "pass" or st.editField == "confirm") and isDigitChar(p1) then
            editPasswordAction(st, "digit", p1)
            return st, true
        end
    end
    if (event == "key") and (st.mode == "edit" or st.mode == "new") then
        if p1 == keys.backspace then
            if st.editField == "name" and #(st.editUser.name or "") > 0 then
                st.editUser.name = string.sub(st.editUser.name, 1, -2)
                st.editError = ""
                return st, true
            elseif st.editField == "pass" or st.editField == "confirm" then
                editPasswordAction(st, "backspace")
                return st, true
            end
        elseif isEnterKey(p1) then
            editPasswordAction(st, "ok")
            return st, true
        end
    end

    -- Колесо и drag thumb-а скроллбара (list и perms используют общий st.sb,
    -- его границы/контент заданы в draw).
    if (st.mode == "list" or st.mode == "perms") then
        if event == "mouse_scroll" then
            st.sb:scrollBy(p1)
            st.scroll = st.sb.scroll
            return st, true
        end
        if event == "mouse_drag" then
            if st.sb:onDrag(p2, p3) then
                st.scroll = st.sb.scroll
                return st, true
            end
        end
    end

    return st, false
end

return M
