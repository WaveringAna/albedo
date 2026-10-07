"""Draw a screen's ANSI text as a PNG, so a person or a model can look at it.

TUI tests write what a view draws to $ALBEDO_SHOT_DIR/<name>.ans (see shot in
cli/internal/tui/shot_test.go). This turns every .ans in a directory, or the
files named, into a .svg and a .png beside it. Needs rsvg-convert.

    ALBEDO_SHOT_DIR=/tmp/shots go -C cli test ./internal/tui -run TestShot
    python3 test/manual/tui_shot.py /tmp/shots
"""

import html
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

BG, FG = "#1e1e2e", "#cdd6f4"
BASIC = {
    30: "#45475a", 31: "#f38ba8", 32: "#a6e3a1", 33: "#f9e2af",
    34: "#89b4fa", 35: "#cba6f7", 36: "#94e2d5", 37: "#bac2de",
    90: "#585b70", 91: "#f38ba8", 92: "#a6e3a1", 93: "#f9e2af",
    94: "#89b4fa", 95: "#cba6f7", 96: "#94e2d5", 97: "#a6adc8",
}  # fmt: skip
TOKEN = re.compile(
    r"\x1b\[([0-9;:]*)m|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b_.*?\x1b\\|(.)", re.S
)

Style = dict[str, str | bool | None]


def xterm(n: int) -> str:
    if n < 8:
        return BASIC[30 + n]
    if n < 16:
        return BASIC[82 + n]
    if n < 232:
        n -= 16
        level = lambda v: 0 if v == 0 else 55 + 40 * v  # noqa: E731
        return "#%02x%02x%02x" % (level(n // 36), level(n // 6 % 6), level(n % 6))
    v = 8 + 10 * (n - 232)
    return "#%02x%02x%02x" % (v, v, v)


def fresh() -> Style:
    return {
        "fg": None,
        "bg": None,
        "bold": False,
        "faint": False,
        "under": False,
        "reverse": False,
    }


def apply(style: Style, params: list[int]) -> None:
    i = 0
    while i < len(params):
        p = params[i]
        if p == 0:
            style.update(fresh())
        elif p in (1, 2, 4, 7):
            style[{1: "bold", 2: "faint", 4: "under", 7: "reverse"}[p]] = True
        elif p == 22:
            style.update(bold=False, faint=False)
        elif p == 24:
            style["under"] = False
        elif p == 27:
            style["reverse"] = False
        elif p == 39:
            style["fg"] = None
        elif p == 49:
            style["bg"] = None
        elif p in (38, 48):
            key = "fg" if p == 38 else "bg"
            if params[i + 1] == 2:
                style[key] = "#%02x%02x%02x" % tuple(params[i + 2 : i + 5])
                i += 4
            elif params[i + 1] == 5:
                style[key] = xterm(params[i + 2])
                i += 2
        elif 30 <= p <= 37 or 90 <= p <= 97:
            style["fg"] = BASIC[p]
        elif 40 <= p <= 47 or 100 <= p <= 107:
            style["bg"] = BASIC[p - 10]
        i += 1


def width_of(char: str) -> int:
    if unicodedata.combining(char):
        return 0
    return 2 if unicodedata.east_asian_width(char) in "WF" else 1


def to_svg(text: str, cw: int = 9, ch: int = 19, pad: int = 18, size: int = 15) -> str:
    cells: list[tuple[int, int, str, Style, int]] = []
    lines = text.rstrip("\n").split("\n")
    columns = 0
    for y, line in enumerate(lines):
        style, x = fresh(), 0
        for match in TOKEN.finditer(line):
            if match.group(2) is not None:
                w = width_of(match.group(2))
                cells.append((x, y, match.group(2), dict(style), w))
                x += w
            elif match.group(1) is not None:
                apply(
                    style,
                    [
                        int(p) if p else 0
                        for p in re.split("[;:]", match.group(1) or "0")
                    ],
                )
        columns = max(columns, x)
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{pad * 2 + columns * cw}" height="{pad * 2 + len(lines) * ch}">',
        f'<rect width="100%" height="100%" rx="10" fill="{BG}"/>',
        f'<g font-family="Menlo" font-size="{size}" xml:space="preserve">',
    ]
    for x, y, char, style, w in cells:
        fg, bg = style["fg"] or FG, style["bg"]
        if style["reverse"]:
            fg, bg = bg or BG, fg
        if bg:
            out.append(
                f'<rect x="{pad + x * cw}" y="{pad + y * ch}" width="{cw * w + 0.5}" height="{ch + 0.5}" fill="{bg}"/>'
            )
        if char == " ":
            continue
        extra = (' font-weight="bold"' if style["bold"] else "") + (
            ' opacity="0.6"' if style["faint"] else ""
        )
        extra += ' text-decoration="underline"' if style["under"] else ""
        out.append(
            f'<text x="{pad + x * cw + cw * w / 2}" y="{pad + y * ch + ch * 0.75}" text-anchor="middle" fill="{fg}"{extra}>{html.escape(char)}</text>'
        )
    out.append("</g></svg>")
    return "\n".join(out)


def main(args: list[str]) -> int:
    sources = [
        p
        for a in args
        for p in (sorted(Path(a).glob("*.ans")) if Path(a).is_dir() else [Path(a)])
    ]
    if not sources:
        print(__doc__, file=sys.stderr)
        return 2
    for source in sources:
        svg, png = source.with_suffix(".svg"), source.with_suffix(".png")
        svg.write_text(to_svg(source.read_text(encoding="utf-8")), encoding="utf-8")
        subprocess.run(["rsvg-convert", str(svg), "-o", str(png)], check=True)
        print(png)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
