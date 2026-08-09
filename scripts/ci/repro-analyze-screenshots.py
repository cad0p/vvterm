#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Heuristic pixel analysis for the zmx scrollback-reload repro screenshots.
#
# For each screenshot, measure how much terminal content (non-background
# pixels) is visible in the top ~55% of the screen — the region above the
# software keyboard when it is open. A terminal full of text (the replayed
# scrollback) shows a high text fraction; a surface scrolled almost entirely
# off-screen (BUG B) shows a fraction near zero.
#
# Heuristic: quantize luminance into 32-level buckets; the most common bucket
# is the background; pixels >= 2 buckets away from it count as "text".
import sys
from collections import Counter

from PIL import Image


def analyze(path):
    image = Image.open(path).convert("L")
    width, height = image.size
    # Terminal region above the keyboard: top 55% of the screen.
    region = image.crop((0, 0, width, int(height * 0.55)))
    pixels = list(region.getdata())
    counts = Counter(value // 32 for value in pixels)
    background_bucket = counts.most_common(1)[0][0]
    text_pixels = sum(
        1 for value in pixels if abs(value // 32 - background_bucket) >= 2
    )
    fraction = text_pixels / len(pixels) if pixels else 0.0
    return fraction, background_bucket, width, height


def main(paths):
    if not paths:
        print("no screenshots to analyze")
        return 0
    for path in sorted(paths):
        try:
            fraction, bucket, width, height = analyze(path)
            print(
                f"{path}: size={width}x{height} text_fraction={fraction:.3f} "
                f"bg_bucket={bucket}"
            )
        except Exception as exc:  # noqa: BLE001 - report and continue
            print(f"{path}: ERROR {exc}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
