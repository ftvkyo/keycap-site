# SPDX-License-Identifier: MPL-2.0

"""What each shape and function costs: its first example, then sweeps of
one thing at a time, each program loaded, counted and rendered at a fixed
size and bounds on both backends."""

import argparse
import json
import math
import os
import random
import time

from harness import Died, errors
from programs import RANGES, Generator, Hint, Node, Skip, expression

LOAD_TIMEOUT = 60.0
RENDER_TIMEOUT = 180.0
# Cells across the bounds of a timed export
EXPORT_CELLS = 96

COPIES = [1, 4, 16]
LEVELS = [1, 2, 3]
COUNTS = [1, 4, 16]
SIZES = [0.5, 1, 2]
TERMS = [1, 4, 16]
GLYPHS = [1, 4, 16]

# What a shape is measured under, `{s}` the shape and `{d}` half its width
UNDER = {
    "rotate_xyz": ("{s}.rotate_xyz([20, 30, 40])", 3),
    "twist": ("{s}.twist(2 * z)", 3),
    "symmetric_x": ("{s}.symmetric_x()", None),
    "scale_exact": ("{s}.scale_exact(1.5)", None),
    "polar_array 6": ("{s}.move([{d}, 0, 0]).polar_array(6)", None),
    "repeat_polar 6": ("{s}.move([{d}, 0, 0]).repeat_polar(6)", None),
}

# A function of trees is measured as the height of a box's top, its
# input running from 0 to 1 across the box.
FIELD = "draw(max(box([-16, -16, -16], [16, 16, 16]), z - 8 * ({f})));"
FIELD_BOUNDS = "bounds([-20, -20, -20], [20, 20, 20]);"
FIELD_INPUTS = ("t", "v", "a", "y", "seed")

# Thresholds of a cliff: a metric growing faster than its input to this
# power, from at least the floor, or the GPU slower than the CPU by the
# factor
EXPONENT = 1.5
FLOORS = {"cpu_cpu_s": 0.3, "gpu_ms": 50, "load_ms": 100, "nodes": 2000}
NAMES = {"cpu_cpu_s": "CPU-s", "gpu_ms": "GPU ms", "load_ms": "load ms", "nodes": "nodes"}
GPU_SLOWER = 3
# Times a frame that slow is measured again
RECHECKS = 2


# --- Programs ---


class Series:
    """Programs that differ in one thing, `x`, measured within one region:
    `region` when given, else the first program's when the programs are
    of one size, else each program's own."""

    def __init__(self, subject, kind, sweep, programs, region=None):
        self.subject, self.kind, self.sweep = subject, kind, sweep
        # (x, source)
        self.programs = programs
        self.region = region
        self.fixed = sweep in ("union", "nest", "terms")
        # The imports the programs need, set by `series`
        self.headers = ""


def block(code):
    """An example as one expression."""
    return "{\n" + code + "\n}"


def series(entries, values, sweeps):
    """Every subject's series, in the catalogue's order."""
    modules = {e.header.split(" as ")[1].rstrip(";"): e.header for e in entries.values() if e.header}
    shapes, trees = [], []
    for entry in entries.values():
        generator = Generator(entries, values, random.Random(entry.name), typical=True)
        if any(entry is e for e, _ in generator.shapes):
            shapes.append((entry, generator))
        elif any(entry is e for e, _ in generator.trees):
            trees.append((entry, generator))
    made = [shape_series(entry, generator, sweeps) for entry, generator in shapes]
    made += [tree_series(entry, generator, sweeps) for entry, generator in trees]
    for subject in made:
        for s in subject:
            code = "".join(source for _, source in s.programs)
            s.headers = "".join(h + "\n" for alias, h in modules.items() if alias + "::" in code)
            yield s


def typical(entry, generator, shapes=None):
    """A call of `entry` by its first plain signature, typical values in."""
    generator.fresh()
    for s in entry.signatures:
        if s.method:
            continue
        try:
            dim = generator.input_dim(entry, 3)
            return generator.call(entry, s, Hint(entry, None, dim, 2), list(shapes or []))
        except Skip:
            continue
    return None


def leaf(dim):
    return Node("call", "sphere" if dim == 3 else "circle", [Node("num", 8)], dim=dim)


def shape_series(entry, generator, sweeps):
    name, kind = entry.name, entry.kind
    dim_in = generator.input_dim(entry, 3)
    if entry.examples:
        base = block(entry.examples[0])
    else:
        node = typical(entry, generator, [leaf(dim_in), leaf(dim_in)])
        if not node:
            return
        base = expression(node)
    yield Series(name, kind, "example", [(None, f"draw({base});")])
    if "union" in sweeps:
        programs = []
        for n in COPIES:
            copies = ", ".join(f"s.move([{0.37 * i:.2f}, {0.23 * i:.2f}, 0])" for i in range(n))
            programs.append((n, f"let s = {base};\ndraw(union([{copies}]));"))
        yield Series(name, kind, "union", programs)
    if "under" in sweeps:
        programs = []
        for label, (template, dim) in UNDER.items():
            if dim == 3 and kind == "2d":
                continue
            programs.append((label, "draw(" + template.format(s="s", d="{d}") + ");"))
        yield Series(name, kind, "under", [(x, f"let s = {base};\n{p}") for x, p in programs])
    # Nesting needs a shape in and the same kind of shape out.
    same = kind in ("csg", "transform", "pattern") or name in ("twist", "bend", "normalize_z")
    if "nest" in sweeps and same:
        programs = []
        for n in LEVELS:
            node = leaf(3)
            for _ in range(n):
                node = typical(entry, generator, [node, leaf(3), leaf(3)])
                if not node:
                    break
            if node:
                programs.append((n, f"draw({expression(node)});"))
        if programs:
            yield Series(name, kind, "nest", programs)
    if "numbers" in sweeps:
        yield from number_series(entry, generator, [leaf(dim_in), leaf(dim_in)])
    if "glyphs" in sweeps and name == "text":
        programs = [
            (n, 'bounds([-50, -6, -1], [50, 6, 3]);\n'
             f'draw(text("{"QWERTYUIOPASDFGH"[:n]}", #{{size: 8, halign: "center"}}).extrude([0, 2]));')
            for n in GLYPHS
        ]
        yield Series(name, kind, "glyphs", programs)


def number_series(entry, generator, shapes):
    """A series per number its typical call passes, scaled."""
    node = typical(entry, generator, shapes)
    if not node:
        return
    for i, kid in enumerate(node.kids):
        if kid.kind != "num" or kid.value == 0:
            continue
        param = parameter(entry, i)
        integer = isinstance(kid.value, int)
        fixed = RANGES.get((entry.name, param)) or RANGES.get((None, param))
        programs = []
        for factor in COUNTS if integer else SIZES:
            value = kid.value * factor
            if fixed and not fixed[0] <= value <= fixed[1]:
                continue
            kid_value, kid.value = kid.value, (int(value) if integer else round(value, 3))
            programs.append((kid.value, f"draw({expression(node)});"))
            kid.value = kid_value
        if programs:
            yield Series(entry.name, entry.kind, f"number {param}", programs)


def parameter(entry, i):
    for s in entry.signatures:
        if not s.method and i < len(s.params):
            return s.params[i].name
    return str(i + 1)


def tree_series(entry, generator, sweeps):
    def call(inputs):
        node = typical(entry, generator)
        if not node:
            return None
        params = [parameter(entry, i) for i in range(len(node.kids))]
        named = [params.index(p) for p in FIELD_INPUTS if p in params]
        numbers = [i for i, kid in enumerate(node.kids) if kid.kind == "num"]
        if not named + numbers:
            return None
        node.kids[(named + numbers)[0]] = Node("raw", inputs)
        return expression(node)

    f = call("abs(x) / 16")
    if not f:
        return
    programs = [(None, FIELD.format(f=f))]
    yield Series(entry.name, entry.kind, "example", programs, region=FIELD_BOUNDS)
    # A function's union is a sum of its terms.
    if "union" in sweeps:
        programs = []
        for n in TERMS:
            terms = [call(f"abs(x) / {16 + i}") for i in range(n)]
            programs.append((n, FIELD.format(f=f"({' + '.join(terms)}) / {n}")))
        yield Series(entry.name, entry.kind, "terms", programs, region=FIELD_BOUNDS)


# --- Measuring ---


def costs(server, entries, values, o, out):
    width, height = map(int, o.size.split("x"))
    sweeps = set(o.sweeps.split(",")) | {"glyphs"}
    only = set(o.only.split(",")) if o.only else None
    path = out / "costs.jsonl"
    rows = []
    # Half of each example's width, for the arrays it is measured in
    halves = {}
    with open(path, "w") as log:
        for s in series(entries, values, sweeps):
            if only and s.subject not in only:
                continue
            region = s.region
            for x, source in s.programs:
                source = source.replace("{d}", str(halves.get(s.subject, 5)))
                # An example may set its own bounds.
                own = "bounds(" in source
                text = s.headers + ("" if own else region or "") + "\n" + source
                row = dict(subject=s.subject, kind=s.kind, sweep=s.sweep, x=x)
                # A function's field is a solid, though NaN may leave it unbounded.
                view = "shaded" if s.region == FIELD_BOUNDS else None
                row.update(measure(server, text, (width, height), o, view))
                row.update(size=o.size, repeat=o.repeat, at=round(time.time()), load=os.getloadavg()[0])
                if s.sweep == "example" and row.get("width"):
                    halves[s.subject] = row["width"] // 2
                if s.fixed and region is None and "region" in row:
                    region = row["region"]
                row.pop("region", None)
                row["source"] = text
                rows.append(row)
                log.write(json.dumps(row) + "\n")
                log.flush()
            print(f"{s.subject} {s.sweep}: " + ", ".join(
                f"{r['x']}: {r.get('cpu_ms', r.get('error', '?'))}" for r in rows[len(rows) - len(s.programs):]
            ), flush=True)
    recheck(server, rows, o)
    with open(path, "w") as log:
        for row in rows:
            log.write(json.dumps(row) + "\n")
    (out / "costs.md").write_text(report(rows))
    print(f"costs: {path}, {out / 'costs.md'}")


def slow_on_gpu(row):
    cpu, gpu = row.get("cpu_ms"), row.get("gpu_ms")
    return cpu and gpu and "gpu_fallback" not in row and gpu > GPU_SLOWER * cpu and gpu > FLOORS["gpu_ms"]


def recheck(server, rows, o):
    """Frames far slower on the GPU than on the CPU, measured again: another
    process on the GPU makes a frame seconds slower, and its tiles' cost
    the scene's later frames too."""
    width, height = map(int, o.size.split("x"))
    again = argparse.Namespace(**dict(o.__dict__, backends="gpu"))
    for row in rows:
        for _ in range(RECHECKS):
            if not slow_on_gpu(row):
                break
            fresh = measure(server, row["source"], (width, height), again, row.get("view"))
            for key in ("gpu_first_ms", "gpu_ms", "gpu_cpu_s"):
                if fresh.get(key) is not None:
                    row[key] = min(row.get(key, fresh[key]), fresh[key])
            row["rechecked"] = row.get("rechecked", 0) + 1
            print(f"{row['subject']} {row['sweep']} {row['x']}: GPU {row['gpu_ms']} ms again", flush=True)


def measure(server, text, size, o, view=None):
    """Load, count and render one program, in `view` or as its fitted
    bounds suggest; its region is that of its fitted bounds, rounded out,
    for the rest of its series."""
    row = {}
    try:
        reply, _ = server.load(text, LOAD_TIMEOUT)
        row["load_ms"] = reply.get("ms")
        if not reply.get("loaded"):
            row["error"] = (errors(reply) or [{"message": "not loaded"}])[0]["message"]
            return row
        fitted = reply["bounds"]["fitted"]
        lower, upper = (fitted["lower"], fitted["upper"]) if fitted else ([None] * 3, [None] * 3)
        # A 2D shape has no bounds on z, and is seen in a slice.
        flat = view == "sdf" or not view and fitted is not None and (lower[2] is None or lower[2] == upper[2])
        if None not in lower[:2] + upper[:2] and (flat or None not in (lower[2], upper[2])):
            lower = [math.floor(v) for v in lower[:2]] + [-1 if flat else math.floor(lower[2])]
            upper = [math.ceil(v) for v in upper[:2]] + [1 if flat else math.ceil(upper[2])]
            row["region"] = f"bounds({lower}, {upper});"
            row["width"] = max(u - l for l, u in zip(lower, upper))
        view = "sdf" if flat else "shaded"
        row["view"] = view
        stats, _ = server.call({"op": "stats"}, LOAD_TIMEOUT)
        row.update({k: stats.get(k) for k in ("nodes", "tape", "registers", "choices")})
        server.reset_peak()
        for backend in o.backends.split(","):
            first, _ = server.render(*size, backend, view, RENDER_TIMEOUT)
            if "error" in first:
                row["error"] = first["error"]
                return row
            row[f"{backend}_first_ms"] = first["ms"]
            spent = server.cpu_seconds()
            frames = [server.render(*size, backend, view, RENDER_TIMEOUT)[0] for _ in range(o.repeat)]
            failed = [f["error"] for f in frames if "error" in f]
            if failed:
                row["error"] = failed[0]
                return row
            row[f"{backend}_ms"] = min(f["ms"] for f in frames)
            # Less sensitive to other work on the machine than the time
            row[f"{backend}_cpu_s"] = round((server.cpu_seconds() - spent) / o.repeat, 2)
            if first["backend"] != backend:
                row[f"{backend}_fallback"] = first.get("fallback") or first["backend"]
        if o.export:
            row.update(export(server, row, flat))
        row["peak_mb"] = server.peak_mb()
    except Died as died:
        row["error"] = f"{died.why}: {died.detail[-200:]}"
    return row


def export(server, row, flat):
    resolution = EXPORT_CELLS / max(row.get("width") or 20, 1)
    if flat:
        request = dict(op="trace", output="/tmp/keycap-costs.svg", format="svg", resolution=resolution)
    else:
        request = dict(op="mesh", output="/tmp/keycap-costs.stl", resolution=resolution)
    done, ms = server.call(request, RENDER_TIMEOUT)
    if "error" in done:
        return {"export_error": done["error"]}
    return {"export_ms": done.get("ms", round(ms, 1))}


# --- Reports ---


def by_series(rows):
    found = {}
    for row in rows:
        found.setdefault((row["subject"], row["sweep"]), []).append(row)
    return found


def cliffs(rows):
    """Where a series' metric grows faster than its input, or the GPU gives
    up on it or is far slower than the CPU, as lines of text."""
    found = []
    numeric = [r for r in rows if isinstance(r["x"], (int, float)) and "error" not in r]
    for a, b in zip(numeric, numeric[1:]):
        if not a["x"] or b["x"] == a["x"]:
            continue
        for metric, floor in FLOORS.items():
            ya, yb = a.get(metric), b.get(metric)
            if not ya or not yb or yb < floor:
                continue
            exponent = math.log(yb / ya) / math.log(b["x"] / a["x"])
            if exponent > EXPONENT:
                found.append(f"{NAMES[metric]} {ya:g} -> {yb:g} from {a['x']:g} to {b['x']:g} (power {exponent:.1f})")
        if "gpu_fallback" in b and "gpu_fallback" not in a:
            found.append(f"the GPU gives up at {b['x']:g}: {b['gpu_fallback']}")
    for r in rows:
        if slow_on_gpu(r):
            at = r["x"] if r["x"] is not None else "the example"
            found.append(f"the GPU {r['gpu_ms'] / r['cpu_ms']:.0f}x slower than the CPU at {at}: {r['gpu_ms']:g} ms")
    return found


def cell(value, digits=1):
    if value is None:
        return ""
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def ratio(rows, metric):
    """The last row's `metric` over the first's."""
    if len(rows) > 1 and rows[0].get(metric) and rows[-1].get(metric):
        return f"{rows[-1][metric] / rows[0][metric]:.1f}x"
    return ""


def report(rows):
    """costs.md for the rows of a costs.jsonl."""
    subjects = {}
    for (subject, sweep), series_rows in by_series(rows).items():
        subjects.setdefault(subject, {})[sweep] = series_rows
    loads = [r["load"] for r in rows if "load" in r]
    times = [r["at"] for r in rows if "at" in r]
    meta = rows[0] if rows else {}
    lines = [
        "# Costs",
        "",
        f"{len(rows)} programs" + (f" in {(times[-1] - times[0]) / 60:.0f} minutes" if times else "")
        + (f", at load averages from {min(loads):.0f} to {max(loads):.0f} on {os.cpu_count()} threads" if loads else "")
        + f"; frames {meta.get('size', '?')}, the fastest of {meta.get('repeat', '?')} after a warm one.",
        "CPU-s is the server's processor time per CPU frame, which other work on the machine sways less than the frame's time.",
        "Copies, nesting and terms keep their first program's bounds; the rest have their own.",
        "",
        "## Shapes and functions by CPU-s",
        "",
        "| name | kind | nodes | tape | regs | load ms | CPU ms | CPU-s | GPU ms | GPU 1st ms | 16 copies CPU-s | nest 3 nodes | notes |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    examples = [(s, sw["example"][0]) for s, sw in subjects.items() if "example" in sw]
    examples.sort(key=lambda e: -(e[1].get("cpu_cpu_s") or 0))
    for subject, r in examples:
        sweeps = subjects[subject]
        notes = r.get("error", "")[:80] or r.get("gpu_fallback", "")[:60]
        flagged = sum(len(cliffs(rs)) for rs in sweeps.values())
        if flagged:
            notes = (notes + f"; {flagged} cliffs").lstrip("; ")
        lines.append("| " + " | ".join([
            f"`{subject}`", r["kind"], cell(r.get("nodes")), cell(r.get("tape")),
            cell(r.get("registers")), cell(r.get("load_ms")), cell(r.get("cpu_ms")),
            cell(r.get("cpu_cpu_s"), 2), cell(r.get("gpu_ms")), cell(r.get("gpu_first_ms")),
            ratio(sweeps.get("union") or sweeps.get("terms") or [], "cpu_cpu_s"),
            ratio(sweeps.get("nest") or [], "nodes"), notes,
        ]) + " |")
    lines += ["", "## Cliffs", ""]
    for (subject, sweep), series_rows in by_series(rows).items():
        for line in cliffs(series_rows):
            lines.append(f"- `{subject}` {sweep}: {line}")
    lines += ["", "## Series", "", "CPU ms / CPU-s / GPU ms, nodes, at each x.", ""]
    for (subject, sweep), series_rows in by_series(rows).items():
        if sweep == "example":
            continue
        cells = []
        for r in series_rows:
            if "error" in r:
                cells.append(f"{r['x']}: error")
            else:
                cells.append(
                    f"{r['x']}: {cell(r.get('cpu_ms'))}/{cell(r.get('cpu_cpu_s'), 2)}/"
                    f"{cell(r.get('gpu_ms'))}, {r.get('nodes')}"
                )
        lines.append(f"- `{subject}` {sweep}: " + "; ".join(cells))
    failed = [r for r in rows if "error" in r]
    if failed:
        lines += ["", "## Failures", ""]
        for r in failed:
            lines.append(f"- `{r['subject']}` {r['sweep']} {r['x']}: {r['error'][:200]}")
    return "\n".join(lines) + "\n"


def compare(old, new):
    """Rows of two costs.jsonl that differ, as a Markdown table."""
    def load(path):
        with open(path) as f:
            return {(r["subject"], r["sweep"], str(r["x"])): r for r in map(json.loads, f)}

    a, b = load(old), load(new)
    lines = [
        "| name | sweep | x | nodes | CPU ms | GPU ms | load ms |",
        "|---|---|---|---|---|---|---|",
    ]
    changes = []
    totals = {m: [0.0, 0.0] for m in ("cpu_ms", "gpu_ms", "load_ms")}
    failed = 0
    for key in a.keys() & b.keys():
        ra, rb = a[key], b[key]
        if "error" in ra or "error" in rb:
            failed += 1
            continue
        for m in totals:
            totals[m][0] += ra.get(m) or 0
            totals[m][1] += rb.get(m) or 0
        ratios = [rb[m] / ra[m] for m in ("cpu_ms", "gpu_ms", "nodes") if ra.get(m) and rb.get(m)]
        if ratios and max(abs(math.log(r)) for r in ratios) > math.log(1.2):
            changes.append((max(ratios, key=lambda r: abs(math.log(r))), key, ra, rb))
    changes.sort(key=lambda c: -abs(math.log(c[0])))
    for _, key, ra, rb in changes:
        cells = [f"`{key[0]}`", key[1], key[2]]
        for m in ("nodes", "cpu_ms", "gpu_ms", "load_ms"):
            cells.append(f"{cell(ra.get(m))} -> {cell(rb.get(m))}")
        lines.append("| " + " | ".join(cells) + " |")
    summary = ", ".join(f"{m} {t[0]:.0f} -> {t[1]:.0f}" for m, t in totals.items())
    only = (f"; {failed} failed in either, only in old {len(a.keys() - b.keys())}, "
            f"only in new {len(b.keys() - a.keys())}")
    return f"{len(a.keys() & b.keys())} programs in both: {summary}{only}.\n\n" + "\n".join(lines)
