local Connections = dofile("/os/lib/connections.lua")
local Store = dofile("/os/lib/store.lua")
local Discovery = dofile("/os/lib/discovery.lua")

local M = {}
M.id = "connections"
M.name = "Connections"
M.icon = "Co"
M.iconBg = colors.blue
M.iconFg = colors.white
M.version = 1
M.system = true
M.adminOnly = true
M.category = "system"

local FIELDS = {
    {key = "store", name = "App catalog", hint = "URL or rednet:server-number"},
    {key = "osSourceUrl", name = "Stable updates", hint = "Download URL for stable"},
    {key = "osSourceUrlDev", name = "Dev updates", hint = "Download URL for dev"},
    {key = "userServerId", name = "Shared accounts", hint = "Server number; blank = local"},
}

local function line(win, y, text, bg, fg)
    local W, H = win.getSize()
    if y < 1 or y > H then return end
    win.setCursorPos(1, y)
    win.setBackgroundColor(bg or colors.black)
    win.setTextColor(fg or colors.white)
    text = tostring(text or ""):sub(1, W)
    win.write(text .. string.rep(" ", math.max(0, W - #text)))
end

local function value(st, field)
    if field.key == "store" then return Store.defaultSource(st.ctx.config) or "" end
    if field.key == "userServerId" then return st.userChoice and tostring(st.userChoice) or "" end
    return st.ctx.config[field.key] or ""
end

local function edit(st, index, replacement)
    st.selected = index
    st.editing = FIELDS[index]
    st.text = replacement ~= nil and replacement or value(st, st.editing)
    st.replace = true
    st.message = ""
end

local function save(st)
    if not st.ctx.currentUser or not st.ctx.currentUser.isAdmin then return end
    local field = st.editing
    local v = st.text:gsub("^%s+", ""):gsub("%s+$", "")
    local ok, err
    if field.key == "store" then
        local parsed
        parsed, err = Store.parse(v)
        if parsed and (parsed.kind == "http" or parsed.id) then
            ok, err = Store.writeSource(v)
            if ok then
                if parsed.kind == "http" then st.ctx.config.storeSourceUrlInternet = v
                else st.ctx.config.storeComputer = parsed.id end
            end
        else err = "Enter a URL or rednet:number" end
    else
        if field.key == "userServerId" then
            if v == "" then v = false
            elseif v:match("^%d+$") then v = tonumber(v)
            else st.message = "Enter a server number"; return end
        elseif v == "" then v = false end
        ok, err = Connections.set(field.key, v)
        if ok then
            if field.key == "userServerId" then
                st.userChoice = v
                st.needsReboot = true
            elseif v == false then st.ctx.config[field.key] = nil
            else st.ctx.config[field.key] = v end
        end
    end
    if not ok then st.message = tostring(err or "Cannot save"); return end
    st.editing = nil
    st.message = st.needsReboot and "Saved. Reboot for accounts." or "Saved. Close/reopen the app."
end

local function findServers(st)
    if not st.ctx.openRednet() then st.message = "Connect a modem to find servers"; return end
    st.servers = {}
    st.serverScroll = 0
    st.finding = true
    st.searchTimer = os.startTimer(3)
    st.requestId = tostring(st.searchTimer) .. ":" .. tostring(os.clock())
    st.ctx.broadcast({type = "find_services", version = 1, requestId = st.requestId}, Discovery.PROTOCOL)
    st.message = "Searching for servers..."
    st.mode = "servers"
end

function M.init(win, ctx)
    local saved, err = Connections.load()
    local userChoice = ctx.config.userServerId
    if saved and saved.userServerId ~= nil then userChoice = saved.userServerId end
    return {win = win, ctx = ctx, selected = 1, mode = "fields", servers = {},
        serverScroll = 0, userChoice = userChoice, message = err or ""}
end

function M.draw(st, win)
    local W, H = win.getSize()
    win.setBackgroundColor(colors.black); win.clear()
    line(win, 1, " CONNECTIONS", colors.blue)
    if st.editing then
        line(win, 3, st.editing.name, nil, colors.cyan)
        line(win, 5, st.editing.hint, nil, colors.lightGray)
        line(win, 7, st.text:sub(-math.max(1, W - 1)) .. "_", colors.gray)
        if st.editing.key == "userServerId" then
            line(win, 9, "Use an account from that server.")
            line(win, 10, "Local owner is kept for recovery.")
            line(win, 11, "Legacy link: not encrypted.", nil, colors.yellow)
        end
        line(win, H - 2, st.message, nil, colors.yellow)
        line(win, H, "[Save] [Back]", colors.gray)
    elseif st.mode == "servers" then
        line(win, 2, "Select your own server", nil, colors.lightGray)
        for row = 1, math.max(0, H - 5) do
            local s = st.servers[st.serverScroll + row]
            if s then
                local kind = s.service == "users" and "Accounts: " or "Apps: "
                line(win, row + 2, kind .. s.label .. " #" .. s.id, colors.gray)
            end
        end
        line(win, H - 2, st.message, nil, colors.yellow)
        line(win, H - 1, "Older servers: enter number.", nil, colors.lightGray)
        line(win, H, "[Find] [Back]", colors.gray)
    else
        for i, field in ipairs(FIELDS) do
            local y = 3 + (i - 1) * 3
            local prefix = st.selected == i and "> " or "  "
            line(win, y, prefix .. field.name, nil, colors.cyan)
            local v = value(st, field)
            if v == "" then v = field.key == "userServerId" and "Local accounts" or "Not configured" end
            line(win, y + 1, v, colors.gray)
        end
        line(win, H - 2, st.message, nil, colors.yellow)
        line(win, H, "[Find servers] [Reboot]", colors.gray)
    end
end

function M.onEvent(st, event, p1, p2, p3)
    if not st.ctx.currentUser or not st.ctx.currentUser.isAdmin then return st, false end
    local W, H = st.win.getSize()
    if event == "rednet_message" and st.finding and p3 == Discovery.PROTOCOL
        and type(p2) == "table" and p2.type == "service" and p2.version == 1
        and p2.requestId == st.requestId and (p2.service == "users" or p2.service == "app_store")
        and type(p1) == "number" and type(p2.label) == "string" then
        for _, s in ipairs(st.servers) do
            if s.id == p1 and s.service == p2.service then return st, false end
        end
        if #st.servers < 32 then
            st.servers[#st.servers + 1] = {id = p1, service = p2.service, label = p2.label:sub(1, 32)}
        end
        st.message = #st.servers .. " server(s) found"
        return st, true
    elseif event == "timer" and p1 == st.searchTimer then
        st.finding = false
        if #st.servers == 0 then st.message = "No servers found" end
        return st, true
    end
    if st.editing then
        if event == "char" or event == "paste" then
            if st.replace then st.text = ""; st.replace = false end
            st.text = (st.text .. tostring(p1):gsub("[%c]", "")):sub(1, 2048)
            return st, true
        elseif event == "key" then
            if p1 == keys.enter then save(st)
            elseif p1 == keys.escape then st.editing = nil
            elseif p1 == keys.backspace then
                if st.replace then st.text = "" else st.text = st.text:sub(1, -2) end
                st.replace = false
            elseif p1 == keys.delete then st.text = ""; st.replace = false end
            return st, true
        elseif (event == "mouse_click" or event == "monitor_touch") and p3 == H then
            if p2 <= 6 then save(st) elseif p2 <= 13 then st.editing = nil end
            return st, true
        end
        return st, false
    end
    if st.mode == "servers" then
        if event == "mouse_scroll" then
            st.serverScroll = math.max(0, math.min(math.max(0, #st.servers - (H - 5)), st.serverScroll + p1))
            return st, true
        elseif event == "key" and p1 == keys.escape then st.mode = "fields"; return st, true
        elseif event == "mouse_click" or event == "monitor_touch" then
            if p3 == H then
                if p2 <= 6 then findServers(st) else st.mode = "fields" end
            elseif p3 >= 3 and p3 <= H - 3 then
                local s = st.servers[st.serverScroll + p3 - 2]
                if s then
                    st.mode = "fields"
                    edit(st, s.service == "users" and 4 or 1,
                        s.service == "users" and tostring(s.id) or "rednet:" .. s.id)
                end
            end
            return st, true
        end
        return st, false
    end
    if event == "key" then
        if p1 == keys.up then st.selected = math.max(1, st.selected - 1)
        elseif p1 == keys.down then st.selected = math.min(#FIELDS, st.selected + 1)
        elseif p1 == keys.enter then edit(st, st.selected) end
        return st, true
    elseif event == "char" and p1:lower() == "f" then findServers(st); return st, true
    elseif event == "mouse_click" or event == "monitor_touch" then
        if p3 == H then
            if p2 <= 14 then findServers(st) elseif p2 <= 23 then os.reboot() end
        else
            for i in ipairs(FIELDS) do
                local y = 3 + (i - 1) * 3
                if p3 == y or p3 == y + 1 then edit(st, i); break end
            end
        end
        return st, true
    end
    return st, false
end

return M
