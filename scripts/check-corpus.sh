#!/bin/sh
# Opens every book in the robustness corpus in the Debug build and checks
# what actually happened: that it rendered (and, for some, what is on the
# page), or that it failed with the expected message.
#
# Usage: scripts/check-corpus.sh        (after building Debug and running
#                                        scripts/make-fixtures.py)
# Exit status is non-zero if any book fails its check.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
G="$ROOT/Fixtures/generated"
FAILED=0

# The page text of the current section, logged as a step result.
TEXT="platen.view.renderer.getContents()[0].doc.body.innerText"

# check <file> <step or -> <expected log substring> [<substring that must NOT appear>]
check() {
    file=$1; step=$2; expect=$3; forbid=${4:-}
    [ "$step" = "-" ] && step=""
    out=$("$ROOT/scripts/run-debug.sh" "$G/$file" "$step" 2>/dev/null)
    if echo "$out" | grep -aqF -- "$expect" && { [ -z "$forbid" ] || ! echo "$out" | grep -aqF -- "$forbid"; }; then
        echo "PASS  $file"
    else
        echo "FAIL  $file (expected “$expect”${forbid:+, without “$forbid”})"
        echo "$out" | sed 's/^/      /' | tail -5
        FAILED=1
    fi
}

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
# Plain text: title from the header, three chapters in Contents, the book
# serif by default, and the poem's line breaks kept.
check gutenberg.txt           "(d=>'title:'+platen.view.book.metadata.title+' toc:'+platen.view.book.toc.length+' font:'+getComputedStyle(d.body).fontFamily.split(',')[0]+' poem:'+d.querySelectorAll('p.lines').length)(platen.view.renderer.getContents()[0].doc)" "title:A Plain Tale toc:3 font:\"Iowan Old Style\""
check windows-1252.txt        "$TEXT"                                  "Café notes"
check drm-adept.epub          "-"                                      "drm(PlatenCore.DRMScheme.adobeADEPT)"

exit $FAILED
