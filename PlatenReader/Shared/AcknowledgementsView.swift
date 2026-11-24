import SwiftUI

/// The third-party components Platen uses, with their copyright notices and
/// licence texts, as their licences (Apache, MIT, BSD) require.
///
/// Read from Acknowledgements.json, which is bundled in both apps and made,
/// with THIRD_PARTY_LICENSES.md, by scripts/make-acknowledgements.py from
/// Licenses/components.json. To change the list, edit that and run the
/// script; nothing here needs to change.
struct Acknowledgements: Decodable {
    struct Component: Decodable, Identifiable, Hashable {
        let name: String
        let version: String
        let licence: String
        /// The copyright notice (or a line saying who made it).
        let notice: String
        let source: String
        /// "app" (inside the app) or "voice" (in the natural-voice pack).
        let shipped: String
        /// The name of its licence text in `texts`.
        let text: String
        var id: String { name }
    }

    let components: [Component]
    /// Each licence's full text, by name.
    let texts: [String: String]
    /// General notes (no GPL; what is not shipped).
    let notes: [String]

    /// The bundled list, or none if it is missing (a build without it).
    static let bundled: Acknowledgements = {
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? decode(data) else {
            return Acknowledgements(components: [], texts: [:], notes: [])
        }
        return list
    }()

    /// The list from the file's bytes (the tests read the file itself).
    static func decode(_ data: Data) throws -> Acknowledgements {
        try JSONDecoder().decode(Acknowledgements.self, from: data)
    }
}

/// The list of components, each opening its notice and licence. On the Mac
/// a sidebar beside the text (its own window, AcknowledgementsWindow); on
/// iOS a list whose rows open a page each.
struct AcknowledgementsView: View {
    private let list = Acknowledgements.bundled
    #if os(macOS)
    @State private var selection: Acknowledgements.Component?
    #endif

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            List(selection: $selection) {
                rows
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            if let selection {
                AcknowledgementDetail(component: selection, licenceText: list.texts[selection.text] ?? "")
            } else {
                notes
            }
        }
        .onAppear { selection = selection ?? list.components.first }
        #else
        List {
            rows
            Section { notes }
        }
        .navigationTitle(Text("Acknowledgements"))
        #endif
    }

    /// One row per component, in two groups: what is in the app, and what
    /// is in the voice pack.
    @ViewBuilder private var rows: some View {
        Section {
            ForEach(list.components.filter { $0.shipped == "app" }) { row($0) }
        } header: {
            Text("In the App")
        }
        Section {
            ForEach(list.components.filter { $0.shipped == "voice" }) { row($0) }
        } header: {
            Text("In the Natural Voice Download")
        }
    }

    @ViewBuilder private func row(_ component: Acknowledgements.Component) -> some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: component.name)
            Text(verbatim: component.licence).font(.caption).foregroundStyle(.secondary)
        }
        .tag(component)
        #else
        NavigationLink {
            AcknowledgementDetail(component: component, licenceText: list.texts[component.text] ?? "")
        } label: {
            LabeledContent(component.name, value: component.licence)
        }
        #endif
    }

    /// The general notes (no GPL code, what is not shipped).
    private var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(list.notes, id: \.self) { Text(verbatim: $0) }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding()
    }
}

/// One component: what it is, its notice, and its licence in full.
struct AcknowledgementDetail: View {
    let component: Acknowledgements.Component
    let licenceText: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                #if os(macOS)
                // (iOS has the name in the navigation bar.)
                Text(verbatim: component.name)
                    .font(.title2.weight(.semibold))
                #endif
                Text(verbatim: component.version)
                    .foregroundStyle(.secondary)
                if let url = URL(string: component.source) {
                    Link(destination: url) { Text(verbatim: component.source) }
                        .tint(.platenAccent)
                }
                Text(verbatim: component.notice)
                    .padding(.top, 4)
                Divider()
                // The licence exactly as written: on the Mac in a
                // fixed-width font, so its layout survives; on a phone in the
                // usual font, as 80 fixed-width columns wrap badly there.
                Text(verbatim: licenceText)
                    #if os(macOS)
                    .font(.system(.caption, design: .monospaced))
                    #else
                    .font(.footnote)
                    #endif
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        #if os(iOS)
        .navigationTitle(Text(verbatim: component.name))
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
