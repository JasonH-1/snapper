# Advanced photo tools

## Included in this release

- Adjust: highlights, shadows, bloom, halation and vignette, in addition to the existing sliders.
- Color: hue, saturation and luminance for seven overlapping color bands.
- Selective: on-device foreground detection with separate subject/background brightness, saturation and warmth.
- Collections: Golden Hour, After Dark and Quiet Days, with nine recipes, rendered samples and shooting tips. These combine existing LUTs with the new tools; they are not nine new LUTs.
- Guide: searchable instructions for all four additions, with interactive color and bloom examples.

The new tools can be previewed without a subscription. Exporting a recipe that uses them requires Premium, including camera automatic saving, editor Save/Share and Library batch exports. Originals remain editable in Snapper. No video, ads or redemption-code backend is included.

## Storage and rendering

Old recipes decode with neutral defaults for the new fields. Recipes store all settings; changing a collection later does not alter existing photos. Portable presets with advanced adjustments use format version 2 so older apps reject them instead of silently dropping settings. Basic presets remain version 1. Import validates ranges and color band names.

Presets carry global tone, color and film settings. Crop, finishing and selective edits stay with the destination photo. The live camera, editor and export use the same global adjustment pipeline. Effects are additive to any film effects already in the base look.

Selective detection uses Vision's foreground instance mask request on the original's oriented, 1024-pixel proxy, off the main actor. All detected foreground instances form a single subject area. A bounded, memory-only mask cache is shared by preview and export; masks are regenerated after app restart. Masks receive exactly the photo's crop, rotation and flip, then scale for export. There is no mask brush or individual instance selection. Fine hair, transparent objects, small subjects and large exports need device QA; detection can fail. Exports with active selective edits fail explicitly if a mask cannot be generated. Retry or reset is available in Selective.

## Adding a future collection

1. Add a release to `CuratedCollection.releases` with a new stable collection ID and unique style IDs.
2. Use installed look IDs and valid adjustment ranges. Write a distinct shooting tip for each recipe.
3. Inspect each recipe on several real photos, including skin tones and low-light scenes. The cards render the bundled sample using the exact recipe.
4. Run the curated catalog tests and ship an app update. There is no promised release cadence or remote content service.

## Device checks before release

- Run on an iPhone with a freshly generated Xcode project. Open a pre-update Library photo and an old preset; check their appearance and export.
- Check editor tabs, tool scrolling, slider labels and buttons on a small screen and with large Dynamic Type. Use VoiceOver to change color bands and selective areas.
- Adjust highlights and shadows on clipped and unclipped photos; compare preview and full-size export. Check bloom and halation on lights at night and vignette on both portrait and landscape photos.
- Try selective edits on a person, pet, object, multiple subjects and a scene without a clear foreground. Check hair/edges, crop, rotation, flip, undo, relaunch and full-resolution exports. If detection fails, verify Retry and Reset and confirm export reports the problem.
- Apply a collection in camera and editor. Change to another look to clear the camera recipe. Save/share/import an advanced preset and apply it to another photo; ensure selective edits do not transfer.
- Check free, subscribed and expired access. Free previews must work. Premium export gating must cover automatic camera save, editor Save/Share, style cards and Library exports. Removing advanced edits from a free look must restore free export.
- Run StoreKit purchase/restore integration tests in local Xcode; hosted CI skips those two tests.

Automated tests cover legacy decoding, recipe and preset round trips, validation, selected color behavior, tone/effect pixels, selective mask alignment, export failure, preview/export consistency, undo and entitlement behavior. They use deterministic masks and do not certify Vision accuracy or physical-device performance.
