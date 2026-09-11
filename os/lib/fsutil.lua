-- Файловые операции с атомарной записью и безопасными ошибками.
local FsUtil = {}

function FsUtil.readFile(path)
    FsUtil.repair(path)
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

-- Атомарная запись. Порядок подобран так, чтобы в любой точке прерывания
-- содержимое можно было восстановить (см. FsUtil.repair):
--   1. новые данные пишутся в .tmp и закрываются;
--   2. старый файл отъезжает в .old (fs.move не умеет перезаписывать);
--   3. .tmp встаёт на место;
--   4. .old удаляется.
-- Пока файл отсутствует (между 2 и 3), рядом лежат полный .tmp и полный .old.
function FsUtil.atomicWrite(path, data)
    ensureParent(path)
    local tmp, old = path .. ".tmp", path .. ".old"

    if fs.exists(tmp) then fs.delete(tmp) end
    local handle = fs.open(tmp, "w")
    if not handle then return false, "cannot write " .. tmp end
    handle.write(data or "")
    handle.close()

    if fs.exists(old) then fs.delete(old) end
    if fs.exists(path) then
        local moved = pcall(fs.move, path, old)
        if not moved then return false, "cannot move " .. path .. " -> " .. old end
    end
    local ok = pcall(fs.move, tmp, path)
    if not ok then
        -- Вернуть старый файл, чтобы не оставить дыру.
        if fs.exists(old) and not fs.exists(path) then pcall(fs.move, old, path) end
        return false, "cannot move " .. tmp .. " -> " .. path
    end
    if fs.exists(old) then pcall(fs.delete, old) end
    return true
end

-- Доделывает прерванный atomicWrite. Файл отсутствует только между шагами 2 и 3,
-- и тогда .tmp гарантированно полный — он закрыт до того, как тронули оригинал.
-- Если .tmp нет, возвращаем .old. Стирать хвосты при живом файле безопасно.
function FsUtil.repair(path)
    local tmp, old = path .. ".tmp", path .. ".old"
    if fs.exists(path) then
        if fs.exists(old) then pcall(fs.delete, old) end
        return false
    end
    if not fs.exists(old) then return false end
    local restored
    if fs.exists(tmp) then
        restored = pcall(fs.move, tmp, path)
        if restored then pcall(fs.delete, old) end
    end
    if not restored then
        restored = pcall(fs.move, old, path)
    end
    return restored == true
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
