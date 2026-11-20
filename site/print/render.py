"""Render the print's pictures, in grey and at print resolution.

usage: render.py SERVER PRELUDE JOBS OUT_DIR

JOBS is a JSON file, a list of jobs.  A keycap job is one script and what
to make of it:

- `script`: the script's path, `$KEYCAP_DIR` and `$KEYCAP_DESIGNS_DIR`
  expanded
- `source`: a script's text instead, run as if it were `script`
- `renders`: `{"name", "width", "height", "view", "camera", "slice"}`, each
  written to `OUT_DIR/name.png`; `camera` merges into an orthographic one
  at zoom 1
- `traces`: `{"name", "slice", "resolution", "tolerance"}`, each written to
  `OUT_DIR/name.svg`

An OpenSCAD job, `{"openscad", "name", "size", "defines"}`, renders a
`.scad` file (`$OPENSCAD_DIR` expanded) with `openscad` from PATH, in its
default view.

Every PNG is grey, cropped to what it shows, and its greys darkened by
`gamma` (1.5 by default) so that a light model keeps its shading on paper.
Frames are rendered on the CPU, so the same pins give the same bytes.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageChops

MARGIN = 0.02  # of the larger side, around the crop


def main():
    server, prelude, jobs, out = sys.argv[1:5]
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    for job in json.loads(Path(jobs).read_text()):
        if "openscad" in job:
            openscad(job, out)
        else:
            keycap(server, prelude, job, out)


##########
# keycap #
##########

def keycap(server, prelude, job, out):
    script = Path(os.path.expandvars(job["script"]))
    source = job.get("source") or script.read_text()
    process = subprocess.Popen([server, "--prelude", prelude], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    ids = iter(range(1, 1000))

    def ask(request):
        request["id"] = next(ids)
        process.stdin.write(json.dumps(request) + "\n")
        process.stdin.flush()
        while True:
            reply = json.loads(process.stdout.readline())
            if "progress" not in reply:
                if "error" in reply:
                    sys.exit(f"render.py: {script}: {reply['error']}")
                return reply

    loaded = ask({"op": "load", "source": source, "path": str(script)})
    if not loaded["loaded"] or any(d["severity"] == "error" for d in loaded["diagnostics"]):
        sys.exit(f"render.py: {script}: {loaded['diagnostics']}")

    for r in job.get("renders", []):
        ppm = out / f"{r['name']}.ppm"
        ask({
            "op": "render", "output": str(ppm), "width": r["width"], "height": r["height"],
            "view": r.get("view", "shaded"), "bounds": r.get("bounds", "fitted"), "backend": "cpu",
            "camera": {"zoom": 1, "pan": [0, 0], "orthographic": True, **r.get("camera", {})},
            "slice": r.get("slice", {"axis": "z", "offset": 0}),
            "background": [1, 1, 1],
        })
        grey(Image.open(ppm), r).save(out / f"{r['name']}.png", optimize=True)
        ppm.unlink()
        print(f"render.py: {r['name']}.png", file=sys.stderr)

    for t in job.get("traces", []):
        ask({
            "op": "trace", "output": str(out / f"{t['name']}.svg"), "format": "svg",
            "bounds": t.get("bounds", "fitted"), "slice": t.get("slice"),
            "resolution": t.get("resolution"), "tolerance": t.get("tolerance"),
        })
        print(f"render.py: {t['name']}.svg", file=sys.stderr)

    process.stdin.close()
    process.wait()


############
# OpenSCAD #
############

def openscad(job, out):
    png = out / f"{job['name']}.png"
    defines = [arg for name, value in job.get("defines", {}).items() for arg in ("-D", f"{name}={json.dumps(value)}")]
    subprocess.run(
        ["openscad", "--backend=manifold", "--render", "-o", str(png), f"--imgsize={job['size']},{job['size']}",
         *defines, os.path.expandvars(job["openscad"])],
        check=True, capture_output=True,
    )
    image = Image.open(png).convert("RGB")
    # Its background is a colour of its own: white, as keycap's.
    background = Image.new("RGB", image.size, image.getpixel((0, 0)))
    mask = ImageChops.difference(image, background).convert("L").point(lambda v: 255 if v > 2 else 0)
    image = Image.composite(image, Image.new("RGB", image.size, "white"), mask)
    grey(image, job).save(png, optimize=True)
    print(f"render.py: {png.name}", file=sys.stderr)


#########
# Greys #
#########

def grey(image, spec):
    image = image.convert("L")
    gamma = spec.get("gamma", 1.5)
    image = image.point(lambda v: round(255 * (v / 255) ** gamma))
    if spec.get("crop", True):
        box = ImageChops.invert(image).getbbox()
        if box:
            pad = round(MARGIN * max(image.size))
            image = image.crop((max(box[0] - pad, 0), max(box[1] - pad, 0),
                                min(box[2] + pad, image.width), min(box[3] + pad, image.height)))
    return image


if __name__ == "__main__":
    main()
