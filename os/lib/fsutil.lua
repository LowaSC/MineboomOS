-- Файловые операции с атомарной записью и безопасными ошибками.
local FsUtil = {}

function FsUtil.readFile(path)
    if not fs.exists(path) then return nil, "no such file: " .. path end
    local handle = fs.open(path, "r")
    if not handle then return nil, "cannot open " .. path end
    local data = handle.readAll()
    handle.close()
    return data
end

local function ensureParent(path)
    local dir = fs.getDir(path)
    if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
end

-- Атомарная запись: пишем в tmp, удаляем целевой, переносим.
-- При сбое до fs.move целевой файл остаётся прежним.
function FsUtil.atomicWrite(path, data)
    ensureParent(path)
    local tmp = path .. ".tmp"

    if fs.exists(tmp) then fs.delete(tmp) end
    local handle = fs.open(tmp, "w")
    if not handle then return false, "cannot write " .. tmp end
    handle.write(data or "")
    handle.close()

    if fs.exists(path) then fs.delete(path) end
    local ok = pcall(fs.move, tmp, path)
    if not ok then
        return false, "cannot move " .. tmp .. " -> " .. path
    end
    return true
end

-- Прямая запись (без атомарности). Оставлена для совместимости.
function FsUtil.writeFile(path, data)
    return FsUtil.atomicWrite(path, data)
end

function FsUtil.exists(path)
    return fs.exists(path)
end

function FsUtil.ensureDir(path)
    if path and path ~= "" and not fs.exists(path) then fs.makeDir(path) end
end

function FsUtil.basename(path)
    return string.match(path, "([^/]+)$") or path
end

return FsUtil
