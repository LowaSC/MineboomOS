-- Keyboard-driven setup on the built-in terminal, before the shell event loop.
local FirstRun = {}

local function heading(title)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print(title)
    print("")
end

local function ask(prompt, fallback, masked)
    write(prompt)
    local value = read(masked and "*" or nil)
    if value == "" then return fallback or "" end
    return value or ""
end

function FirstRun.device(device)
    if device.setupComplete then return true end
    heading("Welcome to MineboomOS")
    print("Choose a name for this computer.")
    print("Press Enter to keep the default.")
    local label
    repeat
        label = ask("Name: ", device.computer.label):gsub("^%s+", ""):gsub("%s+$", "")
        if #label == 0 or #label > 32 then print("Use 1-32 characters.") end
    until #label > 0 and #label <= 32
    device.computer.label = label
    device.setupComplete = true
    local Device = dofile("/os/lib/device.lua")
    return Device.save(device)
end

function FirstRun.owner()
    local Users = dofile("/os/lib/users.lua")
    local db = Users.load()
    if #db.users > 0 then return true end
    -- Do not replace an existing unreadable database with a new owner.
    if fs.exists("/data/users.db") then
        local h = fs.open("/data/users.db", "r")
        if not h then return false, "Cannot read users.db" end
        local data = h.readAll()
        h.close()
        -- Older Users databases have a 'return ' prefix.
        local ok, parsed = pcall(textutils.unserialize, (data:gsub("^%s*return%s+", "")))
        if not ok or type(parsed) ~= "table" or type(parsed.users) ~= "table" then
            return false, "Cannot read users.db; restore it before continuing"
        end
    end

    heading("Create the first owner")
    print("This account is stored on this computer.")
    print("No user server is required.")
    local id
    repeat
        id = ask("Login: "):lower()
        if not id:match("^[a-z0-9_-]+$") or #id > 24 then
            print("Use 1-24 letters, digits, - or _.")
        end
    until id:match("^[a-z0-9_-]+$") and #id <= 24
    local name
    repeat
        name = ask("Display name [" .. id .. "]: ", id)
        if #name > 32 then print("Use at most 32 characters.") end
    until #name <= 32
    local pin, again
    repeat
        pin = ask("PIN (4-12 digits): ", nil, true)
        if not pin:match("^%d+$") or #pin < 4 or #pin > 12 then
            print("Use 4-12 digits.")
        else
            again = ask("Repeat PIN: ", nil, true)
            if pin ~= again then print("PINs do not match.") end
        end
    until pin:match("^%d+$") and #pin >= 4 and #pin <= 12 and pin == again
    Users.create(db, id, name, pin, true)
    return Users.save(db)
end

return FirstRun
