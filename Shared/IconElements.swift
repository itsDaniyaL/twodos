import SwiftUI

// MARK: - The mark

/// The twodos mark: **two** ticks against **two** rules, redrawn as vectors from
/// `AppIcon.icon`.
///
/// This is the app's actual identity, so it is drawn rather than approximated
/// with an SF Symbol. `checklist` — the symbol used before — is one tick, one
/// empty circle and three rules, which quietly says something different from the
/// name of the app.
///
/// Because it is a `Shape`-based drawing it stays crisp at any size, animates,
/// and inherits the current foreground style, so it works equally on a 40-point
/// empty state and a 120-point onboarding hero.
struct TwodosMark: View {
    /// 0 → nothing drawn, 1 → both rows complete. Animate this to draw the mark
    /// on, which is what the onboarding hero does.
    var progress: Double = 1
    /// Tick colour. Defaults to the current foreground style.
    var tickStyle: AnyShapeStyle?
    /// Rule colour. Defaults to a dimmed version of the tick.
    var ruleStyle: AnyShapeStyle?

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let rowHeight = side * 0.32
            let gap = side * 0.16

            VStack(spacing: gap) {
                row(index: 0, side: side, height: rowHeight)
                row(index: 1, side: side, height: rowHeight)
            }
            .frame(width: side, height: side, alignment: .center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    /// Each row draws its tick slightly ahead of its rule, and the second row
    /// trails the first, so an animated draw-on reads left-to-right, top-to-bottom.
    private func row(index: Int, side: CGFloat, height: CGFloat) -> some View {
        let stagger = Double(index) * 0.35
        let tickProgress = clamp((progress - stagger) / 0.4)
        let ruleProgress = clamp((progress - stagger - 0.2) / 0.4)

        return HStack(spacing: side * 0.1) {
            Tick()
                .trim(from: 0, to: tickProgress)
                .stroke(
                    tickStyle ?? AnyShapeStyle(.foreground),
                    style: StrokeStyle(lineWidth: height * 0.42, lineCap: .butt, lineJoin: .miter)
                )
                .frame(width: side * 0.42, height: height)

            Capsule(style: .continuous)
                .fill(ruleStyle ?? tickStyle ?? AnyShapeStyle(.foreground))
                .frame(width: side * 0.42 * ruleProgress, height: height * 0.42)
                .frame(width: side * 0.42, alignment: .leading)
        }
    }

    private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }

    /// The tick itself: a stroked V, matching the icon's hard mitred corner
    /// rather than the rounded stroke SF Symbols would give.
    private struct Tick: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.34, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            return path
        }
    }
}

// MARK: - Landscape elements

/// The soft hill from the bottom of the app icon.
///
/// A single smooth wave — high on the left, dipping through the middle, rising
/// again on the right — matched to the icon's silhouette.
struct HillShape: Shape {
    /// Shifts the wave horizontally so several hills can be layered without
    /// looking like copies of each other.
    var phase: CGFloat = 0

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: h * 0.28))
        path.addCurve(
            to: CGPoint(x: w * 0.46, y: h * 0.72),
            control1: CGPoint(x: w * (0.18 + phase * 0.04), y: h * 0.02),
            control2: CGPoint(x: w * 0.30, y: h * 0.74)
        )
        path.addCurve(
            to: CGPoint(x: w * 0.86, y: h * 0.40),
            control1: CGPoint(x: w * 0.64, y: h * 0.70),
            control2: CGPoint(x: w * (0.70 + phase * 0.05), y: h * 0.34)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: h * 0.62),
            control1: CGPoint(x: w * 0.95, y: h * 0.44),
            control2: CGPoint(x: w * 0.99, y: h * 0.55)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// One of the icon's peach clouds: a capsule that runs off the edge of the
/// canvas, so only its rounded end is visible.
struct CloudBar: View {
    enum Edge { case leading, trailing }

    var edge: Edge
    var width: CGFloat
    var height: CGFloat
    var opacity: Double = 1

    var body: some View {
        Capsule(style: .circular)
            .fill(Brand.apricotFill.opacity(opacity))
            .frame(width: width, height: height)
            // Pushed halfway off-screen so the flat end is clipped away and
            // only the rounded cap shows, exactly as in the icon.
            .offset(x: edge == .leading ? -width / 2 : width / 2)
            .frame(maxWidth: .infinity, alignment: edge == .leading ? .leading : .trailing)
            .accessibilityHidden(true)
    }
}

/// The icon's whole scene — clouds and hill — as a backdrop.
///
/// Used behind the onboarding hero and the signed-out screen so the app opens
/// into the picture the user just tapped on their Home Screen. It is decorative
/// only: nothing here carries meaning, and it sits at low contrast so text over
/// it always wins.
struct IconLandscape: View {
    /// Drives a slow drift on the clouds and a gentle rise on the hill.
    var animate: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack(alignment: .top) {
                // Sky: two clouds near the top, each anchored to an opposite
                // edge so they read as one horizon rather than scattered blobs.
                VStack(alignment: .leading, spacing: h * 0.035) {
                    CloudBar(edge: .leading, width: w * 0.46, height: h * 0.030, opacity: 0.9)
                        .offset(x: isDrifting ? w * 0.025 : 0)
                    CloudBar(edge: .trailing, width: w * 0.32, height: h * 0.024, opacity: 0.6)
                        .offset(x: isDrifting ? -w * 0.03 : 0)
                }
                .padding(.top, h * 0.11)

                // Ground: two hills pinned to the bottom, the back one paler.
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ZStack(alignment: .bottom) {
                        HillShape(phase: 0.6)
                            .fill(Brand.meadowSoft.opacity(0.45))
                            .frame(height: h * 0.20)
                            .offset(y: isDrifting ? -h * 0.008 : 0)

                        HillShape()
                            .fill(
                                LinearGradient(
                                    colors: [Brand.meadowDeep, Brand.meadowSoft],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .frame(height: h * 0.15)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard animate, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 11).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
    }

    private var isDrifting: Bool { drift && animate && !reduceMotion }
}

// MARK: - Composed hero

/// The mark, drawing itself on, over a soft halo.
///
/// It deliberately carries **no** landscape of its own: the screen behind it
/// already supplies the clouds and hill, and two overlapping scenes read as
/// clutter rather than depth.
struct TwodosHero: View {
    var size: CGFloat = 120
    /// Set false to render the finished state immediately, e.g. in a preview.
    var animatesIn: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawProgress: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Brand.meadowSoft.opacity(0.28), .clear],
                        center: .center, startRadius: 0, endRadius: size * 0.62
                    )
                )
                .frame(width: size * 1.25, height: size * 1.25)
                .blur(radius: 8)

            TwodosMark(
                progress: drawProgress,
                tickStyle: AnyShapeStyle(Brand.ink),
                ruleStyle: AnyShapeStyle(Brand.ink.opacity(0.4))
            )
            .frame(width: size * 0.72, height: size * 0.72)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard animatesIn, !reduceMotion else {
                drawProgress = 1
                return
            }
            withAnimation(.easeOut(duration: 1.0).delay(0.15)) { drawProgress = 1 }
        }
        .accessibilityElement()
        .accessibilityLabel("twodos")
    }
}
