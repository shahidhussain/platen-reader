#!/usr/bin/env python3
"""Generates the synthetic part of Platen's robustness corpus.

Writes EPUB files into Fixtures/generated/ (git-ignored). Each one exercises a
case from the spec's "Format support and robustness" table. Real-world books
(Standard Ebooks, Gutenberg, the W3C EPUB 3 test suite) belong in
Fixtures/corpus/ when they may be redistributed, or Fixtures/local/ otherwise.

Usage: scripts/make-fixtures.py
"""
import hashlib
import os
import random
import uuid
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

    for m in made:
        print(f"{os.path.getsize(m):>10,}  {os.path.relpath(m, ROOT)}")


if __name__ == "__main__":
    main()
