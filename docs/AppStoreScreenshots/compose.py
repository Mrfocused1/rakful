"""Composes App Store screenshots (6.9", 1320x2868) from raw simulator captures.

Raw captures come from BrandJourneyUITests (run with
TEST_RUNNER_RR_SCREENSHOT_DIR set) on an iPhone 16 Pro Max simulator.
Usage: python3 compose.py   (reads raw/, writes framed/)
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
RAW, OUT = HERE / "raw", HERE / "framed"
W, H = 1320, 2868
TOP, BOTTOM = (0xF6, 0xF7, 0xFB), (0xE6, 0xE9, 0xF8)  # pale blue-grey into a faint lilac
FONT = "/System/Library/Fonts/Avenir Next.ttc"
HEAVY, MEDIUM = 8, 5

FRAMES = [
    ("01", "store-05-discover", "Find things to sell\nin your photos", "Spot sellable items you already own"),
    ("02", "store-07-review", "Swipe to keep\nwhat's yours", "Confirm what you own in seconds"),
    ("03", "store-06-discover-cards", "Everything you could\nsell, in one place", "Jackets, trainers, bags and more"),
    ("04", "store-09-ready-to-list", "Ready to list\nin minutes", "Title and description drafted for you"),
    ("05", "store-10-listed", "Ready for wherever\nyou sell", "Copy, post and you're done"),
    ("06", "store-02-privacy", "Your photos stay\non your iPhone", "Nothing is uploaded unless you choose"),
]


def background():
    img = Image.new("RGB", (W, H))
    draw = ImageDraw.Draw(img)
    for y in range(H):
        t = y / (H - 1)
        draw.line([(0, y), (W, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)))
    glow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(glow).ellipse([W * 0.35, -H * 0.15, W * 1.4, H * 0.3], fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(160))
    return Image.composite(Image.new("RGB", (W, H), "white"), img, glow)


def hide_dynamic_island(shot):
    """simctl captures include the Dynamic Island; XCUITest captures don't."""
    w, h = shot.size
    sample = shot.getpixel((int(w * 0.33), int(h * 0.03)))
    island = [int(w * 0.34), int(h * 0.008), int(w * 0.66), int(h * 0.052)]
    if sum(shot.getpixel((w // 2, int(h * 0.03)))[:3]) < 60:
        ImageDraw.Draw(shot).rounded_rectangle(island, radius=60, fill=sample)
    return shot


def device(shot, width):
    shot = hide_dynamic_island(shot.convert("RGB"))
    height = round(shot.height * width / shot.width)
    shot = shot.resize((width, height), Image.LANCZOS)
    bezel, radius = 22, 118
    frame = Image.new("RGBA", (width + bezel * 2, height + bezel * 2), (0, 0, 0, 0))
    ImageDraw.Draw(frame).rounded_rectangle([0, 0, frame.width - 1, frame.height - 1], radius=radius + bezel, fill=(16, 18, 17, 255))
    mask = Image.new("L", shot.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, width - 1, height - 1], radius=radius, fill=255)
    frame.paste(shot, (bezel, bezel), mask)
    return frame


def compose(number, source, title, subtitle):
    img = background().convert("RGBA")
    draw = ImageDraw.Draw(img)
    heavy, medium = ImageFont.truetype(FONT, 112, index=HEAVY), ImageFont.truetype(FONT, 54, index=MEDIUM)
    y = 190
    for line in title.split("\n"):
        width = draw.textlength(line, font=heavy)
        draw.text(((W - width) / 2, y), line, font=heavy, fill=(17, 17, 20))
        y += 128
    width = draw.textlength(subtitle, font=medium)
    draw.text(((W - width) / 2, y + 24), subtitle, font=medium, fill=(96, 101, 116))

    phone = device(Image.open(RAW / f"{source}.png"), 1010)
    top = 190 + 2 * 128 + 150
    shadow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [(W - phone.width) / 2, top + 30, (W + phone.width) / 2, top + phone.height + 30], radius=140, fill=(40, 50, 100, 55))
    img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(40)))
    img.alpha_composite(phone, ((W - phone.width) // 2, top))
    img.convert("RGB").save(OUT / f"{number}-{source.removeprefix('store-')}.png", optimize=True)


if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    for frame in FRAMES:
        compose(*frame)
    print(f"Wrote {len(FRAMES)} screenshots to {OUT}")
