-- Notification Center MineboomOS.
-- Хранит ленту уведомлений: добавление, прочтение, очистка.
-- Список персистится в /data/notifications.db.
local FsUtil = dofile("/os/lib/fsutil.lua")

local Notify = {}

Notify.STORE_PATH = "/data/notifications.db"
Notify.MAX_KEEP   = 50         -- сколько уведомлений хранить

local _items = nil             -- кэш: список {id, ts, level, title, body, read}
local _listeners = {}

local function epochSeconds()
    if os.epoch then return math.floor(os.epoch("utc") / 1000) end
    return math.floor(os.clock())
end

local function nextId()
    return tostring(epochSeconds()) .. "-" .. tostring(math.random(0, 9999))
end

local function load()
    if _items ~= nil then return end
    _items = {}
    if not fs.exists(Notify.STORE_PATH) then return end
    local data = FsUtil.readFile(Notify.STORE_PATH)
    if type(data) ~= "string" then return end
    local ok, t = pcall(textutils.unserialize, data)
    if ok and type(t) == "table" then _items = t end
end

local function save()
    FsUtil.ensureDir("/data")
    FsUtil.atomicWrite(Notify.STORE_PATH, textutils.serialize(_items or {}))
end

local function trim()
    while #_items > Notify.MAX_KEEP do table.remove(_items, 1) end
end

local function dispatch(entry)
    for _, fn in ipairs(_listeners) do pcall(fn, entry) end
end

function Notify.push(title, body, opts)
    load()
    opts = opts or {}
    local entry = {
        id    = nextId(),
        ts    = epochSeconds(),
        level = opts.level or "info",       -- info | warn | error | success
        title = tostring(title or ""),
        body  = body and tostring(body) or nil,
        read  = false,
        source = opts.source,
    }
    table.insert(_items, entry)
    trim()
    save()
    dispatch(entry)
    return entry
end

function Notify.list()
    load()
    return _items
end

function Notify.unreadCount()
    load()
    local n = 0
    for _, e in ipairs(_items) do if not e.read then n = n + 1 end end
    return n
end

function Notify.markAllRead()
    load()
    local changed = false
    for _, e in ipairs(_items) do
        if not e.read then e.read = true; changed = true end
    end
    if changed then save() end
end

function Notify.markRead(id)
    load()
    for _, e in ipairs(_items) do
        if e.id == id and not e.read then e.read = true; save(); return true end
    end
    return false
end

function Notify.clear()
    load()
    _items = {}
    save()
end

function Notify.subscribe(fn)
    table.insert(_listeners, fn)
    return fn
end

function Notify.unsubscribe(fn)
    for i = #_listeners, 1, -1 do
        if _listeners[i] == fn then table.remove(_listeners, i) end
    end
end

return Notify
