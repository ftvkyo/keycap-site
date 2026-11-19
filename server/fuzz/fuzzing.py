# SPDX-License-Identifier: MPL-2.0

"""The fuzzing loop: programs made from a seed and an index, checked,
and each kind of misbehaviour shrunk to a repro once."""

import collections
import json
import os
import random
import re
import tempfile
import time

from harness import Died, errors, script_location
from programs import Generator, Skip, line_column, mutate, offset_of, shrink

LOAD_TIMEOUT = 30.0
RENDER_TIMEOUT = 60.0
# Slower than this at the fuzzer's small sizes is a finding of its own.
SLOW_MS = 10_000
FRAME = (160, 120)
# Fewer pixels than this differing between the backends' mono frames is
# the GPU's voxels being a little off the CPU's.
MISMATCH = 0.05
# Cells across the fitted bounds of the fuzzer's exports
EXPORT_CELLS = 24
# What an export says when it has nothing to do or not the memory to do it
EXPORT_REFUSALS = re.compile(r"is empty|nothing|memory")

# Outcomes that are findings, as opposed to ok, rejected (a valid
# program refused with the prelude's own message), caught (a mistake
# refused on its token) and accepted (a mistake that loads)
FINDINGS = {
    "panic", "timeout", "slow", "leak", "render-error", "gpu-mismatch",
    "export-error", "misplaced", "unlocated",
}


class Outcome:
    def __init__(self, kind, message="", **row):
        self.kind, self.message, self.row = kind, message, row

    def key(self):
        return self.kind, template(self.message)


def template(message):
    """`message` with its numbers, strings and paths made generic."""
    message = re.sub(r"/\S+/", "", message)
    message = re.sub(r"anon\$\w+", "anon$", message)
    message = re.sub(r'"[^"]*"', '"…"', message)
    return re.sub(r"-?\d+(\.\d+)?(e-?\d+)?", "N", message)[:200]


def make(entries, values, o, index, server=None):
    """The program of `index` in a run, and its mistake in `invalid`
    mode; the same for the same seed.  Given the server, a mistake goes
    into a program that loads, so that its error is the mistake's."""
    rng = random.Random(f"{o.seed}:{o.mode}:{index}")
    generator = Generator(entries, values, rng, o.size, o.depth)
    comment = f"fuzz {o.mode} --seed {o.seed} {index}"
    for _ in range(50):
        try:
            program = generator.program(comment)
        except Skip:
            continue
        if o.mode == "valid":
            return program, None
        if server:
            loaded = loads(server, program)
            # A program that brings the server down is a finding as it is.
            if loaded is None:
                return program, None
            if not loaded:
                continue
        mutated = mutate(program, rng, entries)
        if mutated:
            return mutated
    raise RuntimeError(f"no program for index {index}")


def loads(server, program):
    """Whether `program` loads; None when the server died of it."""
    try:
        return bool(server.load(program.text()[0], LOAD_TIMEOUT)[0].get("loaded"))
    except Died:
        return None


# --- Checks ---


def leaks(diagnostic):
    """Whether an error is Rhai's or Rust's own words from inside the
    prelude or the server, rather than a message written for the script."""
    message = diagnostic.get("message", "")
    if re.search(r"unwrap|panicked|anon\$|\bNone\b|RUST_BACKTRACE", message):
        return True
    return "file" in diagnostic and not re.match(r"[A-Za-z_][\w:]*: ", message)


def check(server, program, what, o):
    text, marks = program.text()
    try:
        reply, _ = server.load(text, LOAD_TIMEOUT)
        if what is None:
            return valid(server, reply, o)
        return invalid(text, marks, reply, what)
    except Died as died:
        # Rust's panic is a line of where, then a line of what.
        lines = died.detail.splitlines()
        at = [i for i, l in enumerate(lines) if "panicked at" in l]
        if at:
            return Outcome(died.why, " ".join(lines[at[-1] : at[-1] + 2]))
        return Outcome(died.why, died.detail[-300:])


def valid(server, reply, o):
    row = dict(load_ms=reply.get("ms"))
    if not reply.get("loaded"):
        error = (errors(reply) or [{"message": "no error, yet not loaded"}])[0]
        return Outcome("leak" if leaks(error) else "rejected", error["message"], **row)
    if reply["ms"] > SLOW_MS:
        return Outcome("slow", f"load took {reply['ms']} ms", **row)
    stats, _ = server.call({"op": "stats"}, LOAD_TIMEOUT)
    row.update({k: stats.get(k) for k in ("nodes", "tape", "registers")})
    frames = {}
    for backend in ["cpu"] if o.no_gpu else ["cpu", "gpu"]:
        frame, _ = server.render(*FRAME, backend, "mono", RENDER_TIMEOUT)
        if "error" in frame:
            return Outcome("render-error", frame["error"], **row)
        if frame["ms"] > SLOW_MS:
            return Outcome("slow", f"{backend} frame took {frame['ms']} ms", **row)
        row[f"{backend}_ms"] = frame["ms"]
        if frame["backend"] == backend:
            frames[backend] = server.pixels()
        else:
            row["fallback"] = frame.get("fallback")
    if len(frames) == 2:
        a, b = frames["cpu"], frames["gpu"]
        differ = sum(a[i] != b[i] for i in range(0, len(a), 3)) / (len(a) // 3)
        if differ > MISMATCH:
            return Outcome("gpu-mismatch", f"{differ:.0%} of the mono frame differs", **row)
    frame, _ = server.render(*FRAME, "cpu", "shaded", RENDER_TIMEOUT)
    if "error" in frame:
        return Outcome("render-error", frame["error"], **row)
    if not o.no_export:
        outcome = export(server, reply, row)
        if outcome:
            return outcome
    return Outcome("ok", **row)


def export(server, reply, row):
    fitted = reply["bounds"]["fitted"]
    if not fitted or None in fitted["lower"] + fitted["upper"]:
        return None
    span = max(u - l for l, u in zip(fitted["lower"], fitted["upper"]))
    flat = fitted["lower"][2] == fitted["upper"][2]
    resolution = EXPORT_CELLS / max(span, 1)
    output = os.path.join(tempfile.gettempdir(), f"keycap-fuzz-{os.getpid()}")
    if flat:
        request = dict(op="trace", output=output + ".svg", format="svg", resolution=resolution)
    else:
        request = dict(op="mesh", output=output + ".stl", resolution=resolution)
    done, ms = server.call(request, RENDER_TIMEOUT)
    row["export_ms"] = round(ms, 1)
    if "error" in done and not EXPORT_REFUSALS.search(done["error"]):
        return Outcome("export-error", done["error"], **row)
    if ms > SLOW_MS:
        return Outcome("slow", f"{request['op']} took {ms:.0f} ms", **row)
    return None


def invalid(text, marks, reply, what):
    if reply.get("loaded"):
        return Outcome("accepted", what)
    error = (errors(reply) or [None])[0]
    if not error:
        return Outcome("unlocated", "not loaded, yet no error")
    message = error["message"]
    if leaks(error):
        return Outcome("leak", message)
    at = script_location(error)
    if not at:
        return Outcome("unlocated", message)
    offset = offset_of(text, *at)
    if "call" not in marks:
        return Outcome("lost", "the mistake was shrunk away")
    start, end = marks["call"]
    if what.startswith("syntax"):
        # The parser finds the mistake where it stops making sense, which
        # may be past the call, but not before it.
        fine = start <= offset and at[0] <= line_column(text, end)[0] + 1
    else:
        fine = start <= offset <= end
    if not fine:
        where = f"at {at[0]}:{at[1]}, not in {line_column(text, start)}-{line_column(text, end)}"
        return Outcome("misplaced", f"{message} ({where})")
    return Outcome("caught", message)


# --- The loop ---


def fuzz(server, entries, values, o, out):
    name = f"fuzz-{o.mode}-{o.seed}"
    log = open(out / f"{name}.jsonl", "a")
    repros = out / "repros"
    repros.mkdir(exist_ok=True)
    found = {}
    counts = collections.Counter()
    messages = collections.Counter()
    first = {}
    deadline = time.monotonic() + o.minutes * 60
    index = o.start
    last_report = time.monotonic()
    while (o.count and index < o.start + o.count) or (not o.count and time.monotonic() < deadline):
        program, what = make(entries, values, o, index, server)
        start = time.perf_counter()
        outcome = check(server, program, what, o)
        counts[outcome.kind] += 1
        if outcome.kind in ("rejected", "accepted"):
            key = (outcome.kind, template(what if outcome.kind == "accepted" else outcome.message))
            messages[key] += 1
            first.setdefault(key, index)
        row = dict(
            index=index, outcome=outcome.kind, message=outcome.message[:300], mistake=what,
            wall_ms=round((time.perf_counter() - start) * 1e3, 1), **outcome.row,
        )
        # Findings of one kind may have different causes; each keeps its program.
        if outcome.kind in FINDINGS:
            row["source"] = program.text()[0]
        log.write(json.dumps(row) + "\n")
        log.flush()
        if outcome.kind in FINDINGS:
            key = outcome.key()
            if key in found:
                found[key]["count"] += 1
            else:
                found[key] = record(server, program, what, outcome, index, o, repros)
                print(f"{index}: {outcome.kind}: {outcome.message[:160]}", flush=True)
        if time.monotonic() - last_report > 60:
            last_report = time.monotonic()
            print(f"{index + 1 - o.start} programs: {dict(counts)}", flush=True)
        index += 1
    summary = report(o, name, index - o.start, counts, found, messages, first)
    (out / f"{name}.md").write_text(summary)
    with open(out / "findings.jsonl", "a") as f:
        for finding in found.values():
            f.write(json.dumps(finding) + "\n")
    print(summary)


def record(server, program, what, outcome, index, o, repros):
    """A new finding, its program shrunk to a repro that still shows it."""
    text = program.text()[0]
    small = program
    if not o.no_shrink:
        key = outcome.key()

        def fails(candidate):
            return check(server, candidate, what, o).key() == key

        attempts = 30 if outcome.kind in ("timeout", "slow") else 300
        small = shrink(program, fails, attempts)
    repro = small.text()[0]
    if what:
        repro += f"// mistake: {what}\n"
    path = repros / f"{o.mode}-{o.seed}-{index}-{outcome.kind}.keycap"
    path.write_text(repro)
    return dict(
        kind=outcome.kind, message=outcome.message, mode=o.mode, seed=o.seed, index=index,
        mistake=what, count=1, program=text, repro=repro, path=str(path),
    )


def report(o, name, tried, counts, found, messages, first):
    lines = [f"# {name}", "", f"{tried} programs: " + ", ".join(
        f"{n} {kind}" for kind, n in counts.most_common()), ""]
    lines += ["## Findings", ""]
    if not found:
        lines.append("None.")
    for finding in sorted(found.values(), key=lambda f: (f["kind"], -f["count"])):
        lines += [
            f"### {finding['kind']} ({finding['count']}x): {finding['message'][:200]}",
            "",
            f"First at {finding['index']}" + (f", mistake {finding['mistake']}" if finding["mistake"] else "")
            + f"; `{finding['path']}`:",
            "",
            "```",
            finding["repro"].rstrip(),
            "```",
            "",
        ]
    label = "Rejected valid programs" if o.mode == "valid" else "Accepted mistakes"
    lines += [f"## {label}, most common first", ""]
    for (kind, message), n in messages.most_common(40):
        lines.append(f"- {n}x `{message}` (first at {first[(kind, message)]})")
    return "\n".join(lines) + "\n"
