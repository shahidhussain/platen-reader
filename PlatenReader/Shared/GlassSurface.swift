import SwiftUI

// The surface the overlay's controls sit on (spec, "Overlay"): Liquid Glass
// on iOS 26 and later, the translucent material on older systems. The
// system's glass honours Reduce Transparency and Increase Contrast by itself.
//
// The Mac keeps the material for now: the spec wants glass there too
// (macOS 26 and later), but it has not yet been checked on screen there (the
// debug snapshots draw views offscreen, where glass does not appear).

extension View {
    /// Puts the view on glass (or, on the Mac and before iOS 26, on the
    /// regular material with a hairline edge) in the given shape.
    ///
    /// - Parameter seeThrough: on older systems only, how much of the page
    ///   shows through the material (the Mac bar is slightly see-through
    ///   until the pointer is over it).
    @ViewBuilder
    func overlaySurface<S: InsettableShape>(_ shape: S, seeThrough: Bool = false) -> some View {
        #if os(iOS)
        if #available(iOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            materialSurface(shape, seeThrough: seeThrough)
        }
        #else
        materialSurface(shape, seeThrough: seeThrough)
        #endif
    }

    private func materialSurface<S: InsettableShape>(_ shape: S, seeThrough: Bool) -> some View {
        background { shape.fill(.regularMaterial).opacity(seeThrough ? 0.82 : 1) }
            .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
    }
}
