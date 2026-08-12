# Gocci

A tiny macOS menu bar app that mounts **Google Drive anywhere you want** —
including an external disk — without macFUSE.

The official Google Drive app cannot choose where it mounts. Mountain Duck on
macOS always lands in `~/Library/CloudStorage`. CloudMounter can mount
anywhere, but it lists every file you have ever opened through a share link at
the top of the drive, and there is no setting to hide them.

Gocci runs `rclone nfsmount` under the hood. rclone serves NFS on localhost and
macOS mounts it, so **no kernel extension is involved** — nothing to install,
nothing to approve, no reboot. Shared items never appear, because rclone does
not show them unless asked.

It does one thing: one Google account, one mount point, mounted at login.

## Requirements

- Apple silicon, macOS 14 or later
- A Google Cloud client ID of your own (see below)

## Install

Download the DMG from [Releases](https://github.com/piro0919/gocci/releases)
and drag Gocci into Applications.

Builds are ad-hoc signed, so the first launch is met with an "unidentified
developer" warning. Allow it from System Settings → Privacy & Security.

## Setting up rclone

Gocci ships rclone inside the app, but the Google Drive connection itself is an
rclone remote you create once.

```bash
rclone config    # create a remote named "gdrive" of type "drive"
```

rclone's shared Google client ID is being retired during 2026, so **make your
own** while you are in there — [rclone's
instructions](https://rclone.org/drive/#making-your-own-client-id) walk through
the Google Cloud Console. Gocci does not ship a client ID of its own: publishing
an app that uses a restricted scope means brand review, data access review and
possibly a third-party security assessment, and staying in "testing" instead
caps the number of users and expires refresh tokens.

Then open Gocci's settings and point it at the remote name and the folder you
want it mounted in.

## Settings

| Item | Notes |
| --- | --- |
| Mount point | Any folder, including one on an external disk |
| Cache folder | Empty means the same disk as the mount point |
| rclone remote | The name from `rclone config`, default `gdrive` |
| Language | Japanese / English, defaults to the system |
| Launch at login | Mounts as soon as the disk is there |

Writing goes through `--vfs-cache-mode full`, so a file being written lives in
the cache folder until it is uploaded. That is why the cache does not default
to your internal disk — if you mounted on an external disk, you probably did it
for the space.

## What the menu shows

The state of the mount, the path, and buttons to open it in Finder or to
connect and disconnect. You need the manual switch in two situations: before
unplugging the external disk, and when things get stuck.

## When rclone dies

Gocci notices and reconnects: after 2, 5 and 15 seconds, up to three times in
ten minutes. If the external disk disappeared instead, it waits for the disk to
come back rather than reconnecting.

There is one case it cannot fix by itself. A dead rclone leaves its NFS mount
in the mount table, and clearing that entry on an external disk is refused
(`umount: Operation not permitted`) unless the app has Full Disk Access. So the
menu tells you the command to run instead:

```bash
umount -f /Volumes/YourDisk/GoogleDrive
```

Granting Full Disk Access does make Gocci clear it by itself — but the grant is
tied to the exact build, so **every update silently breaks it** while the switch
still looks enabled. That is why Gocci does not ask for it.

## Build

Xcode is not required — the Swift that ships with the Command Line Tools is
enough. rclone and Sparkle are fetched into `Vendor/` on the first build.

```bash
./build.sh
open Gocci.app
```

## Development

```bash
./test.sh       # run the logic tests (touches nothing on disk)
./icon.sh       # regenerate the menu bar mark preview at its real size
./release.sh 1.0.0   # build, sign the appcast, publish to GitHub Releases
```

The mount logic logs to the unified log:

```bash
log show --predicate 'subsystem == "io.kkweb.gocci"' --last 10m --info
```

## Artwork

`Resources/gocci-icon.png` is the app icon; the prompt used to generate it lives
in [docs/art-prompt.md](docs/art-prompt.md). The menu bar mark is not an image —
it is drawn as shapes in `Sources/Mark.swift`, so it stays sharp at 18pt and can
express connected, disconnected, waiting and failed with the same silhouette.

## Design decisions

See [SPEC.md](./SPEC.md), which also records the approaches that were tried and
dropped, and why.

## Notes

- rclone's NFS mount is marked **experimental** by rclone itself. The bundled
  version is pinned to one that was tested by hand
- If you use a menu bar manager such as Ice, a newly added item starts out in
  the hidden section

> 仕様の記録（[SPEC.md](./SPEC.md)）と絵の生成に使う指示（[docs/art-prompt.md](docs/art-prompt.md)）は日本語です。
