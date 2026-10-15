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

## Adding your own

Drop JPEG/PNG photos here, then run:

```sh
pip install -r tools/lutgen/requirements.txt
python3 tools/lutgen/lutgen.py review
```

For the best review, include people across a range of skin tones, daylight
and indoor scenes, a night street with signs, food, greenery and sky. Delete
`stand-ins/` once you have your own set.
