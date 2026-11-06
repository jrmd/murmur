# Localization

Murmur's UI is localized with Xcode string catalogs. The source language is
English (`en`); the catalog ships with the English source strings only, so the
app is ready for translations without any of them being present yet.

## Target languages

The Parakeet v3 speech model understands 25 European languages, so those are the
languages Murmur aims to speak:

bg, hr, cs, da, nl, en, et, fi, fr, de, el, hu, it, lv, lt, mt, pl, pt-PT, ro,
sk, sl, es, sv, ru, uk

`CFBundleLocalizations` in `project/Info.plist` declares them to macOS. The
catalog itself only needs a `localizations` entry per language once a
translation exists.

## How strings are authored

Two forms, picked by what the string is:

**SwiftUI literals** — anything the view renders directly. These are already
`LocalizedStringKey`, so nothing extra is needed:

```swift
Text("Listening")
Button("Cancel") { … }
Toggle("Play sounds", isOn: $playSounds)
.help("Stop the download. It resumes from where it stopped next time.")
```

**Custom view parameters** take `LocalizedStringKey`, not `String`, so a literal
passed to them is still extracted:

```swift
struct SettingLabel: View {
    let title: LocalizedStringKey
    var subtitle: Text?
}
```

When a value must *not* be looked up — a file path, a model name, a device name
— pass it as `Text(verbatim:)` or keep the parameter a `String`. `SettingLabel`
has a `verbatimSubtitle:` initializer for exactly that case.

**AppKit and model code** cannot use `LocalizedStringKey`, so it uses
`String(localized:)` with a comment:

```swift
alert.messageText = String(localized: "Replace your dictionary or merge?",
                           comment: "Title of the alert shown when importing a JSON dictionary.")
```

**Interpolation** goes inside the literal so the catalog gets a placeholder:

```swift
Text("Remove \(model.displayName)?")            // key: "Remove %@?"
String(localized: "Imported \(applied) words.") // key: "Imported %lld words."
```

Do not build a sentence by concatenating `Text` values; interpolate a `Text`
instead, so translators see one string:

```swift
Text("Click \(Text("Allow Microphone").bold()) below.")   // key: "Click %@ below."
```

**Plurals** use a catalog variation. Write the plural form in the source and add
`one`/`other` under `localizations.en.variations.plural` in the catalog:

```swift
Text("\(store.entries.count) words")   // key: "%lld words"
```

**Comments** are required for anything a translator cannot place from the text
alone. `String(localized:)` takes a `comment:`; for SwiftUI literals the comment
lives in the catalog entry, because a literal has nowhere to put one.

## Adding a language

1. Open `Sources/Murmur/Localizable.xcstrings` in Xcode.
2. Select the catalog, then add the language in the file inspector (or add a
   `localizations.<code>` object to each string by hand).
3. Translate the entries. Leave `shouldTranslate: false` entries alone.
4. Add the language to `CFBundleLocalizations` in `project/Info.plist` if it is
   not there yet.
5. Build and check `Murmur.app/Contents/Resources/<code>.lproj/`.

`InfoPlist.xcstrings` holds the strings macOS reads from `Info.plist`, currently
`NSMicrophoneUsageDescription`. `CFBundleName` is deliberately not localized: it
comes from `PRODUCT_NAME`, which differs between the release and dev builds.

## Deliberately not translated

These stay as they are in every language:

- Product and model names: Murmur, Parakeet, Parakeet Ultra, Murmur Clean 350M,
  LFM3, Hugging Face, GGUF, GitHub, FluidAudio, llama.cpp, Sparkle.
- Keyboard key glyphs and labels: ⌘ ⌥ ⌃ ⇧, fn, and the key names in
  `ShortcutLabel`.
- Sample dictation text and the dictionary's example rows.
- File names, such as the default `Murmur Dictionary.csv` export name.
- URLs, SF Symbol names, `UserDefaults` keys, log text, and anything inside
  `#if DEBUG`.

In the catalog these are marked `"shouldTranslate": false`.

## Known gaps

`MurmurCore` is a separate package and its strings are English only. The app
never shows a package error message for a failure whose kind it knows: it maps
`DictationError.Kind` to its own localized text in
`AppController.localizedMessage(for:)`, and only `.other` falls back to the
package's message. The remaining English text that reaches the UI comes from the
package's model descriptions (`SpeechModel.detail`, `CleanupModel.detail` and
`.summary`, `CleanupLevel.summary`), which are shown verbatim, and from the
technical detail of a clean-up failure, which is shown under a localized banner.

## Review

Translations are expected to be machine-assisted first drafts. Every language
needs a native speaker to review it before release, especially the permission
explanations, the setup steps, and the error messages, where a mistranslation
costs the user a working app.
