local Screen = dofile("/os/lib/screen.lua")
local Updater = dofile("/os/lib/updater.lua")
local Modem = dofile("/os/lib/modem.lua")

local Lab = {}

local function now()
    if os.epoch then return math.floor(os.epoch("utc") / 1000) end
    return math.floor(os.clock())
end

function Lab.run(ctx)
    local screen = Screen.create()
    local modemSide = Modem.open(ctx.computer.modemSide)
    local rednetOpen = modemSide ~= nil
    local status = Updater.status(ctx.manifest, ctx.computer.role)
    local lastDraw = 0

    local function draw()
        screen:title(ctx.manifest.name .. " / " .. ctx.computer.label, "Computer " .. ctx.id)
        screen:line(4, "Role:      " .. tostring(ctx.computer.role), colors.white, colors.black)
        screen:line(5, "Channel:   " .. tostring(ctx.computer.channel or ctx.manifest.channel), colors.white, colors.black)
        screen:line(6, "Version:   " .. tostring(ctx.manifest.version), colors.white, colors.black)
        screen:line(7, "Mode:      " .. tostring(status.mode), colors.white, colors.black)
        screen:line(8, "Files:     " .. tostring(status.files), colors.white, colors.black)
        screen:line(9, "HTTP:      " .. tostring(status.http), colors.white, colors.black)
        screen:line(10, "Rednet:    " .. tostring(rednetOpen) .. (modemSide and (" (" .. modemSide .. ")") or ""), colors.white, colors.black)
        screen:line(12, "[u] HTTP update  [r] reboot  [q] shell", colors.yellow, colors.black)
        screen:line(14, "Data stays local in /data. OS is loaded from /os.", colors.lightGray, colors.black)
        lastDraw = now()
    end

    draw()

    while true do
        local event, p1 = os.pullEvent()

        if event == "char" then
            if p1 == "q" then
                screen:clear(colors.black, colors.white)
                print("MineboomOS shell")
                return
            elseif p1 == "r" then
                os.reboot()
            elseif p1 == "u" then
                screen:line(16, "HTTP update is configured in updater.lua API.", colors.cyan, colors.black)
            end
        elseif event == "timer" then
            draw()
        end

        if now() - lastDraw > 10 then draw() end
    end
end

return Lab
