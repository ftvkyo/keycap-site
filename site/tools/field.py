# SPDX-License-Identifier: GPL-3.0-or-later
"""Print the front page's field: a rounded union of a disc and a box, and
its distance bands, in characters; the surface is wrapped for the CSS.

python3 tools/field.py > content/field.html
"""

import math

W, H = 70, 15
ASPECT = 2.1  # a character is about twice as tall as it is wide


def field(x, y):
    disc = math.hypot(x + 8, y) - 5.5
    qx, qy = abs(x - 6) - 7, abs(y) - 3
    box = math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0)
    k = 5  # smooth union, so the two shapes melt into one
    h = max(k - abs(disc - box), 0) / k
    return min(disc, box) - h * h * k / 4


bands = " .:-=+*"
rows = []
for j in range(H):
    y = (j - (H - 1) / 2) * ASPECT / 2.0 * 1.15
    row = ""
    for i in range(W):
        x = (i - (W - 1) / 2) / 1.6
        d = field(x, y)
        if d <= 0:
            row += '<span class="surface">#</span>' if d > -1.2 else '<span class="surface">@</span>'
        else:
            band = int(d / 1.6)
            row += bands[-1 - band] if band < len(bands) and band % 2 == 0 else " "
    rows.append(row.rstrip())
print('<pre class="field" aria-hidden="true">')
print("\n".join(rows))
print("</pre>")
