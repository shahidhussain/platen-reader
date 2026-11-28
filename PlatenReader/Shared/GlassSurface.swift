import SwiftUI

// The surface the overlay's controls sit on (spec, "Overlay"): Liquid Glass
// on iOS 26 and later, the translucent material on older systems. The
// system's glass honours Reduce Transparency and Increase Contrast by itself.
//
// The Mac has glass too on macOS 26 and later (the spec), with the material
// before. The debug snapshots draw views offscreen, where glass does not
// appear, so it is checked by eye on screen.

extension View {
    /// Puts the view on glass (or, on the Mac and before iOS 26, on the
    /// regular material with a hairline edge) in the given shape.
    ///
    /// - Parameter seeThrough: on older systems only, how much of the page
    ///   shows through the material (the Mac bar is slightly see-through
    ///   until the pointer is over it).
    @ViewBuilder
    func overlaySurface<S: InsettableShape>(_ shape: S, seeThrough: Bool = false) -> some View {
        // The glass API exists only in the iOS 26 SDK (Swift 6.2, Xcode 26
        // and later); older toolchains, such as CI's, build the material.
        #if compiler(>=6.2)
        if #available(iOS 26, macOS 26, *), !Self.snapshotting {
            glassEffect(.regular, in: shape)
        } else {
            materialSurface(shape, seeThrough: seeThrough)
        }
        #else
        materialSurface(shape, seeThrough: seeThrough)
        #endif
    }

    /// A bar across the window's whole width (the Mac's title bar while the
    /// controls are up): glass on macOS 26 and later, so the page shows
    /// through it softly; before that (and in debug snapshots), the system's
    /// bar material with a hairline along its bottom edge.
    @ViewBuilder
    func barSurface() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, macOS 26, *), !Self.snapshotting {
            glassEffect(.regular, in: Rectangle())
        } else {
            barMaterial()
        }
        #else
        barMaterial()
        #endif
    }

    private func barMaterial() -> some View {
        background(.bar).overlay(alignment: .bottom) { Divider() }
    }

    /// Debug snapshots (PLATEN_SNAPSHOT_DIR) draw views offscreen, where
    /// glass does not draw (nor, reliably, what is on it): they get the
    /// material, and glass is checked by eye on screen.
    private static var snapshotting: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["PLATEN_SNAPSHOT_DIR"] != nil
        #else
        false
        #endif
    }

    private func materialSurface<S: InsettableShape>(_ shape: S, seeThrough: Bool) -> some View {
        background { shape.fill(.regularMaterial).opacity(seeThrough ? 0.82 : 1) }
            .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
    }
}

extension View {
    /// Groups glass pieces that sit close together, so they blend into each
    /// other as the system's own controls do (iOS 26 and later). Elsewhere
    /// the view is returned unchanged.
    @ViewBuilder
    func glassGroup(spacing: CGFloat) -> some View {
        #if os(iOS) && compiler(>=6.2)
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
        #else
        self
        #endif
    }
}
