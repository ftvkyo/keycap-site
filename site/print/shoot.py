"""Screenshot frames.el's pages in Chromium, in grey and at print resolution.

usage: shoot.py CHROMIUM PAGES OUT_DIR

Every PAGES/NAME.html is written to OUT_DIR/NAME.png, in the site's
light scheme, headless Chromium's default, cropped to what the page
shows on its white and darkened as render.py darkens a model.
Chromium rasterises on the CPU, with the site's fonts, so the same pins
give the same bytes.
"""

import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageChops

# The style sheet's pixels, as Chromium lays out a page 1280 wide: the
# root's 18 px, a frame 64 of those wide; screenshot 3 times as dense.
WIDTH, HEIGHT, SCALE = 1280, 1200, 3
GAMMA = 1.5


def main():
    chromium, pages, out = sys.argv[1:4]
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as profile:
        for page in sorted(Path(pages).glob("*.html")):
            png = out / f"{page.stem}.png"
            subprocess.run([
                chromium, "--headless", "--no-sandbox", "--disable-gpu", "--hide-scrollbars",
                "--no-first-run", "--disable-crash-reporter", f"--user-data-dir={profile}",
                f"--force-device-scale-factor={SCALE}", f"--window-size={WIDTH},{HEIGHT}",
                f"--screenshot={png}", page.resolve().as_uri(),
            ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            grey(Image.open(png)).save(png, optimize=True)
            print(f"shoot.py: {png.name}", file=sys.stderr)


def grey(image):
    image = image.convert("L")
    box = ImageChops.invert(image).getbbox()
    if box[3] >= image.height:
        sys.exit(f"shoot.py: a frame runs past the window's {HEIGHT} px")
    image = image.crop(box)
    return image.point(lambda v: round(255 * (v / 255) ** GAMMA))


if __name__ == "__main__":
    main()
