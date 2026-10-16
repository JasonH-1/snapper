# Snapper release acceptance

This branch implements the proposed $19.99/year product package; it does not establish demand, change live App Store Connect products, or approve a public release.

## Required owner inputs

- [ ] Set the developer/publisher name and real monitored support email in `AppConfig.swift` and `docs/*.html`. Confirm the terms' governing-law placeholder. Do not guess these identities or legal terms.
- [ ] Set the App Store ID when it exists; configure the monthly/yearly products and localized benefits to match the app.
- [ ] Replace showcase stand-ins with owned/permissioned original photos (at least 1600px on the long edge). Keep consent/licensing records. Do not upscale the current samples and call them new originals.
- [ ] Confirm the privacy/support/terms pages are deployed and accessible.

Run `python3 scripts/check-release.py` to report unresolved configuration and showcase checks. It deliberately fails until the required inputs are supplied; it is not part of ordinary development CI.

## Photographic acceptance: five signature looks

These looks are featured with tips, not newly validated against human subjects. No LUT changes are justified solely by synthetic charts. Use original iPhone photos and compare final on-device exports, not just Python contact sheets (which omit spatial effects).

| Look | Intended use | Required scenes |
|---|---|---|
| Boardwalk | Warm everyday/travel print | Daylight faces, greenery, sky, open shade |
| Flashbulb | Friends and nights out | Direct flash, mixed indoor light, multiple skin tones |
| Cream | Soft portraits | Window light, open shade, light and dark skin, white clothing |
| Afterglow | Dusk and city lights | Faces near neon, mixed colour temperatures, bright signs |
| Halo | Highlight glow and texture | Backlight, specular highlights, low-light faces |

- [ ] Compare 100% and reduced strength on every scene, including darker skin tones. Reject unwanted colour casts, clipped facial highlights, banding, distracting glow or repetitive grain.
- [ ] Compare unlabeled outputs with the chosen competitors; record preferences and reasons from target users.
- [ ] Only then tune `tools/lutgen/looks.toml`, rebuild, run `verify`, review output and commit LUTs plus fixtures together.

## Device and editing checks

- [ ] Test the oldest supported available iPhone plus a recent model, in portrait/landscape and at the largest accessibility text sizes.
- [ ] Time cold launch, first usable preview and shutter-to-save. Run repeated shots for 10 minutes and check heat, memory, dropped frames and interruptions. Capture a baseline before accepting regressions.
- [ ] Check all six free looks export without a watermark through automatic save, editor save/share and batch save/share.
- [ ] On a fresh install, onboarding opens the camera; no automatic purchase screen blocks the first photo. Denied Photos access must not trigger a successful-save offer.
- [ ] Save a preset, relaunch, rename, duplicate, delete and apply it. Crops, rotations and frames must stay unchanged. An invalid name must not erase anything.
- [ ] Apply a preset to a mixed portrait/landscape batch. Undo it. Edit one photo after the batch and verify batch undo preserves that later edit.
- [ ] Check white/cream/black/instant frames, each layout and border extremes. Compare saved JPEG and HEIC against the preview. Verify date placement and imported-photo date correction. Check no extra crop or unexpected stretching.
- [ ] Crop after adding a frame, undo/redo finishing, relaunch, and confirm recipes still match.

## Purchases and subscription changes

Use the checked-in StoreKit configuration locally, then validate real products in App Store Connect sandbox/TestFlight.

- [ ] Load products, monthly purchase, yearly trial, pending/Ask to Buy, cancellation, failure, restore and offline cached entitlements.
- [ ] With Premium, save several presets and photos with finishing. Expire/refund Premium: keep all data, allow choosing one free preset, block exports of premium looks/finishing and block full batch preset application.
- [ ] Remove finishing/select a free look: export must work again without paying.
- [ ] Renew/restore Premium: all saved presets and finishing exports work without recreation.
- [ ] Verify prices/renewal terms are localized from StoreKit and purchase buttons cannot double-submit.

## Continuing value and launch validation

- Start with the five signature looks plus the existing collection catalog. Include new premium collections released while subscribed, without promising an unproven cadence.
- Before each collection: pick a shooting need, collect representative originals, tune/review looks, validate on device, add sample photos and useful shooting tips, then ship an app update.
- For the initial two-week test with 20–30 target users, record which looks get exported, whether people return without reminders, actual purchase results after launch, and why they choose Snapper. Consent-based interviews and App Store reporting can start this without adding tracking SDKs.
- Revisit pricing after evidence. A successful build is not evidence that the subscription is commercially validated.
