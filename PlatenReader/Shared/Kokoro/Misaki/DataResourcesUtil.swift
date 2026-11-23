// Vendored from MisakiSwift (https://github.com/mlalma/MisakiSwift, Apache-2.0,
// at b7477b15fc46cf8e20b32c008126611b38ec6b79), a Swift port of hexgrad/misaki
// (Apache-2.0). See LICENSE in this folder and docs/read-aloud.md. Platen's
// changes: no MLX (the neural fallback for unknown words is replaced by
// `KokoroFallback`), the lexicons are read from the voice pack's folder, and
// the types are internal to the app.
import Foundation

final class DataResourcesUtil {
    private init() {}

    static func loadGold(british: Bool, directory: URL) -> [String: Any] {
        load(british ? "gb_gold" : "us_gold", in: directory)
    }

    static func loadSilver(british: Bool, directory: URL) -> [String: Any] {
        load(british ? "gb_silver" : "us_silver", in: directory)
    }

    private static func load(_ name: String, in directory: URL) -> [String: Any] {
        let url = directory.appendingPathComponent(name + ".json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }
}

/// MLXUtilsLibrary's debug print, which the vendored code calls.
@inline(__always) func logPrint(_ s: String) {
    #if DEBUG
    print(s)
    #endif
}
