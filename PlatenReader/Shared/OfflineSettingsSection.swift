import SwiftUI

/// Settings › Offline, in both apps (iOS's settings sheet, the Mac's
/// Settings › Advanced): Keep Favourites on This Device, or This Mac
/// (OfflineCopies), on unless turned off, with what the copies take up.
struct OfflineSettingsSection: View {
    @ObservedObject private var offline = OfflineCopies.shared
    @ObservedObject private var favourites = RecentList.favorites

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { offline.isEnabled }, set: { offline.isEnabled = $0 })) {
                #if os(macOS)
                Text("Keep Favourites on This Mac")
                #else
                Text("Keep Favourites on This Device")
                #endif
                Text("Favourites in iCloud Drive, on a network share or a drive are copied here, so they can be read offline or away from the share. Removing a book from Favourites deletes its copy.")
            }
        } header: {
            Text("Offline")
        } footer: {
            if offline.isEnabled, !offline.copied.isEmpty {
                let size = ByteCountFormatter.string(fromByteCount: offline.bytes, countStyle: .file)
                #if os(macOS)
                Text("Favourites kept on this Mac: \(offline.copied.count) (\(size)).")
                #else
                Text("Favourites kept on this device: \(offline.copied.count) (\(size)).")
                #endif
            }
        }
    }
}
