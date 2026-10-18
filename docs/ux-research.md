# Snapper UI/UX implementation brief

Research date: October 17, 2026. This is a code-based interface audit and desk research, not a usability study. The changes need visual and task-based testing on iPhone before release.

## Findings and implemented response

| Finding in Snapper | Implemented response | Intended benefit |
| --- | --- | --- |
| Look discovery begins with several vertically stacked text-heavy recommendations. | Horizontal photo-led signature cards, then the catalog. | More visual character and less scrolling before choosing. |
| A 41-look catalog is difficult to scan for a specific use. | Search names, collection names/taglines, and shooting guidance; All/Free/Favorites scopes with explicit empty states. | Find a style without remembering its collection; understand the free offering. |
| Camera look and preset destinations compete in one small caption row. | Separate labeled Looks and My Styles cards; show the active choice and a disclosure cue; label Flip. | Explain what each control opens while retaining the photo and shutter as the focus. |
| Import is represented by an icon; batch finishing sits behind Select then Style. | Library entry cards for latest photo, Import Photos, and Style a Set; contextual selection guidance. | Make the existing workflows visible at entry. |
| Reusing an edit requires saving a named preset. | Session-only Copy/Paste Style, available for the latest photo, photo menus, and selected sets, plus a clipboard banner. | Reuse an edit quickly without managing a preset. |
| The four editor tools are compressed into a segmented control. | Icon-and-label tool rail with a filled selected state. | Clarify tool purpose and selection. |
| Flat black surfaces provide little hierarchy. | Charcoal canvas, raised cards, photographic discovery, serif style names, and consistent yellow emphasis. | Add visual depth while keeping photos central. |

Copy/Paste Style includes look, strength, and color adjustments only. Each destination keeps its crop, frame, layout, and date. Single-photo paste is available without Premium; batch paste retains the Premium gate. Premium looks still require Premium to export. The clipboard lasts for the current Library session. Existing undo protections skip later edits.

## Research sources and interpretation

- [Apple: Explore navigation design for iOS](https://developer.apple.com/videos/play/wwdc2022/10001/): familiar navigation patterns and clear titles/labels help orientation. Application: explicit destination labels and recognizable symbols. This pass retains the camera-first navigation; it does not introduce an imitation tab bar for modal actions.
- [Apple: Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars): provide convenient access to frequent commands and distinguish actions from top-level navigation. Application: direct import and set-selection commands; editor controls stay local to the photo.
- [Apple: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility): support readable text, VoiceOver, and state indicators beyond color. Application: semantic look buttons, separate 44-point favorite controls, selected checkmarks, system text styles, and icon/text tool labels. These changes are not a full accessibility certification.
- [Darkroom product](https://darkroom.co/): describes reversible edits, copy/paste, batch workflows, and searchable preset discovery. Application: prioritize reusable edits and findability. Snapper still imports its own copies; direct Apple Photos editing is not implemented here.
- [VSCO Capture](https://www.vsco.co/capture): describes visible live presets, adjustable creative controls, and a camera-to-edit workflow. Application: show the active look and personal style close to capture controls. No competitor imagery, brand assets, or preset recipes were copied.

These sources inform design hypotheses; they do not establish that this redesign improves retention or conversion.

## Next feature priorities

1. Validate this pass with 5–10 testers: find a free daylight look, import a photo, edit it, copy its style to another photo, style a set, and export. Record assistance needed, wrong turns, and completion time.
2. Add highlights/shadows and a vignette only after defining shared live/export rendering, numeric limits, preset compatibility, and image-quality acceptance fixtures. These are proposed, not implemented.
3. Consider native persistent Camera/Library/Styles navigation if testing shows people still lose their place. That requires a dedicated navigation/state-lifecycle change.
4. Consider albums and photo favorites if testers accumulate enough photos to need organization. Avoid building account, community, or cloud workflows before validating this need.

## Device acceptance checklist

- iOS 17 and current iOS; small and large iPhones; portrait and landscape.
- Default and accessibility text sizes: camera cards, search scopes, editor tools, Library calls to action.
- VoiceOver: select a look, independently star it, switch editor tools, copy/paste, save/share.
- Confirm the visible photo crop matches output when the larger camera control area overlaps the preview on short screens.
- Search while scrolled deep in the catalog; change scopes; clear search; empty favorites; premium export affordances.
- Confirm latest-photo card and grid thumbnails match after editing; selecting a set preserves targets.
- Paste to one photo, a Premium set, and a free-plan set; undo; edit a destination before undo; delete a destination.
- Measure camera responsiveness and rendering after repeated sheet transitions.
