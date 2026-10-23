# Filter expansion: 47 to 87

Research checked October 22, 2026. This is a product hypothesis based on public
signals, not a representative survey of Snapper customers or proof of willingness
to pay. Competitor filters and film-stock recipes were not copied.

## Evidence and direction

- [VSCO Capture](https://www.vsco.co/capture) advertises over 50 live presets;
  [the main VSCO editor](https://www.vsco.co/learn/getting-started-vsco) offers
  over 200. A catalog of 80–100 is plausible, but the number alone is not a
  differentiation or pricing argument.
- [VSCO's own popular-filter examples](https://www.vsco.co/features/photo-filters)
  span warm analog, classic black and white, and polished natural color. This
  supports adding useful everyday choices alongside Snapper's stronger effects.
- [Fuji X Weekly's January–July 2026 page-view ranking](https://fujixweekly.com/2026/08/03/top-26-most-popular-fujifilm-recipes-of-2026-so-far-summer-edition/)
  puts Reggie's Portra, Kodachrome 64 and Kodak Gold 200 first, second and third;
  Tri-X 400 is seventh. These are website views among Fujifilm enthusiasts,
  not actual filter-use counts or a ranking of iPhone customer preferences.
- [Apple's Dazz Cam editorial](https://apps.apple.com/au/iphone/story/id1804863178)
  highlights direct-flash digicam, 35mm, soft medium-format and instant-print
  aesthetics. Snapper already covers neon, disposable and flash looks well;
  expand instant prints and everyday film before adding more neon variants.

## Catalog

| Addition | Looks | Purpose |
| --- | ---: | --- |
| Everyday Film | 12 | Natural negative color, travel slides, olive foliage, warm daylight and clean cool scenes |
| Black & White | 8 | Neutral street, documentary, hard light, soft portrait, silver and cyan-toned monochrome |
| Cinema | 8 | Daylight and interior palettes, muted rain, warm desert, lavender dusk and restrained silver color |
| Instant Prints | 6 | Pastel, paper white, amber, mint, rose and faded-print color |
| Digicam additions | 6 | Day/night CCD color, shopping-mall light, soft indoor color, party color and bold primaries |
| **Total added** | **40** | **87 looks across 10 collections, excluding Original** |

The existing 47 IDs, tiers and transforms stay intact. Day Roll, Graphite,
Daybreak and Peel are free, giving 13 free looks and at least one free entry
in every collection. The remaining 74 require Premium to export, following
the existing access rules.

These additions are original color transforms, not calibrated film-stock
emulations. They deliberately avoid baking grain, flash, borders or blur into
every look; Snapper's existing editing/finishing tools remain separate. A color
preset cannot recreate actual flash lighting or recover clipped sensor detail.

## Finding and comparing looks

Keep Favorites, Recent, collection chips and search. Add all 40 descriptions
and shooting tips to search, but feature only four new starting points so the
guidance carousel does not become a second 87-item catalog. Each new collection
has a bundled sample image in the app. Website previews for the new looks are
prepared separately; this change updates the app catalog only.

## Validation and release checks

- Rebuild and verify all cubes using `tools/lutgen/lutgen.py`; retain the existing
  gates for shadow/highlight separation, skin hue/chroma, monotonic tone and
  gradient banding. Do not weaken thresholds to increase the count.
- Refresh the reference fixture: the existing Core Image comparison test now
  covers all 87 transforms. Existing manifest/sample tests cover new resources.
- Review new looks on portraits, daylight, food and night scenes; compare their
  nearest existing looks before accepting them. Numerical separation alone is
  not proof of useful visual variety.
- On iPhone, check picker scrolling/thumbnail memory, front/rear camera preview,
  strength adjustment, full-resolution export and Lock Screen selection.
- Ask a small beta group to choose favorites in blind comparisons on their own
  photos. Remove weak/redundant looks even if this lowers the headline count.
  Add further collections only when repeated requests identify a clear gap.

Catalog size supports discovery; reliable capture, strong favorites and good
results are the subscription value. Do not raise the price solely for 40 additions.
