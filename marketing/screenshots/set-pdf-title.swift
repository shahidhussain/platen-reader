// Sets a PDF's title (the one Platen Reader shows in its top bar), for the
// screenshots' copies of sample books whose own title is a file slug.
// Only ever run on the copy in the simulator; the sample library is not touched.
//
// Usage: swift set-pdf-title.swift <file.pdf> <title>

import PDFKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let document = PDFDocument(url: URL(fileURLWithPath: arguments[1])) else {
    FileHandle.standardError.write("usage: set-pdf-title.swift <file.pdf> <title>\n".data(using: .utf8)!)
    exit(2)
}
var attributes = document.documentAttributes ?? [:]
attributes[PDFDocumentAttribute.titleAttribute] = arguments[2]
document.documentAttributes = attributes
exit(document.write(to: URL(fileURLWithPath: arguments[1])) ? 0 : 1)
