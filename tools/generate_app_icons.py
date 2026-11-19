#!/usr/bin/env python3
"""Rebuild only launcher icons from branding/Farming_App_Logo.png.

Requires Pillow: python3 -m pip install Pillow
Run from the project root: python3 tools/generate_app_icons.py
Does not modify Flutter/Dart code, dependency files or Android manifests.
"""

from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "branding" / "Farming_App_Logo.png"
BG = (255, 255, 255, 255)
ANDROID_SIZES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}


def artwork(size: int, scale: float, transparent: bool = False) -> Image.Image:
    """Center the *unmodified* logo; resize only, preserving aspect ratio."""
    base = Image.new("RGBA", (size, size), (0, 0, 0, 0) if transparent else BG)
    logo = Image.open(SOURCE).convert("RGBA")
    extent = round(size * scale)
    logo.thumbnail((extent, extent), Image.Resampling.LANCZOS)
    xy = ((size - logo.width) // 2, (size - logo.height) // 2)
    base.alpha_composite(logo, xy)
    return base


def save_png(im: Image.Image, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    im.save(dest, "PNG", optimize=True)


def main() -> None:
    if not SOURCE.is_file():
        raise FileNotFoundError(SOURCE)
    with Image.open(SOURCE) as source:
        if source.size != (1024, 1024) or "A" not in source.getbands():
            raise ValueError("Expected the original 1024x1024 transparent PNG logo")

    res = ROOT / "android" / "app" / "src" / "main" / "res"
    for density, legacy_size in ANDROID_SIZES.items():
        mipmap = res / ("mipmap-" + density)
        save_png(artwork(legacy_size, 0.92), mipmap / "ic_launcher.png")
        # Adaptive icon layers are 108dp; critical elements stay inside
        # the central 66dp safe circle so round/squircle masks cannot clip the leaf.
        foreground_size = legacy_size * 108 // 48
        save_png(artwork(foreground_size, 0.52, transparent=True),
                 mipmap / "ic_launcher_foreground.png")

    # Existing AndroidManifest.xml already uses @mipmap/ic_launcher.
    # Android 8+ automatically resolves the adaptive variant.
    adaptive = res / "mipmap-anydpi-v26" / "ic_launcher.xml"
    adaptive.parent.mkdir(parents=True, exist_ok=True)
    adaptive.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '</adaptive-icon>\n', encoding="utf-8"
    )
    colors = res / "values" / "ic_launcher_background.xml"
    colors.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<resources>\n'
        '    <color name="ic_launcher_background">#FFFFFF</color>\n'
        '</resources>\n', encoding="utf-8"
    )

    # Replace only the already-present, default Flutter web and Windows icons.
    web = ROOT / "web"
    save_png(artwork(64, 0.92), web / "favicon.png")
    for size in (192, 512):
        save_png(artwork(size, 0.92), web / "icons" / f"Icon-{size}.png")
        save_png(artwork(size, 0.64), web / "icons" / f"Icon-maskable-{size}.png")

    win_icon = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"
    win_icon.parent.mkdir(parents=True, exist_ok=True)
    artwork(256, 0.92).convert("RGBA").save(
        win_icon, format="ICO", sizes=[(s, s) for s in (16, 24, 32, 48, 64, 128, 256)]
    )

    # The Play Console listing uses a separate 512 x 512 store icon.
    save_png(artwork(512, 0.92), ROOT / "branding" / "play_store_icon_512.png")
    print("Updated Android launcher, adaptive, web and Windows icon assets.")
    print("Original logo: branding/Farming_App_Logo.png")
    print("Play Store listing icon: branding/play_store_icon_512.png")


if __name__ == "__main__":
    main()
