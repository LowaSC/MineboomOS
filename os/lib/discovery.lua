-- Public service advertisements only. Discovery is not authentication/pairing.
local Discovery = {}
Discovery.PROTOCOL = "mineboom_discovery"

function Discovery.reply(ctx, sender, msg, protocol, service)
    if protocol ~= Discovery.PROTOCOL or type(msg) ~= "table"
        or msg.type ~= "find_services" or msg.version ~= 1
        or type(msg.requestId) ~= "string" or #msg.requestId > 64 then return false end
    local label = ctx.computer and ctx.computer.label or service
    pcall(rednet.send, sender, {
        type = "service", version = 1, requestId = msg.requestId,
        service = service, label = label,
    }, Discovery.PROTOCOL)
    return true
end

return Discovery
