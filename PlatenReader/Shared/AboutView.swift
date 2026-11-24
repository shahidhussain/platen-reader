import SwiftUI

/// What the About screen says about this copy of the app, worked out once:
/// its version and build, and the text "Copy Version Info" puts on the
/// clipboard for a bug report.
enum AboutInfo {
    private static var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    /// "0.8.51".
    static var version: String { info["CFBundleShortVersionString"] as? String ?? "?" }
    /// The build number ("1"; release builds number their builds).
    static var build: String { info["CFBundleVersion"] as? String ?? "?" }
    /// The git commit the build was made from, where the build recorded it
    /// (the iOS target's "Record Git Commit" phase).
    static var commit: String? {
        guard let commit = info["PlatenCommit"] as? String, !commit.isEmpty else { return nil }
        return commit
    }

    /// "Version 0.8.51 (1)", the Mac's usual form for a version and build.
    static var versionLine: String {
        String(localized: "Version \(version) (\(build))",
               comment: "About: the app's version, then its build number in brackets, such as “Version 0.8.51 (1)”.")
    }

    /// The system's name and version: "macOS 26.6.2 (25G83)", "iOS 27.2.1 (25C101)".
    static var system: String {
        #if os(macOS)
        let name = "macOS"
        #else
        let name = "iOS"
        #endif
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var line = "\(name) \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        // The system's build; not in the Simulator, where the kernel's is
        // the Mac's.
        if ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] == nil, let build = osBuild {
            line += " (\(build))"
        }
        return line
    }

    /// The system's build ("25G83"), from the kernel.
    private static var osBuild: String? {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &value, &size, nil, 0) == 0 else { return nil }
        return String(cString: value)
    }

    /// What "Copy Version Info" copies, laid out to paste into a bug report:
    ///
    ///     Platen Reader 0.8.51 (build 1, commit 3f2a9c1)
    ///     macOS 26.6.2 (25G83)
    ///     Mac15,6
    ///
    /// Not localised: it is for the developer reading the report.
    static var versionInfo: String {
        var app = "Platen Reader \(version) (build \(build)"
        if let commit { app += ", commit \(commit)" }
        app += ")"
        return [app, system, DiagnosticLog.modelCode].joined(separator: "\n")
    }
}

/// The About screen, shared by the Mac's About window (AboutWindowController)
/// and iOS's Settings › About: the app icon, name and version; who made it;
/// copyright and licence; what Platen does with your data; the credit for
/// read aloud's natural voice; links to the source and to report an issue;
/// and two buttons, Copy Version Info and Acknowledgements.
///
/// Each app passes in what is its own: the icon, how to put text on the
/// clipboard, and how to show the acknowledgements (a window on the Mac, the
/// next page of the navigation stack on iOS).
struct AboutView: View {
    /// The app's icon, as each platform has it.
    let icon: Image
    /// Puts text on the system clipboard.
    let copyToClipboard: (String) -> Void
    /// Shows the acknowledgements (the Mac; iOS uses a navigation link).
    var showAcknowledgements: (() -> Void)?

    /// True for two seconds after Copy Version Info, to say it worked.
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.bottom, 16)
            VStack(spacing: 10) {
                credits
                Divider().padding(.horizontal, 40).padding(.vertical, 4)
                promises
                links
                    .padding(.top, 4)
            }
            buttons
                .padding(.top, 20)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
    }

    // MARK: - The parts, top to bottom

    /// Icon, name, version and build.
    private var header: some View {
        VStack(spacing: 6) {
            icon
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                #if os(iOS)
                // iOS icons are square; the system rounds them on the Home
                // Screen, so this does too.
                .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                #endif
                .accessibilityHidden(true)
            Text("Platen Reader")
                .font(.title2.weight(.semibold))
            Text(verbatim: AboutInfo.versionLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    /// Who made it, copyright and licence.
    private var credits: some View {
        VStack(spacing: 4) {
            // "Made by Shahid Hussain", the name linking to the website.
            Self.text(String(localized: "Made by Shahid Hussain"), linking: "Shahid Hussain", to: AppLinks.author)
            Text(verbatim: "© 2026 Shahid Hussain")
                .foregroundStyle(.secondary)
            // The licence's name links to the LICENSE file in the repository.
            Self.text(String(localized: "Released under the Mozilla Public License 2.0"),
                      linking: "Mozilla Public License 2.0", to: AppLinks.licence)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .tint(.platenAccent)
    }

    /// What Platen does with your data, and where read aloud's voice comes
    /// from. The privacy line is worded to stay true with the app's one
    /// network request: the natural voice's download, made only when the
    /// reader asks, which sends nothing about them (docs/read-aloud.md).
    private var promises: some View {
        VStack(spacing: 8) {
            Text("Platen doesn’t collect any data or track you. Nothing you read leaves your device unless you share it yourself.")
            Text("Read Aloud’s natural voice is powered by Kokoro, an open-weight text-to-speech model created by hexgrad and released under the Apache 2.0 licence. All speech is generated on your device.")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8)
    }

    /// Source code and Report an Issue, side by side.
    private var links: some View {
        HStack(spacing: 18) {
            Link(destination: AppLinks.repository) { Text("Source Code") }
            Link(destination: AppLinks.newIssue) { Text("Report an Issue") }
        }
        .font(.callout)
        // The accent, as the links above: on the Mac a Link ignores tint.
        .foregroundStyle(Color.platenAccent)
        .tint(.platenAccent)
    }

    /// `sentence` with the words `part` as a link to `url` (names are not
    /// translated, so `part` is found in any language's sentence; if it is
    /// not, the sentence shows without a link).
    private static func text(_ sentence: String, linking part: String, to url: URL) -> Text {
        var string = AttributedString(sentence)
        if let range = string.range(of: part) { string[range].link = url }
        return Text(string)
    }

    /// Copy Version Info and Acknowledgements: side by side, or one above
    /// the other where they do not fit (a small phone, large text).
    private var buttons: some View {
        ViewThatFits {
            HStack(spacing: 12) { buttonPair }
            VStack(spacing: 10) { buttonPair }
        }
    }

    @ViewBuilder private var buttonPair: some View {
        Group {
            Button {
                copyToClipboard(AboutInfo.versionInfo)
                withAnimation { copied = true }
                // The confirmation goes after two seconds.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { copied = false }
                }
            } label: {
                // The label says it worked, in place, for two seconds. Both
                // labels are always laid out (one hidden), so the button
                // keeps the width of the longer and nothing beside it moves.
                ZStack {
                    Text("Copy Version Info").opacity(copied ? 0 : 1)
                    Text("Copied").opacity(copied ? 1 : 0)
                }
            }
            // VoiceOver reads the label showing, not both.
            .accessibilityLabel(copied ? Text("Copied") : Text("Copy Version Info"))
            .accessibilityHint(Text("Copies the version, system and device, to paste into a bug report."))
            #if os(iOS)
            NavigationLink {
                AcknowledgementsView()
            } label: {
                Label("Acknowledgements", systemImage: "list.bullet.rectangle")
            }
            #else
            Button {
                showAcknowledgements?()
            } label: {
                Label("Acknowledgements", systemImage: "list.bullet.rectangle")
            }
            #endif
        }
        .labelStyle(.titleOnly)
        #if os(iOS)
        .buttonStyle(.bordered)
        #else
        .controlSize(.regular)
        #endif
    }
}
