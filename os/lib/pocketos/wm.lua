-- Жизненный цикл приложений PocketOS: запуск и закрытие.
local WM = {}

local TITLEBAR_H = 1

local function appGeometry(workArea)
    local w, h = workArea.getSize()
    return 1, TITLEBAR_H + 1, w, math.max(1, h - TITLEBAR_H)
end

-- Запускает приложение или переключается на него, если уже открыто.
-- Возвращает (running, newFocusedIdx).
function WM.launch(running, focusedIdx, def, workArea, ctx)
    for i, r in ipairs(running) do
        if r.def.id == def.id then
            return running, i
        end
    end

    local x, y, w, h = appGeometry(workArea)
    local appWin = window.create(workArea, x, y, w, h)
    local r = {def = def, state = {}, win = appWin, crashed = false}
    local ok, st = pcall(def.init, appWin, ctx)
    if ok then
        r.state = st or {}
    else
        r.crashed = true
        r.crashErr = tostring(st)
        if ctx and ctx.log then
            pcall(ctx.log, "error", "init: " .. r.crashErr, def.id or "app")
        end
        if ctx and ctx.notify then
            pcall(ctx.notify, "App crashed: " .. (def.id or "app"),
                  r.crashErr, {level = "error", source = def.id})
        end
    end
    table.insert(running, r)
    return running, #running
end

-- Обновляет размеры окон приложений после изменения размера экрана/scale.
function WM.reposition(running, workArea)
    local x, y, w, h = appGeometry(workArea)
    for _, r in ipairs(running) do
        if r.win and r.win.reposition then
            r.win.reposition(x, y, w, h)
        end
    end
end

-- Пересоздаёт окна приложений на новом workArea (после смены экрана:
-- monitor ↔ terminal). Старые окна были привязаны к старому workArea,
-- и просто reposition не поможет — родитель тоже сменился.
-- Состояние приложения (r.state) сохраняется; мы только переподключаем
-- те поля, которые типично хранят ссылку на window/monitor.
function WM.rebind(running, workArea)
    local x, y, w, h = appGeometry(workArea)
    for _, r in ipairs(running) do
        local newWin = window.create(workArea, x, y, w, h)
        r.win = newWin
        -- Большинство наших приложений хранят win в state (см. logs, files,
        -- rtc, hub, minesweeper). Обновляем, чтобы getSize() в onEvent
        -- между рендерами не указывал на старое окно.
        if type(r.state) == "table" then
            if r.state.win ~= nil then r.state.win = newWin end
            -- ui_framework держит ссылку на «монитор» (фактически window).
            if type(r.state.ui) == "table" and r.state.ui.monitor ~= nil then
                r.state.ui.monitor = newWin
            end
        end
    end
end

-- Закрывает приложение по индексу.
-- Возвращает новый focusedIdx.
function WM.close(running, focusedIdx, idx)
    local r = running[idx]
    if not r then return focusedIdx end
    if r.def.onClose then pcall(r.def.onClose, r.state) end
    table.remove(running, idx)
    if focusedIdx >= idx then
        return math.max(0, focusedIdx - 1)
    end
    return focusedIdx
end

return WM
