# MineboomOS

> [!CAUTION]
> **EARLY ALPHA — NOT READY FOR NORMAL PLAY.** MineboomOS is under active
> development. Installation, updates, networking, shared accounts and
> applications may be incomplete or break without migration. It currently
> targets the maintainer's test environment and is not expected to work
> correctly on other Minecraft servers. Use only on disposable test computers
> and keep backups of every world and ComputerCraft data directory.

MineboomOS is a desktop and server-role operating system for
[CC:Tweaked](https://tweaked.cc/). The current alpha targets
Minecraft 1.21.1, NeoForge and CC:Tweaked 1.120.2.

## Alpha installation

The `main` branch contains the current experimental build and is what the
`dev` update channel points to. There is no portable stable channel yet.

MineboomOS 1.0.6 Obsidian remains the stable release for the maintainer's
existing world. It is not exported here as a portable `stable` branch because
it predates standalone profiles and contains assumptions about that world's
registry and service IDs. The first portable `stable` branch will be created
from `main` after dev.45 passes the in-game checklist.

On a disposable CC:Tweaked computer, run:

```text
wget run https://raw.githubusercontent.com/LowaSC/MineboomOS/main/install.lua
```

The installer currently offers the `dev` channel only. Its menus and first-run
setup are unfinished and require keyboard input. Do not install this over an
important computer without backing up its directory first.

On first boot MineboomOS asks for the device name and creates a local recovery
owner. Settings > Connections configures update channels, an application source
and an optional shared-account server.

## Roles

- `pocketos` — desktop shell and system applications
- `lab` — minimal development shell
- `app_server` — Rednet application catalog server
- `user_server` — shared account database server

The installer downloads `core` plus the selected role from `os/manifest.lua`.
Runtime state is stored under `/data` and is not replaced by OTA updates.

## Applications

System applications ship with the OS under `os/apps`. Games, Factory, Storage
and other user applications will live in a separate `MineboomApps` repository
and are installed through the Apps system application. The distribution points
to its public alpha catalog by default. A different source can be configured in
Settings > Connections.

## Development

All code is Lua 5.1 compatible. There is no runtime test environment outside
Minecraft. Run `luac -p` on every changed Lua file before committing.

Development flow:

1. Work and test on `main`; the `dev` update channel follows it.
2. Update `os/changelog.lua` and `os/manifest.lua`.
3. Validate installation and OTA updates in Minecraft.
4. Promote the tested commit from `main` to `stable`.

The in-game validation checklist is maintained in the private server workspace.
