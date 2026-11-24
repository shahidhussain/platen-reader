# The robustness corpus's checks, shared by scripts/check-corpus.sh (the Mac
# app) and scripts/check-corpus-ios.sh (the iOS app in the Simulator). Each
# script defines `check` and sets NARROW, then reads this file.
#
#   check <file> <step or -> <expected log substring> [<substring that must NOT appear>]
#
# Every fixture in the spec's "Format support and robustness" table needs a
# line here (CLAUDE.md).
#
# The page text of the current section, logged as a step result, on one
# line (the iOS log shows only the first line of a result).
TEXT="platen.view.renderer.getContents()[0].doc.body.innerText.replace(/\\s+/g,' ')"

check novel.epub              "-"                                      "First page visible"
check epub2-ncx.epub          "-"                                      "First page visible"
check no-toc.epub             "-"                                      "First page visible"
check malformed-xhtml.epub    "$TEXT"                                  "the lenient fallback worked"
check case-mismatch.epub      "$TEXT"                                  "Case mismatch"
check unicode-names.epub      "$TEXT"                                  "Café chapter"
check scripted.epub           "'heading: '+platen.view.renderer.getContents()[0].doc.querySelector('h1').textContent" "heading: Scripts are off"
check remote-resource.epub    "String([...platen.view.renderer.getContents()[0].doc.images].map(i=>i.naturalWidth))" "step result: 0"
check obfuscated-font.epub    "(d=>d.fonts.ready.then(()=>0)&&String([...d.fonts].map(f=>f.family.replace(/\"/g,'')+':'+f.status)))(platen.view.renderer.getContents()[0].doc)" "Obf:loaded"
check rtl.epub                "String(platen.view.book.dir)"           "step result: rtl"
check fixed-layout.epub       "String(platen.view.isFixedLayout)"      "step result: true"
check kobo.kepub.epub         "$TEXT"                                  "Kobo chapter"
check truncated.epub          "-"                                      "rebuilt package"
# 12 px text must follow the text size setting, keeping its proportion to
# the root size (12/16 = 0.75), and nothing may be wider than the page.
check fixed-font-sizes.epub   "(d=>'ratio:'+parseFloat(getComputedStyle(d.querySelector('p.px')).fontSize)/parseFloat(getComputedStyle(d.documentElement).fontSize)+' over:'+[...d.body.querySelectorAll('*')].some(e=>[...e.getClientRects()].some(r=>r.width>parseFloat(getComputedStyle(d.documentElement).columnWidth)+1)))(platen.view.renderer.getContents()[0].doc)" "ratio:0.75 over:false"
# Unreadable publisher colours are replaced, whichever theme is in use.
check low-contrast.epub       "'recoloured:'+(platen.view.renderer.getContents()[0].doc.querySelectorAll('[data-platen-colour]').length>0)" "recoloured:true"
# Dark blue links on the Dark theme are lightened, keeping their blue.
check low-contrast.epub       "@theme:dark;'link:'+getComputedStyle(platen.view.renderer.getContents()[0].doc.querySelector('.toc span')).color" "link:rgb(68, 135, 228)"
# Plain text: title from the header, three chapters in Contents, the book
# serif by default, and the poem's line breaks kept.
check gutenberg.txt           "(d=>'title:'+platen.view.book.metadata.title+' toc:'+platen.view.book.toc.length+' font:'+getComputedStyle(d.body).fontFamily.split(',')[0].replace(/\"/g,'')+' poem:'+d.querySelectorAll('p.lines').length)(platen.view.renderer.getContents()[0].doc)" "title:A Plain Tale toc:3 font:Iowan Old Style"
check windows-1252.txt        "$TEXT"                                  "Café notes"
check "Writer, R J Van - The Hill.txt" "(b=>'title:'+b.metadata.title+' by:'+JSON.stringify(b.metadata.author)+' page:'+platen.view.renderer.getContents()[0].doc.querySelectorAll('p.title').length)(platen.view.book)" "title:The Hill by:"
# An EPUB 2 cover page first in the spine (its picture is the folder view's
# cover), shown as a page that is one picture (as large as the page).
check cover-page.epub         "'lone:'+platen.view.renderer.getContents()[0].doc.documentElement.classList.contains('platen-lone-picture')" "lone:true"
# A page partway through a chapter that is one picture and nothing else
# counts as a picture-only page (the page before it, text, does not).
check plate-page.epub         "${NARROW}platen.view.goTo(0);'before:'+platen.pagePicture();platen.next();'plate:'+platen.pagePicture()" "plate:true" "before:true"
# Body text set at 75% by the book still comes out at the size chosen.
check small-body-text.epub    "(d=>'body:'+(Math.abs(parseFloat(getComputedStyle(d.querySelector('p')).fontSize)-platen.fontSize())<0.1))(platen.view.renderer.getContents()[0].doc)" "body:true"
# PDF (PDFKit): its pages and its outline as Contents.
check outline.pdf             "-"                                      "PDF: 6 pages, 3 contents entries"
check pictures.pdf            "-"                                      "PDF: 4 pages, 2 contents entries"
check fixed-layout-wide.epub  "-"                                      "First page visible"
check picture-book.epub       "-"                                      "First page visible"
# MOBI and AZW3 (KF8, here with the srcset Standard Ebooks' files carry):
# the text shows and the picture draws.
PICS="'pics:'+[...platen.view.renderer.getContents()].flatMap(c=>[...c.doc.querySelectorAll('img')]).map(e=>e.naturalWidth>0).join(',')+' text:'+platen.view.renderer.getContents()[0].doc.body.innerText.replace(/\\s+/g,' ').slice(0,40)"
check mobi-picture.mobi        "$PICS"                                  "pics:true text:Chapter One The lighthouse" "pics:false"
check azw3-picture.azw3        "$PICS"                                  "pics:true text:The Harbour The lighthouse" "pics:false"
# Read aloud in a PDF: the running header and the page numbers left out, a
# word hyphenated across lines joined, a sentence across pages read whole.
check running-heads.pdf       "@readAloudPreview:"                     "read aloud: Rivers begin as rain falling on high ground. | The water gathers in small streams that join and grow. | Each stream finds its own path down the hillside, and the river ran on and on until it met the sea at last." "RIVER STUDIES"
check square-pages.pdf        "-"                                      "PDF: 4 pages, 2 contents entries"
# A note reference opens its note in a pop-up (and the page does not move);
# a superscript link into a notes file counts as one too.
NOTE='(d=>(d.querySelector(SEL).click(),"clicked"))(platen.view.renderer.getContents()[0].doc)'
POPUP="'note: '+(document.getElementById('platen-note')||{}).innerText"
check footnotes.epub          "$(echo "$NOTE" | sed 's/SEL/"#r1"/');$POPUP" "note: The footnote text."
check footnotes.epub          "$(echo "$NOTE" | sed 's/SEL/"#r2"/');$POPUP" "note: The endnote text."
check drm-adept.epub          "-"                                      "drm(PlatenCore.DRMScheme.adobeADEPT)"
# Read aloud: the text it would begin with, and the languages that choose
# its voice (the book's own, and a passage's).
check french.epub             "platen.readAloudPreview()"             "book:fr blocks:fr,fr,fr first:Le premier chapitre"
check mixed-language.epub     "platen.readAloudPreview()"             "book:en blocks:en,fr,en first:A Letter from Paris"
# Hard-wrapped paragraphs (pandoc's EPUBs) are read as whole sentences, not
# one sentence per line of the source; titles and initials ("Mr.", "J.") do
# not end a sentence.
check hard-wrapped.epub       "platen.readAloudSentences(5)"          "sentences: The Train | There was the sound of an inter-train door opening, and then footsteps and an odd slithering sound coming down the hallway of the train. | She looked up from her book. | Nobody came in. | Mr. Potter and Prof. J. K. Rowling sat by St. Mungo."
