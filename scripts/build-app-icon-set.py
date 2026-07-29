#!/usr/bin/env python3
"""Populate the macOS AppIcon set from the approved Agent Notch master icon."""

from pathlib import Path
import shutil

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "docs/assets/agent-notch-app-icon-black-pet-v1.png"
DESTINATION = ROOT / "ClaudeIsland/Assets.xcassets/AppIcon.appiconset"
BRAND_DESTINATION = ROOT / "ClaudeIsland/Assets.xcassets/BrandIcon.imageset/agent-notch-brand-icon.png"

SIZES = {
    "icon_16x16.png": 16,
    "icon_32x32 1.png": 32,
    "icon_32x32.png": 32,
    "icon_64x64.png": 64,
    "icon_128x128.png": 128,
    "icon_256x256 1.png": 256,
    "icon_256x256.png": 256,
    "icon_512x512 1.png": 512,
    "icon_512x512.png": 512,
    "icon_1024x1024.png": 1024,
}


def main() -> None:
    if not SOURCE.exists():
        raise SystemExit(f"Missing approved icon master: {SOURCE}")
    master = Image.open(SOURCE).convert("RGB")
    for filename, size in SIZES.items():
        # The mascot is a production pixel sprite; never use a smoothing filter.
        icon = master.resize((size, size), Image.Resampling.NEAREST)
        icon.save(DESTINATION / filename, optimize=True)
        print(DESTINATION / filename)
    BRAND_DESTINATION.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(SOURCE, BRAND_DESTINATION)
    print(BRAND_DESTINATION)


if __name__ == "__main__":
    main()
