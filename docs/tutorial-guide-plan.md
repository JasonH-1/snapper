# Snapper tutorial and guide plan

Status: the standalone searchable Guide is implemented in Settings with 16 topics, labeled diagrams, interactive sample-photo comparisons and shortcuts to Camera, Looks, Library and My Styles. The optional guided walkthrough and contextual tips remain future phases. Based on the current camera, Library, editor, presets and Settings code. The accompanying UI change removes the collapsing Library navigation title while retaining the selection count and toolbar actions.

## Experience

Offer a short, optional first-photo walkthrough, contextual help, and a searchable Guide in Settings. Keep the camera usable immediately: Skip and Done are always available, tutorials are replayable, and completing one is never required to take or export a photo. Extend the existing onboarding instead of presenting a second mandatory sequence.

Use plain language: introduce “Looks (filters)” once, then use the app's actual labels. Every topic answers what the control does, when to use it, how to try it, and how to return to Auto or reset. Use a bundled example photo for editing exercises so people do not have to grant Photos access or modify personal photos to learn.

## First photo: five short steps

1. **Choose a look.** Highlight Looks; choose a free look and show the live preview. Swiping is an optional shortcut, never the only instruction.
2. **Focus and brighten.** Tap a subject to focus; open Exposure and demonstrate a small adjustment. Provide Reset. Explain that a brighter preview can lose detail in bright areas.
3. **Take a photo.** Highlight the shutter. Let users take a real photo or skip to an example; never trigger capture automatically.
4. **Make it yours.** Open the photo in Library, change look strength and demonstrate holding to compare. Explain that edits remain editable in Snapper.
5. **Save or share.** Explain Snapper Library versus Apple's Photos app. Let the user choose Save or Share; request permission only when needed. Show a completion confirmation and a link to the full Guide.

If camera permission is denied, offer the example-photo path and instructions for changing permission. If the user dismisses a sheet, backgrounds the app or leaves a screen, pause the walkthrough and allow resuming or skipping.

## Complete guide contents

| Chapter | Topics and practical exercise |
| --- | --- |
| Camera basics | Shutter, front/rear Flip, flash modes, zoom buttons and pinch zoom, framing ratios, Grid, Level, timer and cancelling it; take a level photo using the grid. |
| Focus and exposure | Tap to focus, AE/AF lock and release, exposure compensation and reset, manual focus, ISO and shutter speed; explain noise and motion blur with an example. Show only controls supported by the active camera. |
| White balance | Auto, Daylight, Cloudy, Tungsten and Fluorescent; choose for the light source, not the desired filter effect. Explain that rear presets may switch to the main 1× lens, zoom becomes digital, focus/exposure reset, and Auto restores normal lens switching and previous zoom. Explain unavailable controls without promising support on every phone. |
| Looks and discovery | Looks versus saved styles, collections, search, All/Free/Favorites, starring looks, occasion suggestions and live preview. Find and favorite one look; explain Premium badges before a paid save is attempted. |
| Library | Open latest photo, import chosen photos, date groups and filters, open editor, selection and Select All, batch actions, delete confirmation, and return to camera. Clarify that import copies a photo into Snapper. |
| Editing | Looks and strength; brightness, contrast, saturation, warmth, fade and grain; crop ratios, straighten, rotate and flip; compare, Undo/Redo and Reset. Teach one example with a visible before/after. Do not imply editing white balance recovers lost image data. |
| My Styles | Save, name, apply, rename and delete a preset; shoot with a style; copy/paste a photo style; import/export .snapperpreset files and share style cards. Explain exactly what transfers: look, strength and adjustments, not crop or finish. Explain the free preset limit and preserve existing styles when Premium expires. |
| Style a Set | Select photos, batch look/style application, copy/paste to a set, finishing and last-batch undo. Explain paid actions before applying them. No automatic selection of all photos. |
| Finish and export | Frame choices and border size, export layouts, date stamp and date selection, Save to Photos and Share. Explain that export layout fits the cropped image inside a canvas; distinguish it from cropping. Premium finish previews are free but saving requires entitlement. |
| Settings and troubleshooting | Automatic saving, also saving original, photo size, HEIF/JPEG, mirrored selfies, volume shutter support, permissions, restore purchases, support and storage cleanup. Explain cleanup's consequence before the destructive action and distinguish Snapper storage from Photos. |

## Contextual help

Add a small Help button to Camera Options, Looks, editor tools and My Styles, opening the relevant Guide topic. Keep the camera toolbar uncluttered. Use one dismissible first-use tip for unfamiliar behavior: AE/AF lock, compare-original, saving edits to Photos, and the white-balance main-lens switch. Never repeatedly display a dismissed tip after every launch.

Example copy:

- **Exposure:** “Make the photo brighter or darker. Start near 0 and adjust until your subject looks right.”
- **White balance:** “Match the light around you. Auto is a good starting point; Tungsten helps with warm indoor lighting.”
- **Rear manual white balance:** “These presets use the main lens. Choose Auto to bring back 0.5× and automatic lens switching.”
- **Saved styles:** “Reuse your look and adjustments on another photo. Crop and frames stay with each photo.”
- **Saving:** “Your edits are kept in Snapper. Save adds an edited copy to Photos.”

## Implementation order

1. Build the searchable Guide and all chapter content, accessible through Settings → Guide. Add accessible headings, real UI labels, capability-aware notes and a reusable topic detail view.
2. Link contextual Help from each relevant screen; add the saving and main-lens explanations first.
3. Implement the optional five-step walkthrough using stable IDs for real controls. Store completion and dismissed-tip versions locally. Wait for actual screen transitions and user actions, not fixed delays. Avoid full-screen overlays that intercept working controls.
4. Add bundled visual examples for exposure, ISO/shutter, white balance and edit comparisons. Adapt to Dynamic Type, VoiceOver and Reduce Motion; do not rely on color, gesture-only interaction or animation to convey the lesson.

Suggested code organization: GuideTopic/GuideCatalog for local content and search metadata, GuideView/GuideTopicView for presentation, and TutorialCoordinator for walkthrough state. Screen views expose specific help routes and stable target anchors. Keep guide progress separate from camera settings and photo edits. Do not add a remote content service or analytics dependency.

## Acceptance checks

- Every currently exposed camera, editor, Library, preset and Settings feature has a topic; verify descriptions against actual behavior before release.
- A new user can take, edit and save a free photo without completing a tutorial or encountering a mandatory upgrade.
- Guide search finds familiar words such as filter, blurry, yellow, brightness, selfie and save; aliases lead to the relevant topics.
- Skip, replay, resume, permission denial, no-camera demo mode and disabled hardware features behave correctly.
- Tips never obscure the shutter or intercept button edges, zoom, sliders or preview focus. Test on a small iPhone and at large text sizes.
- Simulated examples never change or delete real photos. Paid features are clearly marked; prices come from the actual purchase UI rather than hardcoded guide text.
- For the Library title removal: scroll down/up, enter and exit selection, import, open the editor and return. No collapsing Library title; selection count, Camera, Select and Import remain usable.

Do not call the guide finished until the camera walkthrough and white-balance chapter are verified on a physical iPhone. Simulator checks can cover navigation, search, tutorial state and example-photo editing.
