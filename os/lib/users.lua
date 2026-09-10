-- Глобальная база пользователей. Пароли хранятся как djb2-хеш.
-- Поддерживает remote-режим: Users.setRemote(serverId, modemSide) переключает
-- load/save на обращения к серверу пользователей (компьютер 23).
local FsUtil = dofile("/os/lib/fsutil.lua")
local Modem = dofile("/os/lib/modem.lua")

local Users = {}

local USERS_DB       = "/data/users.db"
local USER_CACHE_DB  = "/data/users_cache.db"
local SESSION_DB     = "/data/session.db"
local LAST_USER_DB   = "/data/last_user.db"
local PROTOCOL     = "user_server"
local TIMEOUT    = 3   -- секунды ожидания ответа от сервера
local CACHE_TTL  = 30  -- секунды жизни кеша

-- Remote-режим
local _remote = nil   -- {serverId, modemSide} или nil
local _cache  = {db = nil, time = -CACHE_TTL}  -- кеш загрузки
local _network = {online = true, source = "local", detail = nil}

local function statePath(path)
    if _remote and _remote.isolated then
        return "/data/user_servers/" .. _remote.serverId .. "/" .. FsUtil.basename(path)
    end
    return path
end

-- Match the selected endpoint, even if another server responds first.
-- This is routing validation; legacy Rednet still has no authentication.
local function receiveFromServer(expectedType)
    local timer = os.startTimer(TIMEOUT)
    while true do
        local event, sender, msg, protocol = os.pullEvent()
        if event == "timer" and sender == timer then return nil end
        if event == "rednet_message" and sender == _remote.serverId and protocol == PROTOCOL
            and type(msg) == "table" and msg.type == expectedType then
            os.cancelTimer(timer)
            return msg
        end
    end
end

local function djb2(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483648 end
    return h
end

function Users.hashPassword(password)
    return djb2(tostring(password or ""))
end

local function loadTable(path)
    if not fs.exists(path) then return nil end
    local data = FsUtil.readFile(path)
    if type(data) ~= "string" then return nil end
    local env = {ipairs=ipairs, pairs=pairs, string=string, table=table, math=math}
    local fn
    if _VERSION == "Lua 5.1" then
        fn = loadstring(data, path)
        if fn then setfenv(fn, env) end
    else
        fn = load(data, path, "t", env)
    end
    if not fn then return nil end
    local ok, t = pcall(fn)
    return (ok and type(t) == "table") and t or nil
end

local function saveTable(path, t)
    FsUtil.ensureDir(fs.getDir(path))
    return FsUtil.atomicWrite(path, "return " .. textutils.serialize(t))
end

local function migrateUser(u)
    -- Автомиграция старого canEditFiles → permissions
    if u.canEditFiles ~= nil and not u.permissions then
        u.permissions = {
            editFiles   = u.canEditFiles == true,
            deleteFiles = u.canEditFiles == true,
            installApps = true,
        }
        u.canEditFiles = nil
    end
    if not u.permissions then
        u.permissions = {editFiles = false, deleteFiles = false, installApps = false}
    end
end

local function setNetwork(online, source, detail)
    _network = {
        online = online == true,
        source = source or (online and "remote" or "cache"),
        detail = detail,
    }
end

local function loadUserCache()
    local t = loadTable(statePath(USER_CACHE_DB))
    if type(t) == "table" and type(t.users) == "table" then
        local db = {users = t.users}
        for _, u in ipairs(db.users) do migrateUser(u) end
        return db
    end
    return nil
end

local function saveUserCache(db)
    if type(db) ~= "table" or type(db.users) ~= "table" then return end
    FsUtil.ensureDir("/data")
    saveTable(statePath(USER_CACHE_DB), {
        users = db.users,
        cachedAt = os.epoch and math.floor(os.epoch("utc") / 1000) or math.floor(os.clock()),
    })
end

-- Переключает load/save на удалённый сервер пользователей.
function Users.setRemote(serverId, modemSide, isolated)
    _remote = serverId and {serverId = serverId, modemSide = modemSide, isolated = isolated} or nil
    _cache  = {db = nil, time = -CACHE_TTL}
    if _remote then setNetwork(false, "cache", "not checked")
    else setNetwork(true, "local", nil) end
end

local function remoteLoad()
    local side = Modem.open(_remote.modemSide)
    if side then _remote.modemSide = side end
    if not side then
        setNetwork(false, "cache", "modem not found")
        return nil
    end
    local okSend = pcall(rednet.send, _remote.serverId, {type = "get_users"}, PROTOCOL)
    if not okSend then
        setNetwork(false, "cache", "send failed")
        return nil
    end
    local resp = receiveFromServer("users")
    if type(resp) == "table" and resp.type == "users" and type(resp.users) == "table" then
        local db = {users = resp.users}
        for _, u in ipairs(db.users) do migrateUser(u) end
        _cache = {db = db, time = os.clock()}
        saveUserCache(db)
        setNetwork(true, "remote", nil)
        return db
    end
    setNetwork(false, "cache", "server timeout")
    return nil
end

local function remoteSave(db)
    local side = Modem.open(_remote.modemSide)
    if side then _remote.modemSide = side end
    if side then
        local okSend = pcall(rednet.send, _remote.serverId, {type = "save_users", users = db.users}, PROTOCOL)
        if okSend then
            local resp = receiveFromServer("ok")
            if type(resp) == "table" and resp.type == "ok" then
                setNetwork(true, "remote", nil)
            else
                setNetwork(false, "cache", "server timeout")
            end
        else
            setNetwork(false, "cache", "send failed")
        end
    else
        setNetwork(false, "cache", "modem not found")
    end
    -- Обновляем локальный кеш немедленно, не ждём подтверждения.
    _cache = {db = db, time = os.clock()}
    saveUserCache(db)
end

function Users.load()
    if _remote then
        -- Возвращаем кеш если он свежий
        if _cache.db and (os.clock() - _cache.time) < CACHE_TTL then
            return _cache.db
        end
        local db = remoteLoad()
        if db then return db end
        -- Сервер недоступен — возвращаем RAM-кеш, persistent-кеш или пустую базу.
        db = _cache.db or loadUserCache()
        if db then
            _cache = {db = db, time = os.clock()}
            return db
        end
        return {users = {}}
    end
    local db = loadTable(USERS_DB)
    if type(db) == "table" and type(db.users) == "table" then
        for _, u in ipairs(db.users) do migrateUser(u) end
        return db
    end
    return {users = {}}
end

function Users.save(db)
    if _remote then
        remoteSave(db)
        return
    end
    FsUtil.ensureDir("/data")
    return saveTable(USERS_DB, db)
end

-- Принудительно сбрасывает кеш (для получения актуальных данных с сервера).
function Users.invalidateCache()
    _cache = {db = nil, time = -CACHE_TTL}
end

function Users.getNetworkStatus()
    return {
        online = _network.online == true,
        source = _network.source,
        detail = _network.detail,
        remote = _remote ~= nil,
    }
end

function Users.find(id)
    local db = Users.load()
    for _, u in ipairs(db.users) do
        if u.id == id then return u end
    end
    return nil
end

function Users.findByIndex(idx)
    local db = Users.load()
    return db.users[idx]
end

function Users.list()
    return Users.load().users
end

function Users.authenticate(id, password)
    local u = Users.find(id)
    if not u then return false end
    return u.passHash == Users.hashPassword(password)
end

function Users.getDataRoot(id)
    if _remote and _remote.isolated then
        return "/data/user_servers/" .. _remote.serverId .. "/users/" .. tostring(id)
    end
    return "/data/users/" .. tostring(id)
end

function Users.ensureDir(id)
    local root = Users.getDataRoot(id)
    FsUtil.ensureDir(root)
end

function Users.getSession()
    local s = loadTable(statePath(SESSION_DB))
    if type(s) == "table" and type(s.userId) == "string" then return s end
    return nil
end

function Users.saveSession(userId)
    FsUtil.ensureDir("/data")
    saveTable(statePath(SESSION_DB), {userId = userId})
end

function Users.clearSession()
    local path = statePath(SESSION_DB)
    if fs.exists(path) then fs.delete(path) end
end

-- Последний успешно вошедший на ЭТОТ компьютер. Хранится локально и, в отличие
-- от сессии, переживает logout — экран входа показывает его по умолчанию.
function Users.getLastUser()
    local t = loadTable(statePath(LAST_USER_DB))
    return (type(t) == "table" and type(t.userId) == "string") and t.userId or nil
end

function Users.setLastUser(userId)
    FsUtil.ensureDir("/data")
    saveTable(statePath(LAST_USER_DB), {userId = userId})
end

function Users.create(db, id, name, password, isAdmin)
    table.insert(db.users, {
        id          = id,
        name        = name,
        passHash    = Users.hashPassword(password),
        isAdmin     = isAdmin or false,
        lockTimeout = 600,
        allowedApps = nil,
        permissions = {
            editFiles   = isAdmin or false,
            deleteFiles = isAdmin or false,
            installApps = isAdmin or false,
        },
    })
end

-- Проверяет право пользователя. Администратор всегда имеет все права.
function Users.can(user, perm)
    if not user then return false end
    if user.isAdmin then return true end
    if not user.permissions then return false end
    return user.permissions[perm] == true
end

function Users.updatePassword(db, id, newPassword)
    for _, u in ipairs(db.users) do
        if u.id == id then
            u.passHash = Users.hashPassword(newPassword)
            return true
        end
    end
    return false
end

function Users.delete(db, id)
    for i, u in ipairs(db.users) do
        if u.id == id then
            table.remove(db.users, i)
            return true
        end
    end
    return false
end

-- Проверяет, доступно ли приложение пользователю.
-- nil = все доступны (или isAdmin).
function Users.canUseApp(user, appId)
    if not user then return false end
    if user.isAdmin then return true end
    if user.allowedApps == nil then return true end
    for _, id in ipairs(user.allowedApps) do
        if id == appId then return true end
    end
    return false
end

return Users
