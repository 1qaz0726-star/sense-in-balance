# -*- coding: utf-8 -*-
"""
Markdown -> PDF (Traditional Chinese) via reportlab.
Supports: h1-h6, paragraphs, bullet/numbered lists, tables, blockquote, hr,
bold, italic, inline code, links, and footnote markers like [1].

Usage: python md2pdf.py <input.md> <output.pdf>
"""
import sys
import os
import re
import html

from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib import colors
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.enums import TA_LEFT
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (BaseDocTemplate, PageTemplate, Frame, Paragraph,
                                Spacer, Table, TableStyle, HRFlowable)

FONTDIR = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts")
pdfmetrics.registerFont(TTFont("CJK", os.path.join(FONTDIR, "msjh.ttc"), subfontIndex=0))
pdfmetrics.registerFont(TTFont("CJK-B", os.path.join(FONTDIR, "msjhbd.ttc"), subfontIndex=0))
pdfmetrics.registerFontFamily("CJK", normal="CJK", bold="CJK-B",
                              italic="CJK", boldItalic="CJK-B")

INK = colors.HexColor("#1a1a1a")
MUTED = colors.HexColor("#6b6b6b")
RULE = colors.HexColor("#d8d4cc")
BAND = colors.HexColor("#f2efe9")
ACCENT = colors.HexColor("#8a3d4e")
ALT = colors.HexColor("#faf9f6")


def S(name, **kw):
    base = dict(fontName="CJK", fontSize=10.2, leading=16.5, textColor=INK,
                wordWrap="CJK", alignment=TA_LEFT, spaceBefore=0, spaceAfter=0)
    base.update(kw)
    return ParagraphStyle(name, **base)


ST = {
    "title": S("title", fontName="CJK-B", fontSize=21, leading=29, spaceAfter=4, textColor=ACCENT),
    "h1": S("h1", fontName="CJK-B", fontSize=16.5, leading=24, spaceBefore=17, spaceAfter=7, textColor=ACCENT),
    "h2": S("h2", fontName="CJK-B", fontSize=13.5, leading=21, spaceBefore=14, spaceAfter=6),
    "h3": S("h3", fontName="CJK-B", fontSize=11.5, leading=18, spaceBefore=11, spaceAfter=5),
    "h4": S("h4", fontName="CJK-B", fontSize=10.5, leading=17, spaceBefore=9, spaceAfter=4, textColor=MUTED),
    "body": S("body", spaceAfter=7),
    "li": S("li", leftIndent=13, bulletIndent=2, spaceAfter=3.5),
    "quote": S("quote", leftIndent=11, fontSize=9.8, leading=16, textColor=MUTED,
               spaceBefore=4, spaceAfter=8),
    "cell": S("cell", fontSize=8.6, leading=12.8),
    "cellh": S("cellh", fontName="CJK-B", fontSize=8.6, leading=12.8),
    "ref": S("ref", fontSize=8.4, leading=13, spaceAfter=3.5, leftIndent=16, firstLineIndent=-16),
    "code": S("code", fontName="CJK", fontSize=8.2, leading=11.6,
              backColor=colors.HexColor("#f6f4ef"), borderPadding=6, spaceAfter=8),
}

RE_CODE = re.compile(r"`([^`]+)`")
RE_BI = re.compile(r"\*\*\*(.+?)\*\*\*")
RE_B = re.compile(r"\*\*(.+?)\*\*")
RE_I = re.compile(r"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)")
RE_STRIKE = re.compile(r"~~(.+?)~~")
RE_LINK = re.compile(r"\[([^\]]+)\]\((https?://[^\s)]+)\)")
RE_FOOT = re.compile(r"(?<![\w\]])\[(\d{1,3})\](?!\()")
RE_BARE = re.compile(r"(?<![\"'>=])(https?://[^\s<>\)\]\u3000-\u9fff]+)")


def inline(t):
    """Convert markdown inline syntax to reportlab mini-HTML."""
    t = html.escape(t, quote=False)
    t = RE_CODE.sub(r'<font face="CJK" size="9" color="#8a3d4e">\1</font>', t)
    t = RE_BI.sub(r"<b><i>\1</i></b>", t)
    t = RE_B.sub(r"<b>\1</b>", t)
    t = RE_I.sub(r"<i>\1</i>", t)
    t = RE_STRIKE.sub(r"<strike>\1</strike>", t)
    t = RE_LINK.sub(r'\1 <font size="7.6" color="#6b6b6b">\2</font>', t)
    t = RE_FOOT.sub(r'<font color="#8a3d4e" size="8"><b>[\1]</b></font>', t)
    return t


def split_row(line):
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|"):
        line = line[:-1]
    out, cur, esc = [], "", False
    for ch in line:
        if esc:
            cur += ch
            esc = False
            continue
        if ch == "\\":
            esc = True
            continue
        if ch == "|":
            out.append(cur.strip())
            cur = ""
            continue
        cur += ch
    out.append(cur.strip())
    return out


def build_table(rows, avail):
    ncol = max(len(r) for r in rows)
    rows = [r + [""] * (ncol - len(r)) for r in rows]
    header, body = rows[0], rows[1:]

    # Wide tables: shrink padding and font so every column still fits.
    # Without this, ncol * 2 * padding can exceed a narrow column's share of
    # `avail` and reportlab raises "negative availWidth".
    if ncol <= 6:
        pad, fs = 4.5, 8.6
    elif ncol <= 9:
        pad, fs = 3.0, 7.6
    elif ncol <= 12:
        pad, fs = 2.0, 6.8
    else:
        pad, fs = 1.2, 6.0

    # Every column needs room for padding plus at least one CJK glyph.
    min_w = 2 * pad + fs + 0.5
    while ncol * min_w > avail and pad > 0.4:
        pad -= 0.4
        fs = max(5.0, fs - 0.4)
        min_w = 2 * pad + fs + 0.5

    cell = S("cell_%d" % ncol, fontSize=fs, leading=fs * 1.5)
    cellh = S("cellh_%d" % ncol, fontName="CJK-B", fontSize=fs, leading=fs * 1.5)

    weights = []
    for c in range(ncol):
        longest = max(len(rows[r][c]) for r in range(len(rows)))
        weights.append(max(4.0, min(float(longest), 34.0)))
    total = sum(weights)

    usable = avail - ncol * 2 * pad
    if usable <= ncol:                      # pathological column count
        widths = [avail / ncol] * ncol
    else:
        widths = [2 * pad + usable * w / total for w in weights]
        # Lift any column that still sits below the printable minimum,
        # taking the difference from the widest columns.
        for i, w in enumerate(widths):
            if w < min_w:
                deficit = min_w - w
                widths[i] = min_w
                j = widths.index(max(widths))
                widths[j] = max(min_w, widths[j] - deficit)
        scale = avail / sum(widths)
        widths = [w * scale for w in widths]

    data = [[Paragraph(inline(c), cellh) for c in header]]
    for r in body:
        data.append([Paragraph(inline(c), cell) for c in r])
    t = Table(data, colWidths=widths, repeatRows=1, hAlign="LEFT")
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), BAND),
        ("LINEBELOW", (0, 0), (-1, 0), 0.8, RULE),
        ("GRID", (0, 0), (-1, -1), 0.35, RULE),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), pad),
        ("RIGHTPADDING", (0, 0), (-1, -1), pad),
        ("TOPPADDING", (0, 0), (-1, -1), 4 if ncol <= 6 else 2.5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4 if ncol <= 6 else 2.5),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, ALT]),
    ]))
    return t


def is_divider(s):
    return bool(re.match(r"^(\*\s*){3,}$|^(-\s*){3,}$|^(_\s*){3,}$", s))


def parse(md, avail):
    flow = []
    lines = md.split("\n")
    i = 0
    in_refs = False
    while i < len(lines):
        raw = lines[i]
        s = raw.strip()
        if not s:
            i += 1
            continue

        if s.startswith("```"):
            i += 1
            buf = []
            while i < len(lines) and not lines[i].strip().startswith("```"):
                buf.append(lines[i])
                i += 1
            i += 1
            txt = html.escape("\n".join(buf)).replace("\n", "<br/>").replace(" ", "&nbsp;")
            flow.append(Paragraph(txt, ST["code"]))
            continue

        if (s.startswith("|") and i + 1 < len(lines)
                and re.match(r"^\s*\|?[\s:\-|]+\|[\s:\-|]*$", lines[i + 1])):
            rows = [split_row(s)]
            i += 2
            while i < len(lines) and lines[i].strip().startswith("|"):
                rows.append(split_row(lines[i]))
                i += 1
            flow.append(Spacer(1, 3))
            flow.append(build_table(rows, avail))
            flow.append(Spacer(1, 9))
            continue

        if is_divider(s):
            flow.append(Spacer(1, 4))
            flow.append(HRFlowable(width="100%", thickness=0.6, color=RULE))
            flow.append(Spacer(1, 8))
            i += 1
            continue

        m = re.match(r"^(#{1,6})\s+(.*)$", s)
        if m:
            lvl, txt = len(m.group(1)), m.group(2)
            in_refs = bool(re.search(r"參考資料|參考文獻|References", txt))
            if lvl == 1:
                flow.append(Paragraph(inline(txt), ST["title"]))
                flow.append(HRFlowable(width="100%", thickness=1.2, color=ACCENT, spaceAfter=10))
            else:
                flow.append(Paragraph(inline(txt), ST["h%d" % min(lvl - 1, 4)]))
            i += 1
            continue

        if s.startswith(">"):
            buf = []
            while i < len(lines) and lines[i].strip().startswith(">"):
                buf.append(lines[i].strip().lstrip(">").strip())
                i += 1
            flow.append(Paragraph(inline(" ".join(buf)), ST["quote"]))
            continue

        m = re.match(r"^(\s*)([-*+]|\d{1,3}[.)])\s+(.*)$", raw)
        if m:
            depth = len(m.group(1)) // 2
            marker = m.group(2)
            bullet = "\u2022" if marker in ("-", "*", "+") else marker
            st = ParagraphStyle("li%d" % depth, parent=ST["li"],
                                leftIndent=13 + depth * 13, bulletIndent=2 + depth * 13)
            flow.append(Paragraph(inline(m.group(3)), st, bulletText=bullet))
            i += 1
            continue

        if in_refs and re.match(r"^\[\d{1,3}\]", s):
            flow.append(Paragraph(inline(s), ST["ref"]))
            i += 1
            continue

        buf = [s]
        i += 1
        while i < len(lines):
            nxt = lines[i].strip()
            if (not nxt or nxt.startswith(("#", ">", "|", "```"))
                    or re.match(r"^(\s*)([-*+]|\d{1,3}[.)])\s+", lines[i])
                    or is_divider(nxt)):
                break
            buf.append(nxt)
            i += 1
        flow.append(Paragraph(inline(" ".join(buf)), ST["body"]))
    return flow


def make(src, dst):
    with open(src, encoding="utf-8") as fh:
        md = fh.read()

    doc_title = os.path.splitext(os.path.basename(src))[0]
    m = re.search(r"^#\s+(.*)$", md, re.M)
    if m:
        doc_title = re.sub(r"[*`]", "", m.group(1)).strip()

    lm, rm, tm, bm = 20 * mm, 18 * mm, 20 * mm, 18 * mm
    avail = A4[0] - lm - rm
    doc = BaseDocTemplate(dst, pagesize=A4, leftMargin=lm, rightMargin=rm,
                          topMargin=tm, bottomMargin=bm,
                          title=doc_title, author=os.environ.get("PDF_ORG", ""))
    frame = Frame(lm, bm, avail, A4[1] - tm - bm, id="main",
                  leftPadding=0, rightPadding=0, topPadding=0, bottomPadding=0)

    def decorate(canv, _doc):
        canv.saveState()
        canv.setFont("CJK", 7.6)
        canv.setFillColor(MUTED)
        canv.drawString(lm, A4[1] - tm + 7, doc_title[:58])
        canv.drawRightString(A4[0] - rm, A4[1] - tm + 7, os.environ.get("PDF_ORG", ""))
        canv.setStrokeColor(RULE)
        canv.setLineWidth(0.4)
        canv.line(lm, A4[1] - tm + 4, A4[0] - rm, A4[1] - tm + 4)
        canv.drawCentredString(A4[0] / 2, bm - 11, str(canv.getPageNumber()))
        canv.restoreState()

    doc.addPageTemplates([PageTemplate(id="page", frames=[frame], onPage=decorate)])
    doc.build(parse(md, avail))
    return dst


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: md2pdf.py <input.md> <output.pdf>")
    out = make(sys.argv[1], sys.argv[2])
    print("OK %s (%d bytes)" % (out, os.path.getsize(out)))
