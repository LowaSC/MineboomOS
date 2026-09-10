local FsUtil = dofile("/os/lib/fsutil.lua")

local AppMeta = {}

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function stripComment(line)
    local inString = false
    local quote = nil
    local i = 1
    while i <= #line do
        local c = string.sub(line, i, i)
        if inString then
            if c == "\\" then
                i = i + 2
            elseif c == quote then
                inString = false
                quote = nil
                i = i + 1
            else
                i = i + 1
            end
        else
            if c == "'" or c == '"' then
                inString = true
                quote = c
                i = i + 1
            elseif c == "-" and string.sub(line, i, i + 1) == "--" then
                return string.sub(line, 1, i - 1)
            else
                i = i + 1
            end
        end
    end
    return line
end

local ESCAPES = {
    ["\\"] = "\\",
    ['"'] = '"',
    ["'"] = "'",
    ["n"] = "\n",
    ["r"] = "\r",
    ["t"] = "\t",
}

local function unescapeString(body)
    body = body:gsub("\\(%d%d?%d?)", function(code)
        if code == "" then return "\\" end
        local n = tonumber(code)
        if not n then return "\\" .. code end
        return string.char(n)
    end)
    body = body:gsub("\\(.)", function(ch)
        return ESCAPES[ch] or ch
    end)
    return body
end

local function parseString(expr)
    local quote = string.sub(expr, 1, 1)
    if quote ~= '"' and quote ~= "'" then return nil end
    if string.sub(expr, -1) ~= quote then return nil end
    return unescapeString(string.sub(expr, 2, -2))
end

local function parseLiteral(expr)
    expr = trim(expr or "")
    if expr == "" then return nil, false end

    local quoted = parseString(expr)
    if quoted ~= nil then return quoted, true end

    if expr == "true" then return true, true end
    if expr == "false" then return false, true end
    if expr == "nil" then return nil, true end

    local num = tonumber(expr)
    if num ~= nil then return num, true end

    local root, key = string.match(expr, "^(%a[%w_]*)%.(%a[%w_]*)$")
    if root == "colors" and type(colors) == "table" then
        return colors[key], colors[key] ~= nil
    end
    if root == "keys" and type(keys) == "table" then
        return keys[key], keys[key] ~= nil
    end

    return nil, false
end

function AppMeta.read(path)
    local data = FsUtil.readFile(path)
    if type(data) ~= "string" then return nil end

    local meta = {}
    local matched = false
    for rawLine in string.gmatch(data, "[^\r\n]+") do
        local line = stripComment(rawLine)
        local key, expr = string.match(line, "^%s*M%.([%w_]+)%s*=%s*(.-)%s*$")
        if key then
            local value, ok = parseLiteral(expr)
            if ok then
                meta[key] = value
                matched = true
            end
        end
    end

    if not matched then return nil end
    return meta
end

function AppMeta.field(path, key, fallback)
    local meta = AppMeta.read(path)
    if type(meta) ~= "table" then return fallback end
    local value = meta[key]
    if value == nil then return fallback end
    return value
end

return AppMeta
