# Make OS updates transactional across the whole manifest

## Priority

High. The updater modifies boot-critical files and currently cannot recover from
an interrupted commit.

## Problem

`Updater.updateFromHttp` downloads every requested file into `/.os_tmp` before
touching the live installation, but the commit phase then overwrites `/os` one
file at a time. Each individual write is atomic; the update as a whole is not.
If the computer is stopped, the disk fills up, or a write fails after the first
replacement, `/os` contains files from two releases. The staging directory is
deleted on the next attempt, so it cannot be used automatically to finish or
roll back that interrupted transaction.

This is especially dangerous because the manifest includes `/os/boot.lua`, the
loader, role entry points, and their libraries. An incompatible combination can
fail before the graphical updater is available. The top-level installer uses a
similar per-file replacement phase, so reinstalling is exposed to the same
class of interruption.

## Reproduction

1. Publish an update that changes at least two mutually dependent core files.
2. Start an update from the system updater.
3. Stop the computer, or inject an `FsUtil.atomicWrite` failure, after the first
   live file has been replaced.
4. Start the computer again.

### Current result

The live `/os` tree is a mixture of the old and new releases. Boot behavior
depends on which files were committed before the interruption, and no durable
transaction record tells boot or a later update how to recover.

### Expected result

After any interruption, the next boot runs either the complete previous release
or the complete new release. It must never execute a partially committed set of
manifest files.

## Proposed direction

- Stage a complete, role-specific OS tree in a versioned directory and validate
  every expected path before committing it.
- Keep the active release selectable through one small atomic pointer or an
  equivalent directory-swap mechanism supported by CC:Tweaked.
- Retain the previous known-good tree until the new release completes at least
  one successful boot; then garbage-collect it.
- Store a durable transaction journal with the source version, target version,
  phase, and selected role so startup can deterministically resume or roll back.
- Apply the same transaction implementation to both OTA updates and the
  top-level installer rather than maintaining two commit algorithms.
- Preserve `/data`, `/.mineboom_source`, and `/.mineboom_role`; they are runtime
  state and must not be rolled back with `/os`.

The design should account for ComputerCraft disks that cannot temporarily hold
two full desktop installations. If a full-tree swap is too expensive, use a
write-ahead journal plus per-file backups, but preserve the same all-or-nothing
recovery guarantee.

## Acceptance criteria

- Automated fault-injection coverage interrupts every boundary in the commit
  phase and verifies that recovery produces one complete manifest version.
- A failed update leaves the previous OS bootable without requiring network
  access.
- A successful update records the new local manifest only after the release is
  fully committed.
- Boot detects an unfinished transaction before loading release libraries and
  completes recovery with a clear console message.
- Removed or renamed manifest files are handled transactionally and do not
  survive indefinitely in the active release.
- OTA and fresh/reinstall paths share the recovery behavior and are validated
  with the in-game installation checklist.

## Relevant code

- `os/lib/updater.lua`: staging, per-file commit, and local-manifest recording.
- `install.lua`: initial-install staging and per-file move into `/os`.
- `os/boot.lua`: earliest viable recovery entry point.
- `os/lib/fsutil.lua`: atomic single-file primitives on which the transaction
  layer can build.
