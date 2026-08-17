# Gocci

A tiny macOS menu bar app that puts **Google Drive in Finder**, keeps the
downloads **on whichever disk you choose — an external one included**, and never
pulls a folder down just because you opened it.

The official Google Drive app cannot choose where it keeps things: it fills your
startup disk. Mountain Duck lands in `~/Library/CloudStorage` on macOS whatever
you configure. Gocci does
one thing: one Google account, in Finder, on the disk you picked, connected at
login.

## How it works

Gocci registers a **File Provider** with macOS — the same mechanism iCloud Drive
uses. macOS therefore knows the contents live in the cloud, which changes what
Finder is allowed to do:

- Opening a folder downloads **nothing**. Finder lists names and sizes only
- Thumbnails are asked for through a channel of their own, so drawing an icon
  never pulls the file down
- Reading part of a large file fetches **only that part**. Skipping into a 70GB
  video does not fetch 70GB
- Downloaded-or-not is tracked by macOS, so the cloud badges and *Remove
  Download* in Finder are the system's own, not an imitation

Underneath, rclone talks to Drive. It runs without mounting anything: Gocci
starts `rclone rcd`, asks it for listings over HTTP, and hands the answers to
Finder. Nothing is installed into the kernel, nothing needs approval, no reboot.

Drive appears in the Finder sidebar next to iCloud Drive. **Downloads can live on
an external disk** — pick one under *Stored on* in Settings, and what you download
is kept there instead of your startup disk. That needs macOS 15 or later.

## Requirements

- Apple silicon, macOS 14 or later
- A Google Cloud client ID of your own (see below)

## Install

Download the DMG from [Releases](https://github.com/piro0919/gocci/releases)
and drag Gocci into Applications.

Builds are ad-hoc signed, so the first launch is met with an "unidentified
developer" warning. Allow it from System Settings → Privacy & Security.

## Connecting Google

Open Settings and press **Connect Google**. The sign-in happens in your browser,
and that is the whole of it — no terminal.

rclone's shared Google client ID is being retired during 2026, so **make your
own** and paste it into Settings — [rclone's
instructions](https://rclone.org/drive/#making-your-own-client-id) walk through
the Google Cloud Console. You can connect without one and fill it in later;
saving it re-runs the sign-in, because changing the client ID invalidates the
token you already have.

Gocci does not ship a client ID of its own: publishing an app that uses a
restricted scope means brand review, data access review and possibly a
third-party security assessment, and staying in "testing" instead caps the
number of users and expires refresh tokens.

The connection is an ordinary rclone remote, so `rclone config` still works if
you would rather do it that way.

## Settings

| Item | Notes |
| --- | --- |
| Stored on | Which disk keeps what you download. An external disk needs macOS 15 |
| Limit | A ceiling for what is kept on that disk |
| Client ID / secret | Written straight into your rclone remote |
| Account | Only shown when `rclone config` holds more than one Drive remote |
| Language | Japanese / English, defaults to the system |
| Launch at login | Connects as soon as you log in |

**Downloads** says how much of that disk the copies take, and **Remove All**
clears them. Finder can drop them one at a time too — right-click a file and
choose *Remove Download*. Either way the file stays visible; only the copy on
your disk goes.

*Limit* does it without being asked. What goes first is whatever was
downloaded longest ago, not whatever was used longest ago — macOS does not
report a last-used date for these files, and reads do not move the access time
on APFS. Changing *Stored on* reconnects the Drive, and anything already
downloaded is dropped.

## What the menu shows

Whether the Drive is connected, and buttons to open it in Finder or to connect
and disconnect. The connection survives quitting Gocci — macOS remembers it, so
the folder stays in the sidebar and reconnects on the next launch.

## Changes made elsewhere

Once a minute Gocci asks macOS to look again, and the extension compares what
Drive reports against what it last saw. Files added from another machine appear
without reopening the folder. Only folders you have looked at recently are
checked; anywhere else is refreshed when you open it.

## Build

Xcode is not required — the Swift that ships with the Command Line Tools is
enough. rclone and Sparkle are fetched into `Vendor/` on the first build.

```bash
./build.sh
open Gocci.app
```

## Development

```bash
./test.sh            # check the built app (touches nothing else)
./icon.sh            # regenerate the menu bar mark preview at its real size
./release.sh 1.0.0   # build, sign the appcast, publish to GitHub Releases
```

Both the app and the extension log to the unified log:

```bash
log show --predicate 'subsystem == "io.kkweb.gocci"' --last 10m --info
```

The extension runs inside a sandbox and is hard to reach from outside, so it
logs what it was asked for and what it answered. To detach the Drive from
Finder without opening the menu:

```bash
/Applications/Gocci.app/Contents/MacOS/Gocci --file-provider-stop
```

## Artwork

`Resources/gocci-icon.png` is the app icon; the prompt used to generate it lives
in [docs/art-prompt.md](docs/art-prompt.md). The menu bar mark is not an image —
it is drawn as shapes in `Sources/Mark.swift`, so it stays sharp at 18pt and can
express connected, connecting and failed with the same silhouette.

## Design decisions

See [SPEC.md](./SPEC.md), which also records the approaches that were tried and
dropped, and why.

## Notes

- Earlier versions mounted the Drive as a disk through `rclone nfsmount`. That is
  gone. Finder treated it as an ordinary volume and read files just to draw icons,
  and the workaround for that — writing view settings into `.DS_Store` across the
  whole Drive — caused more trouble than the problem it solved. Choosing where the
  downloads live survived the change; see *Stored on* in Settings
- If you use a menu bar manager such as Ice, a newly added item starts out in
  the hidden section

> 仕様の記録（[SPEC.md](./SPEC.md)）と絵の生成に使う指示（[docs/art-prompt.md](docs/art-prompt.md)）は日本語です。
