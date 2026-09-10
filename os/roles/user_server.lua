-- Роль: сервер пользователей. Хранит users.db и отвечает на запросы по Rednet.
-- Протокол: "user_server". Модем определяется автоматически.
local Users = dofile("/os/lib/users.lua")
local Modem = dofile("/os/lib/modem.lua")
local Discovery = dofile("/os/lib/discovery.lua")

local PROTOCOL = "user_server"

local UserServerRole = {}

function UserServerRole.run(ctx)
    if not fs.exists("/data") then fs.makeDir("/data") end

    local FirstRun = dofile("/os/lib/first_run.lua")
    local ok, setupErr = FirstRun.owner()
    if not ok then error("Owner setup failed: " .. tostring(setupErr), 0) end

    local modem, err = Modem.open(ctx.computer.modemSide)
    if not modem then
        print("ERROR: Cannot open modem: " .. tostring(err))
        return
    end

    print("User server ready. ID=" .. os.getComputerID() .. "  proto=" .. PROTOCOL .. "  modem=" .. modem)
    print(#Users.load().users .. " users loaded.")

    while true do
        local senderId, msg, protocol = rednet.receive()
        Discovery.reply(ctx, senderId, msg, protocol, "users")
        if protocol == PROTOCOL and type(msg) == "table" then
            if msg.type == "get_users" then
                local db2 = Users.load()
                rednet.send(senderId, {type = "users", users = db2.users}, PROTOCOL)

            elseif msg.type == "save_users" and type(msg.users) == "table" then
                local db2 = Users.load()
                db2.users = msg.users
                Users.save(db2)
                rednet.send(senderId, {type = "ok"}, PROTOCOL)
                print("Users updated by computer " .. senderId)
            end
        end
    end
end

return UserServerRole
