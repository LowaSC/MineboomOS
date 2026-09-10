-- Манифест MineboomOS.
--
-- Файлы разбиты на ядро и наборы по ролям: машина ставит core + roles[<её роль>].
-- Сервер магазина берёт ~56 KB вместо 624 KB, а карманные компьютеры перестают
-- качать серверные роли, которые никогда не запустят.
--
-- Куда класть новый файл:
--   * нужен любой машине (загрузка, ФС, сеть, обновления) -> core
--   * нужен одной роли -> roles.<роль>
--   * нужен нескольким -> перечислить в каждой, дубликаты схлопываются
-- Ничего не перечислять нельзя: файл вне списков не поедет на компьютеры.

local core = {
    "/os/boot.lua",
    "/os/install.lua",
    "/os/manifest.lua",
    "/os/README.md",
    "/os/config/computers.lua",
    "/os/lib/loader.lua",
    "/os/lib/fsutil.lua",
    "/os/lib/device.lua",
    "/os/lib/first_run.lua",
    "/os/lib/connections.lua",
    "/os/lib/discovery.lua",
    "/os/lib/modem.lua",
    "/os/lib/registry.lua",
    "/os/lib/httpfetch.lua",
    "/os/lib/updater.lua",
    "/os/lib/log.lua",
}

local roles = {
    pocketos = {
        "/os/roles/pocketos.lua",
        "/os/changelog.lua",
        "/os/lib/appmeta.lua",
        "/os/lib/clock.lua",
        "/os/lib/notify.lua",
        "/os/lib/scrollbar.lua",
        "/os/lib/sound.lua",
        "/os/lib/store.lua",
        "/os/lib/users.lua",
        "/os/lib/pocketos/dashboard.lua",
        "/os/lib/pocketos/init.lua",
        "/os/lib/pocketos/launcher.lua",
        "/os/lib/pocketos/lockscreen.lua",
        "/os/lib/pocketos/login.lua",
        "/os/lib/pocketos/modal.lua",
        "/os/lib/pocketos/README.md",
        "/os/lib/pocketos/shell.lua",
        "/os/lib/pocketos/taskbar.lua",
        "/os/lib/pocketos/toast.lua",
        "/os/lib/pocketos/wm.lua",
        -- ui_framework нужен установленным из магазина приложениям
        -- (factory/storage грузят /os/lib/ui_framework/init.lua), а themes.lua —
        -- самой оболочке.
        "/os/lib/ui_framework/init.lua",
        "/os/lib/ui_framework/README.md",
        "/os/lib/ui_framework/state.lua",
        "/os/lib/ui_framework/themes.lua",
        "/os/apps/admin.lua",
        "/os/apps/apps.lua",
        "/os/apps/files.lua",
        "/os/apps/logs.lua",
        "/os/apps/os_update.lua",
        "/os/apps/settings.lua",
        "/os/apps/connections.lua",
        "/os/apps/terminal.lua",
    },

    lab = {
        "/os/roles/lab.lua",
        "/os/lib/screen.lua",
    },

    app_server = {
        "/os/roles/app_server.lua",
        "/os/lib/store.lua",
    },

    user_server = {
        "/os/roles/user_server.lua",
        "/os/lib/users.lua",
    },
}

-- Порядок ролей фиксирован, чтобы собранный список файлов не «плавал»
-- между загрузками (pairs по таблице порядок не гарантирует). Этот же порядок
-- определяет пункты меню в установщике.
local ROLE_ORDER = {"pocketos", "lab", "app_server", "user_server"}

-- Однострочники для меню установщика. Новая роль появляется в меню сама,
-- достаточно добавить её сюда и в roles/ROLE_ORDER.
local ROLE_INFO = {
    pocketos    = "Desktop shell for players and pocket computers",
    lab         = "Minimal development shell",
    app_server  = "App Store server (serves the app catalog)",
    user_server = "User database server (accounts and permissions)",
}

-- files = core + все роли. Считается здесь, а не дублируется руками: разъехаться
-- не может. Нужен клиентам dev.42 и старше, которые читают только manifest.files —
-- без него они не смогли бы обновиться никогда.
local files, seen = {}, {}
local function append(list)
    for _, path in ipairs(list) do
        if not seen[path] then
            seen[path] = true
            files[#files + 1] = path
        end
    end
end
append(core)
for _, name in ipairs(ROLE_ORDER) do append(roles[name]) end

return {
    name    = "MineboomOS",
    channel = "dev",
    version = "2026.09.10-dev.45",
    entry   = "/os/boot.lua",
    config  = "/os/config/computers.lua",
    features = {standalone = true, connections = true},
    -- Explicit layout of this distribution, resolved from the installation URL.
    -- appStore is a repository path, not the Rednet ID of a trusted server.
    distribution = {
        channels = {
            dev = "https://raw.githubusercontent.com/LowaSC/MineboomOS/dev/os",
            -- stable = "https://raw.githubusercontent.com/LowaSC/MineboomOS/stable/os",
        },
        -- User applications are distributed independently from the OS.
        appStore = "https://raw.githubusercontent.com/LowaSC/MineboomApps/main",
    },

    core      = core,
    roles     = roles,
    roleOrder = ROLE_ORDER,
    roleInfo  = ROLE_INFO,
    files     = files,
}
