# Murmur onboarding: design spec

Mockups: `dark/*.png` and `light/*.png` (2x, 1720×1320 including wallpaper margin; the window itself is **760×560 pt**). Overview: `onboarding-board.png`.
Source: `src/onboarding.html` + `src/murmur.css` (open with `?theme=dark|light&screen=welcome|mic|access|input|shortcut|models|done&state=…`), re-render with `python3 src/render.py`.

## Flow and states
| # | Screen | States drawn | Primary button (exactly one, coral) |
|---|---|---|---|
| 1 | Welcome | — | Get started (no Back) |
| 2 | Microphone | needed → granted (live level meter) | Allow Microphone → Continue |
| 3 | Accessibility | needed → waiting for System Settings → granted | Open System Settings → Continue |
| 4 | Input Monitoring | granted + relaunch notice | Continue (Relaunch Murmur is a small glass button inside the notice) |
| 5 | Choose your shortcut | Hold to talk selected, fn | Continue |
| 6 | Download models | not downloaded → downloading → ready | Download models → Continue (disabled while downloading) → Continue |
| 7 | You're all set | listening (HUD) → result (cleaned text + raw "You said") | Finish |

Rules: the permission action *is* the primary button until granted, then it becomes Continue. Back is always a glass (secondary) capsule bottom-left. The stepper (7 dots) sits centred in the footer.

## Colour
| Token | Hex / value | Use |
|---|---|---|
| coral | `#FF8A6B` | accent, icons, progress start, active dot (sampled from icon wave ≈ `#FA8A6C`) |
| coralDeep | `#F2674A` | gradient end, progress end, pressed |
| primary button gradient | `#FF9878 → #F5704F → #EE6142` (top→bottom) | primary capsule |
| coralSoft | coral @ 16% | icon chips, assurance banner, "Turn on" tag |
| green (granted / ready) | `#34C77B`; text dark `#5FE29A`, light `#1E9E5A` | Granted/Ready pills, toggles, done progress |
| amber (waiting / notice) | `#FFB547` @ 13% fill, 25% stroke; text dark `#FFC56E`, light `#B86E00` | Waiting pill, relaunch notice |
| **Dark** window tint | `rgba(30,24,26,0.66)` over blur 60 + saturate 180% | warm neutral, not grey |
| Dark text / secondary / tertiary | `#F6F1EF` / 66% / 42% | |
| Dark card | white 5.5% fill, white 9% 1px stroke, white 7% top highlight | |
| **Light** window tint | `rgba(253,250,248,0.70)` | |
| Light text / secondary / tertiary | `#1E1917` / 64% / 42% | |
| Light card | white 58% fill, `rgba(60,30,20,0.07)` stroke | |
| Track (progress, inactive dots, off toggles) | dark: white 9%; light: `rgba(60,30,20,0.09)` | |

## Type (SF Pro; mockups use Inter as stand‑in)
| Role | Size / weight | Tracking |
|---|---|---|
| Welcome title | 32 / Bold | −0.8 |
| Step title (h1) | 28 / Bold | −0.6 |
| Eyebrow "STEP 3 OF 7 · PERMISSIONS" | 11.5 / Semibold, uppercase, tertiary | +0.6 |
| Lead paragraph | 15 / Regular, secondary, line height 1.5, max width 600 | −0.1 |
| Card title | 14 / Semibold | −0.1 |
| Card subtitle | 12.5 / Regular, secondary | |
| Captions, progress meta | 12.5 / 11.5 Regular, tertiary, tabular numbers | |
| Buttons | 14 / Semibold (small: 12.5) | |
| Pills | 12 / Semibold | |
| Practice result text | 16 / Regular | −0.15 |

## Layout, spacing, radii
- Window 760×560, corner radius **26**, full‑size content (no visible title), traffic lights at x 20, y 20.
- Title bar zone 52 pt; content inset **56 pt** left/right; footer 76 pt tall, 24 pt side inset, no divider line.
- Header: 56 pt icon tile (radius 16) + 16 pt gap + eyebrow/title; status pill right-aligned. Lead text 16 pt below; main content 18–22 pt below lead.
- Cards: radius **18**, padding 14–16 × 16; gap between cards 10–12. Icon chips 34 pt, radius 10 (32/10 on Welcome, 30/9 in tips).
- Mini System Settings illustration: 296 pt wide, radius 16; inner list radius 10.
- Pills: height 26, radius 13 (capsule). Buttons: height 36, radius 18 (capsule), horizontal padding 20; small 28 / 14.
- Progress bar: 6 pt, radius 3. Stepper dots 7 pt, current dot 24×7, gap 7.
- Welcome icon: 104 pt app icon with a radial coral glow (≈55% → 0 over ~78 pt radius, blur 10).

## Components
- **Primary button**: coral capsule, white label, inner top highlight, coral shadow (y 6, blur 18, 42%). Disabled = 38% opacity, no glow.
- **Glass button**: material capsule, 1 px hairline, label in primary text colour.
- **Status pill**: Needed (dashed ring, neutral), Waiting for System Settings (amber + spinner), Granted / Ready (green + filled check), Downloading (coral + spinner), Not downloaded (neutral).
- **Numbered steps** (permission screens): 22 pt circles; current = coral fill with 3 pt halo; done = green with check; future = card fill.
- **Selectable card** (shortcut mode): selected = 1.5 pt coral stroke + 4 pt coral halo @14% + 7% coral fill; radio top-right.
- **Keycap**: min 58×46, radius 12, subtle bottom bevel; the active shortcut gets the coral ring.
- **Listening HUD**: dark glass capsule, 40 pt, coral record dot + level bars; this can double as the real floating dictation HUD.

## SwiftUI hints (macOS 26)
```swift
extension Color {
  static let murmurCoral = Color(red: 1.0, green: 0.541, blue: 0.420)      // #FF8A6B
  static let murmurCoralDeep = Color(red: 0.949, green: 0.404, blue: 0.290) // #F2674A
}

WindowGroup("Welcome to Murmur") { OnboardingView() }
  .windowStyle(.hiddenTitleBar)          // full-size content, keeps traffic lights
  .windowResizability(.contentSize)
  .defaultSize(width: 760, height: 560)

// Window background: translucent glass
OnboardingView()
  .containerBackground(.thickMaterial, for: .window)      // or .glassEffect(.regular, in: .rect(cornerRadius: 26))
  .tint(.murmurCoral)

// Buttons
Button("Allow Microphone", systemImage: "mic") { … }
  .buttonStyle(.glassProminent).tint(.murmurCoral).controlSize(.large)   // primary
  .keyboardShortcut(.defaultAction)
Button("Back") { … }.buttonStyle(.glass).controlSize(.large)            // secondary

// Cards
GlassEffectContainer(spacing: 12) {
  ModelRow(…).padding(16).glassEffect(.regular, in: .rect(cornerRadius: 18))
}
// Selected mode card: .glassEffect(.regular.tint(.murmurCoral.opacity(0.12)).interactive(), in: .rect(cornerRadius: 18))

// Progress
ProgressView(value: progress).progressViewStyle(.linear).tint(.murmurCoral)   // switch tint to .green when ready

// Pills
Label("Granted", systemImage: "checkmark.circle.fill")
  .font(.system(size: 12, weight: .semibold)).foregroundStyle(.green)
  .padding(.horizontal, 10).frame(height: 26)
  .background(.green.opacity(0.14), in: .capsule)
```
SF Symbols used: `mic`, `accessibility`, `keyboard`, `fn` / `globe`, `arrow.down.circle`, `waveform`, `sparkles`, `lock.shield`, `macwindow`, `wifi.slash`, `checkmark.circle.fill`, `arrow.clockwise`, `checkmark.seal`, `gearshape`, `hand.tap` / `switch.2` (mode cards). Use `.symbolEffect(.pulse)` on the "Waiting" spinner and `.contentTransition(.numericText())` on download percentages.

Permission plumbing behind the screens:
- Microphone: `AVCaptureDevice.requestAccess(for: .audio)`; the live meter can use `AVAudioEngine` input tap RMS.
- Accessibility: `AXIsProcessTrustedWithOptions`; open `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`; poll every ~1 s while on screen to flip to Granted.
- Input Monitoring: `CGPreflightListenEventAccess()` / `CGRequestListenEventAccess()`; pane `…?Privacy_ListenEvent`. Relaunch via `NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, …)` then `NSApp.terminate`, resuming at step 4.

## Assumptions / placeholders
- **LFM3‑1.7B download size is unknown**: shown as a dashed `x.x GB` placeholder. Fill it in from the real file.
- Parakeet v3 shown as "~600 MB"; progress figures (384 MB, 64%, "About 30 seconds left") and "Cleaned up in 0.4 s" are illustrative.
- "MacBook Air Microphone" should be the real default input device name.
- The System Settings and microphone-prompt illustrations are stylised, not pixel copies of macOS. "Terminal" and "Script Editor" are filler rows.
- The mockups use Inter because SF Pro isn't available on the render box. In the app, use the system font.
