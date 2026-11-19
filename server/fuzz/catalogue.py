# SPDX-License-Identifier: MPL-2.0

"""What scripts can call, from the server's `docs` reply: each entry's
signatures parsed from the manual's notation, its examples, and the
numbers the examples pass, which become the ranges programs draw from."""

import re
from dataclasses import dataclass, field

# --- Types ---

# A type is a tuple:
#   ("name", "Tree")                  a named type, or an alias of the entry
#   ("lit", '"round"')                a literal
#   ("array", T), ("tuple", [T])      T[], [A, B]
#   ("map", [(key, optional, T)])     #{ a: A, b?: B }
#   ("dict", T)                       #{ [key: string]: T }
#   ("union", [T])                    A | B
#   ("fn", [(name, T)], R)            (t: Tree) => R

TOKEN = re.compile(
    r'\s*(?:(?P<str>"[^"]*")|(?P<num>-?\d+(?:\.\d+)?)'
    r"|(?P<name>[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*)"
    r"|(?P<op>\.\.\.|=>|#\{|[()\[\]{}:?,|=.<>]))"
)


class Unparsed(Exception):
    pass


class Parser:
    def __init__(self, text):
        self.text = text
        self.tokens = []
        at = 0
        while at < len(text):
            m = TOKEN.match(text, at)
            if not m or m.end() == at:
                if text[at:].strip():
                    raise Unparsed(f"{text!r} at {at}")
                break
            kind = m.lastgroup
            self.tokens.append((kind, m.group(kind), m.start(kind), m.end()))
            at = m.end()
        self.i = 0

    def peek(self, k=0):
        i = self.i + k
        return self.tokens[i][1] if i < len(self.tokens) else None

    def kind(self):
        return self.tokens[self.i][0] if self.i < len(self.tokens) else None

    def take(self, want=None):
        if self.i >= len(self.tokens):
            raise Unparsed(f"{self.text!r}: ran out")
        token = self.tokens[self.i][1]
        if want is not None and token != want:
            raise Unparsed(f"{self.text!r}: {want} expected, {token} found")
        self.i += 1
        return token

    def type(self):
        options = [self.atom()]
        while self.peek() == "|":
            self.take()
            options.append(self.atom())
        return options[0] if len(options) == 1 else ("union", options)

    def atom(self):
        t = self.base()
        while self.peek() == "[" and self.peek(1) == "]":
            self.take(), self.take()
            t = ("array", t)
        return t

    def base(self):
        token, kind = self.peek(), self.kind()
        if kind in ("str", "num"):
            return ("lit", self.take())
        if token == "(":
            # A function's parameters, the unit type, or a type in parentheses
            if self.peek(1) == ")" and self.peek(2) != "=>":
                self.take(), self.take()
                return ("name", "()")
            if self.peek(1) == ")" or self.peek(2) in (":", "?"):
                params = self.params(")")
                self.take("=>")
                return ("fn", [(p.name, p.type) for p in params], self.type())
            self.take()
            t = self.type()
            self.take(")")
            return t
        if token == "[":
            self.take()
            items = [self.type()]
            while self.peek() == ",":
                self.take()
                items.append(self.type())
            self.take("]")
            return ("tuple", items)
        if token == "#{":
            self.take()
            if self.peek() == "[":
                self.take(), self.take(), self.take(":"), self.type(), self.take("]")
                self.take(":")
                t = self.type()
                self.take("}")
                return ("dict", t)
            fields = []
            while self.peek() != "}":
                key = self.take()
                optional = self.peek() == "?"
                if optional:
                    self.take()
                self.take(":")
                fields.append((key, optional, self.type()))
                if self.peek() == ",":
                    self.take()
            self.take("}")
            return ("map", fields)
        if kind == "name":
            return ("name", self.take())
        raise Unparsed(f"{self.text!r}: a type expected, {token} found")

    def params(self, close):
        """Parameters up to `close`, past the opening bracket."""
        self.take()
        params = []
        while self.peek() != close:
            rest = self.peek() == "..."
            if rest:
                self.take()
            if self.peek() == "#{":
                # fidget's shapes take their fields as one map too.
                params.append(Param("", self.type()))
            else:
                name = self.take()
                if self.peek() == "?":
                    self.take()
                self.take(":")
                params.append(Param(name, self.type(), rest=rest))
            if self.peek() == "=":
                self.take()
                params[-1].default = self.raw(close)
            if self.peek() == ",":
                self.take()
        self.take(close)
        return params

    def raw(self, close):
        """The text of a default, up to the next `,` or `close` outside brackets."""
        if self.i >= len(self.tokens):
            raise Unparsed(f"{self.text!r}: ran out")
        depth, start = 0, self.tokens[self.i][2]
        while True:
            token = self.peek()
            if token is None:
                raise Unparsed(f"{self.text!r}: ran out")
            if depth == 0 and token in (",", close):
                return self.text[start : self.tokens[self.i][2]].strip()
            depth += token in ("(", "[", "{", "#{")
            depth -= token in (")", "]", "}")
            self.take()


@dataclass
class Param:
    name: str
    type: tuple
    default: str | None = None
    rest: bool = False


@dataclass
class Signature:
    name: str
    params: list
    returns: tuple | None
    method: bool = False


def signature(text):
    """A signature such as `shape.offset(d: Tree): Shape`; None for one
    that is no call, such as an operator's or a constant's."""
    p = Parser(text)
    if p.kind() != "name":
        return None
    method = p.peek(1) == "."
    if method:
        p.take(), p.take()
    name = p.take()
    if p.peek() != "(":
        return None
    params = p.params(")")
    returns = None
    if p.peek() == ":":
        p.take()
        returns = p.type()
    return Signature(name, params, returns, method)


def alias(text):
    """`type Name = T` as (name, T)."""
    p = Parser(text)
    p.take("type")
    name = p.take()
    p.take("=")
    return name, p.type()


# --- Entries ---


@dataclass
class Entry:
    name: str
    kind: str
    source: str
    signatures: list
    examples: list
    aliases: dict = field(default_factory=dict)
    file: str = ""
    # The import that makes a module's functions callable
    header: str | None = None

    def returns(self, name):
        return any(mentions(s.returns, name) for s in self.signatures)


def mentions(t, name):
    """Whether type `t` is or contains the named type."""
    if t is None:
        return False
    if t[0] == "name":
        return t[1] == name
    if t[0] in ("array", "dict"):
        return mentions(t[1], name)
    if t[0] in ("tuple", "union"):
        return any(mentions(u, name) for u in t[1])
    if t[0] == "map":
        return any(mentions(u, name) for _, _, u in t[1])
    return False


FENCE = re.compile(r"^```[^\n]*\n(.*?)^```", re.M | re.S)


def entries(docs):
    """The entries of a `docs` reply that scripts call, by name."""
    found = {}
    for item in docs["shapes"] + docs["functions"] + docs["modules"]:
        if item.get("source") == "rhai" or item["name"] in found:
            continue
        signatures = []
        for text in item.get("signatures", []):
            try:
                s = signature(text)
            except Unparsed:
                continue
            if s and s.name == item["name"]:
                signatures.append(s)
        if not signatures:
            continue
        aliases = {}
        for text in item.get("types") or []:
            try:
                name, t = alias(text)
            except Unparsed:
                continue
            aliases.setdefault(name, t)
        header = None
        if "::" in item["name"]:
            module = item["file"].rsplit("/", 1)[-1].removesuffix(".rhai")
            header = f'import "keycap/{module}" as {item["name"].split("::")[0]};'
        found[item["name"]] = Entry(
            name=item["name"],
            kind=item.get("kind", ""),
            source=item.get("source", "fidget"),
            signatures=signatures,
            examples=[code.strip() for code in FENCE.findall(item.get("doc", ""))],
            aliases=aliases,
            file=item.get("file", ""),
            header=header,
        )
    return found


# --- Numbers in examples ---

# A literal as the examples write it: a number, a string, an array or a map
# of them; anything else is None.
LITERAL = re.compile(r'\s*(-?\d+(?:\.\d+)?(?:e-?\d+)?|"[^"]*"|#\{|[\[\]{},:]|[A-Za-z_]\w*)')


def literal(text):
    tokens = LITERAL.findall(text)
    if "".join(tokens) != LITERAL.sub(lambda m: m.group(1), text).strip():
        return None
    try:
        value, rest = _literal(tokens)
    except (IndexError, ValueError):
        return None
    return value if not rest else None


def _literal(tokens):
    head, rest = tokens[0], tokens[1:]
    if head == "[":
        items = []
        while rest[0] != "]":
            item, rest = _literal(rest)
            items.append(item)
            if rest[0] == ",":
                rest = rest[1:]
        return items, rest[1:]
    if head == "#{":
        items = {}
        while rest[0] != "}":
            key, rest = rest[0], rest[2:]
            items[key], rest = _literal(rest)
            if rest[0] == ",":
                rest = rest[1:]
        return items, rest[1:]
    if head.startswith('"'):
        return head[1:-1], rest
    if head in ("true", "false"):
        return head == "true", rest
    number = float(head)
    return (int(number) if re.fullmatch(r"-?\d+", head) else number), rest


def calls(code):
    """(name, method, [argument text]) for each call in `code`."""
    code = re.sub(r"//[^\n]*", "", code)
    for m in re.finditer(r"(\.)?\b([A-Za-z_]\w*(?:::\w+)?)\(", code):
        depth, start, args = 1, m.end(), []
        i = start
        while i < len(code) and depth:
            c = code[i]
            if c in '"|':
                # A string, or a closure's parameters, splits no arguments.
                end = code.find(c, i + 1)
                i = end if end >= 0 else len(code)
            elif c in "([{":
                depth += 1
            elif c in ")]}":
                depth -= 1
            elif c == "," and depth == 1:
                args.append(code[start:i])
                start = i + 1
            i += 1
        if code[start : i - 1].strip():
            args.append(code[start : i - 1])
        yield m.group(2), bool(m.group(1)), args


def example_values(catalogue):
    """The literals the examples pass, by (function, parameter) and by
    parameter alone: maps' keys are parameters of their own."""
    values = {}

    def note(fn, name, value):
        if isinstance(value, dict):
            for key, v in value.items():
                note(fn, key, v)
        elif value is not None:
            values.setdefault((fn, name), []).append(value)
            values.setdefault((None, name), []).append(value)

    for entry in catalogue.values():
        for code in entry.examples:
            for name, method, args in calls(code):
                callee = catalogue.get(name)
                if not callee:
                    continue
                offset = 1 if method else 0
                plain = [s for s in callee.signatures if not s.method]
                methods = [s for s in callee.signatures if s.method]
                for s in plain if plain or not method else methods:
                    if s.method:
                        offset = 0
                    if len(s.params) >= len(args) + offset:
                        for param, text in zip(s.params[offset:], args):
                            note(name, param.name, literal(text))
                        break
    return values
