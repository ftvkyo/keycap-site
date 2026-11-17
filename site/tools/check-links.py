# SPDX-License-Identifier: GPL-3.0-or-later
"""Fail if a local href or src in the built site points at nothing, or a #fragment at no id.

usage: check-links.py SITE_DIR
"""

import re
import sys
from pathlib import Path
from urllib.parse import unquote

site = Path(sys.argv[1])
pages = sorted(site.rglob("*.html"))
ids = {page: set(re.findall(r'\bid="([^"]+)"', page.read_text())) for page in pages}
dead = []
for page in pages:
    for link in re.findall(r'\b(?:href|src)="([^"]+)"', page.read_text()):
        if re.match(r"^(?:[a-z]+:|//)", link):
            continue
        path, _, fragment = link.partition("#")
        target = (page.parent / unquote(path)).resolve() if path else page.resolve()
        if path and target.is_dir():
            target = target / "index.html"
        if not target.exists():
            dead.append(f"{page.relative_to(site)}: {link}")
        elif fragment and target.suffix == ".html" and fragment not in ids.get(target, set(re.findall(r'\bid="([^"]+)"', target.read_text()))):
            dead.append(f"{page.relative_to(site)}: {link} (no such id)")
print(f"{len(pages)} pages, {len(dead)} dead links")
for line in dead[:40]:
    print(" ", line)
sys.exit(1 if dead else 0)
