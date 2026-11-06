# Contributing to Murmur

Thanks for helping. Murmur is a small app with a narrow purpose: hold `fn`, speak, get clean text in the app you were already typing in. Changes that keep it small and private are the easiest to accept.

## Building

See [Building](README.md#building) in the README. `Packaging/dev.sh` generates the Xcode project, builds Debug and launches **Murmur (dev)**, which has its own bundle identifier, permissions and settings, so it never disturbs a released install.

You need Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). `Murmur.xcodeproj` is generated from `project.yml` and is not committed; edit `project.yml` instead.

## Tests

`MurmurCore` is a Swift package, so its tests run without generating the Xcode project:

```sh
swift test
```

`TidyLiveTests` run the real clean-up models and are skipped unless you opt in. They download models on first run, so they are not part of CI:

```sh
MURMUR_LIVE=1 swift test --filter TidyLiveTests
MURMUR_LIVE=1 MURMUR_LIVE_MODEL=lfm3 swift test --filter TidyLiveTests
```

Run `swift test` before opening a pull request. CI runs the same command plus a Debug build of the app.

## Code style

- Match the code around you. Terse is the house style: short functions, small types, no ceremony.
- No comments that restate the code. Comment the reason something is done, especially where a workaround or an Apple API quirk forced it.
- Keep the pipeline in `Sources/MurmurCore` free of UI and AppKit; the app target owns windows, menus and permissions.
- Prefer the standard library and what is already a dependency. New dependencies need a reason in the pull request, and a licence entry in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Proposing changes

Open an issue first for anything beyond a small fix, so we can agree on the approach before you spend time on it. Bug reports and feature requests have templates; fill in the version, macOS version and models, since most reports turn on those.

Pull requests should be one coherent change, with a summary and a note on how you tested it. If you changed behaviour, say what a user will notice.

## Privacy principles

These are not negotiable, and a pull request that breaks one will be declined:

- **Nothing leaves the device.** Audio, transcripts and cleaned text stay on the Mac. No analytics, no crash reporting, no accounts, no sync.
- **No telemetry.** Not even anonymous usage counts.
- **Model downloads only from Hugging Face**, on first use, over HTTPS, into local storage. No other network calls at runtime except the Sparkle update check against the appcast.
- **Permissions are asked for once, explained, and used for one thing.** Microphone to record, Input Monitoring to see the dictation key, Accessibility to paste.

## Releasing

Maintainers only. The process, signing identities and the update feed are described in [Packaging/RELEASING.md](Packaging/RELEASING.md).
