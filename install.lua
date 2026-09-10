-- Установщик MineboomOS: качает manifest, скачивает файлы во временную зону
-- /.os_install/, после успешной загрузки переносит в /os/. Если что-то сломалось
-- в середине — старая ОС остаётся в живых.
--
--   install.lua                      интерактивно: выбор канала и роли
--   install.lua <url>                поставить всё с этого адреса, без вопросов
--   install.lua <url> <role>         поставить набор роли, без вопросов
--
-- Роль решает, какой набор файлов манифеста ставится: сервер не тащит оболочку
-- и системные приложения. Выбор пишется в /.mineboom_role — boot.lua по нему
-- регистрирует машину и стартует в нужной роли, пока её нет в конфиге.
local STAGING      = "/.os_install"
local HTTP_TIMEOUT = 10

local CHANNELS = {
    {name = "dev", url = "https://raw.githubusercontent.com/LowaSC/MineboomOS/dev/os", note = "current development"},
}

local args        = {...}
local interactive = (#args == 0)
local baseUrl     = args[1]
local role        = args[2]
local hadOS       = fs.exists("/os/boot.lua")

-- ── Утилиты ───────────────────────────────────────────────────────────────────

local function joinUrl(base, path)
    return string.gsub(base, "/$", "") .. "/" .. string.gsub(path, "^/os/", "")
end

local function fetch(url)
    if not http or not http.get then
        return nil, "HTTP API is disabled"
    end

    local ok, handle, err = pcall(http.get, url, nil, false, HTTP_TIMEOUT)
    if not ok then
        ok, handle, err = pcall(http.get, url)
        if not ok then return nil, "http.get crashed: " .. tostring(handle) end
    end
    if not handle then return nil, err or "http.get failed" end

    local data = handle.readAll()
    handle.close()
    return data
end

local function writeFile(path, data)
    local dir = fs.getDir(path)
    if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end

    local handle = fs.open(path, "w")
    if not handle then return false, "cannot write " .. path end
    handle.write(data or "")
    handle.close()
    return true
end

local function moveOver(src, dst)
    local dir = fs.getDir(dst)
    if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    if fs.exists(dst) then fs.delete(dst) end
    return pcall(fs.move, src, dst) == true
end

-- Манифест приходит по сети, поэтому исполняем его в песочнице без fs/http.
local function loadManifest(data)
    local env = {ipairs = ipairs, pairs = pairs, string = string, table = table}
    local fn, err
    if _VERSION == "Lua 5.1" then
        fn, err = loadstring(data, "manifest")
        if fn then setfenv(fn, env) end
    else
        fn, err = load(data, "manifest", "t", env)
    end
    if not fn then return nil, err end

    local ok, manifest = pcall(fn)
    if not ok then return nil, manifest end
    if type(manifest) ~= "table" then return nil, "manifest is not a table" end
    return manifest
end

-- Ядро + набор роли. Повторяет Updater.filesFor: установщик работает до того,
-- как ОС появилась на диске, и звать /os/lib/updater.lua ещё не может.
local function filesFor(mf, wanted)
    if type(mf.core) ~= "table" or type(mf.roles) ~= "table" then
        return mf.files or {}   -- манифест старого формата
    end

    local out, seen = {}, {}
    local function append(list)
        if type(list) ~= "table" then return end
        for _, path in ipairs(list) do
            if not seen[path] then
                seen[path] = true
                out[#out + 1] = path
            end
        end
    end

    append(mf.core)

    local roleFiles = wanted and mf.roles[wanted]
    if roleFiles then
        append(roleFiles)
    else
        for _, name in ipairs(mf.roleOrder or {}) do append(mf.roles[name]) end
        append(mf.files)
    end
    return out
end

-- ── Интерактивный выбор ───────────────────────────────────────────────────────

local function ask(prompt, default)
    write(prompt)
    local answer = read()
    if answer == nil or answer == "" then return default end
    return answer
end

local function header()
    term.clear()
    term.setCursorPos(1, 1)
    if term.isColor and term.isColor() then term.setTextColor(colors.yellow) end
    print("MineboomOS installer")
    print("EARLY ALPHA - TEST COMPUTERS ONLY")
    if term.isColor and term.isColor() then term.setTextColor(colors.white) end
    print("")
end

local function chooseChannel()
    local saved
    if fs.exists("/.mineboom_source") then
        local handle = fs.open("/.mineboom_source", "r")
        if handle then saved = handle.readAll(); handle.close() end
        if saved then saved = saved:gsub("%s+$", "") end
    end
    local choices = {}
    if saved and saved:match("^https?://") then
        choices[#choices + 1] = {name = "Current source", url = saved}
    end
    choices[#choices + 1] = {name = "Enter download URL"}
    for i, ch in ipairs(CHANNELS) do
        choices[#choices + 1] = {name = ch.name .. ": " .. ch.note, url = ch.url}
    end
    print("Where to install from:")
    for i, ch in ipairs(choices) do print("  " .. i .. ") " .. ch.name) end
    print("Stable is not published yet.")
    print("")
    while true do
        local pick = tonumber(ask("Select [1]: ", "1"))
        if pick and choices[pick] then
            if choices[pick].url then return choices[pick].url end
            local url = ask("Download URL (blank cancels): ", "")
            if url == "" then return nil end
            if url:match("^https?://%S+$") then return url end
            print("Enter an http:// or https:// URL.")
        else
            print("Choose one of the listed options.")
        end
    end
end

local function chooseRole(mf)
    local order = mf.roleOrder or {}
    if #order == 0 then return nil end

    print("")
    print("What is this computer for:")
    for i, name in ipairs(order) do
        local count = #filesFor(mf, name)
        print(string.format("  %d) %-12s %d files", i, name, count))
        local info = mf.roleInfo and mf.roleInfo[name]
        if info then print("     " .. info) end
    end
    print(string.format("  %d) %-12s %d files", #order + 1, "everything", #filesFor(mf, nil)))
    print("     Every role, as older versions installed")
    print("")

    while true do
        local pick = tonumber(ask("Select [1]: ", "1"))
        if pick and order[pick] then return order[pick] end
        if pick == #order + 1 then return nil end -- everything
        print("Choose one of the listed options.")
    end
end

local function confirm(prompt)
    local answer = string.lower(ask(prompt, "y"))
    return answer == "y" or answer == "yes"
end

-- ── Поехали ───────────────────────────────────────────────────────────────────

if interactive then
    header()
    baseUrl = chooseChannel()
else
    term.clear()
    term.setCursorPos(1, 1)
    print("MineboomOS installer")
end

if not baseUrl then print("Cancelled."); return end
if not baseUrl:match("^https?://%S+$") then
    print("Source must be an http:// or https:// URL.")
    return
end
print("")
print("Source: " .. baseUrl)

if fs.exists(STAGING) then fs.delete(STAGING) end

-- ── Фаза 1: манифест ──────────────────────────────────────────────────────────
write("Fetching manifest... ")
local manifestData, manifestErr = fetch(joinUrl(baseUrl, "/os/manifest.lua"))
if not manifestData then
    print("failed")
    print("Cannot fetch manifest: " .. tostring(manifestErr))
    return
end

local manifest, parseErr = loadManifest(manifestData)
if not manifest then
    print("failed")
    print("Cannot parse manifest: " .. tostring(parseErr))
    return
end
print(tostring(manifest.name) .. " " .. tostring(manifest.version))

local features = type(manifest.features) == "table" and manifest.features or {}
if fs.exists("/data/system/device.db") and not features.standalone then
    print("This release does not support your standalone profile.")
    print("Nothing installed. Choose a newer release.")
    return
end
if fs.exists("/data/system/connections.db") and not features.connections then
    print("This release does not support your connections settings.")
    print("Nothing installed. Choose a newer release.")
    return
end

if interactive then
    role = chooseRole(manifest)
elseif role and manifest.roles and not manifest.roles[role] then
    print("Unknown role '" .. tostring(role) .. "'. Nothing installed.")
    return
end

local files = filesFor(manifest, role)

-- Файлы прошлой установки, которые в новый набор не входят. Берём их из
-- локального манифеста, а не обходом /os: приложения, установленные из магазина,
-- живут в /os/apps и в манифесте не значатся — так их не заденем.
local stale = {}
if fs.exists("/os/manifest.lua") then
    local localData = nil
    local handle = fs.open("/os/manifest.lua", "r")
    if handle then localData = handle.readAll(); handle.close() end
    local localManifest = localData and loadManifest(localData)
    if type(localManifest) == "table" then
        local wanted = {}
        for _, path in ipairs(files) do wanted[path] = true end
        for _, path in ipairs(localManifest.files or {}) do
            if not wanted[path] and fs.exists(path) then stale[#stale + 1] = path end
        end
    end
end

if interactive then
    print("")
    print("About to install:")
    print("  Version : " .. tostring(manifest.version))
    print("  Role    : " .. (role or "everything"))
    print("  Files   : " .. #files)
    if not hadOS then
        print("  Setup   : standalone, no preconfigured servers")
    end
    if #stale > 0 then
        print("  Remove  : " .. #stale .. " files from the previous install")
    end
    print("")
    if not confirm("Proceed? [Y/n]: ") then
        print("Cancelled.")
        return
    end
    print("")
elseif role then
    print("Role: " .. role .. " (" .. #files .. " files)")
end

-- ── Фаза 2: качаем всё в staging ──────────────────────────────────────────────
for index, path in ipairs(files) do
    print(string.format("[%d/%d] %s", index, #files, path))
    local data, err = fetch(joinUrl(baseUrl, path))
    if not data then
        print("Failed: " .. tostring(err))
        fs.delete(STAGING)
        return
    end

    local rel = string.gsub(path, "^/os/?", "")
    local ok, writeErr = writeFile(STAGING .. "/" .. rel, data)
    if not ok then
        print("Failed: " .. tostring(writeErr))
        fs.delete(STAGING)
        return
    end
end

-- ── Фаза 3: переносим в /os (это коммит установки) ────────────────────────────
print("Installing...")
for _, path in ipairs(files) do
    local rel = string.gsub(path, "^/os/?", "")
    if not moveOver(STAGING .. "/" .. rel, path) then
        print("Failed to install " .. path)
        return
    end
end
fs.delete(STAGING)

-- Уборка только после успешной установки: пока новые файлы не на месте,
-- старые — единственная рабочая ОС.
if #stale > 0 then
    local removed = 0
    for _, path in ipairs(stale) do
        if pcall(fs.delete, path) then removed = removed + 1 end
    end
    print("Removed " .. removed .. " files from the previous install")
end

local sourceOk, sourceErr = writeFile("/.mineboom_source", baseUrl)
if not sourceOk then print(sourceErr); return end
if role and manifest.roles and manifest.roles[role] then
    local roleOk, roleErr = writeFile("/.mineboom_role", role)
    if not roleOk then print(roleErr); return end
elseif fs.exists("/.mineboom_role") then
    -- Ставили «everything» — прошлый выбор роли больше не отражает установку.
    pcall(fs.delete, "/.mineboom_role")
end

-- Only new machines opt into standalone settings. Existing legacy machines
-- keep their registry/config behavior; reinstallation preserves local profiles.
if fs.exists("/os/lib/device.lua") then
    local Device = dofile("/os/lib/device.lua")
    local device, deviceErr = Device.load()
    if deviceErr then print(deviceErr); return end
    if device or not hadOS then
        device = device or Device.fresh(role)
        if role then device.computer.role = role end
        -- 'Everything' preserves an existing role, or defaults to PocketOS.
        if not fs.exists("/os/roles/" .. device.computer.role .. ".lua") then
            print("Selected role is not installed: " .. device.computer.role)
            return
        end
        local deviceOk, saveErr = Device.save(device)
        if not deviceOk then print("Cannot save device settings: " .. tostring(saveErr)); return end
    end
end

local startupOk, startupErr = writeFile("/startup.lua", [[
local boot = "/os/boot.lua"

if fs.exists(boot) then
    shell.run(boot)
else
    print("MineboomOS is not installed. Run installer again.")
end
]])
if not startupOk then print(startupErr); return end

print("Installed " .. tostring(manifest.name) .. " " .. tostring(manifest.version)
      .. (role and (" [" .. role .. "]") or ""))
print("Rebooting...")
sleep(1)
os.reboot()
