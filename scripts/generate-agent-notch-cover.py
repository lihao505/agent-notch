#!/usr/bin/env python3
"""Build the Agent Notch cover from the canonical Vibe Pet production frame.

The composition stays intentionally small (480x270 logical pixels) and is
scaled exactly 4x with nearest-neighbor sampling.  That keeps every source
pixel, including the 1px gutters in the pet, visibly crisp in the exported
1920x1080 cover.
"""

from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ClaudeIsland/Resources/VibePet/00-idle-green-f1.png"
OUTPUT = ROOT / "docs/assets/agent-notch-pixel-cover-compact-v1.png"
ICON_OUTPUT = ROOT / "docs/assets/agent-notch-app-icon-mac-idle-v1.png"
ICON_PREVIEW_OUTPUT = ROOT / "docs/assets/agent-notch-app-icon-mac-idle-preview.gif"
GRADIENT_ICON_OUTPUT = ROOT / "docs/assets/agent-notch-app-icon-black-pet-v1.png"
LOGICAL_SIZE = (400, 225)
SCALE = 4


def rect(draw: ImageDraw.ImageDraw, box, fill) -> None:
    draw.rectangle(box, fill=fill)


def pixel_text(canvas: Image.Image, xy: tuple[int, int], value: str, color, scale: int = 2) -> None:
    """Render PIL's bitmap font at integer scale, preserving hard edges."""
    font = ImageFont.load_default()
    bbox = font.getbbox(value)
    layer = Image.new("RGBA", (bbox[2] + 2, bbox[3] + 2), (0, 0, 0, 0))
    ImageDraw.Draw(layer).text((1, 1), value, font=font, fill=color)
    layer = layer.resize((layer.width * scale, layer.height * scale), Image.Resampling.NEAREST)
    canvas.alpha_composite(layer, xy)


def pet_with_external_glow(size: int, source: Path = SOURCE) -> tuple[Image.Image, Image.Image, Image.Image]:
    """Return the crisp pet plus two stepped, external glow layers."""
    pet = Image.open(source).convert("RGBA").resize((size, size), Image.Resampling.NEAREST)
    alpha = pet.getchannel("A")
    far = Image.new("RGBA", pet.size, (33, 230, 166, 0))
    mid = Image.new("RGBA", pet.size, (55, 255, 187, 0))
    for dx, dy in [(-5, 0), (5, 0), (0, -5), (0, 5), (-4, -4), (4, 4), (-4, 4), (4, -4)]:
        shifted = Image.new("L", pet.size, 0)
        shifted.paste(alpha, (dx, dy))
        far.putalpha(Image.eval(ImageChops.lighter(far.getchannel("A"), shifted), lambda p: min(p, 44)))
    for dx, dy in [(-2, 0), (2, 0), (0, -2), (0, 2)]:
        shifted = Image.new("L", pet.size, 0)
        shifted.paste(alpha, (dx, dy))
        mid.putalpha(Image.eval(ImageChops.lighter(mid.getchannel("A"), shifted), lambda p: min(p, 78)))
    return far, mid, pet


def add_notch(draw: ImageDraw.ImageDraw, center: int, width: int, height: int) -> None:
    """Draw an intentionally stepped hardware-notch silhouette."""
    x0 = center - width // 2
    x1 = center + width // 2
    rect(draw, (x0 + 8, 0, x1 - 8, 4), (0, 0, 0, 255))
    rect(draw, (x0 + 4, 5, x1 - 4, 12), (0, 0, 0, 255))
    rect(draw, (x0, 13, x1, height - 5), (0, 0, 0, 255))
    rect(draw, (x0 + 4, height - 4, x1 - 4, height), (0, 0, 0, 255))


def make_mac_screen_backdrop() -> Image.Image:
    """An original soft screen color field; it is not a copied wallpaper."""
    image = Image.new("RGBA", (256, 256), (0, 0, 0, 255))
    pixels = image.load()
    for y in range(256):
        for x in range(256):
            horizontal = x / 255
            vertical = y / 255
            blue = int(151 - 40 * horizontal + 12 * vertical)
            red = int(84 + 108 * horizontal + 14 * vertical)
            green = int(132 + 27 * horizontal + 16 * vertical)
            pixels[x, y] = (red, green, blue, 255)
    draw = ImageDraw.Draw(image)
    draw.polygon([(0, 128), (0, 214), (132, 256), (256, 256), (256, 229), (145, 174)], fill=(87, 78, 174, 160))
    draw.polygon([(0, 164), (0, 240), (106, 256), (148, 256), (75, 192)], fill=(71, 171, 191, 150))
    return image


def make_idle_icon(source: Path, signal_phase: int) -> Image.Image:
    """A Mac notch plus its idle compact island, with no active-task UI."""
    icon = make_mac_screen_backdrop()
    draw = ImageDraw.Draw(icon)
    # Hardware bezel and camera notch: the icon should read as a Mac first.
    rect(draw, (0, 18, 256, 30), (1, 2, 5, 255))
    rect(draw, (0, 30, 256, 34), (10, 13, 18, 255))
    rect(draw, (88, 28, 168, 63), (0, 0, 0, 255))
    rect(draw, (84, 34, 172, 57), (0, 0, 0, 255))
    rect(draw, (91, 58, 165, 66), (0, 0, 0, 255))
    # Expanded little notch is attached to the real hardware notch below.
    rect(draw, (63, 62, 193, 125), (0, 0, 0, 255))
    rect(draw, (58, 68, 198, 119), (0, 0, 0, 255))
    rect(draw, (63, 120, 193, 125), (0, 0, 0, 255))
    far, mid, pet = pet_with_external_glow(54, source)
    icon.alpha_composite(far, (78, 69))
    icon.alpha_composite(mid, (78, 69))
    icon.alpha_composite(pet, (78, 69))
    # Mirrors PetStateSignalIcon.idle: a calm three-pixel vertical breath.
    active = abs(signal_phase % 4 - 2)
    for index in range(3):
        opacity = 0.95 if index == active else 0.34
        base = (77, 150, 112)
        fill = tuple(int(channel * opacity) for channel in base) + (255,)
        rect(draw, (164, 79 + index * 12, 171, 86 + index * 12), fill)
    return icon


def make_gradient_pet_icon() -> Image.Image:
    """A black app icon whose notch is inhabited, not merely overlaid."""
    size = 1024
    canvas = Image.new("RGBA", (size, size), (5, 6, 9, 255))

    draw = ImageDraw.Draw(canvas)
    # White expanded-notch line art; the icon is intentionally otherwise black.
    outer = (128, 268, 896, 758)
    inner = (158, 298, 866, 728)
    draw.rounded_rectangle(outer, radius=98, fill=(255, 255, 255, 240))
    draw.rounded_rectangle(inner, radius=75, fill=(0, 0, 0, 0))
    draw.rounded_rectangle(inner, radius=75, fill=(5, 6, 9, 255))
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle((410, 324, 614, 348), radius=12, fill=(255, 255, 255, 242))

    pet = Image.open(SOURCE).convert("RGBA").resize((228, 228), Image.Resampling.NEAREST)
    # External glow remains a layer outside the hard-edge sprite itself.
    alpha = pet.getchannel("A")
    glow = Image.new("RGBA", pet.size, (210, 255, 232, 0))
    for dx, dy in [(-8, 0), (8, 0), (0, -8), (0, 8), (-6, -6), (6, 6), (-6, 6), (6, -6)]:
        shifted = Image.new("L", pet.size, 0)
        shifted.paste(alpha, (dx, dy))
        glow.putalpha(Image.eval(ImageChops.lighter(glow.getchannel("A"), shifted), lambda p: min(p, 64)))
    # The pet occupies the left half of the notch; its companion lives on the right.
    canvas.alpha_composite(glow, (248, 430))
    canvas.alpha_composite(pet, (248, 430))
    for index, opacity in enumerate((0.36, 0.95, 0.36)):
        fill = (55, int(231 * opacity), int(172 * opacity), 255)
        draw.rectangle((685, 464 + index * 46, 712, 491 + index * 46), fill=fill)
    return canvas


def main() -> None:
    if not SOURCE.exists():
        raise SystemExit(f"Missing canonical pet frame: {SOURCE}")

    canvas = Image.new("RGBA", LOGICAL_SIZE, (7, 10, 18, 255))
    draw = ImageDraw.Draw(canvas)

    # A sparse, fixed-grid night field — decorative pixels only, never blurred.
    for x, y, tone in [
        (24, 34, (32, 48, 75, 255)), (58, 48, (38, 61, 85, 255)),
        (98, 24, (31, 54, 78, 255)), (324, 30, (29, 51, 75, 255)),
        (371, 52, (37, 63, 85, 255)), (359, 180, (31, 51, 75, 255)),
        (31, 193, (29, 45, 69, 255)),
    ]:
        rect(draw, (x, y, x + 2, y + 2), tone)

    add_notch(draw, 200, 126, 27)

    # A single compact, product-specific card keeps the eye moving inward.
    rect(draw, (48, 54, 352, 177), (11, 17, 29, 255))
    rect(draw, (50, 56, 350, 175), (10, 14, 24, 255))
    for x, y in [(48, 54), (348, 54), (48, 173), (348, 173)]:
        rect(draw, (x, y, x + 4, y + 4), (55, 231, 172, 255))

    far, mid, pet = pet_with_external_glow(104)
    canvas.alpha_composite(far, (66, 66))
    canvas.alpha_composite(mid, (66, 66))
    canvas.alpha_composite(pet, (66, 66))

    # Agent activity signals: separate 3x3 clusters match the right-side notch language.
    signal_x, signal_y = 216, 115
    for row, color, active in [
        (0, (49, 155, 255, 255), 3),
        (1, (255, 176, 71, 255), 2),
        (2, (55, 231, 172, 255), 1),
    ]:
        yy = signal_y + row * 20
        for i in range(4):
            fill = color if i < active else (35, 47, 65, 255)
            rect(draw, (signal_x + i * 11, yy, signal_x + i * 11 + 6, yy + 6), fill)
        rect(draw, (signal_x + 52, yy + 2, signal_x + 104, yy + 4), (51, 65, 84, 255))
        rect(draw, (signal_x + 52, yy + 2, signal_x + 52 + active * 16, yy + 4), color)

    # Brand copy is bitmap text, rendered at an integer scale.
    pixel_text(canvas, (211, 60), "AGENT", (213, 225, 240, 255), 2)
    pixel_text(canvas, (211, 79), "NOTCH", (55, 231, 172, 255), 2)
    pixel_text(canvas, (110, 192), "YOUR AGENTS, AT A GLANCE", (121, 142, 166, 255), 1)

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").resize((LOGICAL_SIZE[0] * SCALE, LOGICAL_SIZE[1] * SCALE), Image.Resampling.NEAREST).save(OUTPUT, optimize=True)
    print(OUTPUT)

    # A real AppIcon is static: frame one plus the middle point of the idle breath.
    icon = make_idle_icon(SOURCE, signal_phase=0)
    icon.convert("RGB").resize((1024, 1024), Image.Resampling.NEAREST).save(ICON_OUTPUT, optimize=True)
    print(ICON_OUTPUT)

    # Preview the actual idle companion motion at 1 fps. The mascot is fixed to
    # the selected idle keyframe; only the quiet right-side state signal breathes.
    idle_frames = [
        make_idle_icon(SOURCE, signal_phase=phase).convert("RGB").resize((512, 512), Image.Resampling.NEAREST)
        for phase in range(4)
    ]
    idle_frames[0].save(
        ICON_PREVIEW_OUTPUT,
        save_all=True,
        append_images=idle_frames[1:],
        duration=1000,
        loop=0,
        optimize=False,
        disposal=2,
    )
    print(ICON_PREVIEW_OUTPUT)

    make_gradient_pet_icon().convert("RGB").save(GRADIENT_ICON_OUTPUT, optimize=True)
    print(GRADIENT_ICON_OUTPUT)


if __name__ == "__main__":
    main()
