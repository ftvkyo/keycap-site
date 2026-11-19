# SPDX-License-Identifier: MPL-2.0

"""Fuzzing and cost measurement for keycap-server and the prelude.

    python3 server/fuzz costs [--only NAME,...] [--export]
    python3 server/fuzz fuzz [--mode valid|invalid] [--minutes M | --count N]
    python3 server/fuzz show [--mode valid|invalid] [--seed S] INDEX
    python3 server/fuzz compare OLD.jsonl NEW.jsonl
    python3 server/fuzz report COSTS.jsonl

What scripts can call comes from the server's `docs` reply.  `costs`
measures each shape and function of the docs, from its first example and
in sweeps (unions of copies, nesting, under transforms, its numbers
scaled), into costs.jsonl and costs.md.  `fuzz` loads random programs:
`valid` ones must load, render on both backends alike and export;
`invalid` ones, each with one mistake, must fail with an error on the
mistake.  What misbehaves is shrunk to a small repro, in repros/, and
listed in fuzz-MODE-SEED.md and findings.jsonl.  Neither may make the
server panic or hang.  Results go to TREE/server/target/fuzz, or --out.

`--tree DIR` measures another checkout's server and prelude, so that two
can be compared on the same programs."""

import argparse
import json
import os
import sys
from pathlib import Path

import catalogue
import fuzzing
import measure
from harness import Server

HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(prog="fuzz", description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)

    def command(name, help):
        sub = commands.add_parser(name, help=help)
        sub.add_argument("--tree", help="the checkout whose server and prelude to run (this one)")
        sub.add_argument("--server", help="the server binary (TREE/server/target/release/keycap-server)")
        sub.add_argument("--prelude", help="the prelude directory (TREE/prelude)")
        sub.add_argument("--threads", type=int, help="the server's --threads")
        sub.add_argument("--out", help="where results go (TREE/server/target/fuzz)")
        return sub

    costs = command("costs", "measure every shape and function")
    costs.add_argument("--only", help="names to measure, comma-separated")
    costs.add_argument("--sweeps", default="union,nest,under,numbers",
                       help="sweeps besides the example (union,nest,under,numbers; example for none)")
    costs.add_argument("--size", default="640x480", help="frame size")
    costs.add_argument("--backends", default="cpu,gpu")
    costs.add_argument("--repeat", type=int, default=2, help="frames timed after a warm one")
    costs.add_argument("--export", action="store_true", help="time a mesh or trace too (slow)")

    fuzz = command("fuzz", "load random programs, valid or with one mistake each")
    fuzz.add_argument("--mode", choices=["valid", "invalid"], default="valid")
    fuzz.add_argument("--seed", default="0")
    fuzz.add_argument("--start", type=int, default=0, help="the first program's index")
    fuzz.add_argument("--count", type=int, default=0, help="programs to try (no limit)")
    fuzz.add_argument("--minutes", type=float, default=5.0, help="time to fuzz for")
    fuzz.add_argument("--size", type=int, default=12, help="calls per program at most")
    fuzz.add_argument("--depth", type=int, default=4, help="nesting of shapes at most")
    fuzz.add_argument("--no-gpu", action="store_true", help="skip the GPU's frames")
    fuzz.add_argument("--no-export", action="store_true", help="skip the low-resolution exports")
    fuzz.add_argument("--no-shrink", action="store_true")

    show = command("show", "print a fuzzed program")
    show.add_argument("--mode", choices=["valid", "invalid"], default="valid")
    show.add_argument("--seed", default="0")
    show.add_argument("--size", type=int, default=12)
    show.add_argument("--depth", type=int, default=4)
    show.add_argument("index", type=int)

    compare = commands.add_parser("compare", help="compare two costs.jsonl")
    compare.add_argument("old")
    compare.add_argument("new")

    report = commands.add_parser("report", help="write costs.md again from a costs.jsonl")
    report.add_argument("costs")

    o = parser.parse_args()
    if o.command == "compare":
        print(measure.compare(o.old, o.new))
        return
    if o.command == "report":
        path = Path(o.costs)
        with open(path) as f:
            rows = [json.loads(line) for line in f]
        path.with_suffix(".md").write_text(measure.report(rows))
        return

    tree = Path(o.tree).resolve() if o.tree else HERE.parent.parent
    binary = o.server or str(tree / "server/target/release/keycap-server")
    prelude = o.prelude or str(tree / "prelude")
    if not os.access(binary, os.X_OK):
        sys.exit(f"fuzz: no server at {binary}; `just server-build` builds it")
    server = Server(binary, prelude, o.threads)
    try:
        docs, _ = server.call({"op": "docs"})
        entries = catalogue.entries(docs)
        values = catalogue.example_values(entries)
        if o.command == "show":
            program, what = fuzzing.make(entries, values, o, o.index, server)
            print(program.text()[0], end="")
            if what:
                print(f"// mistake: {what}")
            return
        out = Path(o.out) if o.out else tree / "server/target/fuzz"
        out.mkdir(parents=True, exist_ok=True)
        if o.command == "costs":
            measure.costs(server, entries, values, o, out)
        else:
            fuzzing.fuzz(server, entries, values, o, out)
    finally:
        server.stop()


if __name__ == "__main__":
    main()
