# Opening Snapper from Camera Control, the Lock Screen and Control Center

Snapper can be the camera that Camera Control, the Lock Screen and Control Center open (iOS 18 and later). The app itself still supports iOS 17; everything here is behind availability checks, and `LockedCameraCapture` is weak-linked.

## Pieces

| Piece | Where | What it does |
|---|---|---|
| `SnapperCaptureIntent` | `Snapper/CameraLaunch/SnapperCaptureIntent.swift` | The `CameraCaptureIntent` the system uses to open Snapper's camera. It is built into all three targets, as the system requires. Its app context, `SnapperCameraContext`, carries the camera as the person left it (look, swipe order, preset, flash, exposure, front/back camera, aspect ratio, timer, grid, Photo Size, Premium). |
| Lock Screen camera | `SnapperCapture/` (ExtensionKit, `com.apple.securecapture`) | Snapper's own `CameraModel`, `CaptureService` and looks, while the iPhone is locked. Its photos and any setting changes go to the session folder (`LockedCaptureInbox`). The photo button asks the person to unlock, then opens Snapper's Library. |
| Control Center control | `SnapperControls/` (WidgetKit) | A `ControlWidgetButton` that runs the intent. It can also be added to the Lock Screen and the Action button. |
| Camera Control | `CaptureService.updateCameraControl(_:)`, `CameraModel` | A look picker (`AVCaptureIndexPicker`, swipe order from `AppSettings.orderedLooks`) and a ⅓-stop exposure slider (`AVCaptureSlider`, ±2 EV like the slider on screen). Both work in the app and in the Lock Screen camera. Changes made on Camera Control aren't sent back to it, so a fast scroll isn't pulled back. The on-screen controls fade while Camera Control's overlay is up. |
| Import | `Snapper/CameraLaunch/AppModel+LockScreen.swift` | At launch and whenever Snapper becomes active, the Lock Screen photos are added to the Library (and to Photos when auto-save is on, without Premium parts for free users, as with any shot). Snapper then carries on with the look and settings last used on the Lock Screen. A session is cleared only once all of its photos are in the Library. |

Remembered between launches (`AppSettings`): look and preset (as before), plus flash, exposure compensation and front/back camera (`CameraPreferences`). Manual ISO/shutter, manual focus, white balance and zoom still reset, as in the system Camera.

## Size

The Lock Screen camera bundles its own copy of `Resources/Filters` (about 30 MB of `.cube` text, much smaller once compressed in the App Store download), because an extension reads resources from its own bundle. If that matters, try loading LUTs from the containing app's bundle on a device first. It parses only the current look and its neighbours up front (`CameraModel(preloadsEveryLook: false)`) so it starts fast.

## Adding shared code

`project.yml` lists the app files the Lock Screen camera compiles. If a look or camera file starts using a new type from another file, add that file to `SnapperCapture`'s sources, or the extension build fails.

## Checks that need a real iPhone

None of this can run in the Simulator: there is no camera, no Camera Control, and the Lock Screen camera only runs on a locked device. Use an iPhone 16 or later for Camera Control, and the oldest iOS 18 iPhone you have for the rest. Install a build signed with your team (both extensions get their own bundle IDs: `<app id>.capture` and `<app id>.controls`).

- [ ] **Settings › Camera › Camera Control › Launch Camera** lists Snapper. Choose it, lock the phone, press Camera Control: the Lock Screen camera opens with the look, flash, exposure, camera, aspect ratio, grid and timer last used in Snapper.
- [ ] Press Camera Control again to take a photo (with the Volume & Camera Control shutter on in Snapper's settings). Take several, including with the front camera, a Premium look without Premium, and a preset.
- [ ] Unlock from the photo button: Snapper opens to the Library with those photos (newest first, with their look and crop), and auto-save puts them in Photos (free version plus the one-time explanation for a Premium look). Opening Snapper some other way imports them too. Nothing is imported twice.
- [ ] Change the look on the Lock Screen, take no photo, open Snapper: it carries on with that look. Lock again: the Lock Screen camera opens on it too. (If the extension may not update the app context, the second step only works after Snapper has been opened; check the console for "Sharing with the Lock Screen camera failed".)
- [ ] Add **Snapper Camera** in Control Center, on the Lock Screen and on the Action button. Locked: it opens the Lock Screen camera. Unlocked: it opens Snapper on the camera.
- [ ] Swipe the Lock Screen to the right with Snapper set as the Lock Screen camera, if offered.
- [ ] In Snapper, light-press Camera Control: **Looks** and **Exposure** appear. Scrolling Looks changes the live look in swipe order, favourites first, with the name banner. Edit favourites and check the order again. Exposure moves in ⅓ stops and matches the on-screen slider both ways; it is disabled while ISO & Shutter is manual. Both work in the Lock Screen camera. The on-screen buttons fade while the Camera Control overlay is up.
- [ ] Flip to the front camera, set flash to Auto and exposure to +0.7, force quit and relaunch: all three are kept. Do the same for the Lock Screen camera.
- [ ] The Lock Screen camera looks like Snapper's: unlock from it and the top bar, preview, look dial, shutter and Flip stay where they were. On the smallest iOS 18 iPhone, with a 10s timer, an exposure change and a Premium look without Premium, nothing overlaps; with a preset from Snapper the dial shares its row with the style readout, which goes after a swipe. VoiceOver: swiping up or down on the dial changes the look.
- [ ] Camera permission never granted: the Lock Screen camera explains and opens Snapper.
- [ ] Measure the Lock Screen camera's launch time and memory during 50 shots and fast look scrolling.
- [ ] On an iOS 17 device, Snapper still launches and works (the extensions are simply absent).
