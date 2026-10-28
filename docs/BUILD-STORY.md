# How rTech Whisper for iPhone was built

Sources for this page: the private development repository's full history (248
commits up to the 2026-10-13 export, 140 of them non-merge, plus later
commits), its issues and pull requests, the CHANGELOG, the test suite and the
sync-protocol document in `docs/`. This public repository holds the export
only, so its own `git log` starts at that export.

## The problem and the first version (2026-09-29)

rTech Whisper started as a fork of the OpenWhispr desktop dictation app,
pointed at self-hosted speech-to-text. The phone was the gap: there was no way
to dictate on the iPhone into the same notes and history. The upstream project
has a phone client tied to its own cloud, so the decision was to write a
native iOS app from scratch and give both apps one self-hosted server, the
[hub](https://github.com/rodaddy/rtech-whisper-hub).

The first day's commits, on 2026-09-29, did the groundwork in order:

1. A project skeleton (SwiftUI app plus the `RtechWhisperKit` package, with
   `project.yml` and XcodeGen instead of a committed Xcode project).
2. A written map of the desktop app's sync protocol, read from its source
   (`docs/desktop-sync-protocol.md`), and the choice of which contract the hub
   would speak.
3. One-command build-and-install on a real iPhone, and connecting the phone to
   the hub with a pasted device key.
4. Codable models for the sync contract, a hub sync client, a 16 kHz WAV
   encoder and recorder, a SwiftData store, dictation with an offline queue,
   on-device speech as the offline backup, and both halves of the sync engine
   (pull with cursors and conflicts, then push).
5. By the end of the day: notes with an editor and conflict banner, a tabbed
   shell, transcription history, a Start Dictation intent and Control Center
   control, the Live Activity, Upload and Dictionary screens, AI cleanup of
   dictation, and chat sessions with note tools.

## Timeline

| Date | Phase |
|---|---|
| 2026-09-29 | Skeleton, protocol map, sync engine, dictation, notes, Live Activity, chat core (85 commits) |
| 2026-09-30 | Review-fix rounds, chat tab, keyboard extension, dictionary and snippet sync, upload resume, on-device takes, brain dump (142 commits) |
| 2026-10-01 to 10-02 | Transcription language setting, deleted-folder sync fix, background upload transport, truncated-upload retry |
| 2026-10-07 | User-ordered tab bar |
| 2026-10-11 | Research note on sherpa-onnx streaming speech recognition as a future offline path |
| 2026-10-13 | Public export: private references removed, chat persona made neutral |
| 2026-10-14 | Test suite pruned to functional table tests (after the export) |

## Key design decisions

- **Speak the desktop's protocol.** Rather than invent a new API, the phone
  and hub follow the sync protocol the desktop app already used, and the
  divergences are written down. One server then serves both apps.
- **Logic in a package, thin targets.** Everything testable lives in
  `RtechWhisperKit` so its tests run with `swift test` and no simulator.
- **Never lose a take.** When the hub is down, the phone transcribes on the
  device and shows the text at once. When Whisper's answer arrives it replaces
  the on-device text, unless the person edited it, in which case both are kept.
- **Phone history is push-only.** After first syncing both ways, history was
  changed (issue 468) so the phone pushes its own dictations and keeps the
  last 15 locally by default, instead of pulling the Mac's history onto a
  small screen.
- **Keyboard inserts only on a tap.** The first keyboard extension inserted
  dictated text automatically by matching the host app. That was replaced by
  an Insert key with a preview, so text only lands where the person chooses.
- **Cut uploads at silence.** Long uploads were first split into overlapping
  chunks whose words were merged afterwards. That was replaced (issue 105) by
  cutting at silence, which removed the overlap merge.

## How AI agents built, reviewed and tested it

The app was written by AI coding agents (Claude Code) under a controller
session that split the work into small lanes, each on its own branch and
worktree, merged through pull requests. Issue and PR numbers passed 600 within
a week; 106 of the commits up to the export are merges.

Every PR went through a review loop before merge. On 2026-09-30 the loop was
written down as a workflow: the diff is cut into slices of about 400 lines,
and each slice is reviewed by a subject-matter reviewer, an adversarial
reviewer (Claude Opus) and a reviewer from a second model family (an OpenAI
model run as a separate process). Findings are verified, posted as one rollup,
low-severity items are filed as issues, and one fixer PR addresses the rest.
The review is rerun on the fixer's head until no high or medium findings
remain. 74 commits in the history are named "review findings for ..." and some
PRs went through six rounds. Low-severity findings were batched later into
fix PRs that each close 10 to 20 issues.

## How it is tested

The `RtechWhisperKit` package uses Swift Testing. On this exported snapshot
`swift test --package-path Packages/RtechWhisperKit` runs 675 tests in 124
suites, all passing. Builds and tests ran on a self-hosted CI runner by manual
dispatch; no CI configuration ships in this export.

On 2026-10-14, after the export, the suite was pruned on purpose: tests named
after reviews or findings, mock and call-order pins and real-timer waits were
removed, and each function's cases became one table-driven test. The count
went from 682 to 276 tests, and boundaries that lost an integration test
gained a structured log line instead. The prune also removed the one flaky
real-timer test that had been failing the baseline run.

## What did not work

- Automatic keyboard insertion by host matching was dropped and
  replaced by the tap-to-insert key, so text lands only where the person taps.
- Overlapping upload chunks with a word-merge step were replaced by cutting at
  silence.
- Two-way history sync to the phone was dropped for push-only local history.
- A deleted folder on the hub could strand notes on existing installs; it took
  two fixes (pull requests 550 and 566 for issue 335) to refile them to the default folder.
- Review loops on the chat PRs ran many rounds before they came back clean,
  which led to batching low-severity findings into separate issues.

## Current state

Version 0.1.0, experimental. It runs from development builds on the author's
iPhone against his own hub. Development continues in the private repository;
open items include broader Siri App Intents coverage.
