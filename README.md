# Snapper

An iPhone camera with live film looks, sold with an auto-renewing subscription.

- **Live preview through every look:** Core Image + Metal, 30 fps, off the main thread. Swipe the preview to change looks, with a live split as you drag.
- **What you see is what you save:** the preview, the full-resolution photo and every export go through the same pipeline (`LookPipeline`).
- **30 original looks in three collections:** Disposable, Neon Nights and Soft Portrait. Six are free.
- **Looks are data:** each look is a 33-point `.cube` file listed in `filters.json`, and a Python tool generates and quality-checks them.
- **StoreKit 2:** monthly and yearly plans (7-day trial on yearly). There are no accounts and no backend; the Apple ID is the account.

Requirements: Xcode 26 or later, iOS 17+, iPhone only. CI builds with Xcode 26.6 on `macos-latest`.

---

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
4. Pick your iPhone and press Run. First launch shows onboarding, the camera and Photos permissions, then the paywall once (close it to continue).

Run `xcodegen generate` again whenever you add, remove or rename files. The `.xcodeproj` is generated and not committed.

**In the Simulator** there's no camera, so a demo photo stands in for the live feed. Swiping, the shutter, review, saving and the paywall all work, which makes it handy for screenshots.

## Test purchases

**Locally, no App Store Connect needed.** The `Snapper` scheme runs with `Config/Snapper.storekit`, so purchases are simulated on device or in the Simulator.
- Plans: `snapper.premium.monthly` ($3.99/month) and `snapper.premium.yearly` ($19.99/year, 1-week free trial).
- **Debug › StoreKit › Manage Transactions** lets you refund, expire or cancel a subscription and watch the app re-lock.
- With `Snapper.storekit` open, **Editor** lets you speed up renewals, turn on Ask to Buy (tests the "pending" path) and fail transactions (tests the error alerts).
- **Offline restore:** buy, turn on Airplane Mode, then use Settings › Restore Purchases. Entitlements cached on the device still unlock Premium.

**Against App Store Connect (sandbox):** in Edit Scheme › Run › Options, set StoreKit Configuration to *None*. Sign in with a Sandbox Apple Account on the iPhone (Settings › Developer › Sandbox Apple Account on iOS 18 and later; Settings › App Store on iOS 17), then run from Xcode or TestFlight.

**Unit tests:** `StoreKitPurchaseServiceTests` uses `SKTestSession` with the same `.storekit` file to check plan loading, the trial and a purchase. Run them from Xcode (⌘U). Hosted CI runners can't configure StoreKit's test daemon, so CI skips those two tests and covers the paywall's purchase, pending and restore paths through `PaywallModelTests`, which uses a fake backend.

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
4. If you change product IDs or prices, update `AppConfig.swift` and `Config/Snapper.storekit` to match.
5. **First submission:** submit the subscriptions together with app version 1.0. Select them on the version page under *In-App Purchases and Subscriptions*.
6. **App Information:**
   - Privacy Policy URL: `https://jasonh-1.github.io/snapper/privacy.html`
   - Support URL: `https://jasonh-1.github.io/snapper/support.html`
   - Add `Terms of Use: https://jasonh-1.github.io/snapper/terms.html` to the app description. Apple requires a Terms link in the metadata for auto-renewable subscriptions.
7. **App Privacy:** choose *Data Not Collected*. The app has no analytics, ads or tracking, and the privacy manifest is in `Snapper/Resources/PrivacyInfo.xcprivacy`.
8. **GitHub Pages:** in the repo, go to Settings › Pages, choose *Deploy from a branch*, then `main` and `/docs`.

## Before you submit

- [ ] Fill in the placeholders in `Snapper/App/AppConfig.swift`: developer name, support email, and the App Store ID once the app exists. The ID turns on the "Rate Snapper" deep link.
- [ ] Replace the highlighted placeholders in `docs/*.html` (name, email, governing law).
- [ ] Replace `Snapper/Resources/Showcase/*.jpg` with your own high-resolution photos (1600 px or more) shot with consent. They appear in onboarding, on the paywall, and in the Simulator. The current ones are small public-domain stand-ins.
- [ ] Review `filter-review/` with your own test photos and adjust `filters.json`.
- [ ] Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml` for each upload.
- [ ] App Review notes: "The paywall appears once after onboarding and can be closed with the × button. Premium looks can be previewed for free; saving or sharing them requires Premium. Use a sandbox account to test the subscription."

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
  Resources/    Assets, Info.plist, PrivacyInfo.xcprivacy, Filters/ (filters.json, LUTs/), Showcase/
SnapperTests/   LUT parser, manifest, capture store, export, Core Image vs generator, StoreKit
tools/lutgen/   Look generator, quality gates, contact sheets
docs/           Privacy Policy, Terms of Use, Support (GitHub Pages)
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
