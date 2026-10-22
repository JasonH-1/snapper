# Snapper

Find your look. Shoot with it. Style your whole weekend.

An iPhone camera and photo editor with live film looks and reusable personal styles.

- **Live preview through every look:** Core Image + Metal, 30 fps, off the main thread. Swipe the preview to change looks, with a live split as you drag.
- **What you see is what you save:** the preview, the full-resolution photo and every export go through the same pipeline (`LookPipeline`).
- **47 original looks in six collections:** Disposable, Neon Nights, Soft Portrait, Overclock, Darkroom and Digicam. Nine are free, at least one in every collection.
- **Looks are data:** each look is a 33-point `.cube` file listed in `filters.json`, plus optional effects (sky gradient, direct flash, glow, CCD smear, halation, chromatic aberration, chroma bleed, glitch, light leak, scanlines, sharpening, noise, film grain, vignette) drawn after it. A Python tool generates and quality-checks them.
- **Opens from Camera Control, the Lock Screen and Control Center (iOS 18):** a Lock Screen camera extension with the same live looks, a Control Center control, and a look picker and exposure slider on Camera Control. Snapper also keeps the last look, flash, exposure and front/back camera between launches. See [docs/camera-launch.md](docs/camera-launch.md).
- **StoreKit 2:** monthly and yearly plans (7-day trial on yearly) and a one-time Lifetime unlock. There are no accounts and no backend; the Apple ID is the account.

Requirements: Xcode 26 or later, iOS 17+, iPhone only. CI builds with Xcode 26.6 on `macos-latest`.

---

## Release workflow features

- **Personal presets:** Looks › Presets saves the look, strength and light/colour adjustments. Rename, duplicate or delete from each preset's menu. One preset is free; Premium unlocks unlimited presets. After expiry all presets remain stored, and the user can choose which one is their free preset.
- **Batch styling:** Library › Select › Style applies a look or a complete personal preset (Premium). Crops, frames and date stamps are preserved. Undo Last Batch skips photos edited again since the batch.
- **Finish:** adjustable white, cream, black or instant-photo borders; a confirmed date stamp; fitted square, portrait-post and story canvases. The date stamp is free; frames and layouts preview free and need Premium to export. Originals remain untouched and the same renderer powers previews and exports. Finished canvases are capped at 8192 pixels on the longest edge.
- **Featured looks:** the look picker includes sample thumbnails and shooting guidance for Boardwalk, Flashbulb, Cream, Afterglow and Halo. This does not replace real-device photographic approval.
- **Free experience:** all exports are watermark-free, and highlights, shadows and the date stamp are free. Onboarding no longer opens a paywall. The first automatic save may show an optional upgrade toast, and the editor offers an upgrade after saving.
- **No photo is ever locked:** a photo shot or edited with a previewed Premium look or tool can always be saved without those parts (the editor's *Save Without …* button; Library batch save and share ask first; automatic save does it and says so). Its full edit stays in Snapper. Premium edits made while Premium is active are remembered per photo (`CaptureRecord.premiumEdits`) and stay exportable after a subscription ends.

See [the release checklist](docs/release-checklist.md) for owner-supplied details, photographic acceptance, StoreKit tests and device checks still needed before public release.

## Connected photo workflows

- **Choose by occasion:** Looks starts with Friends & Flash, Travel & Daylight, Soft Portraits and City at Night. Each offers three existing looks and a practical shooting tip; the complete catalog remains below.
- **Shoot your personal style:** Camera › Presets applies the saved strength and all color adjustments to the live feed and new photos. The active preset is remembered. Choosing/swiping to a base look clears the preset; canceling a swipe keeps it. Editor › Presets › … › Shoot with This Preset returns to the camera.
- **Finish a set:** Library › Select › Style › Finish Photo Set previews a shared frame and/or layout on every selected photo. Crops, color edits and date stamps are preserved. Apply keeps the set selected; Apply & Share prepares a single share operation. Premium is checked again when applying/exporting. Undo Last Batch preserves later edits.
- **Exchange styles:** Presets › … › Share Preset File creates a `.snapperpreset` file. Import through Presets › Import Preset File, or open a shared file in Snapper. A sample preview and settings appear before confirmation. Each import creates a new preset, respects the one-free-preset limit and never overwrites an existing style. Imported premium looks still require Premium to export photos.
- **Optional style cards:** Share Style Card sends a labeled image plus its preset file. From the editor it uses that photo with its crop and finishing kept, using the selected style; elsewhere it uses a clearly labeled sample. Ordinary exports stay clean.
- Preset files carry only a version, name, look identifier, strength and adjustments. Imports are bounded to 64 KB and reject unknown versions/looks and invalid values. No server or account is added.

## Editing tools

- **Zoom and the selection overlay:** pinch, double-tap or drag on the editor's photo to inspect it (up to 8×; the zoom badge's Fit goes back). Selective › Show Selection lays the selection over the whole photo in red.
- **Selection brush:** Selective › Refine Selection paints onto (Paint) or off (Erase) the detected subject, with Size and Softness. One finger paints, two fingers zoom and move; each stroke is one undo step. Strokes are stored as points on the original photo, so they follow later crops, turns and flips, and they're drawn the same way for previews and full-resolution exports (`MaskBrush`). Without a detectable subject, Paint the Area starts from an empty selection.
- **Versions:** the Versions button on the photo keeps named edits of one photo (Warm, Black & White…) together with its Original and As Shot. The version showing keeps every change; an edit that isn't a version yet is kept automatically when switching. Versions can be duplicated, renamed, saved to Photos one by one or all at once, and are kept in `captures.json` with the photo.
- **Curves and split toning:** Curves edits an RGB curve and one per channel (monotone cubic, applied to sRGB values with `CIColorCurves`); Color › Split Toning tints highlights and shadows with a balance control (an Oklab tint baked into a 33-point cube). Both are Premium to export, preview free, and travel in presets (preset file version 3).
- **Export options:** the gear next to Save, and Settings › Saving & Sharing, choose HEIF or JPEG, size (Full, 3840, 2048 or 1080 px), quality and whether location stays in the file (GPS, Apple maker notes and IPTC place names are removed when off). The editor shows the real file size by writing the file in the background, and then saves or shares that same file. Photos are saved with a file URL, not in-memory data.
- **Backup and restore:** Settings › Backup writes a `.snapperbackup` file (originals unchanged, records with edits and versions, presets, favorites) to share, save to Files or AirDrop; opening it in Snapper, or Restore from Backup, adds what isn't already there. The format is documented in `LibraryBackup.swift`; it streams, so Library size isn't limited by memory.

## Run it on your iPhone

1. Install XcodeGen: `brew install xcodegen`
2. Tell Xcode who you are. Create `Config/Local.xcconfig` (it's git-ignored):
   ```
   APP_BUNDLE_ID = com.yourname.snapper
   DEVELOPMENT_TEAM = ABCDE12345
   ```
   Your Team ID is in Xcode › Settings › Accounts (or developer.apple.com › Membership).
3. Generate and open the project:
   ```sh
   xcodegen generate
   open Snapper.xcodeproj
   ```
4. Pick your iPhone and press Run. First launch shows onboarding, the camera and Photos permissions, then the camera. A non-blocking upgrade offer follows the first successful automatic save; premium tools also have explicit upgrade entry points.

Run `xcodegen generate` again whenever you add, remove or rename files. The `.xcodeproj` is generated and not committed.

**In the Simulator** there's no camera, so a demo photo stands in for the live feed. Swiping, the shutter, review, saving and the paywall all work, which makes it handy for screenshots.

## Test purchases

**Locally, no App Store Connect needed.** The `Snapper` scheme runs with `Config/Snapper.storekit`, so purchases are simulated on device or in the Simulator.
- Plans: `snapper.premium.monthly` ($3.99/month), `snapper.premium.yearly` ($19.99/year, 1-week free trial) and `snapper.premium.lifetime` ($39.99 once, non-consumable).
- **Debug › StoreKit › Manage Transactions** lets you refund, expire or cancel a subscription and watch the app re-lock.
- With `Snapper.storekit` open, **Editor** lets you speed up renewals, turn on Ask to Buy (tests the "pending" path) and fail transactions (tests the error alerts).
- **Offline restore:** buy, turn on Airplane Mode, then use Settings › Restore Purchases. Entitlements cached on the device still unlock Premium.
- **Switching to Lifetime:** buy a subscription, then use Settings › Switch to Lifetime. Buying Lifetime never cancels the subscription; the app says it keeps renewing and offers Manage Subscription. Once auto-renew is off (Manage Subscription, or Debug › StoreKit › Manage Transactions), that guidance goes away, though Premium and the subscription last until the period ends.
- **Promo codes:** `Snapper.storekit` has a *Test Promo Code* on Yearly (one month free). Tap Redeem Code in Settings or at the bottom of the paywall, pick it and redeem: the paywall closes and Premium turns on. Real codes are offer codes made in App Store Connect; the same button takes them.

**Against App Store Connect (sandbox):** in Edit Scheme › Run › Options, set StoreKit Configuration to *None*. Sign in with a Sandbox Apple Account on the iPhone (Settings › Developer › Sandbox Apple Account on iOS 18 and later; Settings › App Store on iOS 17), then run from Xcode or TestFlight.

**Unit tests:** `StoreKitPurchaseServiceTests` uses `SKTestSession` with the same `.storekit` file to check plan loading, the trial, a subscription purchase and a Lifetime purchase and restore. Run them from Xcode (⌘U). Hosted CI runners can't configure StoreKit's test daemon, so CI skips those tests and covers the paywall's purchase, pending and restore paths through `PaywallModelTests`, which uses a fake backend.

## Filters

### Swap, reorder, rename, or move between free and premium (no code)
Edit `Snapper/Resources/Filters/filters.json`:
```json
{ "id": "boardwalk", "name": "Boardwalk", "collection": "disposable", "lut": "boardwalk.cube", "tier": "free" }
```
- **Order:** the order in the file is the swipe order. Original always comes first, followed by the person's favorites.
- **Tier:** `"tier": "free"` or `"premium"`.
- **Hide a look:** add `"enabled": false`.

### Add a new look from any `.cube` file
1. Drop a 3D `.cube` (any size from 2 to 128, 0–1 domain, display-referred sRGB) into `Snapper/Resources/Filters/LUTs/`.
2. Add an entry to `filters.json`.
3. Run `xcodegen generate`.

The app applies cubes with `CIColorCubeWithColorSpace` in sRGB, which matches how editing apps apply `.cube` files.

### Regenerate or tweak Snapper's own looks
Each look is a set of parameters in `tools/lutgen/looks.toml`: white balance, exposure, highlight rolloff, contrast, tone curves, fade, split toning, per-hue saturation, hue and lightness, and skin protection. The file header documents them.

```sh
pip install -r tools/lutgen/requirements.txt
python3 tools/lutgen/lutgen.py build     # write .cube files + test fixture; new looks are added to filters.json as premium
python3 tools/lutgen/lutgen.py review    # contact sheets + report in filter-review/
python3 tools/lutgen/lutgen.py verify    # what CI runs: cubes up to date, quality gates pass
python3 tools/lutgen/lutgen.py build --only boardwalk,cream
```

Every look must pass these quality gates:
- the tone curve never inverts
- shadows aren't crushed and highlights aren't clipped
- Monk-scale skin tones don't drift toward orange, magenta or grey
- smooth gradients don't band

`filter-review/` holds one contact sheet per collection, plus a table for approving or rejecting looks. Put your own photos in `test-photos/` and run `review` again. The current photos are public-domain stand-ins (see `test-photos/README.md`).

A unit test renders reference colours through the app's Core Image pipeline and checks them against the generator's output for every look. That test is what guarantees the contact sheets show what the app renders.

## Set up the subscriptions in App Store Connect

1. **Agreements:** sign the Paid Apps agreement and fill in banking and tax. Subscriptions don't work, even in sandbox, until this is done.
2. **Create the app** with the same bundle ID as `APP_BUNDLE_ID`.
3. **Monetization › Subscriptions:** create a subscription group named **Snapper Premium** and give it a localized display name. Then add two auto-renewable subscriptions to that group:

   | Reference name | Product ID | Duration | Price | Introductory offer |
   |---|---|---|---|---|
   | Premium Yearly | `snapper.premium.yearly` | 1 year | $19.99 | Free trial, 1 week, new subscribers |
   | Premium Monthly | `snapper.premium.monthly` | 1 month | $3.99 | none |

   Give each one a display name and description, and a review screenshot of the paywall (the Simulator works).
4. **Monetization › In-App Purchases:** add a **Non-Consumable** with reference name *Premium Lifetime*, product ID `snapper.premium.lifetime` and price $39.99. Its description should say it covers all current and future looks and tools. Never move what it unlocks behind a subscription later.
5. If you change product IDs or prices, update `AppConfig.swift` and `Config/Snapper.storekit` to match.
6. **First submission:** submit the subscriptions and the Lifetime purchase together with app version 1.0. Select them on the version page under *In-App Purchases and Subscriptions*.
7. **App Information:**
   - Privacy Policy URL: `https://jasonh-1.github.io/snapper/privacy.html`
   - Support URL: `https://jasonh-1.github.io/snapper/support.html`
   - Add `Terms of Use: https://jasonh-1.github.io/snapper/terms.html` to the app description. Apple requires a Terms link in the metadata for auto-renewable subscriptions.
8. **App Privacy:** choose *Data Not Collected*. The app has no analytics, ads or tracking, and the privacy manifest is in `Snapper/Resources/PrivacyInfo.xcprivacy`.
9. **GitHub Pages:** in the repo, go to Settings › Pages, choose *Deploy from a branch*, then `main` and `/docs`.

## Before you submit

- [ ] Fill in the placeholders in `Snapper/App/AppConfig.swift`: developer name, support email, and the App Store ID once the app exists. The ID turns on the "Rate Snapper" deep link.
- [ ] Replace the highlighted placeholders in `docs/*.html` (name, email, governing law), and `APP_STORE_ID` in the landing page's App Store links (`docs/index.html`).
- [ ] Check the sample photos in `Snapper/Resources/Showcase/`. They appear in onboarding, on the paywall, in the look thumbnails and in the Simulator. They're Unsplash photos at 1800 px (credits in `docs/photo-credits.md`); Unsplash includes no model releases, so get a release for the portrait or swap in your own photo shot with consent.
- [ ] Review `filter-review/` with your own test photos and adjust `filters.json`.
- [ ] Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml` for each upload.
- [ ] Set `APP_BUNDLE_ID` and `DEVELOPMENT_TEAM` in `Config/Local.xcconfig` (see Setup). The Lock Screen camera and Control Center control get their own IDs, `<app id>.capture` and `<app id>.controls`; register all three in your developer account.
- [ ] App Review notes: "Onboarding ends with one optional Premium offer; Not Now or × goes straight to the camera. Nine looks, highlights, shadows, the date stamp and one personal preset are free, with watermark-free exports. Premium looks and tools can be previewed free; saving them as they are requires Premium, and any photo can be saved for free without its Premium parts. Presets are under Looks › Presets; batch presets are under Library › Select › Style; frames and layouts are in Finish. On iOS 18, Snapper can be chosen as the Lock Screen and Camera Control camera, and has a Control Center control. The paywall has an × close button. Use a sandbox account to test the subscriptions and the Lifetime purchase."

## Guide videos

Each Snapper Guide topic shows a short looping clip of the feature being used, recorded in the Simulator: `Snapper/Resources/GuideDemos/guide-<topic id>.mp4`. A topic without a clip (Lenses & zoom: the Simulator has one lens) keeps its illustration.

Each clip is scripted as a UI test in `SnapperDemos/GuideDemoTests.swift`, which also directs the camera: `focus` zooms in on the controls in use, `wide` pulls back to the whole phone, `hold` keeps a pause. To record or re-record one, with the iPhone 18 Pro Simulator booted:

```
SIMULATOR_ID=<device id> scripts/record-guide-demo.sh testColorMixer color-mixer
```

It builds the `SnapperGuideDemos` scheme, records the screen while the test runs, and encodes the part between the test's DEMO START and DEMO END marks (`scripts/encode-guide-demo.swift`): 720×900 at 60 fps, the phone on a dark backdrop, pauses shortened, a fade at the loop. Touches show as circles (Debug builds launched with `-SnapperShowTouches YES`).

Every photo in the clips is free to use with no credit or model release: the Unsplash photos in `Snapper/Resources/Showcase/` and crops of them (not the portrait), plus three CC0 / public-domain photos from `test-photos/stand-ins/` (see `docs/photo-credits.md`). The camera shows the café photo in place of the Simulator's usual stand-in, the portrait. The scripts expect the Simulator's Library as `scripts/seed-guide-library.sh` fills it (12 photos in a fixed order; photo 5 is a street at night, unedited) and no personal presets. The import picker shows the Simulator's Photos library, so keep only those photos there too (`PHOTOS=1` adds them). Each script undoes its edits afterwards; if one stops part-way, run `testRestoreState` and then `testPrepareCamera` (in `SnapperDemos`) before recording again.

## How it's built

```
Snapper/
  App/          SnapperApp, AppModel (navigation + wiring), AppSettings, AppConfig, RootView
  Camera/       CaptureService (actor on the session queue), PhotoCapture, PreviewRenderer
                (Metal/Core Image, own queue), CameraModel, CameraView + components, LookPicker
  Filters/      Look/LookLibrary (filters.json), CubeLUT (.cube parser), LUTStore, LookPipeline
  Library/      CaptureLibrary (in-app roll), CaptureStore, PhotoRenderer (exports), Watermark,
                PhotoLibrarySaver (add-only Photos access)
  Review/       ReviewModel + ReviewView (change look/strength, save, share, delete)
  Store/        PurchaseService protocol, StoreKitPurchaseService, PaywallModel + PaywallView
  Onboarding/   OnboardingView
  Settings/     SettingsView, FavoritesView
  CameraLaunch/ SnapperCaptureIntent (shared with both extensions), Lock Screen photo inbox and import
  Resources/    Assets, Info.plist, PrivacyInfo.xcprivacy, Filters/ (filters.json, LUTs/), Showcase/
SnapperCapture/  Lock Screen camera (LockedCameraCapture extension, reuses the camera code)
SnapperControls/ Control Center control (WidgetKit)
SnapperDemos/   UI-test scripts for the Guide's videos (scripts/record-guide-demo.sh)
SnapperTests/   LUT parser, manifest, capture store, export, Core Image vs generator, StoreKit
tools/lutgen/   Look generator, quality gates, contact sheets
docs/           Landing page, Privacy Policy, Terms of Use, Support (GitHub Pages)
```

- **MVVM.** SwiftUI views over `@Observable` models on the main actor. Camera and rendering work never touches the main actor.
- **Threading.** `CaptureService` is an actor whose executor is the capture session queue. Camera frames arrive on the renderer's queue, which draws into the `MTKView`'s Metal layer with backpressure: frames are dropped rather than queued when the GPU is busy. Exports render on the `PhotoRenderer` actor.
- **Preview matches the photo.** Preview frames are rotated and mirrored to match how the photo's orientation is recorded. The capture is the camera's own full-size HEIF, up to 24 MP; see `PhotoCapture.maxMegapixels`. Both pass through `LookPipeline`, which uses the same cube, colour space and strength blend.
- **One file to swap the purchase backend.** The UI only knows `PurchaseService` and `SubscriptionPlan`. To move to RevenueCat, write `RevenueCatPurchaseService` and change one line in `SnapperApp`.
- **Ready for later features.**
  - Video: add a movie output next to `PhotoCapture`; the renderer already processes live frames.
  - Library import: feed `CaptureLibrary.add` from a PHPicker.
  - Translations: UI strings already go through `String(localized:)` / `LocalizedStringKey`, so adding a String Catalog is mechanical.
  - iCloud sync: `CaptureStore` is the single persistence point.
  - Custom looks: looks are data.
  - Pro controls: add them in `CaptureService`.

## CI

`.github/workflows/ci.yml` runs on every push:
- **macOS:** `xcodegen generate`, a Simulator build, a gate that fails on any compiler or asset warning, and the unit tests.
- **Ubuntu:** `lutgen.py verify`.
