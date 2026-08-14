# CLAUDE.md (gocci)

How to work in this repository. Written from what actually went wrong on 2026-08-13.

## Measure before asserting

**A claim about behaviour ships with the measurement in the same reply.** If the measurement
cannot be shown, say 未確認 instead. Never mix a guess and a reading in one sentence.

Claims that turned out wrong, all on the same day:

- "Menu items are not redrawn while the menu is open" — the value simply was not being updated
- "The progress not moving is a display problem" — five copies of rclone were running on the
  same directory
- "File Provider fixes where the data lives" — taken from an article. The CloudMounter install
  on this machine was a counterexample
- "Per-folder view settings cannot be persisted" — they can, once `--noappledouble` is dropped

## Do not write "impossible"

The most that may be written is **not found yet** or **not verified yet**. Before calling
something impossible, at minimum:

- Read the tool's `--help` **to the end**. Do not stop at the first `grep` hit
- For an API, read the whole listing. Prefer the machine and the official text over articles
- Check whether a counterexample is running right in front of you

`--noappledouble` was in `--help` from the start. It went unread while the answer "cannot be
done" was repeated.

## The machine beats the article

When the web text and the local behaviour disagree, **take the local behaviour**. An article is
often only describing the default.

## When corrected, finish that conversation

- Do not attach a proposal for the next task to a reply about a correction. Returning to work
  is the other person's call
- While they are saying they are not convinced, do not switch the subject to implementation
- Do not end a reply by forcing a decision. No "shall I add it?", no "which would you prefer?"
- Never write "shall we stop here for today?"

## Gather what you can before asking

Every request costs the other person a turn. Reach for these first.

- `log show --predicate 'subsystem == "io.kkweb.gocci"' --last 10m --info`
- Reading the screen: `screencapture -l <window id>`, the window list under `Tools`, and System
  Events for the contents of a menu
- `./test.sh` and `./test-live.sh`

The same check was handed to the other person four times. From the second time on, find a way
to read it directly.

## Language

Commit messages, PR titles and bodies, the README, docs, and release notes are written in
English. This file is part of that. It has been asked for more than once.

**Comments in the source stay in Japanese.** That is what the existing code does. Do not
translate them.

## Restart Finder after replacing the app

Once the extension is swapped, Finder stops asking about badges. Follow a replacement with
`killall Finder`. Say that the restart is happening rather than doing it silently.
