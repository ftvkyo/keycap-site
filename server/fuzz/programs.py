# SPDX-License-Identifier: MPL-2.0

"""Random keycap programs, typed by the docs' signatures: valid ones to
load and render, mutated ones that must fail with an error on the right
token, and the shrinking of a program that misbehaves to a small one that
still does."""

import copy
import json
import math

from catalogue import mentions

# --- Ranges ---

# What the examples do not show well, as (low, high), integers when both
# are; by (function, parameter) or by parameter alone.
RANGES = {
    ("squircle", "s"): (0.1, 0.99),
    ("squircle_ray", "s"): (0.1, 0.99),
    ("recurse", "levels"): (1, 3),
    ("involute_gear", "teeth"): (8, 40),
    ("gear_radii", "teeth"): (8, 40),
    ("star", "n"): (3, 12),
    ("star_ray", "n"): (3, 12),
    ("regular_polygon", "n"): (3, 12),
    ("polygon_ray", "n"): (3, 12),
    ("kaleidoscope", "n"): (2, 12),
    ("hex_grid", "rings"): (1, 3),
    (None, "sides"): (3, 32),
    (None, "angle"): (-180.0, 180.0),
    (None, "twist"): (-90.0, 90.0),
    (None, "tilt"): (-30.0, 30.0),
    (None, "t"): (0.0, 1.0),
    (None, "k"): (0.5, 4.0),
    (None, "r"): (1.0, 15.0),
}

# Shapes whose shape arguments are solids, though their kind is `extrude`
SOLID_INPUTS = {"twist", "bend", "normalize_z", "normalize_slope"}

# Transforms that turn a 2D shape out of its plane
OUT_OF_PLANE = {
    "rotate", "rotate_x", "rotate_y", "rotate_xyz", "reflect_z", "symmetric_z", "half",
}

# Trees that must vary in space, by the coordinate they vary along
COORDINATES = {
    ("remap", "x"): "x",
    ("remap", "y"): "y",
    ("remap", "z"): "z",
    ("twist", "angle"): "z",
}

# Never generated: reading a file, or nothing to draw
SKIP = {"svg", "draw", "draw_rgb", "bounds", "resolution", "to_string", "axes"}

EASES = [
    "linear", "in_sine", "out_sine", "in_out_sine", "in_quadratic", "out_quadratic",
    "in_out_quadratic", "in_cubic", "out_cubic", "in_out_cubic", "in_asine", "out_asine",
    "in_out_asine", "in_elastic", "out_elastic", "in_out_elastic", "in_bounce",
    "out_bounce", "in_out_bounce",
]


class Skip(Exception):
    """A type the generator cannot make a value of."""


# --- Syntax ---


class Node:
    """An expression: `kind` is num, str, bool, raw, array, map, call, op
    or closure; `value` the number, text, name, operator, keys or
    parameters; `type` what it was made as and `dim` a shape's dimensions,
    for the shrinker; `mark` the target of a mutation, `edit` a syntax
    error to write into its text."""

    __slots__ = ("kind", "value", "kids", "type", "dim", "method", "mark", "edit", "optional")

    def __init__(self, kind, value=None, kids=(), type=None, dim=None, method=False):
        self.kind = kind
        self.value = value
        self.kids = list(kids)
        self.type = type
        self.dim = dim
        self.method = method
        self.mark = None
        self.edit = None
        # How many of a call's last arguments may be left out
        self.optional = 0

    def walk(self, path=()):
        yield path, self
        for i, kid in enumerate(self.kids):
            yield from kid.walk(path + (i,))


def number(value):
    if isinstance(value, int) and not isinstance(value, bool):
        return str(value)
    if 0 < abs(value) < 1e-3:
        return f"{value:.1e}"
    text = f"{value:.3f}".rstrip("0")
    return text + "0" if text.endswith(".") else text


class Program:
    """Statements, each ("let", name, node), ("draw", node) or
    ("raw", text), after the imports `headers`."""

    def __init__(self, statements, headers=(), comment=""):
        self.statements = statements
        self.headers = sorted(headers)
        self.comment = comment

    def nodes(self):
        for i, statement in enumerate(self.statements):
            if statement[0] != "raw":
                yield from statement[-1].walk((i,))

    def text(self):
        """The source and the spans of the marked nodes, by mark."""
        body = Writer()
        for statement in self.statements:
            if statement[0] == "raw":
                body.write(statement[1] + "\n")
            elif statement[0] == "let":
                body.write(f"let {statement[1]} = ")
                body.node(statement[2])
                body.write(";\n")
            else:
                body.write("draw(")
                body.node(statement[1])
                body.write(");\n")
        # The imports of the modules called, as the shrinker leaves them
        head = f"// {self.comment}\n" if self.comment else ""
        for header in self.headers:
            if header.rsplit(" ", 1)[-1].rstrip(";") + "::" in body.text:
                head += header + "\n"
        marks = {k: (a + len(head), b + len(head)) for k, (a, b) in body.marks.items()}
        return head + body.text, marks

    def replace(self, path, node):
        """A copy with the node at `path` replaced."""
        program = copy.deepcopy(self)
        statement = list(program.statements[path[0]])
        if len(path) == 1:
            statement[-1] = node
        else:
            parent = statement[-1]
            for i in path[1:-1]:
                parent = parent.kids[i]
            parent.kids[path[-1]] = node
        program.statements[path[0]] = tuple(statement)
        return program


class Writer:
    def __init__(self):
        self.text = ""
        self.marks = {}

    def write(self, text):
        self.text += text

    def node(self, n):
        start = len(self.text)
        kind = n.kind
        if kind == "num":
            self.write(number(n.value))
        elif kind == "str":
            self.write(json.dumps(n.value))
        elif kind == "bool":
            self.write("true" if n.value else "false")
        elif kind == "raw":
            self.write(n.value)
        elif kind == "array":
            self.write("[")
            self.join(n.kids)
            self.write("]")
        elif kind == "map":
            self.write("#{")
            for i, (key, kid) in enumerate(zip(n.value, n.kids)):
                self.write(", " if i else "")
                self.write(f"{key}: ")
                self.node(kid)
            self.write("}")
        elif kind == "call":
            args = n.kids
            if n.method:
                receiver, args = args[0], args[1:]
                self.node(receiver)
                self.write(".")
            self.write(f"{n.value}(")
            self.join(args)
            self.write(")")
        elif kind == "op":
            if len(n.kids) == 1:
                self.write(f"{n.value}(")
                self.node(n.kids[0])
                self.write(")")
            else:
                self.write("(")
                self.node(n.kids[0])
                self.write(f" {n.value} ")
                self.node(n.kids[1])
                self.write(")")
        elif kind == "closure":
            self.write("|" + ", ".join(n.value) + "| ")
            self.node(n.kids[0])
        if n.edit:
            self.text = self.text[:start] + n.edit(self.text[start:])
        if n.mark:
            self.marks[n.mark] = (start, len(self.text))

    def join(self, kids):
        for i, kid in enumerate(kids):
            self.write(", " if i else "")
            self.node(kid)


def expression(node):
    """The text of one expression."""
    w = Writer()
    w.node(node)
    return w.text


def line_column(text, offset):
    line = text.count("\n", 0, offset) + 1
    return line, offset - (text.rfind("\n", 0, offset) + 1) + 1


def offset_of(text, line, column):
    lines = text.split("\n")
    return sum(len(l) + 1 for l in lines[: line - 1]) + column - 1


# --- Generation ---


class Hint:
    """Where a value goes: the entry and parameter, for ranges; the
    dimensions a shape should have; how much deeper calls may nest."""

    def __init__(self, entry, name, dim, depth):
        self.entry, self.name, self.dim, self.depth = entry, name, dim, depth

    def but(self, **changes):
        hint = copy.copy(self)
        hint.__dict__.update(changes)
        return hint


class Generator:
    """Programs drawn from `rng`.  `typical` makes every value the
    examples' middle one and leaves optional arguments out, for programs
    that measure one thing at a time."""

    def __init__(self, catalogue, values, rng, size=12, depth=4, typical=False):
        self.catalogue = catalogue
        self.values = values
        self.rng = rng
        self.size = size
        self.depth = depth
        self.typical = typical
        self.fresh()
        self.shapes = []
        self.trees = []
        self.producers = {}
        for entry in catalogue.values():
            if entry.name in SKIP:
                continue
            for s in entry.signatures:
                if s.method and not s.params:
                    continue
                if mentions(s.returns, "Shape"):
                    self.shapes.append((entry, s))
                elif mentions(s.returns, "Tree") and all(
                    not mentions(p.type, "Shape") and not mentions(p.type, "Ray")
                    for p in s.params
                ):
                    self.trees.append((entry, s))
                if s.returns and s.returns[0] == "name" and not s.method:
                    self.producers.setdefault(s.returns[1], []).append((entry, s))

    # --- Programs ---

    def fresh(self):
        self.budget = self.size
        self.headers = set()
        # The shapes `let` has bound, and the closures' parameters
        self.scope = []
        self.numbers = []

    def program(self, comment=""):
        self.fresh()
        dim = 3 if self.rng.random() < 0.7 else 2
        statements = []
        if self.rng.random() < 0.1:
            statements.append(("raw", "bounds([-30, -30, -30], [30, 30, 30]);"))
        for i in range(self.rng.choice([0, 0, 1, 2])):
            statements.append(("let", f"s{i}", self.shape(dim, self.depth)))
            self.scope.append((f"s{i}", dim))
        for _ in range(self.rng.choice([1, 1, 1, 2])):
            statements.append(("draw", self.shape(dim, self.depth)))
        return Program(statements, self.headers, comment)

    def call(self, entry, s, hint, shapes=None):
        """A call of `entry` by signature `s`; `shapes`, when given, are the
        nodes its shape parameters take, in order."""
        if entry.header:
            self.headers.add(entry.header)
        args, optional = [], 0
        method = s.method
        params = list(s.params)
        if method:
            params.insert(0, Param("shape", ("name", "Shape")))
        for param in params:
            if param.default is not None:
                # Typical calls leave out what they can, but for the shapes given.
                if self.typical:
                    if not (shapes and mentions(param.type, "Shape")):
                        break
                elif self.rng.random() < 0.6:
                    break
                optional += 1
            sub = hint.but(name=param.name, dim=self.input_dim(entry, hint.dim), depth=hint.depth - 1)
            if param.rest:
                count = 2 if self.typical else self.rng.randint(2, 4)
                for _ in range(count):
                    args.append(self.item(param.type[1], sub, shapes))
                optional += count - 1
                continue
            if shapes and takes_shape(param.type):
                shape = shapes.pop(0)
                if param.type[0] == "array":
                    shape = Node("array", None, [shape], type=param.type)
                args.append(shape)
                continue
            args.append(self.value(param.type, sub))
        node = Node("call", entry.name, args, type=s.returns, dim=hint.dim, method=method)
        node.optional = optional
        return node

    def item(self, t, hint, shapes):
        if shapes and t == ("name", "Shape"):
            return shapes.pop(0)
        return self.value(t, hint)

    def input_dim(self, entry, dim):
        if entry.kind == "extrude" and entry.name not in SOLID_INPUTS:
            return 2
        if entry.kind == "2d":
            return 2
        if entry.kind == "3d":
            return 3
        return dim

    def makes(self, entry, dim):
        """Whether `entry`'s shapes can have `dim` dimensions."""
        if entry.kind in ("2d",) or entry.name == "text":
            return dim == 2
        if entry.kind in ("3d", "extrude"):
            return dim == 3
        return not (dim == 2 and entry.name in OUT_OF_PLANE)

    def shape(self, dim, depth):
        if self.scope and self.rng.random() < 0.2:
            fits = [name for name, d in self.scope if d == dim]
            if fits:
                return Node("raw", self.rng.choice(fits), type=("name", "Shape"), dim=dim)
        leaf = depth <= 0 or self.budget <= 0 or self.rng.random() < 0.35
        options = [
            (e, s) for e, s in self.shapes
            if self.makes(e, dim) and leaf == (not any(
                mentions(p.type, "Shape") and p.default is None for p in s.params
            ) and not s.method)
        ]
        self.rng.shuffle(options)
        for entry, s in options[:8]:
            self.budget -= 1
            try:
                return self.call(entry, s, Hint(entry, None, dim, depth))
            except Skip:
                continue
        raise Skip(f"no {dim}D shape")

    # --- Values by type ---

    def value(self, t, hint):
        kind = t[0]
        if kind == "lit":
            text = t[1]
            if text.startswith('"'):
                return Node("str", text[1:-1], type=t)
            return Node("num", float(text) if "." in text else int(text), type=t)
        if kind == "union":
            options = list(t[1])
            self.rng.shuffle(options)
            if self.typical:
                # A size from a table before a number, as the examples have it
                order = {"string": 0, "number": 1, "Tree": 1}
                options.sort(key=lambda o: order.get(o[1], 2) if o[0] == "name" else 2)
            for option in options:
                try:
                    return self.value(option, hint)
                except Skip:
                    continue
            raise Skip(f"no value of {t}")
        if kind == "array":
            return self.array(t[1], hint)
        if kind == "tuple":
            items = [self.value(u, hint) for u in t[1]]
            if all(i.kind == "num" for i in items):
                # Ascending, as ranges and pairs of radii or angles are
                values = sorted(i.value for i in items)
                for k, (i, v) in enumerate(zip(items, values)):
                    i.value = v + k * max(1, abs(v)) if self.typical else v
            return Node("array", None, items, type=t)
        if kind == "map":
            keys, kids = [], []
            for key, optional, u in t[1]:
                if optional and (self.typical or self.rng.random() > 0.3):
                    continue
                keys.append(key)
                kids.append(self.value(u, hint.but(name=key)))
            return Node("map", keys, kids, type=t)
        if kind == "fn":
            names = [name for name, _ in t[1]]
            usable = [n for n, u in t[1] if u in (("name", "Tree"), ("name", "number"))]
            self.numbers.extend(usable)
            try:
                body = self.value(t[2], hint.but(depth=hint.depth - 1))
            finally:
                del self.numbers[len(self.numbers) - len(usable):]
            return Node("closure", names, [body], type=t)
        if kind == "name":
            return self.named(t[1], hint)
        raise Skip(f"no value of {t}")

    def named(self, name, hint):
        rng = self.rng
        if name == "number":
            return self.number(hint)
        if name == "Tree":
            return self.tree(hint)
        if name in ("Vec2", "Vec3"):
            n = 2 if name == "Vec2" else 3
            return Node("array", None, [self.number(hint) for _ in range(n)], type=("name", name))
        if name == "Shape":
            return self.shape(hint.dim, hint.depth)
        if name == "bool":
            return Node("bool", bool(rng.getrandbits(1)) if not self.typical else False, type=("name", name))
        if name == "string":
            return self.string(hint)
        if name == "Ease":
            makers = self.producers.get("Ease")
            if makers and not self.typical and rng.random() < 0.2:
                entry, s = rng.choice(makers)
                return self.call(entry, s, Hint(entry, None, hint.dim, hint.depth - 1))
            return Node("str", "in_out_sine" if self.typical else rng.choice(EASES), type=("name", name))
        if name == "Axis":
            return Node("str", "z" if self.typical else rng.choice("xyz"), type=("name", name))
        if name == "Height":
            if self.typical or rng.random() < 0.5:
                return self.number(hint.but(name="h"))
            lo, hi = sorted(self.number(hint.but(name="h"), literal=True).value for _ in range(2))
            return Node("array", None, [Node("num", lo), Node("num", hi + 1)], type=("name", name))
        if name == "Sched":
            roll = 0 if self.typical else rng.random()
            if roll < 0.7:
                return self.tree(hint)
            if roll < 0.85:
                return self.value(("fn", [("t", ("name", "Tree"))], ("name", "Tree")), hint)
            return self.keys(hint)
        if name == "Rim":
            if self.typical or rng.random() < 0.5:
                return self.named("Sched", hint)
            return Node("array", None, [self.named("Sched", hint), self.named("Sched", hint)])
        if name in ("Outline", "Point"):
            return self.polygon(hint)
        if name == "Key":
            return self.keys(hint).kids[0]
        if name == "()":
            return Node("raw", "()", type=("name", name))
        if name == "Slice":
            return self.slices(hint, 1).kids[0]
        if name == "Step":
            return self.steps(1).kids[0]
        if hint.entry and name in hint.entry.aliases:
            return self.value(hint.entry.aliases[name], hint)
        producers = self.producers.get(name)
        if producers:
            entry, s = producers[0] if self.typical else rng.choice(producers)
            return self.call(entry, s, Hint(entry, None, hint.dim, hint.depth - 1))
        raise Skip(f"no value of {name}")

    def array(self, t, hint):
        rng = self.rng
        name = t[1] if t[0] == "name" else None
        if name == "Key":
            return self.keys(hint)
        if name == "Point" or name == "Vec2" and hint.name in ("points", "a", "b"):
            return self.polygon(hint)
        if name == "Slice":
            return self.slices(hint, 2 if self.typical else rng.randint(2, 3))
        if name == "Step":
            return self.steps(2 if self.typical else rng.randint(1, 3))
        count = 2 if self.typical else rng.randint(2 if name == "Shape" else 1, 4)
        return Node("array", None, [self.value(t, hint) for _ in range(count)], type=("array", t))

    def number(self, hint, literal=False):
        if self.numbers and not literal and not self.typical and self.rng.random() < 0.2:
            return Node("raw", self.rng.choice(self.numbers), type=("name", "number"))
        lo, hi, integer, seen = self.range(hint)
        if self.typical:
            value = sorted(seen)[len(seen) // 2] if seen else (lo + hi) / 2
            value = round(value) if integer else value
        elif seen and self.rng.random() < 0.3:
            value = self.rng.choice(seen)
        elif integer:
            value = self.rng.randint(int(lo), int(hi))
        else:
            value = round(self.rng.uniform(lo, hi), 2)
        return Node("num", value, type=("name", "number"))

    def range(self, hint):
        """(low, high, integer, the examples' numbers) for `hint`'s parameter."""
        fn = hint.entry.name if hint.entry else None
        # The function's own range, then its examples', then those of the
        # parameter's name anywhere
        fixed, seen = None, []
        for key in ((fn, hint.name), (None, hint.name)):
            fixed = RANGES.get(key)
            seen = [v for v in flat(self.values.get(key, [])) if isinstance(v, (int, float))]
            if fixed or seen:
                break
        if fixed:
            lo, hi = fixed
            return lo, hi, isinstance(lo, int) and isinstance(hi, int), [v for v in seen if lo <= v <= hi]
        if not seen:
            return 0.5, 10.0, False, []
        lo, hi = min(seen), max(seen)
        integer = all(isinstance(v, int) for v in seen)
        lo = lo / 2 if lo > 0 else lo * 1.5
        hi = hi * 1.5 if hi > 0 else hi / 2
        if integer:
            lo, hi = math.floor(lo), math.ceil(hi)
            lo = max(lo, 1) if min(seen) >= 1 else lo
        if lo == hi:
            hi = lo + 1
        return lo, hi, integer, seen

    def tree(self, hint):
        coordinate = COORDINATES.get((hint.entry and hint.entry.name, hint.name))
        if coordinate:
            coordinate = Node("raw", coordinate)
            if hint.name != "angle" and (self.typical or self.rng.random() < 0.5):
                return coordinate
            operation = "*" if self.typical else self.rng.choice("+*")
            return Node("op", operation, [coordinate, self.number(hint.but(name="k"))], type=("name", "Tree"))
        if self.typical or hint.depth <= 0 or self.rng.random() < 0.75:
            return self.number(hint)
        roll = self.rng.random()
        if roll < 0.3:
            coordinate = Node("raw", self.rng.choice(self.numbers or ["x", "y", "z"]))
            return Node("op", self.rng.choice("+-*"), [coordinate, self.number(hint)], type=("name", "Tree"))
        options = list(self.trees)
        self.rng.shuffle(options)
        for entry, s in options[:5]:
            try:
                return self.call(entry, s, Hint(entry, None, hint.dim, hint.depth - 1))
            except Skip:
                continue
        return self.number(hint)

    def string(self, hint):
        fn = hint.entry.name if hint.entry else None
        for key in ((fn, hint.name), (None, hint.name)):
            seen = [v for v in flat(self.values.get(key, [])) if isinstance(v, str)]
            if seen:
                value = seen[0] if self.typical else self.rng.choice(seen)
                return Node("str", value, type=("name", "string"))
        if hint.name == "string":
            return Node("str", "Fuzz", type=("name", "string"))
        raise Skip(f"no string for {fn} {hint.name}")

    def polygon(self, hint):
        if hint.entry and hint.entry.name == "bezier_graph":
            # A graph's control points run to the right.
            ys = [5, 8, 3, 6] if self.typical else [round(self.rng.uniform(0, 10), 2) for _ in range(4)]
            points = [Node("array", None, [Node("num", 5 * i), Node("num", y)]) for i, y in enumerate(ys)]
            return Node("array", None, points, type=("name", "Outline"))
        n = 4 if self.typical else self.rng.randint(3, 7)
        r = 10.0
        angles = [i / n for i in range(n)] if self.typical else sorted(self.rng.random() for _ in range(n))
        points = []
        for a in angles:
            radius = r if self.typical else r * self.rng.uniform(0.5, 1.0)
            points.append(Node("array", None, [
                Node("num", round(radius * math.cos(a * math.tau), 2)),
                Node("num", round(radius * math.sin(a * math.tau), 2)),
            ]))
        return Node("array", None, points, type=("name", "Outline"))

    def keys(self, hint):
        n = 2 if self.typical else self.rng.randint(2, 4)
        ts = [i * 10 for i in range(n)]
        keys = []
        for i, t in enumerate(ts):
            key = [Node("num", t), self.number(hint.but(name="r"))]
            if i and not self.typical and self.rng.random() < 0.4:
                key.append(Node("str", self.rng.choice(EASES)))
            keys.append(Node("array", None, key, type=("name", "Key")))
        return Node("array", None, keys, type=("array", ("name", "Key")))

    def slices(self, hint, n):
        slices = []
        for i in range(n):
            keys = ["z", "shape"]
            kids = [Node("num", i * 10), self.shape(2, hint.depth - 1)]
            if not self.typical and self.rng.random() < 0.4:
                keys.append("scale")
                kids.append(Node("num", round(self.rng.uniform(0.5, 1.5), 2)))
            if i and not self.typical and self.rng.random() < 0.4:
                keys.append("ease")
                kids.append(Node("str", self.rng.choice(EASES)))
            slices.append(Node("map", keys, kids, type=("name", "Slice")))
        return Node("array", None, slices, type=("array", ("name", "Slice")))

    def steps(self, n):
        steps = []
        for i in range(n):
            roll = 0 if self.typical or i == 0 else self.rng.random()
            if roll < 0.5:
                steps.append(Node("map", ["line"], [Node("num", 10)]))
            elif roll < 0.8:
                steps.append(Node("map", ["arc", "turn"], [Node("num", 8), Node("num", self.rng.choice([45, 90, 180]))]))
            else:
                steps.append(Node("map", ["helix", "turn", "rise"], [Node("num", 10), Node("num", 270), Node("num", 10)]))
        return Node("array", None, steps, type=("array", ("name", "Step")))


def takes_shape(t):
    """Whether a parameter of type `t` takes one shape, or an array of them."""
    if t == ("name", "Shape") or t == ("array", ("name", "Shape")):
        return True
    return t[0] == "union" and ("name", "Shape") in t[1]


class Param:
    def __init__(self, name, type):
        self.name, self.type, self.default, self.rest = name, type, None, False


def flat(values):
    for v in values:
        if isinstance(v, list):
            yield from flat(v)
        else:
            yield v


# --- Mutations ---

# Values of each kind, to put where another kind belongs
WRONG = {
    "string": lambda: Node("str", "oops"),
    "number": lambda: Node("num", 2),
    "array": lambda: Node("array", None, [Node("num", 1), Node("num", 2)]),
    "map": lambda: Node("map", ["bogus"], [Node("num", 1)]),
    "shape": lambda: Node("call", "sphere", [Node("num", 1)]),
    "closure": lambda: Node("closure", ["t"], [Node("raw", "t")]),
    "bool": lambda: Node("bool", True),
    "unit": lambda: Node("raw", "()"),
}

# Out of most domains
EXTREMES = [0, -1, -25.5, 0.5, 1_000_000, 1e-9]

# Text edits that make a syntax error
SYNTAX = [
    ("drop the last character", lambda s: s[:-1]),
    ("drop the first character", lambda s: s[1:]),
    ("a stray comma", lambda s: s + ","),
    ("an unclosed bracket", lambda s: "(" + s),
    ("an unterminated string", lambda s: s + ' "'),
    ("a stray semicolon", lambda s: s + ";"),
    ("a doubled operator", lambda s: s + " * *"),
]


def accepts(t, kind):
    """Whether a parameter of type `t` takes a value of `kind`, roughly."""
    if t is None:
        return True
    names = {
        "string": ("string", "Ease", "Axis", "Anchor2", "Anchor3", "Smooth"),
        "number": ("number", "Tree", "Height", "Sched", "Rim", "Vec2", "Vec3", "Anchor2", "Anchor3"),
        "array": ("Vec2", "Vec3", "Height", "Rim", "Outline", "Anchor2", "Anchor3", "Sched", "Move", "Key"),
        "map": ("Ray", "Section", "Slice", "Step", "Plane", "Metric"),
        "shape": ("Shape", "Tree", "Sched", "Rim"),
        "closure": ("Sched", "Rim", "Move", "Ease"),
        "bool": ("bool",),
        "unit": ("()",),
    }[kind]
    shapes = {"string": "lit", "array": ("array", "tuple"), "map": ("map", "dict"), "closure": "fn"}
    def walk(u):
        if u[0] == "name":
            return u[1] in names
        if u[0] == "union":
            return any(walk(o) for o in u[1])
        if u[0] == "lit":
            return kind == ("string" if u[1].startswith('"') else "number")
        return u[0] in (shapes.get(kind) or ())
    return walk(t)


def arities(entry):
    """The numbers of arguments `entry`'s calls take, the receiver of a
    method counted."""
    found = set()
    for s in entry.signatures:
        params = s.params + ([None] if s.method else [])
        if any(p and p.rest for p in params):
            return range(1 << 8)
        required = sum(1 for p in params if p is None or p.default is None)
        found.update(range(required, len(params) + 1))
    return found


def mutate(program, rng, catalogue):
    """A copy of `program` with one mistake, and what the mistake is; its
    target node is marked `target`, the call taking it `call`."""
    calls = [(path, node) for path, node in program.nodes() if node.kind == "call"]
    if not calls:
        return None
    path, call = rng.choice(calls)
    program = copy.deepcopy(program)
    call = node_at(program, path)
    call.mark = "call"
    kinds = ["type", "type", "domain", "drop", "extra", "name", "syntax", "key"]
    rng.shuffle(kinds)
    # Arguments too few or too many for one form may suit another.
    entry = catalogue.get(call.value)
    fits = arities(entry) if entry else ()
    for kind in kinds:
        if kind == "drop" and len(call.kids) - 1 in fits or kind == "extra" and len(call.kids) + 1 in fits:
            continue
        args = list(range(1 if call.method else 0, len(call.kids)))
        if kind == "type" and args:
            i = rng.choice(args)
            options = [k for k in WRONG if not accepts(call.kids[i].type, k)]
            if not options:
                continue
            wrong = rng.choice(options)
            call.kids[i] = WRONG[wrong]()
            call.kids[i].mark = "target"
            return program, f"type: {wrong} for {call.value} argument {i + 1}"
        if kind == "domain":
            numbers = [n for _, n in call.walk() if n.kind == "num" and n is not call]
            if not numbers:
                continue
            target = rng.choice(numbers)
            target.value = rng.choice(EXTREMES)
            target.mark = "target"
            return program, f"domain: {number(target.value)} in {call.value}"
        if kind == "drop" and len(call.kids) > call.optional + (1 if call.method else 0):
            i = rng.choice(args[: len(call.kids) - call.optional - (1 if call.method else 0)] or args)
            del call.kids[i]
            return program, f"arity: {call.value} without argument {i + 1}"
        if kind == "extra":
            call.kids.append(Node("num", 7))
            call.kids[-1].mark = "target"
            return program, f"arity: {call.value} with an extra argument"
        if kind == "name":
            call.value += "_x"
            return program, f"name: {call.value}"
        if kind == "syntax":
            what, edit = rng.choice(SYNTAX)
            call.edit = edit
            return program, f"syntax: {what} in {call.value}"
        if kind == "key":
            maps = [n for _, n in call.walk() if n.kind == "map" and n.type and n.type[0] == "map"]
            if not maps:
                continue
            target = rng.choice(maps)
            target.value = target.value + ["bogus"]
            target.kids.append(Node("num", 1))
            target.mark = "target"
            return program, f"key: bogus in {call.value}'s options"
    return None


def node_at(program, path):
    node = program.statements[path[0]][-1]
    for i in path[1:]:
        node = node.kids[i]
    return node


# --- Shrinking ---


def smaller(program):
    """Programs one step smaller than `program`, those likely to keep its
    problem first."""
    statements = program.statements
    for i in range(len(statements)):
        if statements[i][0] != "raw" and marked(statements[i][-1], None):
            continue
        if statements[i][0] != "draw" or sum(s[0] == "draw" for s in statements) > 1:
            yield Program(statements[:i] + statements[i + 1 :], program.headers, program.comment)
    for path, node in list(program.nodes()):
        if node.mark:
            continue
        # A shape by one of its shape arguments, or a closure's
        if node.kind == "call" and node.dim:
            for kid in node.kids:
                if kid.kind == "closure":
                    kid = kid.kids[0]
                if kid.kind in ("call", "raw") and kid.dim == node.dim and not marked(node, kid):
                    yield program.replace(path, copy.deepcopy(kid))
        if node.kind in ("call", "raw") and node.dim and not marked(node, None):
            if not (node.value in ("sphere", "circle") and len(node.kids) == 1):
                leaf = Node("call", "sphere" if node.dim == 3 else "circle", [Node("num", 1)], dim=node.dim)
                yield program.replace(path, leaf)
        if node.kind == "call" and node.optional and not marked(node.kids[-1], None):
            shorter = copy.deepcopy(node)
            shorter.kids.pop()
            shorter.optional -= 1
            yield program.replace(path, shorter)
        if node.kind in ("array", "map") and len(node.kids) > 1:
            for j in range(len(node.kids)):
                if marked(node.kids[j], None):
                    continue
                shorter = copy.deepcopy(node)
                del shorter.kids[j]
                if node.kind == "map":
                    del shorter.value[j]
                yield program.replace(path, shorter)
        if node.kind in ("op", "call") and node.type in (("name", "Tree"), ("name", "number")) and not marked(node, None):
            yield program.replace(path, Node("num", 1, type=node.type))
        if node.kind == "num" and node.value not in (0, 1) and not node.mark:
            simpler = copy.deepcopy(node)
            simpler.value = round(node.value) if node.value != round(node.value) else 1
            yield program.replace(path, simpler)


def marked(node, keep):
    """Whether `node` holds a marked node other than within `keep`."""
    for _, n in node.walk():
        if n.mark and not (keep is not None and any(m is n for _, m in keep.walk())):
            return True
    return False


def shrink(program, fails, attempts=300):
    """The smallest program reached from `program`, one step at a time,
    for which `fails` still holds."""
    tried = 0
    progress = True
    while progress and tried < attempts:
        progress = False
        for candidate in smaller(program):
            tried += 1
            if fails(candidate):
                program = candidate
                progress = True
                break
            if tried >= attempts:
                break
    return program
