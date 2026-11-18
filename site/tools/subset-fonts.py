# SPDX-License-Identifier: GPL-3.0-or-later
"""Cut the built site's fonts down to the characters its pages use.

usage: subset-fonts.py SITE_DIR

ASCII and the general punctuation stay too, for what the browser draws
itself, such as a list's bullets.  The fonts and the stylesheet that names
them are published under hashes of their content, as publish.el names
them: the new files get new names, and the pages follow.
"""

import hashlib
import html
import io
import re
import sys
from pathlib import Path

from fontTools import subset

site = Path(sys.argv[1])
pages = sorted(site.rglob("*.html"))
(stylesheet,) = site.glob("style.*.css")
used = set()
for file in [*pages, *site.glob("*.css"), *site.glob("*.js")]:
    used |= set(html.unescape(file.read_bytes().decode()))
kept = "".join(sorted(used | {chr(c) for c in range(0x20, 0x7F)} | {chr(c) for c in range(0x2000, 0x2070)}))


def publish(path, data):
    """Replace PATH with DATA, its name's hash changed to DATA's; return the new name."""
    digest = hashlib.sha256(data).hexdigest()[:10]
    new = path.with_name(re.sub(r"\.[0-9a-f]{10}\.", f".{digest}.", path.name))
    path.unlink()
    new.write_bytes(data)
    return new


renamed = {}
css = stylesheet.read_bytes().decode()
for name in re.findall(r'url\("([^"]+\.woff2)"\)', css):
    options = subset.Options(flavor="woff2")
    font = subset.load_font(site / name, options)
    subsetter = subset.Subsetter(options)
    subsetter.populate(text=kept)
    subsetter.subset(font)
    data = io.BytesIO()
    subset.save_font(font, data, options)
    renamed[name] = publish(site / name, data.getvalue()).relative_to(site).as_posix()
for old, new in renamed.items():
    css = css.replace(old, new)
renamed[stylesheet.name] = publish(stylesheet, css.encode()).name
for page in pages:
    data = page.read_bytes()
    for old, new in renamed.items():
        data = data.replace(old.encode(), new.encode())
    page.write_bytes(data)
print(f"{len(renamed) - 1} fonts cut to {len(kept)} characters")
