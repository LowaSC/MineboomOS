# MineboomOS

MineboomOS is a desktop and server-role operating system for
[CC:Tweaked](https://tweaked.cc/). The current private preview targets
Minecraft 1.21.1, NeoForge and CC:Tweaked 1.120.2.

## Status

This repository is private while installation, updates and shared accounts are
being tested. The `dev` branch contains the current portable test build.

MineboomOS 1.0.6 Obsidian remains the stable release for the maintainer's
existing world. It is not exported here as a portable `stable` branch because
it predates standalone profiles and contains assumptions about that world's
registry and service IDs. The first portable stable branch will be promoted
after dev.45 passes the in-game checklist.

## Install during private testing

GitHub does not serve private Raw files anonymously, so the permanent one-line
`wget run` command is not available yet. During private testing, deliver
`install.lua` through an authenticated proxy or copy it to the computer from a
trusted development host. Do not commit a GitHub access token to this repository
or paste it into a shared computer.

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

System applications ship with the OS under `os/apps`. User applications are
distributed separately through the Apps system application. The private preview
does not bundle the maintainer's world-specific application catalog.

## Development

All code is Lua 5.1 compatible. There is no runtime test environment outside
Minecraft. Run `luac -p` on every changed Lua file before committing.

Development flow:

1. Work and test on `dev`.
2. Update `os/changelog.lua` and `os/manifest.lua`.
3. Validate installation and OTA updates in Minecraft.
4. Promote the tested commit to `stable`.

The in-game validation checklist is maintained in the private server workspace.
