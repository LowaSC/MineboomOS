-- Стенд для обновления и установки MineboomOS без Minecraft.
--
-- Поднимает виртуальную ФС с API CC:Tweaked (fs.*), мок http/term/os, кладёт
-- в неё ОС версии v1 из этого репозитория и «публикует» v2. Затем гоняет
-- обновление и установку, обрывая их на каждой файловой операции подряд
-- (как выключение питания), «перезагружает» машину через /startup.lua и
-- проверяет, что /os целиком либо v1, либо v2, а хвостов транзакции нет.
--
-- Запуск: python3 tests/run.py   (нужен пакет lupa с Lua 5.1)

local REPO = os.getenv("MINEBOOM_REPO") or "."
io.stdout:setvbuf("no")
local VERBOSE = os.getenv("MINEBOOM_VERBOSE")
local function stamp() return string.format("[%7.2f] ", os.clock()) end

-- ── Чтение исходников с диска ────────────────────────────────────────────────

local function slurp(path)
    local f = assert(io.open(path, "rb"), "cannot read " .. path)
    local data = f:read("*a")
    f:close()
    return data
end

-- ── Виртуальная ФС ───────────────────────────────────────────────────────────

local vfs = {files = {}, dirs = {}}
local fault = {remaining = math.huge, fired = false}
local POWER_LOSS = "SIMULATED POWER LOSS"

local function norm(p)
    p = tostring(p or "")
    p = p:gsub("\\", "/"):gsub("/+", "/"):gsub("^/", ""):gsub("/$", "")
    if p == "." then p = "" end
    return p
end

local function parentOf(p)
    return (p:match("^(.*)/[^/]+$")) or ""
end

local function tick()
    if fault.remaining == math.huge then return false end
    fault.remaining = fault.remaining - 1
    if fault.remaining <= 0 then
        fault.fired = true
        return true
    end
    return false
end

local function mkdirs(p)
    if p == "" then return end
    if vfs.dirs[p] then return end
    mkdirs(parentOf(p))
    vfs.dirs[p] = true
end

local function children(p)
    local out = {}
    local prefix = (p == "") and "" or (p .. "/")
    for path in pairs(vfs.files) do
        if path:sub(1, #prefix) == prefix then out[#out + 1] = path end
    end
    for path in pairs(vfs.dirs) do
        if path:sub(1, #prefix) == prefix then out[#out + 1] = path end
    end
    table.sort(out)
    return out
end

local fs = {}
function fs.exists(p) p = norm(p); return p == "" or vfs.files[p] ~= nil or vfs.dirs[p] == true end
function fs.isDir(p) p = norm(p); return p == "" or vfs.dirs[p] == true end
function fs.getDir(p)
    p = norm(p)
    if p == "" then return ".." end
    return parentOf(p)
end
function fs.combine(a, b) return norm(norm(a) .. "/" .. norm(b)) end
function fs.getName(p) p = norm(p); return p:match("([^/]+)$") or "" end
function fs.makeDir(p)
    p = norm(p)
    if vfs.dirs[p] then return end
    if vfs.files[p] then error("/" .. p .. ": File exists") end
    if tick() then error(POWER_LOSS) end
    mkdirs(p)
end
function fs.delete(p)
    p = norm(p)
    if p == "" then error("cannot delete root") end
    if not fs.exists(p) then return end
    if tick() then
        -- питание пропало на середине рекурсивного удаления
        local list = children(p)
        for i = 1, math.floor(#list / 2) do
            vfs.files[list[i]] = nil; vfs.dirs[list[i]] = nil
        end
        error(POWER_LOSS)
    end
    for _, c in ipairs(children(p)) do vfs.files[c] = nil; vfs.dirs[c] = nil end
    vfs.files[p] = nil; vfs.dirs[p] = nil
end
function fs.move(src, dst)
    src, dst = norm(src), norm(dst)
    if not fs.exists(src) then error("/" .. src .. ": No such file") end
    if fs.exists(dst) then error("/" .. dst .. ": File exists") end
    if tick() then error(POWER_LOSS) end
    mkdirs(parentOf(dst))
    if vfs.files[src] then
        vfs.files[dst] = vfs.files[src]; vfs.files[src] = nil
        return
    end
    for _, c in ipairs(children(src)) do
        local rel = c:sub(#src + 2)
        if vfs.files[c] then vfs.files[dst .. "/" .. rel] = vfs.files[c]; vfs.files[c] = nil
        else vfs.dirs[dst .. "/" .. rel] = true; vfs.dirs[c] = nil end
    end
    vfs.dirs[src] = nil
    vfs.dirs[dst] = true
end
function fs.open(p, mode)
    p = norm(p)
    if mode == "r" or mode == "rb" then
        local data = vfs.files[p]
        if data == nil then return nil, "/" .. p .. ": No such file" end
        local pos = 1
        return {
            readAll = function() local rest = data:sub(pos); pos = #data + 1; return rest end,
            readLine = function()
                if pos > #data then return nil end
                local nl = data:find("\n", pos, true)
                local line
                if nl then line = data:sub(pos, nl - 1); pos = nl + 1
                else line = data:sub(pos); pos = #data + 1 end
                return line
            end,
            close = function() end,
        }
    elseif mode == "w" or mode == "wb" then
        if vfs.dirs[p] then return nil, "/" .. p .. ": Is a directory" end
        local buf = {}
        return {
            write = function(s) buf[#buf + 1] = tostring(s) end,
            writeLine = function(s) buf[#buf + 1] = tostring(s) .. "\n" end,
            close = function()
                local data = table.concat(buf)
                mkdirs(parentOf(p))
                if tick() then
                    vfs.files[p] = data:sub(1, math.floor(#data / 2)) -- недописанный файл
                    error(POWER_LOSS)
                end
                vfs.files[p] = data
            end,
        }
    end
    error("unsupported mode " .. tostring(mode))
end
function fs.list(p)
    p = norm(p)
    local out, seen = {}, {}
    for _, c in ipairs(children(p)) do
        local rel = (p == "") and c or c:sub(#p + 2)
        local first = rel:match("^([^/]+)")
        if first and not seen[first] then seen[first] = true; out[#out + 1] = first end
    end
    return out
end
function fs.getFreeSpace() return 10 * 1024 * 1024 end
function fs.getSize(p) p = norm(p); return vfs.files[p] and #vfs.files[p] or 0 end
function fs.isReadOnly(p) return norm(p):sub(1, 3) == "rom" end

local function read(p) return vfs.files[norm(p)] end
local function put(p, data) mkdirs(parentOf(norm(p))); vfs.files[norm(p)] = data end

-- ── Остальные глобалы CC ─────────────────────────────────────────────────────

local function serialize(value)
    local t = type(value)
    if t == "string" then return string.format("%q", value) end
    if t == "number" or t == "boolean" then return tostring(value) end
    if t == "table" then
        local parts = {}
        for _, item in ipairs(value) do parts[#parts + 1] = serialize(item) end
        for key, item in pairs(value) do
            if type(key) == "string" then parts[#parts + 1] = "[" .. string.format("%q", key) .. "]=" .. serialize(item) end
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "nil"
end

local remote = {} -- url -> content
local http = {}
function http.get(req)
    local url = type(req) == "table" and req.url or req
    local data = remote[url]
    if not data then return nil, "404 " .. tostring(url) end
    return {readAll = function() return data end, close = function() end}
end
function http.checkURL() return true end

local output = {}
local env = {}
local function G(name, value) env[name] = value end
G("fs", fs); G("http", http)
G("textutils", {
    serialize = serialize, serialise = serialize,
    unserialize = function(s) local fn = loadstring("return " .. s); return fn and fn() end,
})
G("os", {
    epoch = function() return 1700000000000 end, clock = os.clock, time = os.time, date = os.date,
    getComputerID = function() return 7 end, getComputerLabel = function() return "test" end,
    startTimer = function() return 1 end,
    -- Без фильтра: Ctrl, чтобы boot ушёл в safe mode после recovery.
    -- С фильтром "key" (так ждёт panic): Q, чтобы panic вернулся, а не завис.
    pullEvent = function(filter) if filter == "key" then return "key", 16 end return "key", 29 end,
    reboot = function() error("REBOOT") end,
    queueEvent = function() end,
    getenv = os.getenv,
})
G("term", setmetatable({getSize = function() return 51, 19 end, isColor = function() return true end},
    {__index = function() return function() end end}))
G("colors", setmetatable({}, {__index = function() return 1 end}))
G("keys", {leftCtrl = 29, rightCtrl = 157, r = 19, s = 31, q = 16, n = 49, d = 32, x = 45, y = 21,
    enter = 28, escape = 1, backspace = 14, up = 200, down = 208, delete = 211, f5 = 63, f9 = 67})
G("print", function(...) local parts = {} for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end output[#output + 1] = table.concat(parts, "\t") end)
G("write", function(s) output[#output + 1] = tostring(s) end)
G("read", function() return "" end)
G("sleep", function() end)
G("shell", {run = function(path) return env.dofile(path) end})
G("_VERSION", _VERSION)
for _, name in ipairs({"ipairs", "pairs", "next", "select", "tonumber", "tostring", "type", "unpack",
    "pcall", "xpcall", "error", "assert", "setmetatable", "getmetatable", "rawget", "rawset",
    "loadstring", "setfenv", "getfenv", "string", "table", "math", "debug"}) do
    env[name] = _G[name]
end
env._G = env
local function loadIn(source, name)
    local fn, err = loadstring(source, name)
    if not fn then return nil, err end
    setfenv(fn, env)
    return fn
end
G("loadfile", function(path)
    local data = read(path)
    if not data then return nil, "/" .. norm(path) .. ": No such file" end
    return loadIn(data, "=" .. norm(path))
end)
G("dofile", function(path, ...)
    local fn, err = env.loadfile(path)
    if not fn then error(err, 2) end
    return fn(...)
end)
G("load", function(chunk, name, mode, e)
    local fn, err = loadstring(chunk, name)
    if fn then setfenv(fn, e or env) end
    return fn, err
end)

-- ── Версии ОС ────────────────────────────────────────────────────────────────

local manifestSrc = slurp(REPO .. "/os/manifest.lua")
local manifestFn = assert(loadstring(manifestSrc))
setfenv(manifestFn, {ipairs = ipairs, pairs = pairs, string = string, table = table})
local manifest = manifestFn()
local ROLE = "pocketos"

local function filesFor(mf, role)
    local out, seen = {}, {}
    local function append(list) for _, p in ipairs(list or {}) do if not seen[p] then seen[p] = true; out[#out + 1] = p end end end
    append(mf.core); append(mf.roles[role])
    return out
end

local v1, v2 = {}, {}
local V2_VERSION = "2026.09.12-dev.99"
for i, path in ipairs(filesFor(manifest, ROLE)) do
    local src = slurp(REPO .. path)
    if path == "/os/manifest.lua" then
        v1[path] = src
        v2[path] = (src:gsub('version = "[^"]+"', 'version = "' .. V2_VERSION .. '"'))
        v2[path] = v2[path]:gsub('"/os/lib/log.lua",', '"/os/lib/log.lua",\n    "/os/lib/newlib.lua",')
        assert(v2[path]:find("newlib"), "manifest v2 must list newlib")
    elseif path:match("%.lua$") and i % 2 == 0 then
        v1[path] = src
        v2[path] = src .. "\n-- release v2\n"
    elseif path:match("%.md$") then
        v1[path] = src .. "\nv1\n"
        v2[path] = src .. "\nv2\n"
    else
        v1[path] = src; v2[path] = src
    end
end
v2["/os/lib/newlib.lua"] = "return {version = 2}\n"

local BASE = "https://example.test/os"
local function publish(version)
    remote = {}
    for path, data in pairs(version) do
        remote[BASE .. "/" .. path:gsub("^/os/", "")] = data
    end
end

local OLD_STARTUP = 'local boot = "/os/boot.lua"\n\nif fs.exists(boot) then\n    shell.run(boot)\nelse\n    print("MineboomOS is not installed. Run installer again.")\nend\n'

local function installV1(withOldStartup)
    vfs.files, vfs.dirs = {}, {}
    for path, data in pairs(v1) do put(path, data) end
    put("/.mineboom_source", BASE)
    put("/.mineboom_role", ROLE)
    put("/data/system/device.db", serialize({schemaVersion = 1, setupComplete = true,
        computer = {role = ROLE, label = "Test", apps = {}, pocketos = {}}}))
    put("/data/keep.txt", "user data")
    put("/os/apps/snake.lua", "-- user app from the store\n")
    if withOldStartup then put("/startup.lua", OLD_STARTUP)
    else env.dofile("/os/lib/ostx.lua").ensureStartup() end
end

-- ── Проверки ─────────────────────────────────────────────────────────────────

local failures = 0
local function fail(msg) failures = failures + 1; print("FAIL: " .. msg) end
local function check(cond, msg) if not cond then fail(msg) end return cond end

local function whichVersion(label)
    local allV1, allV2 = true, true
    for path, data in pairs(v1) do if read(path) ~= data then allV1 = false end end
    for path, data in pairs(v2) do if read(path) ~= data then allV2 = false end end
    if v2["/os/lib/newlib.lua"] and read("/os/lib/newlib.lua") then allV1 = false end
    if allV1 then return "v1" end
    if allV2 then return "v2" end
    local mixed = {}
    for path in pairs(v2) do
        local d = read(path)
        mixed[#mixed + 1] = path .. "=" .. (d == nil and "missing" or d == v1[path] and "v1" or d == v2[path] and "v2" or "garbage")
    end
    fail(label .. ": /os is a mix of versions: " .. table.concat(mixed, ", "))
    return "mixed"
end

local function checkClean(label, allowOrphans)
    local must = {"/.os_journal", "/.os_journal.done", "/.os_bak"}
    if not allowOrphans then
        for _, p in ipairs({"/.os_recover.lua", "/.os_tmp", "/.os_install"}) do must[#must + 1] = p end
    end
    for _, p in ipairs(must) do
        check(not fs.exists(p), label .. ": leftover " .. p)
    end
    check(read("/data/keep.txt") == "user data", label .. ": user data lost")
    check(read("/os/apps/snake.lua") ~= nil, label .. ": store app lost")
end

-- Перезагрузка. Если /startup.lua исчез (единственное окно: первая миграция со
-- старого startup, между двумя fs.move), CraftOS остаётся в shell и человек
-- запускает /os/boot.lua руками — boot восстанавливает startup.lua сам.
local manualBoots = 0
local function reboot(label)
    fault.remaining = math.huge
    output = {}
    local entry = "/startup.lua"
    if not fs.exists(entry) then
        manualBoots = manualBoots + 1
        entry = "/os/boot.lua"
    end
    local ok, err = pcall(env.dofile, entry)
    check(ok, label .. ": " .. entry .. " crashed: " .. tostring(err) .. "\n" .. table.concat(output, "\n"))
    check(fs.exists("/startup.lua"), label .. ": startup.lua missing after boot")
    local log = table.concat(output, "\n")
    check(not log:find("MineboomOS boot failed"), label .. ": boot panicked:\n" .. log)
    return log
end

-- ── Сценарии ─────────────────────────────────────────────────────────────────

local function runUpdate()
    local Updater = env.dofile("/os/lib/updater.lua")
    local remoteManifest = assert(Updater.fetchManifest(BASE))
    return Updater.updateFromHttp(BASE, remoteManifest, nil, ROLE)
end

local function faultSweep(label, action, withOldStartup, expectFinal)
    publish(v2)
    local n, completed = 0, false
    while not completed do
        n = n + 1
        if VERBOSE then io.stderr:write(stamp() .. label .. " n=" .. n .. " install\n") end
        installV1(withOldStartup)
        if VERBOSE then io.stderr:write(stamp() .. label .. " n=" .. n .. " run\n") end
        fault.remaining, fault.fired = n, false
        local ok, res, msg = pcall(action)
        local tag = label .. " fault#" .. n
        if VERBOSE then io.stderr:write(stamp() .. tag .. " fired=" .. tostring(fault.fired) .. "\n") end
        if fault.fired then
            -- Сбой на необязательной уборке (под pcall) может завершиться успехом;
            -- тогда и без перезагрузки на диске обязан лежать полный v2.
            local claimedSuccess = ok and res ~= false and res ~= nil
            if claimedSuccess then
                check(whichVersion(tag .. " claimed success") == "v2", tag .. ": reported success without complete v2: " .. tostring(msg))
            end
            if VERBOSE then io.stderr:write(stamp() .. tag .. " reboot\n") end
            local log = reboot(tag)
            if VERBOSE then io.stderr:write(stamp() .. tag .. " check\n") end
            local ver = whichVersion(tag .. " after reboot")
            if claimedSuccess then check(ver == "v2", tag .. ": reported success but rebooted into " .. ver) end
            checkClean(tag .. " after reboot", true)
            if ver == "v2" then
                check(read("/startup.lua") == env.dofile("/os/lib/ostx.lua").STARTUP_SOURCE, tag .. ": startup.lua not refreshed")
            end
            -- второй запуск без сбоев должен довести до v2
            fault.remaining = math.huge
            if VERBOSE then io.stderr:write(stamp() .. tag .. " retry\n") end
            local ok2, res2, msg2 = pcall(action)
            if VERBOSE then io.stderr:write(stamp() .. tag .. " retry done\n") end
            check(ok2 and res2 ~= false, tag .. ": retry failed: " .. tostring(ok2 and msg2 or res2))
            reboot(tag .. " retry")
            check(whichVersion(tag .. " after retry") == "v2", tag .. ": retry did not reach v2")
            checkClean(tag .. " after retry")
        else
            completed = true
            check(ok and res ~= false, tag .. ": clean run failed: " .. tostring(ok and msg or res))
            reboot(tag)
            check(whichVersion(tag .. " clean") == expectFinal, tag .. ": clean run did not reach " .. expectFinal)
            checkClean(tag .. " clean")
        end
    end
    print(string.format("%-28s %3d interruption points, all recovered", label, n - 1))
end

-- 1. OTA-обновление, машина уже с новым startup.lua
faultSweep("update (new startup)", runUpdate, false, "v2")
-- 2. OTA-обновление, машина со старым startup.lua (до dev.46)
faultSweep("update (old startup)", runUpdate, true, "v2")

-- 3. Переустановка через install.lua поверх v1
local function runInstall()
    local src = slurp(REPO .. "/install.lua")
    local fn = assert(loadIn(src, "=install.lua"))
    local ok, err = pcall(fn, BASE, ROLE)
    if not ok and tostring(err):find("REBOOT") then return true, "rebooted" end
    if not ok then error(err, 0) end
    -- установщик вернулся без reboot: значит, напечатал ошибку
    return false, table.concat(output, "\n")
end
faultSweep("install.lua over v1", runInstall, true, "v2")

-- 4. Битый staged-файл отклоняет всё обновление до того, как тронут /os
do
    installV1(false)
    local broken = {}
    for k, v in pairs(v2) do broken[k] = v end
    broken["/os/lib/clock.lua"] = "this is not lua ("
    publish(broken)
    fault.remaining = math.huge
    local ok, msg = runUpdate()
    check(ok == false and tostring(msg):find("syntax error"), "syntax check: expected rejection, got " .. tostring(msg))
    check(whichVersion("syntax check") == "v1", "syntax check: /os was touched")
    checkClean("syntax check")
    print("syntax check                 rejected before touching /os")
end

-- 5. Потеря staged-файла после записи журнала -> откат к v1
do
    installV1(false)
    publish(v2)
    fault.remaining = math.huge
    local Tx = env.dofile("/os/lib/ostx.lua")
    local realCommit = Tx.commit
    -- эмулируем: журнал записан, staging повреждён, затем питание пропало
    local Updater = env.dofile("/os/lib/updater.lua")
    local remoteManifest = assert(Updater.fetchManifest(BASE))
    -- стадируем вручную через updater с отказом сразу после журнала
    local count = 0
    local origMove = fs.move
    fs.move = function(src, dst)
        if fs.exists("/.os_journal") then
            count = count + 1
            if count == 3 then
                -- прошло две подмены; теперь теряем staged-файл другого и падаем
                for path in pairs(vfs.files) do
                    if path:match("^%.os_tmp/") and not path:match("ostx") then vfs.files[path] = nil break end
                end
                error(POWER_LOSS)
            end
        end
        return origMove(src, dst)
    end
    local ok, res, msg = pcall(Updater.updateFromHttp, BASE, remoteManifest, nil, ROLE)
    fs.move = origMove
    -- Ошибка fs.move ловится внутри Tx, updater сам зовёт Tx.recover() и
    -- откатывает; если бы питание пропало по-настоящему, откат сделал бы startup.
    local rolledBack = ok and res == false and tostring(msg):find("rolled back") ~= nil
    local log = reboot("rollback")
    rolledBack = rolledBack or log:find("rollback") ~= nil
    check(rolledBack, "rollback: neither updater nor startup reported a rollback: " .. tostring(msg) .. "\n" .. log)
    check(whichVersion("rollback") == "v1", "rollback: expected v1 after lost staged file")
    checkClean("rollback")
    print("lost staged file             rolled back to v1")
end

-- 6. FsUtil.atomicWrite: обрыв на каждом шаге, readFile отдаёт старое или новое
do
    installV1(false)
    fault.remaining = math.huge
    local FsUtil = env.dofile("/os/lib/fsutil.lua")
    local n, done = 0, false
    while not done do
        n = n + 1
        put("/data/db.txt", "OLD")
        for _, p in ipairs({"/data/db.txt.tmp", "/data/db.txt.old"}) do vfs.files[norm(p)] = nil end
        fault.remaining, fault.fired = n, false
        local ok = pcall(FsUtil.atomicWrite, "/data/db.txt", "NEW")
        fault.remaining = math.huge
        local got = FsUtil.readFile("/data/db.txt")
        check(got == "OLD" or got == "NEW", "atomicWrite fault#" .. n .. ": readFile returned " .. tostring(got))
        if not fault.fired then done = true; check(ok and got == "NEW", "atomicWrite clean run failed") end
    end
    print(string.format("%-28s %3d interruption points, all readable", "FsUtil.atomicWrite", n - 1))
end

-- 7. Уже актуальная ОС: обновление ничего не трогает и не оставляет хвостов
do
    installV1(false)
    publish(v1)
    fault.remaining = math.huge
    local ok, msg = runUpdate()
    check(ok and msg == "already up to date", "no-op update: " .. tostring(msg))
    check(whichVersion("no-op") == "v1", "no-op update changed files")
    checkClean("no-op")
    print("up-to-date OS                no-op")
end

-- 8. Files: обычный пользователь заперт в своей папке, системные пути защищены
do
    installV1(false)
    fault.remaining = math.huge
    put("/data/users/bob/notes.txt", "hi")
    put("/data/users/alice/secret.txt", "x")
    put("/data/users.db", "db")
    local Files = env.dofile("/os/apps/files.lua")
    local win = {
        getSize = function() return 26, 20 end,
        setCursorPos = function() end, write = function() end, clear = function() end,
        setTextColor = function() end, setBackgroundColor = function() end,
    }
    local function press(st, key) Files.onEvent(st, "key", env.keys[key]) end
    local function typeName(st, value) st.promptValue = value; press(st, "enter") end
    local function selectPath(st, path)
        for i, e in ipairs(st.entries) do if e.path == path then st.selected = i; return true end end
        return false
    end
    local function drawOk(st, label)
        local ok, err = pcall(Files.draw, st, win)
        check(ok, label .. ": draw crashed: " .. tostring(err))
    end

    -- обычный пользователь
    local bob = {currentUser = {id = "bob", name = "Bob", isAdmin = false,
        permissions = {editFiles = true, deleteFiles = true}}, dataRoot = "/data/users/bob"}
    local st = Files.init(win, bob)
    check(st.path == "/data/users/bob", "files: user does not start in own folder: " .. tostring(st.path))
    check(not st.entries[1] or not st.entries[1].up, "files: '..' shown at user root")
    drawOk(st, "files user")
    press(st, "backspace")
    check(st.path == "/data/users/bob", "files: Backspace left the user root")
    Files.onEvent(st, "mouse_click", 1, 1, 2) -- клик по месту кнопки Up (её нет)
    check(st.path == "/data/users/bob", "files: click left the user root")

    press(st, "n"); typeName(st, "../evil.txt")
    check(not fs.exists("/data/users/evil.txt") and st.statusLevel == "error", "files: created file above root via ..")
    press(st, "n"); typeName(st, "/os/hack.lua")
    check(not fs.exists("/os/hack.lua") and st.statusLevel == "error", "files: created file via absolute name")
    press(st, "d"); typeName(st, "../../pwn")
    check(not fs.exists("/data/pwn") and not fs.exists("/pwn"), "files: created folder above root")
    press(st, "n"); typeName(st, "todo.txt")
    check(fs.exists("/data/users/bob/todo.txt"), "files: cannot create file in own folder")

    check(selectPath(st, "/data/users/bob/notes.txt"), "files: notes.txt not listed")
    press(st, "r"); typeName(st, "../../notes.txt")
    check(fs.exists("/data/users/bob/notes.txt") and not fs.exists("/data/notes.txt"), "files: rename escaped root")
    press(st, "x"); press(st, "y")
    check(not fs.exists("/data/users/bob/notes.txt"), "files: cannot delete own file")

    -- подсунутый путь в состоянии: readDir возвращает в корень
    st.path = "/data/users/alice"; press(st, "f5")
    check(st.path == "/data/users/bob", "files: readDir accepted a path outside root")
    st.path = "/"; press(st, "f5")
    check(st.path == "/data/users/bob", "files: readDir accepted /")
    st.entries = {{name = "secret.txt", path = "/data/users/alice/secret.txt", dir = false}}
    st.selected = 1; press(st, "enter")
    check(st.mode ~= "view", "files: opened another user's file")

    -- администратор
    local admin = {currentUser = {id = "root", name = "Root", isAdmin = true}, dataRoot = "/data/users/root"}
    st = Files.init(win, admin)
    check(st.path == "/", "files: admin does not start at /")
    drawOk(st, "files admin")
    check(#st.entries > 0, "files: admin sees empty /")
    st.path = "/os"; press(st, "f5"); drawOk(st, "files admin /os")
    check(selectPath(st, "/os/boot.lua"), "files: boot.lua not listed for admin")
    press(st, "x"); press(st, "y")
    check(fs.exists("/os/boot.lua") and st.statusLevel == "error", "files: admin deleted /os/boot.lua")
    press(st, "r"); typeName(st, "boot2.lua")
    check(fs.exists("/os/boot.lua"), "files: admin renamed /os/boot.lua")
    st.selected = 0; press(st, "n"); typeName(st, "x.lua")
    check(not fs.exists("/os/x.lua"), "files: admin created file in /os")
    st.path = "/"; press(st, "f5")
    check(selectPath(st, "/startup.lua"), "files: startup.lua not listed")
    press(st, "x"); press(st, "y")
    check(fs.exists("/startup.lua"), "files: admin deleted /startup.lua")
    check(selectPath(st, "/.mineboom_source"), "files: marker file not listed")
    press(st, "x"); press(st, "y")
    check(fs.exists("/.mineboom_source"), "files: admin deleted /.mineboom_source")
    st.path = "/data"; press(st, "f5"); st.selected = 0
    press(st, "n"); typeName(st, "admin.txt")
    check(fs.exists("/data/admin.txt"), "files: admin cannot create in /data")
    st.entries = {{name = "secret.txt", path = "/data/users/alice/secret.txt", dir = false}}
    st.selected = 1; press(st, "enter")
    check(st.mode == "view", "files: admin cannot read user files")
    print("Files                        user confined, OS paths protected")
end

print("manual /os/boot.lua runs (startup.lua migration window): " .. manualBoots)
if failures > 0 then
    print(failures .. " check(s) failed")
    os.exit(1)
end
print("all checks passed")
