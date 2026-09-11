-- Транзакционная замена набора файлов ОС.
--
-- Обновление и установка сначала скачивают файлы в staging, а затем должны
-- подменить ими живые файлы в /os. Поодиночке каждая подмена атомарна, но между
-- ними машину могут выключить — и /os остаётся смесью двух версий. Эта
-- библиотека делает подмену всего набора восстанавливаемой:
--
--   1. staged-файлы проверяются (на месте, .lua компилируется);
--   2. копия этой библиотеки кладётся в /.os_recover.lua — вне /os, чтобы
--      startup.lua и boot.lua могли звать её, пока /os в промежуточном виде;
--   3. в /.os_journal пишется список файлов и существовал ли каждый до начала;
--   4. каждый файл: живой -> /.os_bak, staged -> живой;
--   5. маркер /.os_journal.done, уборка staging/бэкапов, удаление журнала.
--
-- При загрузке, если журнал есть, Tx.recover() докатывает набор вперёд (все
-- staged-файлы на месте) либо откатывает из /.os_bak. В любом случае машина
-- грузится либо со старым, либо с полностью новым набором.
--
-- Библиотека самодостаточна: только fs и стандартный Lua, без других модулей ОС —
-- её запускают и из startup.lua, и из установщика до появления ОС.
local Tx = {}
Tx.JOURNAL = "/.os_journal"
Tx.DONE    = "/.os_journal.done"
Tx.RECOVER = "/.os_recover.lua"
Tx.BACKUP  = "/.os_bak"
Tx.STARTUP = "/startup.lua"
Tx.SELF    = "/os/lib/ostx.lua"

-- ── Файловые примитивы ───────────────────────────────────────────────────────

local function readFile(path)
    if not fs.exists(path) then return nil end
    local handle = fs.open(path, "r")
    if not handle then return nil end
    local data = handle.readAll()
    handle.close()
    return data
end

local function ensureParent(path)
    local dir = fs.getDir(path)
    if dir and dir ~= "" and dir ~= "/" and not fs.exists(dir) then fs.makeDir(dir) end
end

local function writeFile(path, data)
    ensureParent(path)
    local tmp = path .. ".tmp"
    if fs.exists(tmp) then fs.delete(tmp) end
    local handle = fs.open(tmp, "w")
    if not handle then return false, "cannot write " .. tmp end
    handle.write(data or "")
    handle.close()
    if fs.exists(path) then fs.delete(path) end
    local ok = pcall(fs.move, tmp, path)
    if not ok then return false, "cannot move " .. tmp .. " -> " .. path end
    return true
end

local function move(src, dst)
    ensureParent(dst)
    if fs.exists(dst) then fs.delete(dst) end
    local ok, err = pcall(fs.move, src, dst)
    if not ok then return false, "cannot move " .. src .. " -> " .. dst .. ": " .. tostring(err) end
    return true
end

local function remove(path)
    if fs.exists(path) then pcall(fs.delete, path) end
end

local function compile(source, name)
    if type(loadstring) == "function" then
        local fn, err = loadstring(source, name)
        if fn and type(setfenv) == "function" then setfenv(fn, {}) end
        return fn, err
    end
    return load(source, name, "t", {})
end

-- /os/lib/foo.lua -> <root>/lib/foo.lua
local function under(root, path)
    local rel = string.gsub(path, "^/os/?", "")
    rel = string.gsub(rel, "^/", "")
    return root .. "/" .. rel
end

function Tx.stagedPath(staging, path) return under(staging, path) end
local function backupPath(path) return under(Tx.BACKUP, path) end

-- ── Журнал ───────────────────────────────────────────────────────────────────

local function serialize(value)
    local t = type(value)
    if t == "string" then return string.format("%q", value) end
    if t == "number" or t == "boolean" then return tostring(value) end
    if t == "table" then
        local parts = {}
        for _, item in ipairs(value) do parts[#parts + 1] = serialize(item) end
        for key, item in pairs(value) do
            if type(key) == "string" then
                parts[#parts + 1] = "[" .. string.format("%q", key) .. "]=" .. serialize(item)
            end
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "nil"
end

function Tx.readJournal()
    local data = readFile(Tx.JOURNAL)
    if not data then return nil end
    local fn = compile(data, "journal")
    if not fn then return nil, "journal is corrupt" end
    local ok, journal = pcall(fn)
    if not ok or type(journal) ~= "table" or type(journal.files) ~= "table"
        or type(journal.staging) ~= "string" then
        return nil, "journal is corrupt"
    end
    return journal
end

function Tx.pending()
    return fs.exists(Tx.JOURNAL) or fs.exists(Tx.DONE)
end

-- ── Проверка staging ─────────────────────────────────────────────────────────

-- Все файлы набора лежат в staging, и каждый .lua хотя бы компилируется.
-- Битый файл отклоняет всё обновление до того, как тронут хоть один живой.
function Tx.validate(staging, files)
    for _, path in ipairs(files) do
        local staged = under(staging, path)
        if not fs.exists(staged) then
            return false, "missing staged file " .. path
        end
        if string.match(path, "%.lua$") then
            local data = readFile(staged)
            local fn, err = compile(data or "", "=" .. path)
            if not fn then
                return false, "syntax error in " .. path .. ": " .. tostring(err)
            end
        end
    end
    return true
end

-- ── Состояние одного файла ───────────────────────────────────────────────────

-- "done"    — живой файл уже новый
-- "pending" — staged-файл ещё на месте, можно докатить
-- "broken"  — ни докатить, ни понять, что стоит: staged потерян
local function state(journal, entry)
    local live   = fs.exists(entry.path)
    local staged = fs.exists(under(journal.staging, entry.path))
    local backup = fs.exists(backupPath(entry.path))
    if staged then return "pending" end
    if live and (backup or not entry.existed) then return "done" end
    return "broken"
end

local function applyOne(journal, entry)
    if state(journal, entry) ~= "pending" then return true end
    local live, staged, backup = entry.path, under(journal.staging, entry.path), backupPath(entry.path)
    if fs.exists(live) then
        if entry.existed and not fs.exists(backup) then
            local ok, err = move(live, backup)
            if not ok then return false, err end
        else
            remove(live)
        end
    end
    return move(staged, live)
end

local function rollbackOne(journal, entry)
    local live, backup = entry.path, backupPath(entry.path)
    if entry.existed then
        if fs.exists(backup) then
            remove(live)
            return move(backup, live)
        end
        return true -- живой файл ещё старый
    end
    remove(live) -- файла раньше не было
    return true
end

-- Уборка. Порядок важен для обрыва между шагами:
--   * журнал удаляется до маркера, иначе окно между ними выглядело бы как
--     незавершённая фаза apply без бэкапов и вызвало бы ложный откат;
--   * копия библиотеки удаляется последней: пока есть журнал или маркер,
--     startup.lua и boot.lua должны иметь чем их обработать.
local function finalize(journal)
    remove(Tx.BACKUP)
    if journal and journal.staging then remove(journal.staging) end
    remove(Tx.JOURNAL)
    remove(Tx.DONE)
    remove(Tx.RECOVER)
end

-- ── Публичный API ────────────────────────────────────────────────────────────

-- Докатить или откатить незавершённую транзакцию. Идемпотентна: её можно звать
-- сколько угодно раз и с любой точки прерывания.
-- Возвращает true и исход: "nothing", "forward", "rollback", "finalized";
-- либо false и ошибку. При "rollback" третьим значением идёт причина.
function Tx.recover()
    local journal, err = Tx.readJournal()
    if not journal then
        if err then return false, err end
        if fs.exists(Tx.DONE) then finalize(nil); return true, "finalized" end
        return true, "nothing"
    end
    if fs.exists(Tx.DONE) then
        finalize(journal)
        return true, "finalized"
    end

    local reason
    for _, entry in ipairs(journal.files) do
        if state(journal, entry) == "broken" then
            reason = "staged file lost: " .. tostring(entry.path)
            break
        end
    end

    if not reason then
        for _, entry in ipairs(journal.files) do
            local ok, applyErr = applyOne(journal, entry)
            if not ok then return false, applyErr end
        end
        local ok, doneErr = writeFile(Tx.DONE, "done")
        if not ok then return false, doneErr end
        finalize(journal)
        return true, "forward"
    end

    for _, entry in ipairs(journal.files) do
        local ok, rbErr = rollbackOne(journal, entry)
        if not ok then return false, rbErr end
    end
    finalize(journal)
    return true, "rollback", reason
end

-- Подменить набор файлов. plan = {staging = "/.os_tmp", files = {...}, version = "..."}.
-- Возвращает то же, что Tx.recover(): true,"forward" при успехе.
function Tx.commit(plan)
    if type(plan) ~= "table" or type(plan.staging) ~= "string" or type(plan.files) ~= "table" then
        return false, "invalid plan"
    end
    if Tx.pending() then return false, "another update is unfinished" end

    local ok, err = Tx.validate(plan.staging, plan.files)
    if not ok then return false, err end

    -- Копия библиотеки вне /os: пока набор в промежуточном виде, /os/lib/ostx.lua
    -- может быть любой из двух версий или отсутствовать.
    local self = readFile(under(plan.staging, Tx.SELF)) or readFile(Tx.SELF)
    if not self then return false, "recovery library not found" end
    ok, err = writeFile(Tx.RECOVER, self)
    if not ok then return false, err end
    ok, err = Tx.ensureStartup()
    if not ok then return false, err end

    local entries = {}
    for index, path in ipairs(plan.files) do
        entries[index] = {path = path, existed = fs.exists(path)}
    end
    remove(Tx.BACKUP)
    ok, err = writeFile(Tx.JOURNAL, "return " .. serialize({
        phase   = "apply",
        staging = plan.staging,
        version = plan.version,
        files   = entries,
    }))
    if not ok then return false, err end

    return Tx.recover()
end

-- ── startup.lua ──────────────────────────────────────────────────────────────

-- Точка входа машины. Не входит в манифест, поэтому обновляется отсюда: перед
-- каждым коммитом и при каждой загрузке, если содержимое устарело.
Tx.STARTUP_SOURCE = [[
-- MineboomOS startup. Managed by the OS: rewritten on install and update.
local journal, recover = "/.os_journal", "/.os_recover.lua"
if (fs.exists(journal) or fs.exists(journal .. ".done")) and fs.exists(recover) then
    print("Finishing interrupted OS update...")
    local ok, err = pcall(function()
        local done, outcome, why = dofile(recover).recover()
        if not done then error(tostring(outcome), 0) end
        print("Recovery: " .. tostring(outcome) .. (why and (" (" .. tostring(why) .. ")") or ""))
    end)
    if not ok then
        print("Recovery failed: " .. tostring(err))
        print("Reinstall with /os/install.lua, or from a shell run:")
        print("  lua> dofile('/.os_recover.lua').recover()")
    end
end
local boot = "/os/boot.lua"
if fs.exists(boot) then
    shell.run(boot)
else
    print("MineboomOS is not installed. Run installer again.")
end
]]

function Tx.ensureStartup()
    if readFile(Tx.STARTUP) == Tx.STARTUP_SOURCE then return true end
    return writeFile(Tx.STARTUP, Tx.STARTUP_SOURCE)
end

return Tx
