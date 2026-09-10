# UI Framework (`computer/lib/ui_framework/`)

Общая библиотека интерфейса для всех дисплейных компьютеров (0, 9, 13, 14). Обеспечивает рендер, обработку событий, темы, модальные диалоги и персистентные настройки.

## Файлы

| Файл | Содержимое |
|---|---|
| `init.lua` | Движок рендера: кнопки, таблицы, графики, модалы, события |
| `themes.lua` | 10 цветовых схем |
| `state.lua` | Персистентные настройки UI через `ui_settings.db` |

## Подключение

Каждый дисплейный компьютер имеет симлинк:

```bash
ln -s ../../lib/ui_framework computer/{id}/lib/ui_framework
```

Загрузка в коде:

```lua
local Ui = dofile("lib/ui_framework/init.lua")
local ui = Ui.create(monitor, config)
```

## Темы (themes.lua)

Доступно 10 схем:

| ID | Название |
|---|---|
| 1 | BLUE |
| 2 | GREEN |
| 3 | AMBER |
| 4 | RED |
| 5 | PURPLE |
| 6 | CYAN |
| 7 | LIME |
| 8 | GRAY |
| 9 | BROWN |
| 10 | PINK |

Переключаются в меню настроек (`S`) и сохраняются в `ui_settings.db`.

## Режимы отображения (Views)

| Режим | Описание |
|---|---|
| `LIST` | Прокручиваемый список всех групп и устройств |
| `TABLE` | Постраничный вид (одна группа, крупные элементы) |
| `CHARTS` | Аналитика: графики динамики RS-остатков |

Расширяемые через `uiHooks.drawView(ctx, viewType)` — возврат `true` полностью заменяет стандартный рендер.

## Колонки

Описываются в `config.uiColumns`. Каждая колонка:

```lua
{
    id            = "stock",      -- идентификатор
    title         = "RS STOCK",  -- заголовок
    width         = 12,          -- ширина в символах
    defaultVisible = false,      -- скрыта по умолчанию
    required      = true,        -- нельзя скрыть
    kind          = "button",    -- (опционально) рендер как кнопка
    buttonPrefix  = "toggle_lock_",
    buttonFg      = colors.black,
    buttonBg      = colors.yellow,
}
```

Видимость сохраняется в `ui_settings.db`. Колонки заполняются справа налево.

## Хук кастомизации ячейки

```lua
config.uiHooks = {
    getCellValue = function(device, columnId)
        -- вернуть строку или nil (тогда используется стандартное значение)
    end,
    drawView = function(ctx, viewType)
        -- вернуть true, чтобы полностью заменить рендер вида
    end,
}
```

## Звуки кнопок

Базовые звуковые события:

| ID | Когда |
|---|---|
| `menu` | Открытие меню |
| `settings` | Открытие настроек |
| `toggle_on` | Включение устройства |
| `toggle_off` | Выключение устройства |
| `locked` | Попытка переключить заблокированное |
| `error` | Ошибка / недопустимое действие |

Переопределяются в `config.uiSounds`. Громкость регулируется в меню и сохраняется в `ui_settings.db` как `soundVolume`.

## Персистентные настройки (state.lua)

Методы:
- `Ui.State.loadUiSettings(file)` — загрузить из `ui_settings.db`.
- `Ui.State.saveUiSettings(file, settings)` — сохранить.

Хранит: тему, активный вид, видимость колонок, масштаб монитора, громкость.

## Основной цикл рендера (Computer 0)

```lua
ui.draw(state, uptime, rsStock, controllerStatus, history)
```

| Параметр | Описание |
|---|---|
| `state` | Таблица состояний устройств (ON/OFF, locks) |
| `uptime` | Аптайм / время последнего изменения |
| `rsStock` | Таблица остатков RS |
| `controllerStatus` | Статус heartbeat контроллеров |
| `history` | История RS-остатков для CHARTS |
