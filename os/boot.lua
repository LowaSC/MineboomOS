-- MineboomOS bootstrap. Докатывает незавершённое обновление, загружает
-- manifest + конфиг компьютеров, регистрирует машину в реестре и запускает роль.

local function panic(message, hint)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.red)
    term.clear()
    term.setCursorPos(1, 1)
    print("MineboomOS boot failed")
    print(tostring(message))
    if hint then
        term.setTextColor(colors.yellow)
        print(hint)
    end
    term.setTextColor(colors.lightGray)
    print("")
    print("Press R to reboot, S for safe shell, Q to quit to CraftOS.")
    while true do
        local _, key = os.pullEvent("key")
        if     key == keys.r then os.reboot()
        elseif key == keys.q then return
        elseif key == keys.s then
            shell.run("shell")
            return
        end
    end
end

-- Незавершённое обновление: /os может быть смесью двух версий, поэтому до
-- загрузки любой библиотеки докатываем или откатываем его копией библиотеки
-- транзакций, которую обновление оставило вне /os. Обычно это уже сделал
-- startup.lua; здесь страховка для машин со старым startup.lua.
local function recoverInterruptedUpdate()
    local journal, recover = "/.os_journal", "/.os_recover.lua"
    if not (fs.exists(journal) or fs.exists(journal .. ".done")) then
        -- Копия без журнала: обновление оборвалось до его записи, /os не трогали.
        if fs.exists(recover) then pcall(fs.delete, recover) end
        return true
    end
    if not fs.exists(recover) then
        return false, "Update journal found but /.os_recover.lua is missing"
    end
    term.setTextColor(colors.yellow)
    print("Finishing interrupted OS update...")
    local ok, done, outcome, why = pcall(function() return dofile(recover).recover() end)
    if not ok then return false, tostring(done) end
    if not done then return false, tostring(outcome) end
    print("Recovery: " .. tostring(outcome) .. (why and (" (" .. tostring(why) .. ")") or ""))
    term.setTextColor(colors.white)
    return true
end

local recovered, recoverErr = recoverInterruptedUpdate()
if not recovered then
    panic(recoverErr, "Reinstall with /os/install.lua, or run dofile('/.os_recover.lua').recover() from a shell.")
    return
end

-- Библиотеки загружаем под pcall: битый файл ядра должен показать panic с
-- подсказкой, а не голую трассировку CraftOS.
local Loader, manifest, Registry, Device
local okLibs, libErr = pcall(function()
    Loader   = dofile("/os/lib/loader.lua")
    manifest = Loader.require("/os/manifest.lua")
    Registry = Loader.require("/os/lib/registry.lua")
    Device   = Loader.require("/os/lib/device.lua")
end)
if not okLibs then
    panic(libErr, "Core library failed to load. Reinstall with /os/install.lua.")
    return
end

-- startup.lua не входит в манифест: обновляем его здесь, если он устарел.
pcall(function() dofile("/os/lib/ostx.lua").ensureStartup() end)

-- Safe mode: если в первые 1.5 секунды нажата Ctrl, запускаем shell вместо роли.
-- Это страховка от полностью сломанной ОС.
local function detectSafeMode()
    local timer = os.startTimer(1.5)
    while true do
        local event, p1 = os.pullEvent()
        if event == "timer" and p1 == timer then return false end
        if event == "key" and (p1 == keys.leftCtrl or p1 == keys.rightCtrl) then
            return true
        end
    end
end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
print("MineboomOS " .. tostring(manifest.version))
print("Hold Ctrl for safe shell...")

if detectSafeMode() then
    term.setTextColor(colors.yellow)
    print("Safe mode: launching shell. Run 'shell.run(\"/os/boot.lua\")' to retry.")
    return
end

local id = os.getComputerID()

-- Роль, выбранную при установке (install.lua <url> <role>), помним на диске:
-- с ней машина регистрируется в реестре и с ней же стартует, пока её нет
-- в конфиге. Иначе новый сервер поднялся бы как обычный pocketos.
local function readInstalledRole()
    if not fs.exists("/.mineboom_role") then return nil end
    local handle = fs.open("/.mineboom_role", "r")
    if not handle then return nil end
    local value = handle.readAll()
    handle.close()
    value = string.gsub(tostring(value or ""), "%s+", "")
    if value == "" then return nil end
    return value
end

local installedRole = readInstalledRole()

local device, deviceErr = Device.load()
if deviceErr then
    panic(deviceErr, "Restore /data/system/device.db from its backup.")
    return
end
local computers, computer
if device then
    local FirstRun = Loader.require("/os/lib/first_run.lua")
    local ok, err = FirstRun.device(device)
    if not ok then
        panic(err, "Cannot save device settings. Check free disk space.")
        return
    end
    computers = Device.context(device)
    computer = device.computer
else
    computers = Loader.require(manifest.config)

    -- Реестр опционален и НЕ должен морозить загрузку: запрос асинхронный, с
    -- коротким таймаутом. Недоступный сервер больше не вешает
    -- boot на ~20-30с — любую клавишу можно нажать, чтобы пропустить ожидание.
    term.setTextColor(colors.lightGray)
    write("Contacting registry (any key to skip)... ")
    local remoteRegistry, regErr = Registry.fetch(computers, {timeout = 4, allowSkip = true})
    if type(remoteRegistry) == "table" then
        Registry.merge(computers, remoteRegistry)
        term.setTextColor(colors.lime); print("ok")
    else
        term.setTextColor(colors.yellow)
        print(regErr == "skipped" and "skipped" or "offline")
    end

    computer = computers[id]
    if not computer then
        term.setTextColor(colors.lightGray)
        write("Registering computer... ")
        local registered = Registry.register(computers, id, {timeout = 4, role = installedRole})
        if registered then
            term.setTextColor(colors.lime); print("ok")
            remoteRegistry = Registry.fetch(computers, {timeout = 4})
            if type(remoteRegistry) == "table" then
                Registry.merge(computers, remoteRegistry)
            end
            computer = computers[id]
        else
            term.setTextColor(colors.yellow); print("skipped")
        end
    end
    term.setTextColor(colors.white)

    computer = computer or computers.default
    -- Реестр недоступен, а компьютера нет в конфиге: не падаем в дефолтную роль,
    -- если при установке явно выбрали другую.
    if installedRole and not computers[id] then
        local fallback = {}
        for k, v in pairs(computer or {}) do fallback[k] = v end
        fallback.role = installedRole
        computer = fallback
    end
end -- legacy configuration/registry; standalone profiles never contact it

local rolePath = "/os/roles/" .. tostring(computer.role) .. ".lua"
if not fs.exists(rolePath) then
    panic("Missing role: " .. rolePath,
        device and "Reinstall the selected role; settings are in /data/system/device.db."
            or "Check /os/config/computers.lua and ensure the role file exists.")
    return
end

local role, err = Loader.safeDofile(rolePath)
if not role then
    panic(err, "Role file failed to load. Try /os/install.lua to reinstall.")
    return
end

-- Boot splash: показываем пока роль инициализируется
local function showSplash(mf, comp)
    local W, H = term.getSize()
    term.setBackgroundColor(colors.black)
    term.clear()
    local logo = "MineboomOS"
    term.setCursorPos(math.floor((W - #logo) / 2) + 1, math.floor(H / 2) - 1)
    term.setTextColor(colors.white)
    term.write(logo)
    local ver = mf and tostring(mf.version) or ""
    if ver ~= "" then
        term.setCursorPos(math.floor((W - #ver) / 2) + 1, math.floor(H / 2))
        term.setTextColor(colors.gray)
        term.write(ver)
    end
    local lbl = comp and (comp.label or comp.role or "") or ""
    if lbl ~= "" then
        term.setCursorPos(math.floor((W - #lbl) / 2) + 1, math.floor(H / 2) + 1)
        term.setTextColor(colors.lightGray)
        term.write(lbl)
    end
    term.setCursorPos(1, H)
    term.setTextColor(colors.gray)
    term.write("Starting...")
end
showSplash(manifest, computer)

local okRun, runErr = xpcall(function()
    role.run({
        id = id,
        manifest = manifest,
        computer = computer,
        computers = computers,
    })
end, function(e)
    if type(debug) == "table" and type(debug.traceback) == "function" then
        return debug.traceback(tostring(e), 2)
    end
    return tostring(e)
end)

if not okRun then
    panic(runErr, "Role crashed. Logs at /data/logs/system.log if available.")
end
