import SwiftUI

// MARK: - Palette (SC from Search+View.tsx)

extension Color {
    static let sewnBG     = Color(red: 250/255, green: 249/255, blue: 246/255)
    static let sewnInk    = Color(red:  45/255, green:  49/255, blue:  66/255)
    static let sewnGold   = Color(red: 174/255, green: 144/255, blue:  96/255)
    static var sewnBorder: Color { Color.sewnGold.opacity(0.22) }
    static var sewnCard:   Color { Color.white.opacity(0.62) }
    static var sewnFill:   Color { Color.sewnInk.opacity(0.05) }
    static let sewnError  = Color(red: 200/255, green:  60/255, blue:  60/255)
}

// MARK: - Typography

extension Font {
    static func sewnSerif(_ size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        let f = Font.system(size: size, weight: weight, design: .serif)
        return italic ? f.italic() : f
    }

    static func sewnSans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func sewnMono(_ size: CGFloat) -> Font {
        .system(size: size, design: .monospaced)
    }
}

// MARK: - Icon helpers

extension Image {
    static var sewnIcon: Image {
        if let img = Bundle.module.image(forResource: "sewn_icon_480") {
            return Image(nsImage: img)
        }
        return Image(systemName: "eye.fill")
    }
}

// MARK: - Spinning icon view

struct DatabaseSpinningIcon: View {
    let size: CGFloat
    let cornerRadius: CGFloat
    var opacity: Double = 1.0

    @State private var rotation = 0.0

    var body: some View {
        iconContent
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 60).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }

    @ViewBuilder
    private var iconContent: some View {
        if let img = Bundle.module.image(forResource: "sewn_icon_480") {
            Image(nsImage: img)
                .resizable()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .opacity(opacity)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.sewnGold)
                Image(systemName: "eye.fill")
                    .font(.system(size: size * 0.4, weight: .light))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .opacity(opacity)
        }
    }
}

// MARK: - Orbiting rings

struct DatabaseOrbitRings: View {
    let iconSize: CGFloat
    @State private var outerRotation = 0.0
    @State private var innerRotation = 0.0

    var body: some View {
        ZStack {
            // Outer dashed ring
            Circle()
                .strokeBorder(
                    Color.sewnGold.opacity(0.30),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 3])
                )
                .frame(width: iconSize + 40, height: iconSize + 40)
                .rotationEffect(.degrees(outerRotation))
                .onAppear {
                    withAnimation(.linear(duration: 32).repeatForever(autoreverses: false)) {
                        outerRotation = -360
                    }
                }

            // Inner solid ring
            Circle()
                .strokeBorder(Color.sewnGold.opacity(0.30), lineWidth: 1)
                .frame(width: iconSize + 14, height: iconSize + 14)
                .rotationEffect(.degrees(innerRotation))
                .onAppear {
                    withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) {
                        innerRotation = 360
                    }
                }

            // Radial glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.sewnGold.opacity(0.15), .clear],
                        center: .center, startRadius: 0, endRadius: iconSize * 0.6
                    )
                )
                .frame(width: iconSize + 8, height: iconSize + 8)
        }
        .frame(width: iconSize + 48, height: iconSize + 48)
    }
}
