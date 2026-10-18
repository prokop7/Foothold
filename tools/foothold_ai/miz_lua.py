"""Reader/writer for the Lua table files inside a DCS .miz (mission, mapResource, ...).

These files are a single assignment, e.g. ``mission = { ... } -- end of mission``.
Tables become Python dicts (insertion order kept), numbers keep their original
text (``LuaNumber``) so an unchanged file re-serialises without numeric drift.
Standard library only.
"""

from __future__ import annotations


class LuaNumber(str):
    """A Lua number kept as its source text."""

    def __repr__(self) -> str:
        return f"LuaNumber({str.__repr__(self)})"


_ESCAPES = {"a": "\a", "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t",
            "v": "\v", "\\": "\\", '"': '"', "'": "'", "\n": "\n"}


class _Parser:
    def __init__(self, text: str):
        self.s = text
        self.i = 0
        self.n = len(text)

    def error(self, message: str):
        line = self.s.count("\n", 0, self.i) + 1
        raise ValueError(f"{message} at line {line}")

    def skip(self):
        s, n = self.s, self.n
        while self.i < n:
            c = s[self.i]
            if c in " \t\r\n":
                self.i += 1
            elif s.startswith("--", self.i):
                if s.startswith("--[[", self.i):
                    end = s.find("]]", self.i)
                    self.i = n if end < 0 else end + 2
                else:
                    end = s.find("\n", self.i)
                    self.i = n if end < 0 else end + 1
            else:
                break

    def parse_assignment(self):
        self.skip()
        start = self.i
        while self.i < self.n and (self.s[self.i].isalnum() or self.s[self.i] == "_"):
            self.i += 1
        name = self.s[start:self.i]
        if not name:
            self.error("expected variable name")
        self.skip()
        if self.s[self.i] != "=":
            self.error("expected '='")
        self.i += 1
        value = self.parse_value()
        self.skip()
        if self.i != self.n:
            self.error("unexpected trailing content")
        return name, value

    def parse_value(self):
        self.skip()
        c = self.s[self.i]
        if c == "{":
            return self.parse_table()
        if c in "\"'":
            return self.parse_string()
        if self.s.startswith("true", self.i):
            self.i += 4
            return True
        if self.s.startswith("false", self.i):
            self.i += 5
            return False
        if self.s.startswith("nil", self.i):
            self.i += 3
            return None
        return self.parse_number()

    def parse_number(self):
        start = self.i
        s = self.s
        while self.i < self.n and (s[self.i].isalnum() or s[self.i] in ".-+"):
            # '+'/'-' only directly after an exponent marker or at the start
            if s[self.i] in "+-" and self.i != start and s[self.i - 1] not in "eE":
                break
            self.i += 1
        text = s[start:self.i]
        try:
            float(text) if not text.lower().startswith(("0x", "-0x")) else int(text, 16)
        except ValueError:
            self.error(f"bad number {text!r}")
        return LuaNumber(text)

    def parse_string(self):
        quote = self.s[self.i]
        self.i += 1
        out = []
        s = self.s
        while True:
            if self.i >= self.n:
                self.error("unterminated string")
            c = s[self.i]
            if c == quote:
                self.i += 1
                return "".join(out)
            if c == "\\":
                nxt = s[self.i + 1]
                if nxt in _ESCAPES:
                    out.append(_ESCAPES[nxt])
                    self.i += 2
                elif nxt.isdigit():
                    j = self.i + 1
                    while j < self.i + 4 and j < self.n and s[j].isdigit():
                        j += 1
                    out.append(chr(int(s[self.i + 1:j])))
                    self.i = j
                elif nxt == "\r" and s[self.i + 2] == "\n":
                    out.append("\n")
                    self.i += 3
                else:
                    self.error(f"bad escape \\{nxt}")
            else:
                out.append(c)
                self.i += 1

    def parse_table(self):
        self.i += 1  # '{'
        result: dict = {}
        auto = 1
        while True:
            self.skip()
            if self.s[self.i] == "}":
                self.i += 1
                return result
            if self.s[self.i] == "[":
                self.i += 1
                key = self.parse_value()
                if isinstance(key, LuaNumber):
                    key = _number_key(key)
                self.skip()
                if self.s[self.i] != "]":
                    self.error("expected ']'")
                self.i += 1
                self.skip()
                if self.s[self.i] != "=":
                    self.error("expected '='")
                self.i += 1
                result[key] = self.parse_value()
            else:
                save = self.i
                ident = []
                while self.i < self.n and (self.s[self.i].isalnum() or self.s[self.i] == "_"):
                    ident.append(self.s[self.i])
                    self.i += 1
                self.skip()
                if ident and self.s[self.i] == "=" and self.s[self.i + 1] != "=":
                    self.i += 1
                    result["".join(ident)] = self.parse_value()
                else:
                    self.i = save
                    result[auto] = self.parse_value()
                    auto += 1
            self.skip()
            if self.s[self.i] in ",;":
                self.i += 1


def _number_key(n: LuaNumber):
    value = float(n)
    return int(value) if value.is_integer() else value


def loads(text: str):
    """Parse ``name = <table>`` and return (name, value)."""
    return _Parser(text).parse_assignment()


def _escape(s: str) -> str:
    out = ['"']
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\\n")  # DCS style: backslash + real newline
        elif ch == "\r":
            out.append("\\r")
        elif ord(ch) < 32 and ch != "\t":
            out.append("\\%03d" % ord(ch))
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def _key(k) -> str:
    if isinstance(k, bool):
        raise ValueError("boolean table keys are not supported")
    if isinstance(k, (int, float)):
        return f"[{k!r}]" if isinstance(k, float) else f"[{k}]"
    return f"[{_escape(k)}]"


def _value(v, depth: int, out: list, key_label: str | None):
    if isinstance(v, dict):
        if not v:
            out.append("{},\n")
            return
        tabs = "\t" * depth
        out.append("\n" + tabs + "{\n")
        for k, item in v.items():
            out.append("\t" * (depth + 1) + _key(k) + " = ")
            _value(item, depth + 1, out, _key(k))
        out.append(tabs + "}, -- end of " + (key_label or "") + "\n")
        return
    if isinstance(v, bool):
        text = "true" if v else "false"
    elif isinstance(v, LuaNumber):
        text = str(v)
    elif isinstance(v, (int, float)):
        text = repr(v)
    elif isinstance(v, str):
        text = _escape(v)
    elif v is None:
        text = "nil"
    else:
        raise ValueError(f"unsupported value {type(v).__name__}")
    out.append(text + ",\n")


def dumps(name: str, value: dict) -> str:
    """Serialise like the DCS mission editor: tabs, ["key"] = value, end-of comments."""
    out = [name, " = \n{\n"]
    for k, item in value.items():
        out.append("\t" + _key(k) + " = ")
        _value(item, 1, out, _key(k))
    out.append("} -- end of " + name + "\n")
    return "".join(out)


def normalized(value):
    """Comparable form: numbers as floats, tables as dicts of normalized values."""
    if isinstance(value, dict):
        return {(_number_key(LuaNumber(str(k))) if isinstance(k, (int, float)) else k): normalized(v)
                for k, v in value.items()}
    if isinstance(value, LuaNumber):
        return float(str(value)) if not str(value).lower().startswith(("0x", "-0x")) else float(int(value, 16))
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    return value
