#!/usr/bin/env python3
"""Generates the synthetic part of Platen's robustness corpus.

Writes EPUB (and plain-text) files into Fixtures/generated/ (git-ignored). Each one exercises a
case from the spec's "Format support and robustness" table. Real-world books
(Standard Ebooks, Gutenberg, the W3C EPUB 3 test suite) belong in
Fixtures/corpus/ when they may be redistributed, or Fixtures/local/ otherwise.

Usage: scripts/make-fixtures.py
"""
import hashlib
import os
import random
import struct
import uuid
import zlib
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Fixtures", "generated")

CONTAINER = """<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>"""

WORDS = ("the of and to in a is that it was he for on are as with his they at be this from have or by "
         "one had not but what all were when we there can an your which their said if do will each about "
         "how up out them then she many some so these would other into has more her two like him see time "
         "could no make than first been its who now people my made over did down only way find use may water "
         "long little very after words called just where most know get through back much before go good new "
         "write our used me man too any day same right look think also around another came come work three "
         "word must because does part even place well such here take why things help put years different away "
         "again off went old number great tell men say small every found still between name should home big "
         "give air line set own under read last never us left end along while might next sound below saw "
         "something thought both few those always looked show large often together asked house world going want").split()


def paragraph(rng, sentences=6):
    out = []
    for _ in range(sentences):
        n = rng.randint(8, 22)
        s = " ".join(rng.choice(WORDS) for _ in range(n))
        out.append(s[0].upper() + s[1:] + rng.choice([".", ".", ".", "?", "!"]))
    return " ".join(out)


def xhtml(title, body, lang="en", extra_head="", dir_attr=""):
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="{lang}" lang="{lang}"{dir_attr}>
<head><title>{title}</title><link rel="stylesheet" href="style.css" type="text/css"/>{extra_head}</head>
<body>{body}</body>
</html>"""


STYLE = """body { font-family: serif; margin: 0 5%; }
h1 { text-align: center; margin: 2em 0 1em; }
p { text-indent: 1.5em; margin: 0; text-align: justify; }
"""


def opf(identifier, title, manifest, spine, version="3.0", extra_meta="", spine_attrs="", lang="en"):
    items = "\n    ".join(manifest)
    refs = "\n    ".join(spine)
    modified = '<meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>' if version.startswith("3") else ""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="{version}" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:identifier id="uid">{identifier}</dc:identifier>
    <dc:title>{title}</dc:title>
    <dc:creator>Platen Test Corpus</dc:creator>
    <dc:language>{lang}</dc:language>
    {modified}
    {extra_meta}
  </metadata>
  <manifest>
    {items}
  </manifest>
  <spine{spine_attrs}>
    {refs}
  </spine>
</package>"""


def png(width, height, rgb):
    """A plain PNG of one colour with a darker diagonal, for picture tests."""
    rows = b""
    for y in range(height):
        row = bytearray(b"\x00")
        for x in range(width):
            row += bytes(c // 3 for c in rgb) if abs(x * height - y * width) < width * 2 else bytes(rgb)
        rows += bytes(row)
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def write_epub(name, files, mimetype_first=True):
    """files: list of (path, str|bytes). mimetype is added automatically."""
    path = os.path.join(OUT, name)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        if mimetype_first:
            z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        for p, data in files:
            z.writestr(p, data)
        if not mimetype_first:
            z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
    return path


def nav_doc(entries, page_list=None, landmarks=None):
    toc = "".join(f'<li><a href="{h}">{t}</a></li>' for h, t in entries)
    pages = ""
    if page_list:
        pages = '<nav epub:type="page-list" hidden=""><ol>' + "".join(
            f'<li><a href="{h}">{n}</a></li>' for h, n in page_list) + "</ol></nav>"
    marks = ""
    if landmarks:
        marks = '<nav epub:type="landmarks" hidden=""><ol>' + "".join(
            f'<li><a epub:type="{t}" href="{h}">{t}</a></li>' for t, h in landmarks) + "</ol></nav>"
    return xhtml("Contents", f'<nav epub:type="toc"><h1>Contents</h1><ol>{toc}</ol></nav>{pages}{marks}')


def novel(name="novel.epub", chapters=30, paras=60, seed=1):
    """A ~2 MB EPUB 3 novel: nav, page list, landmarks, cover page."""
    rng = random.Random(seed)
    files = [("META-INF/container.xml", CONTAINER), ("OEBPS/style.css", STYLE)]
    manifest = ['<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
                '<item id="css" href="style.css" media-type="text/css"/>',
                '<item id="title" href="title.xhtml" media-type="application/xhtml+xml"/>']
    spine = ['<itemref idref="title"/>']
    files.append(("OEBPS/title.xhtml", xhtml("Title", "<h1>A Synthetic Novel</h1><p>Generated for testing.</p>")))
    toc, pages = [], []
    page = 1
    for c in range(1, chapters + 1):
        body = [f'<h1 id="c{c}">Chapter {c}</h1>']
        for p in range(paras):
            if p % 12 == 0:
                body.append(f'<span epub:type="pagebreak" id="p{page}" title="{page}"/>')
                pages.append((f"ch{c:02}.xhtml#p{page}", str(page)))
                page += 1
            body.append(f"<p>{paragraph(rng)}</p>")
        files.append((f"OEBPS/ch{c:02}.xhtml", xhtml(f"Chapter {c}", "\n".join(body))))
        manifest.append(f'<item id="ch{c}" href="ch{c:02}.xhtml" media-type="application/xhtml+xml"/>')
        spine.append(f'<itemref idref="ch{c}"/>')
        toc.append((f"ch{c:02}.xhtml", f"Chapter {c}"))
    files.append(("OEBPS/nav.xhtml", nav_doc(toc, pages, [("bodymatter", "ch01.xhtml")])))
    files.append(("OEBPS/content.opf", opf(f"urn:uuid:{uuid.UUID(int=seed)}", "A Synthetic Novel", manifest, spine)))
    return write_epub(name, files)


def simple(name, title, chapter_files, extra_files=(), version="3.0", extra_meta="", spine_attrs="",
           manifest_extra=(), lang="en", identifier=None, nav=True):
    files = [("META-INF/container.xml", CONTAINER), ("OEBPS/style.css", STYLE)]
    manifest = ['<item id="css" href="style.css" media-type="text/css"/>'] + list(manifest_extra)
    spine = []
    toc = []
    for i, (href, content) in enumerate(chapter_files, 1):
        files.append((f"OEBPS/{href}", content))
        manifest.append(f'<item id="c{i}" href="{href}" media-type="application/xhtml+xml"/>')
        spine.append(f'<itemref idref="c{i}"/>')
        toc.append((href, f"Section {i}"))
    if nav:
        manifest.append('<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>')
        files.append(("OEBPS/nav.xhtml", nav_doc(toc)))
    files += list(extra_files)
    ident = identifier or f"urn:uuid:{uuid.uuid5(uuid.NAMESPACE_URL, name)}"
    files.append(("OEBPS/content.opf", opf(ident, title, manifest, spine, version, extra_meta, spine_attrs, lang)))
    return write_epub(name, files)


def simple_pdf(path, title, chapters, pages_per_chapter=2, doc_id="9F86D081884C7D659A2FEAA0C55AD015",
               pictures=False, square=False):
    """A small PDF written by hand (no PDF library needed): text pages in
    Helvetica, an outline with one entry per chapter, a title in the
    document information, and a document ID in the trailer, which Platen
    uses to recognise the file again (PDFIdentity). With pictures, every
    page has a picture (an image XObject) in its lower half, and the last
    page is landscape, filled by a picture (for long-press save and share,
    and the One Page layout). With square, every page is square (as many
    picture books' are), so Two Pages pairs them in landscape."""
    objects = []  # bodies, numbered from 1

    def add(body):
        objects.append(body)
        return len(objects)

    def esc(text):
        return text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")

    catalog = add(None)        # filled in below
    pages_obj = add(None)
    font = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    image = None
    if pictures:
        # 64 × 48 pixels of raw RGB: a blue-to-orange gradient.
        w, h = 64, 48
        pixels = bytes(v for y in range(h) for x in range(w)
                       for v in (40 + x * 3, 90 + y, 200 - x * 2))
        image = add(f"<< /Type /XObject /Subtype /Image /Width {w} /Height {h} /ColorSpace /DeviceRGB "
                    f"/BitsPerComponent 8 /Length {len(pixels)} >>\nstream\n" + pixels.decode("latin-1") + "\nendstream")
    page_ids = []
    for c, name in enumerate(chapters):
        for p in range(pages_per_chapter):
            lines = [f"{name}" if p == 0 else f"{name} (continued)", ""]
            lines += [f"Page {len(page_ids) + 1} of the {title.lower()}. Line {i + 1} of the text."
                      for i in range(20)]
            text = f"BT /F1 12 Tf 72 {560 if square else 720} Td 16 TL " + " ".join(f"({esc(l)}) '" for l in lines) + " ET"
            box, xobjects = ("0 0 612 612" if square else "0 0 612 792"), ""
            if image:
                last = c == len(chapters) - 1 and p == pages_per_chapter - 1
                if last:  # landscape, filled by the picture
                    box, text = "0 0 792 612", "q 792 0 0 612 0 0 cm /Im1 Do Q"
                else:
                    text += " q 300 0 0 225 156 60 cm /Im1 Do Q"
                xobjects = f" /XObject << /Im1 {image} 0 R >>"
            stream = add(f"<< /Length {len(text)} >>\nstream\n{text}\nendstream")
            page_ids.append(add(f"<< /Type /Page /Parent {pages_obj} 0 R /MediaBox [{box}] "
                                f"/Contents {stream} 0 R /Resources << /Font << /F1 {font} 0 R >>{xobjects} >> >>"))
    # The outline: one entry per chapter, pointing at its first page.
    outline = add(None)
    items = []
    for c, name in enumerate(chapters):
        items.append(add(None))
    for c, name in enumerate(chapters):
        parts = [f"/Title ({esc(name)})", f"/Parent {outline} 0 R",
                 f"/Dest [{page_ids[c * pages_per_chapter]} 0 R /Fit]"]
        if c > 0: parts.append(f"/Prev {items[c - 1]} 0 R")
        if c < len(items) - 1: parts.append(f"/Next {items[c + 1]} 0 R")
        objects[items[c] - 1] = "<< " + " ".join(parts) + " >>"
    objects[outline - 1] = f"<< /Type /Outlines /First {items[0]} 0 R /Last {items[-1]} 0 R /Count {len(items)} >>"
    objects[pages_obj - 1] = (f"<< /Type /Pages /Kids [{' '.join(f'{p} 0 R' for p in page_ids)}] "
                              f"/Count {len(page_ids)} >>")
    objects[catalog - 1] = f"<< /Type /Catalog /Pages {pages_obj} 0 R /Outlines {outline} 0 R /PageMode /UseOutlines >>"
    info = add(f"<< /Title ({esc(title)}) /Author (Pat D. Eff) >>")

    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for n, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{n} 0 obj\n{body}\nendobj\n".encode("latin-1")
    xref = len(out)
    out += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode()
    for o in offsets:
        out += f"{o:010d} 00000 n \n".encode()
    out += (f"trailer\n<< /Size {len(objects) + 1} /Root {catalog} 0 R /Info {info} 0 R "
            f"/ID [<{doc_id}> <{doc_id}>] >>\nstartxref\n{xref}\n%%EOF\n").encode()
    open(path, "wb").write(bytes(out))


# ---------------------------------------------------------------------------
# MOBI and AZW3 (KF8), written by hand to what foliate-js's mobi.js reads.
# Kindle files are Palm databases: a header, a list of record offsets, then
# the records. Record 0 holds the PalmDOC header, the MOBI header (version 6
# for MOBI, 8 for AZW3) and an EXTH block (title, author); then come the
# book's text records (here uncompressed) and, for KF8, the indexes that say
# how the text is cut into pages; pictures are records of their own.

def _mobi_varlen(value):
    """A forward variable-length number: seven bits a byte, most significant
    first, the last byte marked by its top bit (as mobi.js's getVarLen)."""
    groups = [value & 0x7F]
    value >>= 7
    while value:
        groups.insert(0, value & 0x7F)
        value >>= 7
    groups[-1] |= 0x80
    return bytes(groups)


def _palm_database(name, records):
    """The Palm database: name, type BOOK, creator MOBI, the record offsets,
    two bytes of padding, then the records."""
    header = bytearray(78)
    header[0:len(name[:31])] = name[:31].encode("ascii", "replace")
    header[60:68] = b"BOOKMOBI"
    struct.pack_into(">H", header, 76, len(records))
    offset = 78 + 8 * len(records) + 2
    table = bytearray()
    for i, record in enumerate(records):
        table += struct.pack(">IB3s", offset, 0, (2 * i).to_bytes(3, "big"))
        offset += len(record)
    return bytes(header + table + b"\0\0" + b"".join(records))


def _record0(title, author, version, text_length, text_records, first_resource, kf8=None):
    """Record 0: PalmDOC header, MOBI header (248 bytes from its magic), EXTH,
    then the title. No index is 0xFFFFFFFF."""
    none = 0xFFFFFFFF
    head = bytearray(16 + 248)
    struct.pack_into(">HHIHHHH", head, 0, 1, 0, text_length, text_records, 4096, 0, 0)  # uncompressed, no DRM
    head[16:20] = b"MOBI"
    struct.pack_into(">IIII", head, 20, 248, 2, 65001, 0x0B00C0DE)  # length, type book, UTF-8, uid
    struct.pack_into(">I", head, 36, version)
    for offset in range(40, 264, 4):
        if offset not in (84, 88, 92, 108, 128, 240):
            struct.pack_into(">I", head, offset, none)
    struct.pack_into(">I", head, 92, 9)  # English
    struct.pack_into(">I", head, 108, first_resource)
    struct.pack_into(">I", head, 128, 0x40)  # has EXTH
    struct.pack_into(">I", head, 240, 0)  # no trailing entries
    if kf8:
        struct.pack_into(">II", head, 192, kf8["fdst"], 1)
        struct.pack_into(">II", head, 248, kf8["frag"], kf8["skel"])
    exth_records = [(100, author.encode()), (503, title.encode())]
    body = b"".join(struct.pack(">II", kind, len(data) + 8) + data for kind, data in exth_records)
    exth = b"EXTH" + struct.pack(">II", 12 + len(body), len(exth_records)) + body
    exth += b"\0" * (-len(exth) % 4)
    struct.pack_into(">II", head, 84, len(head) + len(exth), len(title.encode()))
    record = bytes(head) + exth + title.encode()
    return record + b"\0" * (-len(record) % 4)


def _text_records(text):
    return [text[i:i + 4096] for i in range(0, len(text), 4096)] or [b""]


def mobi6(path, title, author, html, pictures):
    """A MOBI 6 book: HTML text (pictures as <img recindex="0000N">), the
    pictures as records after the text."""
    texts = _text_records(html)
    first_resource = 1 + len(texts)
    record0 = _record0(title, author, 6, len(html), len(texts), first_resource)
    open(path, "wb").write(_palm_database(title, [record0] + texts + list(pictures)))


def _indx(entries, tags, cncx_records=0):
    """An index: its header record (with the TAGX tag table) and one data
    record of entries. `tags` are (tag, values per entry, mask); every
    entry has every tag once, so its control byte is the masks' sum (each
    mask's lowest bit set). An entry is (name, [values for each tag])."""
    header = bytearray(192)
    header[0:4] = b"INDX"
    struct.pack_into(">II", header, 4, 192, 0)
    struct.pack_into(">IIIII", header, 20, 0, 1, 65001, 0xFFFFFFFF, len(entries))  # idxt, records, UTF-8, language, total
    struct.pack_into(">I", header, 52, cncx_records)
    tagx = b"".join(bytes([tag, count, mask, 0]) for tag, count, mask in tags) + bytes([0, 0, 0, 1])
    header += b"TAGX" + struct.pack(">II", 12 + len(tagx), 1) + tagx
    control = sum(mask & -mask for _, _, mask in tags)
    data = bytearray(192)
    data[0:4] = b"INDX"
    offsets = []
    for name, values in entries:
        offsets.append(len(data))
        data += bytes([len(name)]) + name.encode() + bytes([control])
        for value in values:
            data += _mobi_varlen(value)
    data += b"\0" * (-len(data) % 4)
    idxt = len(data)
    data += b"IDXT" + b"".join(struct.pack(">H", o) for o in offsets)
    data += b"\0" * (-len(data) % 4)
    struct.pack_into(">II", data, 4, 192, 1)
    struct.pack_into(">II", data, 20, idxt, len(entries))
    return [bytes(header), bytes(data)]


def azw3(path, title, author, skeleton, fragment, pictures):
    """An AZW3 (KF8) book of one page: `skeleton` is its XHTML with the body
    empty, `fragment` the body's content, inserted before </body> (KF8 keeps
    a page as a skeleton and fragments, which the reader puts back
    together); pictures are kindle:embed:000N resources."""
    insert = skeleton.index(b"</body>")
    text = skeleton + fragment
    texts = _text_records(text)
    t = len(texts)
    selector = b"P-//*[@aid='0']"
    frag = _indx([(f"{insert:010d}", [0, 0, 0, 0, len(fragment)])],
                 [(2, 1, 0x01), (3, 1, 0x02), (4, 1, 0x04), (6, 2, 0x08)], cncx_records=1)
    cncx = _mobi_varlen(len(selector)) + selector
    cncx += b"\0" * (-len(cncx) % 4)
    skel = _indx([("SKEL0000000000", [1, 0, len(skeleton)])], [(1, 1, 0x03), (6, 2, 0x0C)])
    # FDST: where each flow is in the text; one flow, all of it. (The table
    # starts at 12, right after the count.)
    fdst = b"FDST" + struct.pack(">II", 12, 1) + struct.pack(">II", 0, len(text))
    # Records (counted from 0): 0, text 1..t, frag index t+1 (header),
    # t+2 (data), t+3 (CNCX), skeleton index t+4 and t+5, FDST t+6, pictures.
    record0 = _record0(title, author, 8, len(text), t, t + 7,
                       kf8={"fdst": t + 6, "frag": t + 1, "skel": t + 4})
    records = [record0] + texts + frag + [cncx] + skel + [fdst] + list(pictures)
    open(path, "wb").write(_palm_database(title, records))


def text_pdf(path, title, pages, doc_id="5D41402ABC4B2A76B9719D911017C592"):
    """A PDF of text pages as a printed book has them: each page is
    (header, body lines, footer), the header at the top, the footer at the
    bottom (read aloud must leave both out, and join a word hyphenated at a
    line's end and a sentence running onto the next page)."""
    objects = []

    def add(body):
        objects.append(body)
        return len(objects)

    def esc(text):
        return text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")

    catalog = add(None)
    pages_obj = add(None)
    font = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    page_ids = []
    for header, body, footer in pages:
        parts = [f"BT /F1 10 Tf 72 760 Td ({esc(header)}) Tj ET"]
        parts.append("BT /F1 12 Tf 72 720 Td 16 TL " + " ".join(f"({esc(l)}) '" for l in body) + " ET")
        parts.append(f"BT /F1 10 Tf 290 40 Td ({esc(footer)}) Tj ET")
        text = " ".join(parts)
        stream = add(f"<< /Length {len(text)} >>\nstream\n{text}\nendstream")
        page_ids.append(add(f"<< /Type /Page /Parent {pages_obj} 0 R /MediaBox [0 0 612 792] "
                            f"/Contents {stream} 0 R /Resources << /Font << /F1 {font} 0 R >> >> >>"))
    objects[pages_obj - 1] = (f"<< /Type /Pages /Kids [{' '.join(f'{p} 0 R' for p in page_ids)}] "
                              f"/Count {len(page_ids)} >>")
    objects[catalog - 1] = f"<< /Type /Catalog /Pages {pages_obj} 0 R >>"
    info = add(f"<< /Title ({esc(title)}) /Author (Pat D. Eff) >>")
    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for n, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{n} 0 obj\n{body}\nendobj\n".encode("latin-1")
    xref = len(out)
    out += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode()
    for o in offsets:
        out += f"{o:010d} 00000 n \n".encode()
    out += (f"trailer\n<< /Size {len(objects) + 1} /Root {catalog} 0 R /Info {info} 0 R "
            f"/ID [<{doc_id}> <{doc_id}>] >>\nstartxref\n{xref}\n%%EOF\n").encode()
    open(path, "wb").write(bytes(out))


def main():
    os.makedirs(OUT, exist_ok=True)
    rng = random.Random(7)
    made = []

    made.append(novel())

    # EPUB 2 with an NCX table of contents and no nav document.
    ncx = """<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head/><docTitle><text>EPUB 2</text></docTitle>
<navMap>""" + "".join(
        f'<navPoint id="n{i}" playOrder="{i}"><navLabel><text>NCX Chapter {i}</text></navLabel><content src="c{i}.xhtml"/></navPoint>'
        for i in range(1, 4)) + "</navMap></ncx>"
    made.append(simple("epub2-ncx.epub", "EPUB 2 with NCX",
                       [(f"c{i}.xhtml", xhtml(f"C{i}", f"<h1>NCX Chapter {i}</h1><p>{paragraph(rng, 30)}</p>")) for i in range(1, 4)],
                       extra_files=[("OEBPS/toc.ncx", ncx)], version="2.0", nav=False,
                       manifest_extra=['<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'],
                       spine_attrs=' toc="ncx"'))

    # Malformed XHTML: unclosed tags and an HTML-only entity. WebKit's XML
    # parser rejects this; foliate-js re-parses it as HTML.
    bad = """<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Bad</title></head>
<body><h1>Malformed &amp; still readable</h1><p>This paragraph is never closed&nbsp;and uses an HTML entity.
<p>Neither is this one. <b>Bold <i>and italic</b></i> tags overlap.<br>
<p>If you can read this, the lenient fallback worked.</body></html>"""
    made.append(simple("malformed-xhtml.epub", "Malformed XHTML", [("bad.xhtml", bad)]))

    # Case mismatch: the manifest says chapter1.xhtml, the zip has Chapter1.xhtml.
    p = os.path.join(OUT, "case-mismatch.epub")
    with zipfile.ZipFile(p, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/container.xml", CONTAINER)
        z.writestr("OEBPS/Chapter1.xhtml", xhtml("Case", "<h1>Case mismatch</h1><p>The manifest asked for chapter1.xhtml.</p>"))
        z.writestr("OEBPS/content.opf", opf("urn:uuid:" + str(uuid.uuid4()), "Case Mismatch",
                                            ['<item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>'],
                                            ['<itemref idref="c1"/>']))
    made.append(p)

    # Percent-encoded and Unicode file names.
    made.append(simple("unicode-names.epub", "Unicode File Names",
                       [("Caf%C3%A9%20Chapter.xhtml", "")], nav=False))
    # (rewrite with the real decoded name in the zip)
    p = os.path.join(OUT, "unicode-names.epub")
    with zipfile.ZipFile(p, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/container.xml", CONTAINER)
        z.writestr("OEBPS/Café Chapter.xhtml", xhtml("Café", "<h1>Café chapter</h1><p>Found via a percent-encoded href.</p>"))
        z.writestr("OEBPS/content.opf", opf("urn:uuid:" + str(uuid.uuid4()), "Unicode Names",
                                            ['<item id="c1" href="Caf%C3%A9%20Chapter.xhtml" media-type="application/xhtml+xml"/>'],
                                            ['<itemref idref="c1"/>']))

    # Scripted content: the script must NOT run (text stays "Scripts are off").
    script = xhtml("Script", '<h1 id="s">Scripts are off</h1><p>If the heading says "SCRIPT RAN", book JavaScript executed.</p>',
                   extra_head='<script>document.addEventListener("DOMContentLoaded",()=>{document.getElementById("s").textContent="SCRIPT RAN"})</script>')
    made.append(simple("scripted.epub", "Scripted Content", [("s.xhtml", script)],
                       manifest_extra=[]))

    # Remote resources: must be blocked (no broken-image network request).
    remote = xhtml("Remote", '<h1>Remote image below is blocked</h1><p><img src="https://example.com/tracker.png" alt="(blocked remote image)"/></p>')
    made.append(simple("remote-resource.epub", "Remote Resources", [("r.xhtml", remote)]))

    # No table of contents at all.
    made.append(simple("no-toc.epub", "No Table of Contents",
                       [(f"x{i}.xhtml", xhtml(f"X{i}", f"<h2>Untitled part {i}</h2><p>{paragraph(rng, 20)}</p>")) for i in range(1, 4)],
                       nav=False))

    # Right-to-left (Arabic-like placeholder text in Hebrew/Arabic script).
    rtl_text = "هذا نص عربي للاختبار. " * 120
    made.append(simple("rtl.epub", "RTL Book", [("r1.xhtml", xhtml("RTL", f"<h1>الفصل الأول</h1><p>{rtl_text}</p>", lang="ar", dir_attr=' dir="rtl"')),
                                                ("r2.xhtml", xhtml("RTL", f"<h1>الفصل الثاني</h1><p>{rtl_text}</p>", lang="ar", dir_attr=' dir="rtl"'))],
                       spine_attrs=' page-progression-direction="rtl"', lang="ar"))

    # Fixed layout picture book with SVG pages and spreads.
    pages = []
    colours = ["#e8d5b7", "#b7d5e8", "#d5e8b7", "#e8b7d5", "#f0e0a0", "#a0e0f0"]
    for i, colour in enumerate(colours, 1):
        pages.append((f"page{i}.xhtml", f"""<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Page {i}</title>
<meta name="viewport" content="width=600, height=800"/>
<style>body{{margin:0;width:600px;height:800px;background:{colour};font:bold 72px sans-serif;display:flex;align-items:center;justify-content:center}}</style></head>
<body><div>Page {i}</div></body></html>"""))
    made.append(simple("fixed-layout.epub", "Fixed Layout", pages,
                       extra_meta='<meta property="rendition:layout">pre-paginated</meta><meta property="rendition:spread">landscape</meta>'))

    # A fixed-layout picture book like Lory Dory (device testing, 21 Nov
    # 2026): landscape pages in strong colours, set in the middle of a
    # phone's screen with room above and below. With ambient light that room
    # glows in the page's colours, as round a PDF's page (the iOS matrix
    # checks it); it used to stay dark, with smudges at the corners.
    pages = []
    for i, colour in enumerate(["#f5d63d", "#4aa3e0", "#e0604a"], 1):
        pages.append((f"page{i}.xhtml", f"""<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Page {i}</title>
<meta name="viewport" content="width=1000, height=600"/>
<style>body{{margin:0;width:1000px;height:600px;background:{colour};font:bold 40px sans-serif;display:flex;align-items:center;justify-content:center}}</style></head>
<body><div>One night Grandpa was tucking me in. ({i})</div></body></html>"""))
    made.append(simple("fixed-layout-wide.epub", "Wide Fixed Layout", pages,
                       extra_meta='<meta property="rendition:layout">pre-paginated</meta>'
                                  '<meta property="rendition:spread">none</meta>'))

    # Publisher sizes in px, pt and keywords, which ignore the root font
    # size: the text size setting must still change them (reader.js rewrites
    # them to rem). Also content wider than a page (a fixed-width table and a
    # long unbreakable rule), which must be kept inside its column.
    sized = xhtml("Fixed sizes", """<h1 style="font-size:24pt">Fixed sizes</h1>
<p><img src="picture.png" alt="Test picture" style="width:200px"/></p>
<p class="px">Sized in pixels. """ + paragraph(rng) + """</p>
<p style="font-size: small">Sized with a keyword. """ + paragraph(rng) + """</p>
<table style="width:1400px"><tr><td>Too wide</td><td>for a page</td></tr></table>
<p>________________________________________________________________________________________________________________________________</p>
<div style="width:90em">A block wider than any page. """ + paragraph(rng) + """</div>""",
        extra_head='<style>p.px { font-size: 12px; line-height: 18px }</style>')
    made.append(simple("fixed-font-sizes.epub", "Fixed Font Sizes", [("s1.xhtml", sized)],
                       extra_files=[("OEBPS/picture.png", png(400, 300, (90, 140, 200)))],
                       manifest_extra=['<item id="pic" href="picture.png" media-type="image/png"/>']))

    # Publisher colours that vanish on some themes: black headings (invisible
    # on Dark and Black) and white text (invisible on Light). Whatever the
    # theme, the reader must swap unreadable colours for the theme's own.
    colours = xhtml("Colours", """<h1 class="block3">Black heading</h1>
<p>""" + paragraph(rng) + """</p>
<h2 class="block3">Another black heading</h2>
<p class="ghost">White text. """ + paragraph(rng) + """</p>
<div class="toc"><p class="toc1"><a href="c1.xhtml"><span class="i">Dark blue contents link</span></a></p>
<p class="toc1"><a href="c1.xhtml">Another dark blue link</a></p></div>""",
        extra_head='<style>.block3 { color: black } .ghost { color: #fff } '
                   '.toc a { text-decoration: none } .i { font-style: italic; color: #103870 }</style>')
    made.append(simple("low-contrast.epub", "Low Contrast", [("c1.xhtml", colours)]))

    # DRM: Adobe ADEPT markers (content is not actually encrypted).
    enc = """<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
<enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
<enc:CipherData><enc:CipherReference URI="OEBPS/c1.xhtml"/></enc:CipherData></enc:EncryptedData></encryption>"""
    made.append(simple("drm-adept.epub", "DRM Book", [("c1.xhtml", xhtml("x", "<p>x</p>"))],
                       extra_files=[("META-INF/encryption.xml", enc),
                                    ("META-INF/rights.xml", '<adept:rights xmlns:adept="http://ns.adobe.com/adept"/>')]))

    # Truncated zip: a novel with its last 30% cut off (no central directory).
    full = novel("tmp-full.epub", chapters=8, seed=3)
    data = open(full, "rb").read()
    open(os.path.join(OUT, "truncated.epub"), "wb").write(data[: int(len(data) * 0.7)])
    os.remove(full)
    made.append(os.path.join(OUT, "truncated.epub"))

    # Obfuscated font (IDPF): uses a system font locally; never committed.
    font_src = "/System/Library/Fonts/Supplemental/Courier New.ttf"
    if os.path.exists(font_src):
        ident = "urn:uuid:" + str(uuid.uuid5(uuid.NAMESPACE_URL, "font"))
        key = hashlib.sha1("".join(ident.split()).encode()).digest()
        font = bytearray(open(font_src, "rb").read())
        for i in range(min(1040, len(font))):
            font[i] ^= key[i % len(key)]
        enc = """<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
<enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
<enc:CipherData><enc:CipherReference URI="OEBPS/fonts/obf.ttf"/></enc:CipherData></enc:EncryptedData></encryption>"""
        css_font = '<style>@font-face{font-family:"Obf";src:url(fonts/obf.ttf)} .f{font-family:"Obf",fantasy;font-size:1.4em}</style>'
        made.append(simple("obfuscated-font.epub", "Obfuscated Font",
                           [("f.xhtml", xhtml("Font", '<h1>Obfuscated font</h1><p class="f">This line should be in Courier New. If it is in a fantasy or fallback face, de-obfuscation failed.</p>', extra_head=css_font))],
                           extra_files=[("META-INF/encryption.xml", enc), ("OEBPS/fonts/obf.ttf", bytes(font))],
                           manifest_extra=['<item id="font" href="fonts/obf.ttf" media-type="font/ttf"/>'],
                           identifier=ident))

    # KEPUB: Kobo's koboSpan markup and fixed-size column wrappers.
    spans = " ".join(f'<span class="koboSpan" id="kobo.1.{i}">{paragraph(rng, 1)}</span>' for i in range(1, 40))
    kepub_body = f'''<div id="book-columns" style="column-count:2;width:600px;height:800px"><div id="book-inner">
<h1>Kobo chapter</h1><p>{spans}</p></div></div>'''
    made.append(simple("kobo.kepub.epub", "KEPUB Book", [("k1.xhtml", xhtml("Kobo", kepub_body))]))

    # Plain text, Project Gutenberg style: a header naming the title and
    # author, a contents list, hard-wrapped paragraphs (joined back up by
    # Platen), chapter headings (which become Contents) and a poem (which
    # keeps its line breaks).
    import textwrap
    chapters = []
    for n, name in enumerate(["The River", "The Bridge", "The Town"], start=1):
        paras = "\n\n".join(textwrap.fill(paragraph(rng, 7), 70) for _ in range(6))
        chapters.append(f"CHAPTER {'I' * n}.\n{name}\n\n{paras}")
    poem = "    The woods are dark and deep,\n    And I have far to go,\n    And miles before I sleep."
    gutenberg = ("The Project Gutenberg eBook of A Plain Tale\n\n"
                 "Title: A Plain Tale\n\nAuthor: Tex T. Fyle\n\nLanguage: English\n\n"
                 "*** START OF THE PROJECT GUTENBERG EBOOK A PLAIN TALE ***\n\n\n"
                 "CONTENTS\n\n CHAPTER I.   The River\n CHAPTER II.  The Bridge\n CHAPTER III. The Town\n\n\n"
                 + "\n\n\n".join(chapters[:1]) + "\n\n" + poem + "\n\n\n" + "\n\n\n".join(chapters[1:]) + "\n")
    p = os.path.join(OUT, "gutenberg.txt")
    open(p, "w", newline="\r\n").write(gutenberg)  # Windows line endings, as Gutenberg ships
    made.append(p)

    # Plain text in Windows-1252, not UTF-8 (older files often are).
    p = os.path.join(OUT, "windows-1252.txt")
    open(p, "wb").write(("Café notes\n\n" + textwrap.fill(paragraph(rng, 5), 70) + "\n\n\u201cQuoted,\u201d she said.\n").encode("cp1252"))
    made.append(p)

    # A short story as older text files come (device testing, 21 Nov 2026):
    # Windows line endings and encoding, a title page of short lines
    # ("THE HILL", "by", the author), one long line per paragraph, and a
    # surname-first "Author - Title" file name. It opens titled "The Hill",
    # by "R.J. Van Writer", with a centred title page.
    p = os.path.join(OUT, "Writer, R J Van - The Hill.txt")
    story = "THE HILL\r\n\r\n\r\n\r\nby\r\n\r\n\r\n\r\nR.J. Van Writer\r\n\r\n\r\n\r\n\r\n"
    story += "\r\n\r\n".join(paragraph(rng, 6).replace("\n", " ") for _ in range(6)) + "\r\n\r\n\u2018Help Wanted!' it says. A fa\u00e7ade.\r\n"
    open(p, "wb").write(story.encode("cp1252"))
    made.append(p)

    # A PDF with an outline (Contents) and a document ID (spec, "PDF").
    p = os.path.join(OUT, "outline.pdf")
    simple_pdf(p, "Sample Report", ["Introduction", "Methods", "Results"])
    made.append(p)

    # Body text set smaller by the book's CSS (body at 75%): it must still
    # come out at the text size chosen (bookfixes.js, normaliseBodyTextSize).
    rng2 = random.Random(7)
    small = xhtml("Small print", "<h1>Small print</h1>" + "".join(f"<p>{paragraph(rng2)}</p>" for _ in range(8)),
                  extra_head="<style>body { font-size: 75%; } h1 { font-size: 1.6em; }</style>")
    made.append(simple("small-body-text.epub", "Small Body Text", [("ch1.xhtml", small)]))

    # A PDF with pictures (long press: save and share) and a landscape last
    # page (One Page layout).
    p = os.path.join(OUT, "pictures.pdf")
    simple_pdf(p, "Picture Book", ["Plates", "Panorama"], pictures=True,
               doc_id="5E884898DA28047151D0E56F8DC62927")
    made.append(p)

    # A picture book with square pages: Two Pages shows two side by side in
    # landscape (they were taken for spreads, and shown one at a time).
    # MOBI and AZW3 with a picture (foliate's mobi.js; VENDORED.md, 23 Nov
    # 2026). The picture must draw: MOBI pictures had no type (WebKit would
    # not draw them); AZW3 pictures had none either (a typo), and carried
    # the EPUB's srcset, whose files a KF8 book does not have, so a Retina
    # screen fetched those instead.
    plate = png(120, 80, (180, 60, 40))
    words = " ".join(["The lighthouse keeper climbed the stairs at dusk."] * 4)
    html = ('<html><head><title>Lamp</title></head><body>'
            '<h1>Chapter One</h1><p><img recindex="00001" alt="A plate"/></p>'
            f'<p>{words}</p><mbp:pagebreak/><h1>Chapter Two</h1><p>{words}</p></body></html>').encode()
    p = os.path.join(OUT, "mobi-picture.mobi")
    mobi6(p, "The Lamp Room", "Mo Bee", html, [plate])
    made.append(p)
    skeleton = ('<?xml version="1.0" encoding="utf-8"?>'
                '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Harbour</title></head>'
                '<body aid="0"></body></html>').encode()
    fragment = ('<div aid="1"><h1>The Harbour</h1>'
                '<p><img src="kindle:embed:0001?mime=image/png" '
                'srcset="../images/harbour-2x.png 2x, ../images/harbour.png 1x" alt="A harbour"/></p>'
                f'<p>{words}</p></div>').encode()
    p = os.path.join(OUT, "azw3-picture.azw3")
    azw3(p, "The Harbour Wall", "Kay Eff", skeleton, fragment, [plate])
    made.append(p)

    # A PDF laid out as a printed book: a running header, "Page N" footers,
    # a word hyphenated across lines and a sentence running onto the next
    # page (read aloud leaves out the header and footers, joins the rest).
    p = os.path.join(OUT, "running-heads.pdf")
    filler = ["The banks are green in spring and brown in autumn.", "Birds nest in the reeds along the shore.",
              "Boats carry goods from the hills to the towns.", "Children swim in the shallows in summer."]
    text_pdf(p, "River Studies", [
        ("RIVER STUDIES", ["Rivers begin as rain falling on high ground. The water gathers in small",
                           "streams that join and grow. Each stream finds its own path down the hill-",
                           "side, and the river ran on and"], "Page 1"),
        ("RIVER STUDIES", ["on until it met the sea at last. A second sentence follows here."] + filler, "Page 2"),
        ("RIVER STUDIES", filler, "Page 3"),
        ("RIVER STUDIES", filler + ["The end of the study comes here."], "Page 4"),
    ])
    made.append(p)

    p = os.path.join(OUT, "square-pages.pdf")
    simple_pdf(p, "Square Book", ["Bears", "Hats"], doc_id="2C26B46B68FFC68FF99B453C1D304134", square=True)
    made.append(p)

    # Footnotes: a marked footnote (epub:type="noteref" to an aside in the
    # same chapter) and an unmarked endnote (a superscript link into a notes
    # file). Both should open in a pop-up rather than jumping.
    ch = xhtml("Notes chapter",
               '<h1>Notes chapter</h1>'
               '<p>A claim that needs a source.<a epub:type="noteref" href="#n1" id="r1">1</a> '
               'And a second one.<sup><a href="notes.xhtml#e1" id="r2">2</a></sup></p>'
               '<aside epub:type="footnote" id="n1"><p>The footnote text. <a href="#r1">↩</a></p></aside>')
    notes = xhtml("Notes", '<h1>Notes</h1><p id="e1">The endnote text.</p>')
    made.append(simple("footnotes.epub", "Footnotes", [("ch1.xhtml", ch), ("notes.xhtml", notes)]))

    # A cover the EPUB 2 way: <meta name="cover"> naming a cover page whose
    # picture the folder view shows (PlatenCore's BookCover). The cover page
    # is first in the spine, as in most real books.
    cover_page = xhtml("Cover", '<div><img src="images/cover.png" alt="Cover"/></div>')
    made.append(simple("cover-page.epub", "The Painted Cover",
                       [("cover.xhtml", cover_page),
                        ("ch1.xhtml", xhtml("One", "<h1>One</h1><p>The book behind the cover.</p>"))],
                       version="2.0", extra_meta='<meta name="cover" content="c1"/>',
                       manifest_extra=['<item id="pic" href="images/cover.png" media-type="image/png"/>'],
                       extra_files=[("OEBPS/images/cover.png", png(400, 600, (176, 64, 48)))]))

    # A picture book shaped like a real one (device testing, 21 Nov 2026):
    # square, brightly coloured pages, each a picture alone, so on a tall
    # phone there is room above and below each; and a contents page styled
    # as Calibre often leaves it, the colour on a span inside each link, dark
    # blue (unreadable on the Dark theme until made lighter). The iOS
    # matrix (scripts/ios-matrix.py) checks that the room round a picture
    # glows with ambient light, and that the bands blend with the glow.
    plate = lambda pic: xhtml("Plate", f'<div class="plate"><img src="images/{pic}.png" alt="A plate"/></div>')
    contents = xhtml("Contents", """<h1 class="calibre3">Contents</h1>
<p class="calibre5"><a href="p1.xhtml"><span class="calibre6">The orange plate</span></a></p>
<p class="calibre5"><a href="p2.xhtml"><span class="calibre6">The blue plate</span></a></p>""",
        extra_head='<style>.calibre6 { color: #103870; font-style: italic } .calibre5 { margin: 0.5em 0 }</style>')
    made.append(simple("picture-book.epub", "The Square Picture Book",
                       [("p1.xhtml", plate("orange")), ("contents.xhtml", contents), ("p2.xhtml", plate("blue")),
                        ("end.xhtml", xhtml("The End", "<h1>The End</h1><p>Goodnight.</p>"))],
                       manifest_extra=['<item id="orange" href="images/orange.png" media-type="image/png"/>',
                                       '<item id="blue" href="images/blue.png" media-type="image/png"/>'],
                       extra_files=[("OEBPS/images/orange.png", png(600, 600, (238, 120, 40))),
                                    ("OEBPS/images/blue.png", png(600, 600, (40, 110, 220)))]))

    # A full-page plate partway through a chapter: text, then a page that
    # is one picture and nothing else, then more text. On iOS that page
    # shows the picture natively, as large as the screen allows, just like
    # a chapter that is one picture.
    words = " ".join(["The ship drifted on through the long grey afternoon."] * 6)
    text = "".join(f"<p>{words}</p>" for _ in range(3))
    # Short enough to fit on one iPhone page at any line spacing, so the
    # next page is the plate.
    opening = "<p>" + " ".join(["The ship drifted on through the long grey afternoon."] * 3) + "</p>"
    plate = xhtml("Plates",
                  f'<h1>Plates</h1>{opening}'
                  '<div style="break-before: column"><img src="images/plate.png" alt="A plate"/></div>'
                  # WebKit's columns ignore break-after, so the text after
                  # the plate starts its own page the way books do it: a
                  # heading that breaks before itself.
                  f'<h2 style="break-before: column">Afterwards</h2>{text}')
    made.append(simple("plate-page.epub", "The Plate Between",
                       [("ch1.xhtml", plate)],
                       manifest_extra=['<item id="pic" href="images/plate.png" media-type="image/png"/>'],
                       extra_files=[("OEBPS/images/plate.png", png(600, 800, (40, 96, 160)))]))

    # Read aloud: a book in French (dc:language fr) is read with Apple's
    # French voice, never offered the English natural voice.
    french = ("<h1>Le premier chapitre</h1>"
              "<p>Il était une fois une petite ville au bord de la mer. Les maisons étaient blanches et les "
              "volets étaient bleus. Chaque matin, les pêcheurs partaient avant le lever du soleil.</p>"
              "<p>Le soir, ils revenaient avec des paniers pleins de poissons. Les enfants couraient sur la "
              "plage pour les accueillir.</p>")
    made.append(simple("french.epub", "La Petite Ville", [("ch1.xhtml", xhtml("Chapitre 1", french, lang="fr"))],
                       lang="fr"))

    # Read aloud: an English book with a passage marked as French. The book's
    # language (English) chooses the voice; the passage's own language is
    # reported with its block.
    mixed = ("<h1>A Letter from Paris</h1>"
             "<p xml:lang=\"fr\" lang=\"fr\">Ma chère amie, je t'écris de Paris où il pleut depuis trois jours.</p>"
             "<p>She folded the letter and put it back in its envelope. Then she went down to the harbour.</p>")
    made.append(simple("mixed-language.epub", "A Letter from Paris",
                       [("ch1.xhtml", xhtml("Chapter 1", mixed))]))

    # Read aloud: paragraphs hard-wrapped in the source, as pandoc writes
    # them (a line break every 72 characters or so, mid-sentence). The
    # breaks are spaces to a reader, and read aloud must take whole
    # sentences, not one per line (it paused at every line's end).
    wrapped = ("<h1>The Train</h1>\n"
               "<p>There was the sound of an inter-train door opening, and then\n"
               "footsteps and an odd slithering sound coming down the hallway of the\n"
               "train. She looked up from her book.</p>\n"
               "<p>Nobody came\nin. Mr. Potter and Prof. J. K. Rowling sat by St. Mungo.</p>")
    made.append(simple("hard-wrapped.epub", "The Train", [("ch1.xhtml", xhtml("Chapter 1", wrapped))]))

    for m in made:
        print(f"{os.path.getsize(m):>10,}  {os.path.relpath(m, ROOT)}")


if __name__ == "__main__":
    main()
