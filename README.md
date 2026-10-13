# rTech Whisper for iPhone

A native SwiftUI dictation app for iPhone. It is the phone companion of
rTech Whisper, a desktop dictation app forked from
[OpenWhispr](https://github.com/OpenWhispr/openwhispr), but it shares no code
with it: everything here was written for iOS from scratch.

## Why it exists

The author dictates all day on a Mac with speech-to-text running on his own
servers. This app brings the same habit to the phone: record, get text back
from your own Whisper server, and have it show up on the desktop too.

## What it does

- **Dictate** and get text back from a self-hosted sync hub that fronts a
  Whisper-compatible speech-to-text server. When the hub cannot be reached,
  the recording is transcribed on the phone with on-device speech
  recognition and shown at once; the Whisper text replaces it later unless you
  edited it.
- **Keyboard extension** with a mic key that hands off to the app and brings
  the transcript back into the field you were typing in.
- **Live Activity** in the Dynamic Island and on the Lock Screen while
  recording, with a Stop button; a Control Center control and Shortcuts
  intents start and stop dictation.
- **Notes, history, dictionary, snippets, brain dumps, and file upload**, kept
  on the phone and synced through the hub.
- **Chat** with an LLM behind the hub, with tool calls, and replies optionally
  read aloud by the hub's speech server.

Logic lives in the `RtechWhisperKit` Swift package
(`Packages/RtechWhisperKit/`), with Swift Testing tests that run without a
simulator. The `App/`, `Keyboard/`, and `Widgets/` targets are thin.

## What it needs

A hub. The app does not talk to OpenAI or any public speech API; every
network call goes to the hub named at build time. The hub is a separate
project (a small TypeScript and Postgres service). `docs/desktop-sync-protocol.md`
records how the desktop app's sync works, which the hub's protocol grew from.
Without a hub the app still records and transcribes on the device.

## How to run it

Requires Xcode with the iOS 27 SDK, [XcodeGen](https://github.com/yonaskolb/XcodeGen),
and an Apple Developer account for running on a device.

```bash
scripts/bootstrap.sh                                  # generates RtechWhisper.xcodeproj from project.yml
swift test --package-path Packages/RtechWhisperKit    # the package tests
```

Then open `RtechWhisper.xcodeproj`, set your team on each target (or fill
`DEVELOPMENT_TEAM` in `project.yml` and rerun the bootstrap), set
`RTW_HUB_BASE_URL` to your hub's URL in `project.yml` (or pass
`RTW_HUB_BASE_URL=https://...` to `xcodebuild`), and run on a device. Change
the bundle ID and app group (`com.rtech-consulting.whisper`,
`group.com.rtech-consulting.whisper`) to ones your team owns.

The generated Xcode project is never committed; `project.yml` is the source of
truth.

## What it does not do

- No App Store or TestFlight build, and no installer here. You build it.
- No hub, speech server, or LLM in this repo.
- No iPad or Mac layout: iPhone only, iOS 27 and later.
- It does not use the upstream OpenWhispr cloud.

## Status

Early. Version 0.1.0. Built and installed from development builds on the
author's own iPhone against his own hub. Not proven: other devices, other hub
deployments, and any use by more than one person. The package tests ran in the
author's private CI before this export; the export itself has not been built
or tested since the scrub.

## License

MIT. See [LICENSE](LICENSE).
