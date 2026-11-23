// Vendored from MisakiSwift (https://github.com/mlalma/MisakiSwift, Apache-2.0,
// at b7477b15fc46cf8e20b32c008126611b38ec6b79), a Swift port of hexgrad/misaki
// (Apache-2.0). See LICENSE in this folder and docs/read-aloud.md. Platen's
// changes: no MLX (the neural fallback for unknown words is replaced by
// `KokoroFallback`), the lexicons are read from the voice pack's folder, and
// the types are internal to the app.
import Foundation

extension Range where Bound: Comparable {
    func contains(_ other: Range<Bound>) -> Bool {
        return self.lowerBound <= other.lowerBound && self.upperBound >= other.upperBound
    }
}
