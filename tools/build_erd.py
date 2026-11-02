"""Build the ShopFlow ERD from the live database schema.

Reads tables, columns, keys and indexes from PostgreSQL (so the diagram
always matches the migrations) and writes:
  lakshitha-month3-erd.png     - rendered with Pillow
  lakshitha-month3-erd.drawio  - same layout, editable in draw.io

Usage (from the repo root, against a database with all migrations applied):
  python tools/build_erd.py --db shopflow_m3
"""

import argparse
import html
import os
import re
import subprocess
from pathlib import Path
from xml.sax.saxutils import quoteattr

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT_PNG = ROOT / "lakshitha-month3-erd.png"
OUT_DRAWIO = ROOT / "lakshitha-month3-erd.drawio"

# Columns of the layout, left to right. Every relationship joins tables in
# neighbouring columns or neighbouring slots of one column, so no line has
# to cross a table.
LAYOUT = [
    ["addresses", "payment_methods", "promotions"],
    ["users", "orders", "order_status_history"],
    ["carts", "cart_items", "wishlist_items", "order_items", "reviews"],
    ["categories", "products", "product_variants", "inventory"],
]

ENV = {**os.environ, "PGCLIENTENCODING": "UTF8"}
ENV.setdefault("PGHOST", "localhost")
ENV.setdefault("PGUSER", "postgres")


def query(db, sql):
    out = subprocess.run(["psql", "-X", "-w", "-A", "-t", "-F", "\t", "-d", db, "-c", sql],
                         capture_output=True, text=True, encoding="utf-8", env=ENV, check=True)
    return [line.split("\t") for line in out.stdout.splitlines() if line]


def short_type(pg_type, default):
    if default and default.startswith("nextval("):
        return "SERIAL"
    replacements = [("character varying", "VARCHAR"), ("timestamp without time zone", "TIMESTAMP"),
                    ("numeric", "DECIMAL"), ("character", "CHAR")]
    for old, new in replacements:
        pg_type = pg_type.replace(old, new)
    return pg_type.upper()


def load_schema(db):
    tables = {}
    for table, name, pg_type, not_null, default in query(db, """
        SELECT c.relname, a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull,
               COALESCE(pg_get_expr(d.adbin, d.adrelid), '')
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
        WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
          AND c.relname <> 'schema_migrations' AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY c.relname, a.attnum"""):
        tables.setdefault(table, {"columns": [], "notes": []})["columns"].append(
            {"name": name, "type": short_type(pg_type, default), "not_null": not_null == "t",
             "keys": []})

    def column(table, name):
        return next(c for c in tables[table]["columns"] if c["name"] == name)

    relationships = []
    for table, kind, cols, ref_table in query(db, """
        SELECT c.relname, con.contype,
               array_to_string(ARRAY(SELECT a.attname FROM unnest(con.conkey) WITH ORDINALITY k(n, i)
                                     JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.n
                                     ORDER BY k.i), ','),
               COALESCE(f.relname, '')
        FROM pg_constraint con
        JOIN pg_class c ON c.oid = con.conrelid
        LEFT JOIN pg_class f ON f.oid = con.confrelid
        WHERE c.relnamespace = 'public'::regnamespace AND con.contype IN ('p', 'u', 'f')
          AND c.relname <> 'schema_migrations'
        ORDER BY c.relname, con.contype"""):
        cols = cols.split(",")
        label = {"p": "PK", "u": "UK", "f": "FK"}[kind]
        if len(cols) == 1:
            column(table, cols[0])["keys"].append(label)
        else:
            tables[table]["notes"].append(f"{label} ({', '.join(cols)})")
        if kind == "f":
            relationships.append({"child": table, "parent": ref_table, "column": cols[0]})

    for table, name, definition in query(db, """
        SELECT t.relname, i.relname, pg_get_indexdef(i.oid)
        FROM pg_index ix
        JOIN pg_class i ON i.oid = ix.indexrelid
        JOIN pg_class t ON t.oid = ix.indrelid
        WHERE t.relnamespace = 'public'::regnamespace
          AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = ix.indexrelid)
        ORDER BY t.relname, i.relname"""):
        m = re.search(r"USING \w+ \((.*?)\)(?: INCLUDE \((.*?)\))?(?: WHERE (.*))?$", definition)
        cols, include, where = m.groups()
        unique = "UNIQUE " if " UNIQUE " in definition else ""
        if where:
            where = re.sub(r"[()]", "", where)
        if not unique and "," not in cols and not where and not include:
            column(table, cols)["keys"].append("IX")
            continue
        text = f"{'P' if where else ''}IX {unique}({cols})"
        if include:
            text += f" INCLUDE ({include})"
        if where:
            text += f" WHERE {where}"
        tables[table]["notes"].append(text)

    # Cardinality: the parent end is "exactly one" when the FK column is
    # NOT NULL, otherwise "zero or one". The child end is "zero or many",
    # or "zero or one" when the FK column is also UNIQUE (a 1:1 link).
    for rel in relationships:
        col = column(rel["child"], rel["column"])
        rel["parent_end"] = "one" if col["not_null"] else "zero_one"
        rel["child_end"] = "zero_one" if "UK" in col["keys"] else "zero_many"
    return tables, relationships


# ── Rendering ────────────────────────────────────────────────────

SCALE = 2
FONT_DIR = Path(os.environ.get("WINDIR", "C:/Windows")) / "Fonts"


def font(name, size):
    return ImageFont.truetype(str(FONT_DIR / name), size * SCALE)


F_TITLE, F_HEAD = font("arialbd.ttf", 22), font("arialbd.ttf", 14)
F_ROW, F_ROW_B = font("consola.ttf", 12), font("consolab.ttf", 12)
F_NOTE, F_SMALL = font("consola.ttf", 11), font("arial.ttf", 12)
F_LABEL = font("arialbd.ttf", 11)

ROW_H, HEAD_H, PAD = 18 * SCALE, 26 * SCALE, 8 * SCALE
COL_GAP, ROW_GAP, MARGIN = 190 * SCALE, 34 * SCALE, 40 * SCALE
INK, GRID, HEAD_BG, KEY_BG = "#1f2933", "#9aa5b1", "#dfe7f2", "#fff6dc"


def text_w(f, s):
    return f.getlength(s)


def measure(tables):
    """Compute width/height of each table box and the layout positions."""
    for name, t in tables.items():
        key_w = max(text_w(F_ROW_B, " ".join(c["keys"])) for c in t["columns"]) + PAD * 2
        name_w = max(text_w(F_ROW, c["name"]) for c in t["columns"]) + PAD * 2
        type_w = max(text_w(F_ROW, c["type"] + (" *" if c["not_null"] else "")) for c in t["columns"])
        notes_w = max([text_w(F_NOTE, n) for n in t["notes"]] or [0])
        t["key_w"], t["name_w"] = max(key_w, 34 * SCALE), name_w
        t["w"] = max(t["key_w"] + name_w + type_w + PAD, notes_w + PAD * 2,
                     text_w(F_HEAD, name) + PAD * 2)
        t["h"] = HEAD_H + ROW_H * len(t["columns"]) + PAD
        if t["notes"]:
            t["h"] += ROW_H * len(t["notes"]) + PAD

    top = MARGIN + 150 * SCALE
    x = MARGIN
    for col in LAYOUT:
        width = max(tables[n]["w"] for n in col)
        y = top
        for n in col:
            tables[n].update(x=x, y=y, w=width)
            y += tables[n]["h"] + ROW_GAP
        x += width + COL_GAP
    # Extra room on the right for the categories self-loop and its label.
    return x - COL_GAP + MARGIN + 40 * SCALE, max(t["y"] + t["h"] for t in tables.values()) + MARGIN


def column_of(name):
    return next(i for i, col in enumerate(LAYOUT) if name in col)


def route(tables, relationships):
    """Give every relationship a polyline with horizontal or vertical end segments."""
    side_slots = {}  # (table, side) -> list of (rel, end)
    for rel in relationships:
        p, c = rel["parent"], rel["child"]
        if p == c:
            rel["kind"] = "self"
            side_slots.setdefault((p, "right"), []).extend([(rel, "parent"), (rel, "child")])
        elif column_of(p) == column_of(c):
            rel["kind"] = "vertical"
        else:
            rel["kind"] = "elbow"
            left, right = (p, c) if column_of(p) < column_of(c) else (c, p)
            rel["left"], rel["right"] = left, right
            side_slots.setdefault((left, "right"), []).append((rel, "left"))
            side_slots.setdefault((right, "left"), []).append((rel, "right"))

    # Spread attachment points along each side, ordered by where the
    # other end sits, so neighbouring lines do not cross.
    def other_y(rel, end):
        other = rel["right"] if end == "left" else rel["left"] if end == "right" else rel["parent"]
        return tables[other]["y"] + tables[other]["h"] / 2

    attach = {}
    for (table, side), items in side_slots.items():
        t = tables[table]
        items.sort(key=lambda it: other_y(*it))
        usable_top, usable_h = t["y"] + HEAD_H, t["h"] - HEAD_H
        for i, (rel, end) in enumerate(items):
            y = usable_top + usable_h * (i + 1) / (len(items) + 1)
            xx = t["x"] + t["w"] if side == "right" else t["x"]
            attach[(id(rel), end)] = (xx, y)

    lanes = {}
    for rel in relationships:
        if rel["kind"] == "elbow":
            gap = min(column_of(rel["left"]), column_of(rel["right"]))
            lanes.setdefault(gap, []).append(rel)
    for gap, rels in lanes.items():
        rels.sort(key=lambda r: attach[(id(r), "left")][1])
        left_edge = max(tables[n]["x"] + tables[n]["w"] for n in LAYOUT[gap])
        step = COL_GAP / (len(rels) + 1)
        for i, rel in enumerate(rels):
            rel["lane_x"] = left_edge + step * (i + 1)

    for rel in relationships:
        p, c = tables[rel["parent"]], tables[rel["child"]]
        if rel["kind"] == "vertical":
            upper, lower = (p, c) if p["y"] < c["y"] else (c, p)
            x = upper["x"] + upper["w"] / 2
            pts = [(x, upper["y"] + upper["h"]), (x, lower["y"])]
            rel["points"] = pts if upper is p else pts[::-1]
        elif rel["kind"] == "self":
            (x1, y1), (x2, y2) = attach[(id(rel), "parent")], attach[(id(rel), "child")]
            out = x1 + 36 * SCALE
            rel["points"] = [(x1, y1), (out, y1), (out, y2), (x2, y2)]
        else:
            (x1, y1), (x2, y2) = attach[(id(rel), "left")], attach[(id(rel), "right")]
            lx = rel["lane_x"]
            pts = [(x1, y1), (lx, y1), (lx, y2), (x2, y2)]
            rel["points"] = pts if rel["left"] == rel["parent"] else pts[::-1]


def draw_end(d, tip, prev, kind):
    """Crow's-foot marker at `tip`, the end of a segment coming from `prev`."""
    ux, uy = tip[0] - prev[0], tip[1] - prev[1]
    length = (ux * ux + uy * uy) ** 0.5 or 1
    ux, uy = ux / length, uy / length          # direction into the table
    px, py = -uy, ux                            # perpendicular
    w = 2 * SCALE

    def at(dist, off=0.0):
        return (tip[0] - ux * dist + px * off, tip[1] - uy * dist + py * off)

    def bar(dist):
        d.line([at(dist, -7 * SCALE), at(dist, 7 * SCALE)], fill=INK, width=w)

    def circle(dist):
        cx, cy = at(dist)
        r = 5 * SCALE
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=INK, fill="white", width=w)

    if kind == "one":
        bar(8 * SCALE)
        bar(14 * SCALE)
    elif kind == "zero_one":
        bar(8 * SCALE)
        circle(20 * SCALE)
    else:  # zero_many
        base = at(12 * SCALE)
        d.line([base, at(0, -8 * SCALE)], fill=INK, width=w)
        d.line([base, at(0, 8 * SCALE)], fill=INK, width=w)
        d.line([base, at(0)], fill=INK, width=w)
        circle(19 * SCALE)


def render_png(tables, relationships, size):
    img = Image.new("RGB", (int(size[0]), int(size[1])), "white")
    d = ImageDraw.Draw(img)

    d.text((MARGIN, MARGIN), "ShopFlow E-Commerce - Entity Relationship Diagram", font=F_TITLE, fill=INK)
    d.text((MARGIN, MARGIN + 34 * SCALE),
           f"PostgreSQL  |  {len(tables)} tables  |  generated from the live schema "
           "(lakshitha-month3-migrations.sql V001-V004)", font=F_SMALL, fill="#52606d")
    legend = [
        "PK primary key   FK foreign key   UK unique   IX index (V002/V004)   PIX partial index   * NOT NULL",
        "Line labels: 1:1 / 1:N relationship type     Line ends:  ||  exactly one     o|  zero or one     o<  zero or many",
        "M:N  users <-> product_variants is resolved by cart_items (via carts) and wishlist_items;  "
        "orders <-> product_variants by order_items;  users <-> products by reviews",
    ]
    for i, line in enumerate(legend):
        d.text((MARGIN, MARGIN + (60 + 20 * i) * SCALE), line, font=F_SMALL, fill=INK)

    for rel in relationships:
        d.line(rel["points"], fill=INK, width=2 * SCALE, joint="curve")

    for name, t in tables.items():
        x, y, w, h = t["x"], t["y"], t["w"], t["h"]
        d.rectangle([x, y, x + w, y + h], fill="white", outline=INK, width=2 * SCALE)
        d.rectangle([x, y, x + w, y + HEAD_H], fill=HEAD_BG, outline=INK, width=2 * SCALE)
        d.text((x + w / 2, y + HEAD_H / 2), name, font=F_HEAD, fill=INK, anchor="mm")
        row_y = y + HEAD_H + PAD / 2
        for col in t["columns"]:
            if col["keys"]:
                d.rectangle([x + 2 * SCALE, row_y, x + t["key_w"], row_y + ROW_H], fill=KEY_BG)
            key_font = F_ROW_B if col["keys"] else F_ROW
            d.text((x + PAD, row_y + ROW_H / 2), " ".join(col["keys"]), font=F_ROW_B, fill="#8a4b00", anchor="lm")
            d.text((x + t["key_w"], row_y + ROW_H / 2), col["name"], font=key_font, fill=INK, anchor="lm")
            d.text((x + t["key_w"] + t["name_w"], row_y + ROW_H / 2),
                   col["type"] + (" *" if col["not_null"] else ""), font=F_ROW, fill="#52606d", anchor="lm")
            row_y += ROW_H
        if t["notes"]:
            row_y += PAD / 2
            d.line([x, row_y, x + w, row_y], fill=GRID, width=SCALE)
            for note in t["notes"]:
                d.text((x + PAD, row_y + ROW_H / 2 + PAD / 2), note, font=F_NOTE, fill="#3e4c59", anchor="lm")
                row_y += ROW_H

    for rel in relationships:
        pts = rel["points"]
        draw_end(d, pts[0], pts[1], rel["parent_end"])
        draw_end(d, pts[-1], pts[-2], rel["child_end"])
        draw_label(d, rel)

    img.save(OUT_PNG, optimize=True)


def relationship_type(rel):
    return "1:1" if rel["child_end"] == "zero_one" else "1:N"


def draw_label(d, rel):
    """Write the relationship type on the line's middle segment."""
    pts = rel["points"]
    (x1, y1), (x2, y2) = (pts[0], pts[1]) if len(pts) == 2 else (pts[1], pts[2])
    x, y = (x1 + x2) / 2, (y1 + y2) / 2
    text = relationship_type(rel)
    if rel["kind"] == "vertical":
        # Short gap between stacked tables: put the label beside the line.
        x, anchor = x + 10 * SCALE, "lm"
    else:
        anchor = "mm"
    left, top, right, bottom = d.textbbox((x, y), text, font=F_LABEL, anchor=anchor)
    pad = 3 * SCALE
    d.rectangle([left - pad, top - pad, right + pad, bottom + pad], fill="white", outline=GRID, width=SCALE)
    d.text((x, y), text, font=F_LABEL, fill=INK, anchor=anchor)


# ── draw.io export ───────────────────────────────────────────────

DRAWIO_ENDS = {"one": "ERmandOne", "zero_one": "ERzeroToOne", "zero_many": "ERzeroToMany"}


def render_drawio(tables, relationships):
    cells = ['<mxCell id="0"/>', '<mxCell id="1" parent="0"/>']
    for name, t in tables.items():
        x, y, w, h = (round(v / SCALE) for v in (t["x"], t["y"], t["w"], t["h"]))
        rows = "<br>".join(
            f"<b>{' '.join(c['keys'])}</b> {html.escape(c['name'])} : "
            f"{html.escape(c['type'])}{' *' if c['not_null'] else ''}" for c in t["columns"])
        if t["notes"]:
            rows += "<hr>" + "<br>".join(html.escape(n) for n in t["notes"])
        cells.append(
            f'<mxCell id="t_{name}" value={quoteattr(name)} style="swimlane;fontStyle=1;'
            f'childLayout=stackLayout;horizontal=1;startSize=26;fillColor=#dfe7f2;rounded=0;" '
            f'vertex="1" parent="1"><mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/></mxCell>')
        cells.append(
            f'<mxCell id="b_{name}" value={quoteattr(rows)} style="text;html=1;align=left;'
            f'verticalAlign=top;spacingLeft=6;fontFamily=Consolas;fontSize=11;" vertex="1" '
            f'parent="t_{name}"><mxGeometry y="26" width="{w}" height="{h - 26}" as="geometry"/></mxCell>')
    for i, rel in enumerate(relationships):
        style = (f"edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;endFill=0;startFill=0;"
                 f"startArrow={DRAWIO_ENDS[rel['parent_end']]};endArrow={DRAWIO_ENDS[rel['child_end']]};")
        cells.append(
            f'<mxCell id="r{i}" value="{relationship_type(rel)}" style="{style}" edge="1" parent="1" '
            f'source="t_{rel["parent"]}" '
            f'target="t_{rel["child"]}"><mxGeometry relative="1" as="geometry"/></mxCell>')
    OUT_DRAWIO.write_text(
        '<mxfile host="build_erd.py"><diagram name="ShopFlow ERD"><mxGraphModel><root>\n'
        + "\n".join(cells) + "\n</root></mxGraphModel></diagram></mxfile>\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", default="shopflow_m3")
    args = parser.parse_args()
    tables, relationships = load_schema(args.db)
    missing = set(tables) - {n for col in LAYOUT for n in col}
    assert not missing, f"tables missing from LAYOUT: {missing}"
    size = measure(tables)
    route(tables, relationships)
    render_png(tables, relationships, size)
    render_drawio(tables, relationships)
    print(f"{len(tables)} tables, {len(relationships)} relationships -> {OUT_PNG.name}, {OUT_DRAWIO.name}")


if __name__ == "__main__":
    main()
