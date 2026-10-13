# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Versioning: small fixes and small features raise the patch; the minor is for
bigger changes; the major is for a new product line.

## [Unreleased]

### Added

- Chat replies read aloud in Skippy's voice through the hub (R6): a "Read
  replies aloud" setting (off by default) and a speaker button on each reply.
- Live Activity while dictating: Recording with the elapsed time, then
  Transcribing, then the first line of the result (or the error) for a few
  seconds, in the Dynamic Island and on the Lock Screen, with a Stop button.
  The phone's version of the desktop floating pill.
- Project skeleton: SwiftUI app, RtechWhisperKit package, manual CI.
- On-device speech as the offline backup: when the hub is unreachable, a
  recording is transcribed on the phone (on-device only) and shown right away;
  Whisper replaces it later unless you edited it, in which case Whisper's text
  is kept alongside.
