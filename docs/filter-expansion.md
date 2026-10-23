# Filter expansion: 47 to 69

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
| Everyday Film | 8 | Soft daylight, golden sun, cool greens, warm walls, mountain air, late sun, beach and slide-style travel color |
| Black & White | 5 | Everyday street, hard-light noir, airy low-contrast, silver and cyan-toned monochrome |
| Cinema | 5 | Low-sun peach and blue, grey-day streets, lamplit interiors, golden-hour copper and bleach-style silver |
| Instant Prints | 6 | Peel-apart, pastel, warm keepsake, mint, rose and faded-print color |
| Digicam additions | 2 | Shop-light color and bold primaries, with Digicam's sharpening and sensor grain |
| **Total added** | **26** | **69 looks across 10 collections, excluding Original, after removing 4 original duplicates** |

Sunday, Graphite, Daybreak and Peel are free, giving 13 free looks and at
least one free entry in every collection. The remaining 56 require Premium to
export, following the existing access rules.

The film, black-and-white, cinema and instant-print additions are original
color transforms, not calibrated film-stock emulations. They deliberately
avoid baking grain, flash, borders or blur into every look; Snapper's existing
editing/finishing tools remain separate. The two Digicam additions carry the
in-camera sharpening and sensor grain every other Digicam look has, so the
collection stays consistent. A color preset cannot recreate actual flash
lighting or recover clipped sensor detail.

## Pruning

The first pass added 40 looks (87 in total). Many were hard to tell apart, so
every look was rendered on six sample photos (portrait, beach, street at
night, café, arcade, cake) and compared as the mean color difference in Oklab
(about 0.02 is a just-visible difference), then checked by eye on contact
sheets. A look was removed when:

- **It barely changes a photo:** Day Roll and Harbor (0.014 and 0.016 from
  the original; Amber 100, at 0.017, stays because its faded haze is clear
  by eye).
- **It nearly duplicates another look's color:** for a new look, closer than
  0.013, or 0.020 within black and white, where only lightness differs; for
  an original look, closer than 0.010. Effects count as a difference: Y2K's
  sensor effects set it apart from Travelogue, but a Digicam addition would
  get the same kind of effects as its twin (Red Eye matches Afterparty's
  color, and Afterparty already adds the flash). The better-known look of
  each pair was kept.

| Removed | Closest kept look | Difference |
| --- | --- | ---: |
| Peach (original) | Honey | 0.003 |
| Studio (original) | Honey | 0.007 |
| Taxi (original) | Lantern | 0.007 |
| Downpour (original) | Last Train | 0.008 |
| Market | Honey | 0.012 |
| Orchard | Velvet | 0.010 |
| Newsprint | Noir | 0.014 |
| Silhouette | Noir | 0.018 |
| Carbon | Noir | 0.019 |
| Desert | Copper | 0.009 |
| Dusk | Velvet | 0.012 |
| Moss | Amber 100 | 0.012 |
| CCD Day | Travelogue | 0.010 |
| CCD Night | Arcade | 0.009 |
| Red Eye | Afterparty (same color; Afterparty adds the flash) | 0.010 |
| Slumber | Petal | 0.012 |

The original catalog's own looks sit a median 0.015 from their nearest
neighbour, so the remaining looks are at least as distinct as before. None of
the removed looks are used by the Guide's demo scripts, the curated
collections or the website's hero clip. The website still lists Peach,
Studio, Taxi and Downpour until it's updated for the new collections.

## Finding and comparing looks

Keep Favorites, Recent, collection chips and search. Add every new look's description
and shooting tip to search, but feature only four new starting points so the
guidance carousel does not become a second catalog. Each new collection
has a bundled sample image in the app. Website previews for the new looks are
prepared separately; this change updates the app catalog only.

## Validation and release checks

- Rebuild and verify all cubes using `tools/lutgen/lutgen.py`; retain the existing
  gates for shadow/highlight separation, skin hue/chroma, monotonic tone and
  gradient banding. Do not weaken thresholds to increase the count.
- Refresh the reference fixture: the existing Core Image comparison test now
  covers all 70 transforms. Existing manifest/sample tests cover new resources.
- Review new looks on portraits, daylight, food and night scenes; compare their
  nearest existing looks before accepting them. Numerical separation alone is
  not proof of useful visual variety.
- On iPhone, check picker scrolling/thumbnail memory, front/rear camera preview,
  strength adjustment, full-resolution export and Lock Screen selection.
- Ask a small beta group to choose favorites in blind comparisons on their own
  photos. Remove weak/redundant looks even if this lowers the headline count.
  Add further collections only when repeated requests identify a clear gap.

Catalog size supports discovery; reliable capture, strong favorites and good
results are the subscription value. Do not raise the price solely for these additions.
