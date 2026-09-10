local M = {}

M.id       = "terminal"
M.name     = "Terminal"
M.icon     = "T>"
M.iconBg   = colors.black
M.iconFg   = colors.lime
M.version  = 7
M.system   = true
M.category = "system"
M.adminOnly = true   -- только для администратора: даёт нативный CraftOS shell

local HOTKEYS = {
    "F1 help",
    "F2 restart",
    "F3 clear",
    "F4 pause",
}

local function writeLine(win, y, text, fg)
    local W = win.getSize()
    win.setCursorPos(1, y)
    win.setBackgroundColor(colors.black)
    win.setTextColor(fg or colors.white)
    local s = tostring(text or "")
    if #s > W then s = string.sub(s, 1, W) end
    win.write(s .. string.rep(" ", math.max(0, W - #s)))
end

local function writeBar(win, text, bg, fg)
    local W, H = win.getSize()
    win.setCursorPos(1, H)
    win.setBackgroundColor(bg or colors.gray)
    win.setTextColor(fg or colors.white)
    local s = tostring(text or "")
    if #s > W then s = string.sub(s, 1, W) end
    win.write(s .. string.rep(" ", math.max(0, W - #s)))
end

local function setBlink(win, enabled)
    if win and win.setCursorBlink then
        pcall(win.setCursorBlink, enabled == true)
    end
end

local function resetWindow(win)
    setBlink(win, false)
    win.setVisible(false)
    win.setBackgroundColor(colors.black)
    win.setTextColor(colors.white)
    win.clear()
    win.setCursorPos(1, 1)
    win.setVisible(true)
end

local function drawHelp(st)
    local win = st.win
    resetWindow(win)
    writeLine(win, 1, "CraftOS Terminal", colors.lime)
    writeLine(win, 3, "Native shell inside MineboomOS.", colors.white)
    writeLine(win, 5, "F1  toggle this help", colors.lightGray)
    writeLine(win, 6, "F2  restart shell", colors.lightGray)
    writeLine(win, 7, "F3  clear terminal screen", colors.lightGray)
    writeLine(win, 8, "F4  pause/resume input", colors.lightGray)
    writeLine(win, 10, "Commands are handled by CraftOS.", colors.gray)
    writeBar(win, table.concat(HOTKEYS, "  "), colors.blue, colors.white)
end

local function drawPaused(st)
    writeBar(st.win, "PAUSED  F4 resume  F2 restart  F1 help", colors.orange, colors.black)
end

local function drawHint(st)
    if st.help then
        drawHelp(st)
    elseif st.paused then
        drawPaused(st)
    end
end

local function restoreDir(dir)
    if dir and shell and shell.setDir then
        pcall(shell.setDir, dir)
    end
end

local function restoreAllowStartup(value)
    if not settings then return end
    if value == nil then
        if settings.unset then pcall(settings.unset, "shell.allow_startup") end
    elseif settings.set then
        pcall(settings.set, "shell.allow_startup", value)
    end
end

local function runCraftShell()
    local candidates = {
        "/rom/programs/shell.lua",
        "/rom/programs/advanced/shell.lua",
    }

    for _, path in ipairs(candidates) do
        if fs.exists(path) then
            return os.run({}, path)
        end
    end

    if shell and shell.run then
        return shell.run("shell")
    end

    error("CraftOS shell program was not found")
end

local function resumeShell(st, ...)
    if st.dead or not st.co then return end

    local oldTerm = term.current()
    term.redirect(st.win)
    local ok, filterOrErr = coroutine.resume(st.co, ...)
    term.redirect(oldTerm)

    if not ok then
        st.dead = true
        st.filter = nil
        restoreDir(st.oldDir)
        restoreAllowStartup(st.oldAllowStartup)
        resetWindow(st.win)
        writeLine(st.win, 1, "CraftOS shell crashed", colors.red)
        writeLine(st.win, 2, tostring(filterOrErr), colors.orange)
        writeLine(st.win, 4, "Close and reopen Terminal to restart.", colors.lightGray)
        return
    end

    if coroutine.status(st.co) == "dead" then
        st.dead = true
        st.filter = nil
        restoreDir(st.oldDir)
        restoreAllowStartup(st.oldAllowStartup)
        setBlink(st.win, false)
        writeLine(st.win, select(2, st.win.getSize()), "Shell exited. Close and reopen Terminal.", colors.lightGray)
    else
        st.filter = filterOrErr
    end
end

local function startShell(st)
    st.dead = false
    st.filter = nil
    st.help = false
    st.paused = false
    st.oldDir = shell and shell.dir and shell.dir() or nil
    st.oldAllowStartup = settings and settings.get and settings.get("shell.allow_startup") or nil
    resetWindow(st.win)

    st.co = coroutine.create(function()
        if shell and shell.setDir then shell.setDir("/") end
        if settings and settings.get and settings.set then
            settings.set("shell.allow_startup", false)
        end

        local ok, err = pcall(runCraftShell)

        restoreAllowStartup(st.oldAllowStartup)
        if not ok then error(err) end
    end)

    resumeShell(st)
    drawHint(st)
end

function M.init(win, ctx)
    local st = {
        win = win,
        ctx = ctx,
        co = nil,
        filter = nil,
        dead = false,
        help = false,
        paused = false,
        oldDir = nil,
    }
    startShell(st)
    return st
end

function M.draw(st, win)
    st.win = win
    if not st.co then
        writeLine(win, 1, "CraftOS Terminal", colors.white)
        writeLine(win, 2, "Close and reopen Terminal to start a new shell.", colors.lightGray)
    end
    drawHint(st)
end

function M.onEvent(st, event, p1, p2, p3, p4)
    if event == "key" then
        if p1 == keys.f1 then
            st.help = not st.help
            if st.help then st.paused = true else st.paused = false end
            drawHint(st)
            return st, false
        elseif p1 == keys.f2 then
            restoreDir(st.oldDir)
            restoreAllowStartup(st.oldAllowStartup)
            startShell(st)
            return st, false
        elseif p1 == keys.f3 then
            st.help = false
            resetWindow(st.win)
            writeBar(st.win, table.concat(HOTKEYS, "  "), colors.gray, colors.white)
            return st, false
        elseif p1 == keys.f4 then
            st.help = false
            st.paused = not st.paused
            if st.paused then drawPaused(st) else writeBar(st.win, table.concat(HOTKEYS, "  "), colors.gray, colors.white) end
            return st, false
        end
    end

    if st.help or st.paused then return st, false end
    if st.dead then return st, false end
    if st.filter and st.filter ~= event then return st, false end
    resumeShell(st, event, p1, p2, p3, p4)
    drawHint(st)
    return st, false
end

function M.onClose(st)
    if st then
        st.dead = true
        st.filter = nil
        st.help = false
        st.paused = false
        setBlink(st.win, false)
        restoreDir(st.oldDir)
        restoreAllowStartup(st.oldAllowStartup)
    end
end

return M
