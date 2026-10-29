import SwiftUI

enum ComposerStyle {
    static let accent = Color(red: 1, green: 0.86, blue: 0.04)
    static let motion = Animation.easeInOut(duration: 0.18)
}

struct ComposerSwitchStyle: ToggleStyle {
    var title = "Effect"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule().fill(configuration.isOn ? ComposerStyle.accent : Color(white: 0.25))
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(configuration.isOn ? .black : .white).padding(1).frame(width: 16, height: 16)
                }
                .frame(width: 28, height: 16)
                .animation(reduceMotion ? nil : ComposerStyle.motion, value: configuration.isOn)
        }.buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
            .accessibilityAddTraits(.isToggle)
    }
}

/// Matches the thin track and ring thumb used by the observed Composer controls.
/// Keyboard/accessibility adjustments use the same binding as pointer dragging.
struct ComposerSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var colors: [Color] = []
    var gradientStops: [Gradient.Stop]? = nil
    var center: Double? = nil
    var automatic = false
    var label = "Adjustment"
    @Environment(\.isEnabled) private var enabled
    private var fraction: Double { min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound))) }
    private func trackStart(width: CGFloat) -> CGFloat {
        guard let midpoint = center else { return 0 }
        return 6 + width * CGFloat(min(1, max(0, (midpoint - range.lowerBound) / (range.upperBound - range.lowerBound))))
    }
    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 12)
            let x = 6 + width * fraction
            ZStack(alignment: .leading) {
                Rectangle().fill(Color(white: 0.22)).frame(height: 2)
                if let gradientStops {
                    Rectangle().fill(LinearGradient(stops: gradientStops, startPoint: .leading, endPoint: .trailing)).frame(height: 2)
                } else if !colors.isEmpty {
                    Rectangle().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)).frame(height: 2)
                } else if !automatic {
                    let start: CGFloat = trackStart(width: width)
                    Rectangle().fill(Color(white: 0.7)).frame(width: max(0, abs(x - start)), height: 2).offset(x: min(x, start))
                }
                Circle().fill(automatic ? ComposerStyle.accent : Color(white: 0.72)).frame(width: 12, height: 12)
                    .overlay(Circle().fill(Color(white: 0.22)).frame(width: 4, height: 4)).offset(x: x - 6)
            }.frame(height: 12).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    guard enabled else { return }
                    value = range.lowerBound + min(1, max(0, (drag.location.x - 6) / width)) * (range.upperBound - range.lowerBound)
                })
        }.frame(height: 12).opacity(enabled ? 1 : 0.35)
            .accessibilityElement().accessibilityLabel(label).accessibilityValue(String(format: "%.2f", value))
            .accessibilityAdjustableAction { direction in
                guard enabled else { return }
                let step = (range.upperBound - range.lowerBound) / 100
                if direction == .increment { value = min(range.upperBound, value + step) }
                if direction == .decrement { value = max(range.lowerBound, value - step) }
            }
    }
}

struct ComposerCameraIcon: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color(white: 0.7)).frame(width: 32, height: 17)
            Circle().fill(.black).frame(width: 13, height: 13)
                .overlay(Circle().stroke(Color(white: 0.3), lineWidth: 2).frame(width: 7, height: 7)).offset(x: 1, y: 1)
            VStack(spacing: 2) {
                ForEach(0..<4) { _ in HStack(spacing: 2) { ForEach(0..<4) { _ in Circle().fill(Color(white: 0.12)).frame(width: 1.5, height: 1.5) } } }
            }.offset(x: 17, y: 2)
            Rectangle().fill(Color(white: 0.5)).frame(width: 18, height: 3).offset(y: 17)
        }.frame(width: 32, height: 20).accessibilityHidden(true)
    }
}

struct ComposerSectionIcon: View {
    let title: String
    let fallback: String
    var body: some View {
        Group {
            if title == "Lighting" {
                ZStack {
                    RoundedRectangle(cornerRadius: 2).fill(.foreground.opacity(0.5))
                    Path { path in
                        path.move(to: CGPoint(x: 3, y: 14))
                        path.addCurve(to: CGPoint(x: 14, y: 3), control1: CGPoint(x: 11, y: 14), control2: CGPoint(x: 6, y: 3))
                    }.stroke(.foreground, lineWidth: 1.5)
                }
            } else if title == "Color" {
                ZStack {
                    Circle().fill(.foreground.opacity(0.5)).frame(width: 8, height: 8).offset(y: -4)
                    Circle().fill(.foreground.opacity(0.5)).frame(width: 8, height: 8).offset(x: -4, y: 4)
                    Circle().fill(.foreground).frame(width: 8, height: 8).offset(x: 4, y: 4)
                }
            } else if title == "Effects" {
                ZStack(alignment: .topLeading) {
                    ComposerSparkle().fill(.foreground).frame(width: 12, height: 13).offset(y: 3)
                    ComposerSparkle().fill(.foreground.opacity(0.6)).frame(width: 6, height: 7).offset(x: 10)
                }
            } else { Image(systemName: fallback).font(.system(size: 17)) }
        }.frame(width: 16, height: 16).accessibilityHidden(true)
    }
}

struct ComposerSidebarIcon: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 2.5).stroke(lineWidth: 1.5)
            .overlay(alignment: .trailing) { RoundedRectangle(cornerRadius: 0.8).fill(.foreground).frame(width: 2.5, height: 11).padding(.trailing, 2.5) }
            .frame(width: 18, height: 14).padding(1).accessibilityHidden(true)
    }
}

struct ComposerFocusIcon: View {
    var body: some View {
        Image(systemName: "viewfinder").font(.system(size: 12))
            .overlay { Circle().fill(.foreground).frame(width: 3, height: 3) }.accessibilityHidden(true)
    }
}

struct ComposerInfinityIcon: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                path.move(to: CGPoint(x: 0.5, y: 0.5))
                path.addCurve(to: CGPoint(x: 0.08, y: 0.5), control1: CGPoint(x: 0.22, y: -0.12), control2: CGPoint(x: 0.08, y: 0.12))
                path.addCurve(to: CGPoint(x: 0.5, y: 0.5), control1: CGPoint(x: 0.08, y: 0.88), control2: CGPoint(x: 0.22, y: 1.12))
                path.addCurve(to: CGPoint(x: 0.92, y: 0.5), control1: CGPoint(x: 0.78, y: -0.12), control2: CGPoint(x: 0.92, y: 0.12))
                path.addCurve(to: CGPoint(x: 0.5, y: 0.5), control1: CGPoint(x: 0.92, y: 0.88), control2: CGPoint(x: 0.78, y: 1.12))
            }.transform(CGAffineTransform(scaleX: geometry.size.width, y: geometry.size.height))
                .stroke(style: StrokeStyle(lineWidth: geometry.size.height * 0.2, lineCap: .round, lineJoin: .round))
        }.accessibilityHidden(true)
    }
}

private struct ComposerSparkle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.midY))
            p.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.midY))
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.midY))
            p.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.midY))
        }
    }
}
