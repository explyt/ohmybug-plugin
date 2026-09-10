#!/usr/bin/env python3
"""Drop whole-line comments from source text; everything else passes through.

Usage: strip-comments.py <path> < file > stripped
The language comes from the path's extension. Unknown extension: the text is
printed unchanged — no stripping is the strict answer.

This is the one definition of "a line that cannot change behaviour" behind the
`cmt:` hunt key (diff-id.sh, ohmybug_cmt_id): a diff whose only delta since the
hunt is comment lines inside code files hashes the same as the hunted one, so
deleting a sentence from a KDoc after a clean hunt does not buy a paid re-hunt.

The rule that shapes every branch below: DOUBT IS CODE. A comment marker inside
a string, a template literal, a heredoc or a raw string is text the program
ships, and stripping it would let a code edit merge unhunted. So each scanner
tracks the multi-line constructs its language has, and when it cannot tell, it
keeps the line. Errors in the other direction — keeping a real comment — only
cost a re-hunt, never an unreviewed merge.

Two more lines that look like prose and are not: a DIRECTIVE comment steers a
tool (`// @ts-expect-error`, `# shellcheck disable=`, `# noqa`, a PEP 263
coding cookie…) and stays as code; and a block comment opens only when nothing
but whitespace precedes it on its line — a `/*` after code (a regex class
`/[/*]/`, JSX text) is not trusted to be a comment, so the line stays and no
block state is entered.
"""
import re
import sys
import tokenize
import io

# A comment whose first word is a tool directive. Deleting or editing one
# changes what compiles, lints or decodes, so it is code for this key.
DIRECTIVE = re.compile(
    r"^\s*(?:#|//|/\*+|\*)\s*(?:"
    r"@ts-|eslint|prettier-ignore|biome-ignore|shellcheck|noqa\b|type:|pragma\b|"
    r"pyright:|mypy:|ruff:|fmt:|syntax=|escape=|coding[:=]|-\*-|@formatter|"
    r"c8\s|istanbul\s|v8\s+ignore|sourceMappingURL=|/\s*<reference\s"
    r")", re.I)


def is_directive(line):
    return DIRECTIVE.match(line) is not None


def c_family(text, tick, triple):
    """`//` and `/* */` comments. `tick`: backtick template literals with `${}`
    (TS/JS). `triple`: `\"\"\"` raw strings (Kotlin). A comment line is one where
    every non-blank character sits inside a comment; a line is kept when any
    character sits in code or in a string.

    States live on a stack: CODE at the bottom; E is a `${ }` expression inside a
    template (code with a brace depth); SQ/DQ single-line strings (a newline
    ends them — an unterminated string is a syntax error in every language here,
    and the line is kept as code either way); T template; B block comment; L
    line comment; R raw triple-quoted string.
    """
    out = []
    stack = [("CODE", 0)]
    i, n = 0, len(text)
    line = []
    has_code = saw_comment = False

    def flush():
        nonlocal line, has_code, saw_comment
        s = "".join(line)
        if not (saw_comment and not has_code) or is_directive(s):
            out.append(s)
        line = []
        has_code = saw_comment = False

    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        top, depth = stack[-1]
        if ch == "\n":
            if top in ("L", "SQ", "DQ"):
                stack.pop()
            if top == "B":
                saw_comment = True  # a blank line inside a block comment is prose
            line.append(ch)
            flush()
            i += 1
            continue
        line.append(ch)
        if top in ("CODE", "E"):
            # A `//` or `/*` right after a backslash is inside a regex literal
            # (`/\/\//`, `/\/*x/`): keep scanning as code.
            prev = text[i - 1] if i > 0 else ""
            if ch == "/" and nxt == "/" and prev != "\\":
                stack.append(("L", 0)); saw_comment = True
                line.append(nxt); i += 2; continue
            # `/*` opens a block only when nothing but whitespace or comment
            # precedes it on this line: mid-line it may be a regex class or
            # JSX text, and a wrong B state would swallow the file's tail.
            if ch == "/" and nxt == "*" and prev != "\\" and not has_code:
                stack.append(("B", 0)); saw_comment = True
                line.append(nxt); i += 2; continue
            if triple and text.startswith('"""', i):
                stack.append(("R", 0)); has_code = True
                line.extend('""'); i += 3; continue
            if ch == "'":
                stack.append(("SQ", 0)); has_code = True; i += 1; continue
            if ch == '"':
                stack.append(("DQ", 0)); has_code = True; i += 1; continue
            if tick and ch == "`":
                stack.append(("T", 0)); has_code = True; i += 1; continue
            if top == "E":
                if ch == "{":
                    stack[-1] = ("E", depth + 1)
                elif ch == "}":
                    if depth == 0:
                        stack.pop()
                    else:
                        stack[-1] = ("E", depth - 1)
            if not ch.isspace():
                has_code = True
            i += 1; continue
        if top == "L":
            i += 1; continue
        if top == "B":
            saw_comment = True
            if ch == "*" and nxt == "/":
                stack.pop(); line.append(nxt); i += 2; continue
            i += 1; continue
        if top in ("SQ", "DQ", "T"):
            has_code = True
            if ch == "\\" and nxt:
                line.append(nxt); i += 2
                if nxt == "\n":
                    flush()
                continue
            if (top == "SQ" and ch == "'") or (top == "DQ" and ch == '"') or (top == "T" and ch == "`"):
                stack.pop(); i += 1; continue
            if top == "T" and ch == "$" and nxt == "{":
                stack.append(("E", 0)); line.append(nxt); i += 2; continue
            i += 1; continue
        if top == "R":
            has_code = True
            if text.startswith('"""', i):
                stack.pop(); line.extend('""'); i += 3; continue
            i += 1; continue
        i += 1
    if line:
        flush()
    return "".join(out)


def shell(text):
    """`#` at the start of a line is a comment — unless the line is inside a
    quoted string that started on an earlier line, inside a heredoc, is the
    shebang, or continues a previous line with `\\`. Every one of those keeps."""
    out = []
    lines = text.split("\n")
    state = "CODE"          # CODE | SQ | DQ
    heredoc = None          # (terminator, strip_tabs) of the body being read
    queue = []              # heredocs opened on one line, bodies follow in order
    continued = False
    for idx, raw in enumerate(lines):
        if heredoc is not None:
            term, strip_tabs = heredoc
            body = raw.lstrip("\t") if strip_tabs else raw
            if body == term:
                heredoc = queue.pop(0) if queue else None
            out.append(raw)
            continue
        stripped = raw.lstrip()
        is_comment = (state == "CODE" and not continued and stripped.startswith("#")
                      and not (idx == 0 and stripped.startswith("#!"))
                      and not is_directive(raw))
        if is_comment:
            continued = False
            continue
        # Scan the line for quote state and heredoc openers — every one on the
        # line, in order (`cat <<A <<B` reads two bodies).
        j = 0
        pending = []
        while j < len(raw):
            ch = raw[j]
            if state == "CODE":
                if ch == "\\":
                    j += 2; continue
                if ch == "'":
                    state = "SQ"
                elif ch == '"':
                    state = "DQ"
                elif ch == "#" and (j == 0 or raw[j - 1] in " \t;|&(){}<>"):
                    break  # a comment starts at a word boundary only: `abc#def` is a word
                elif ch == "<" and raw.startswith("<<", j) and not raw.startswith("<<<", j):
                    k = j + 2
                    strip_tabs = k < len(raw) and raw[k] == "-"
                    if strip_tabs:
                        k += 1
                    while k < len(raw) and raw[k] == " ":
                        k += 1
                    q = raw[k] if k < len(raw) and raw[k] in "'\"\\" else ""
                    if q:
                        k += 1
                    m = k
                    while m < len(raw) and (raw[m].isalnum() or raw[m] == "_"):
                        m += 1
                    if m > k:
                        pending.append((raw[k:m], strip_tabs))
                        j = m + (1 if q and q != "\\" else 0); continue
            elif state == "SQ":
                if ch == "'":
                    state = "CODE"
            elif state == "DQ":
                if ch == "\\":
                    j += 2; continue
                if ch == '"':
                    state = "CODE"
            j += 1
        continued = state == "CODE" and raw.endswith("\\") and not raw.endswith("\\\\")
        if pending and state == "CODE":
            queue.extend(pending)
        if queue and heredoc is None:
            heredoc = queue.pop(0)
        out.append(raw)
    return "\n".join(out)


def python(text):
    """Python knows its own comments: tokenize, drop lines whose tokens are all
    COMMENT/NL. A shebang stays. A file tokenize rejects is returned whole."""
    try:
        toks = list(tokenize.generate_tokens(io.StringIO(text).readline))
    except (tokenize.TokenError, SyntaxError, IndentationError):
        return text
    code_lines = set()
    comment_lines = set()
    for t in toks:
        if t.type == tokenize.COMMENT:
            comment_lines.add(t.start[0])
        elif t.type not in (tokenize.NL, tokenize.NEWLINE, tokenize.INDENT, tokenize.DEDENT,
                            tokenize.ENDMARKER, tokenize.ENCODING):
            for ln in range(t.start[0], t.end[0] + 1):
                code_lines.add(ln)
    lines = text.split("\n")
    out = []
    for no, raw in enumerate(lines, 1):
        if (no in comment_lines and no not in code_lines
                and not (no == 1 and raw.lstrip().startswith("#!"))
                and not is_directive(raw)):
            continue
        out.append(raw)
    return "\n".join(out)


def strip(path, text):
    ext = path.rsplit(".", 1)[-1].lower() if "." in path.rsplit("/", 1)[-1] else ""
    # No tsx/jsx: JSX text is untrackable without a parser, and a text line
    # that begins with `//` would be dropped as a comment. No rule is the
    # strict rule.
    if ext in ("ts", "js", "mjs", "cjs"):
        return c_family(text, tick=True, triple=False)
    if ext in ("kt", "kts"):
        return c_family(text, tick=False, triple=True)
    if ext in ("sh", "bash"):
        return shell(text)
    if ext == "py":
        return python(text)
    return text


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: strip-comments.py <path> < file")
    data = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
    sys.stdout.buffer.write(strip(sys.argv[1], data).encode("utf-8", "surrogateescape"))
