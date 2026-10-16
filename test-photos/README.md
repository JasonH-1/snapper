# Test photos

`tools/lutgen/lutgen.py review` applies every look to every image in this folder
(including subfolders) and writes the contact sheets to `filter-review/`.

## What's here now

`stand-ins/` holds public-domain / CC0 placeholders, because no photos were
provided yet:

| File | Source | License |
|---|---|---|
| `portrait-astronaut.jpg` | Eileen Collins, NASA (via scikit-image) | Public domain |
| `portrait-hopper.jpg` | Grace Hopper, U.S. Navy (via Matplotlib) | Public domain |
| `food-coffee.jpg` | Rachel Michetti (via scikit-image) | CC0 |
| `pet-cat.jpg` | Stefan van der Walt (via scikit-image) | CC0 |
| `outdoor-launch.jpg` | SpaceX (via scikit-image) | Public domain |

They are small (≤ 640 px) and both portraits are of light-skinned people, so the
review also includes synthetic charts (Monk Skin Tone Scale spheres, a colour
checker with gradients, and a neon night scene), which the quality gates
measure directly.

`night-city/` holds real night scenes (signs, lit windows, reflections) for the
Neon Nights and Overclock looks, whose glow and fringing only show on bright
light. They come from Wikimedia Commons and are used under Creative Commons
licences that require credit:

| File | Original | Author | License | Changes |
|---|---|---|---|---|
| `chongqing-nightscape.jpg` | [Chongqing Nightscape](https://commons.wikimedia.org/wiki/File:Chongqing_Nightscape.jpg) | Jay Huang | [CC BY 2.0](https://creativecommons.org/licenses/by/2.0/) | Renamed |
| `chongqing-yuzhong.jpg` | [Chongqing Night Yuzhong](https://commons.wikimedia.org/wiki/File:Chongqing_Night_Yuzhong.jpg) | Jonipoon | [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/) | Renamed |
| `times-square-2012.jpg` | [Times Square at Night](https://commons.wikimedia.org/wiki/File:Times_Square_at_Night_(7823232896).jpg) | Stuart Sevastos | [CC BY 2.0](https://creativecommons.org/licenses/by/2.0/) | Renamed |
| `times-square-2013.jpg` | [1 times square night 2013](https://commons.wikimedia.org/wiki/File:1_times_square_night_2013.jpg) | chensiyuan | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) | Renamed, resized to 2000 px |

`times-square-2013.jpg` is share-alike: anything made from it, such as a
contact sheet in `filter-review/`, must also be shared under CC BY-SA 4.0 with
this credit. These are test images only; they are not bundled in the app.

Effects (glow, scanlines, glitch…) are not in the contact sheets. To see them
on one of these photos, use it as the Simulator's camera feed (Debug builds):

```sh
SIMCTL_CHILD_SNAPPER_DEMO_IMAGE="$PWD/test-photos/night-city/times-square-2013.jpg" \
  xcrun simctl launch --terminate-running-process booted com.example.snapper
```

Use your own `APP_BUNDLE_ID` if you set one. From Xcode, add
`SNAPPER_DEMO_IMAGE` with the photo's full path under Edit Scheme › Run ›
Arguments › Environment Variables instead.

## Adding your own

Drop JPEG/PNG photos here, then run:

```sh
pip install -r tools/lutgen/requirements.txt
python3 tools/lutgen/lutgen.py review
```

For the best review, include people across a range of skin tones, daylight
and indoor scenes, a night street with signs, food, greenery and sky. Delete
`stand-ins/` once you have your own set.
