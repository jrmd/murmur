# Murmur

Private, on-device dictation for macOS. Hold `fn`, say it, let go: Murmur transcribes your speech, tidies the ums and punctuation, and pastes the result wherever you're typing.

Speech recognition and clean-up both run on your Mac. There is no account and no cloud; after a one-time model download it works offline.

**[Download Murmur](https://murmur.bonusobjective.com)** · [Website](https://murmur.bonusobjective.com)

## How it works

1. **Speech to text.** [Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) models run through [FluidAudio](https://github.com/FluidInference/FluidAudio) on the Apple Neural Engine.
2. **Clean-up.** A small language model ([Murmur Clean 350M](https://huggingface.co/bonusobjective/murmur-clean-350m), Liquid AI's LFM3, or any GGUF you pick from Hugging Face) runs through [llama.cpp](https://github.com/ggml-org/llama.cpp). It removes filler words, fixes repeats and adds punctuation, without rewriting what you meant.
3. **Insert.** The text is pasted into the focused app. A personal dictionary corrects names and jargon.

Models are downloaded from Hugging Face on first use and stored locally. Nothing you say is sent anywhere.

## Requirements

- Apple Silicon Mac running macOS 26 or later
- To build: Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Building

```sh
git clone https://github.com/jrmd/murmur.git
cd murmur
Packaging/dev.sh
```

`dev.sh` generates the Xcode project, builds the Debug configuration and launches **Murmur (dev)**. It uses its own bundle identifier (`com.bonusobjective.murmur.dev`), so it has separate permissions, settings and dictionary from the released app and never auto-updates.

`project.yml` is configured with the maintainer's Apple developer team. To build with yours, set it in the environment:

```sh
DEVELOPMENT_TEAM=ABCDE12345 Packaging/dev.sh
```

If you don't have a developer account, build ad-hoc signed instead:

```sh
MURMUR_ADHOC=1 Packaging/dev.sh
```

Ad-hoc builds work, but macOS ties permissions to the code signature, so you will be asked to re-grant Accessibility and Input Monitoring after each rebuild. Signing with a team avoids that.

Murmur needs three permissions: Microphone, Accessibility (to paste) and Input Monitoring (to see the dictation key). Onboarding walks through each.

## Tests

`MurmurCore` is a Swift package, so its tests run without Xcode project generation:

```sh
swift test
```

`TidyLiveTests` run the real clean-up models and are skipped unless you opt in (this downloads the models on first run):

```sh
MURMUR_LIVE=1 swift test --filter TidyLiveTests
MURMUR_LIVE=1 MURMUR_LIVE_MODEL=lfm3 swift test --filter TidyLiveTests
```

## Project layout

| Path | What's there |
| --- | --- |
| `Sources/MurmurCore` | The dictation pipeline: audio capture, speech recognition, clean-up, model storage, dictionary |
| `Sources/Murmur` | The macOS app: menu bar item, notch overlay, onboarding, settings, text insertion, updates |
| `Tests/MurmurCoreTests` | Unit tests, plus opt-in live model tests |
| `Packaging` | Dev, build and release scripts, entitlements. See [RELEASING.md](Packaging/RELEASING.md) |
| `project.yml` | XcodeGen spec. `Murmur.xcodeproj` is generated and not committed |
| `murmur-icons`, `murmur-onboarding` | App icon sources and the onboarding design spec |

## Forking and redistributing

The official builds update themselves from `updates.murmur.bonusobjective.com` using a Sparkle signing key that is not in this repository. If you distribute your own build, change the following in `project/Info.plist` and `project.yml` so your users aren't pointed at the official feed:

- `SUFeedURL` and `SUPublicEDKey` (generate a key pair with Sparkle's `generate_keys`)
- `PRODUCT_BUNDLE_IDENTIFIER`
- `DEVELOPMENT_TEAM`

Please also give your build a different name and icon so it isn't mistaken for the official app.

## Contributing

Issues and pull requests are welcome. For anything beyond a small fix, open an issue first so we can agree on the approach. Run `swift test` before sending a change.

See [CONTRIBUTING.md](CONTRIBUTING.md) for building, tests, code style and the privacy principles a change has to respect.

## License

Murmur is released under the [MIT License](LICENSE).

It bundles or downloads third-party software and models under their own licenses, listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) and in the app under Settings → About → Acknowledgements.
