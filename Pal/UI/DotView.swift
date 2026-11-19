import SwiftUI

/// The little companion dot. Calm when idle, breathes with your voice, orbits while thinking,
/// ripples while talking, wears a slow ring while agents work, and pulses when something's waiting.
struct DotView: View {
    @ObservedObject var model: PalModel
    @ObservedObject var settings: PalSettings

    private var c: PalConfig { settings.config }
    private var scale: CGFloat { c.dotSize }

    var body: some View {
        let animating = model.phase != .idle || model.dotHovered || model.agentsWorking > 0 || model.attention
        TimelineView(.animation(paused: !animating)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                halo(t)
                core(t)
            }
            .frame(width: DotPanel.size, height: DotPanel.size)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: model.phase)
        .animation(.easeOut(duration: 0.15), value: model.dotHovered)
    }

    private var tint: Color {
        switch model.phase {
        case .idle: return model.attention ? Color(hex: c.colorAttention) : Color(hex: c.colorIdle)
        case .listening: return Color(hex: c.colorListening)
        case .thinking: return Color(hex: c.colorThinking)
        case .speaking: return Color(hex: c.colorSpeaking)
        case .error: return Color(red: 1.0, green: 0.3, blue: 0.3)
        }
    }

    private func coreSize(_ t: TimeInterval) -> CGFloat {
        let base: CGFloat
        switch model.phase {
        case .idle:
            base = model.dotHovered ? 13 : (model.attention ? 11 + 1.5 * sin(t * 4) : 10)
        case .listening: base = 13 + model.level * 9
        case .thinking: base = 12 + 1.5 * sin(t * 3)
        case .speaking: base = 13 + 2.5 * abs(sin(t * 5.2)) * abs(sin(t * 2.1 + 1))
        case .error: base = 12
        }
        return base * scale
    }

    private func core(_ t: TimeInterval) -> some View {
        let size = coreSize(t)
        let idle = model.phase == .idle && !model.attention
        return Circle()
            .fill(RadialGradient(colors: [tint, tint.opacity(0.82)], center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: size))
            .overlay(Circle().strokeBorder(.black.opacity(idle ? 0.28 : 0.12), lineWidth: 0.75))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.35), radius: 2.5, y: 1)
            .shadow(color: tint.opacity(idle ? 0 : 0.7), radius: 6 * scale)
            .opacity(idle && !model.dotHovered ? c.idleOpacity : 1)
    }

    @ViewBuilder
    private func halo(_ t: TimeInterval) -> some View {
        switch model.phase {
        case .listening:
            let s = (20 + model.level * 26) * scale
            Circle()
                .fill(tint.opacity(0.22 + 0.2 * model.level))
                .frame(width: s, height: s)
                .blur(radius: 3)
        case .thinking:
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(tint.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 24 * scale, height: 24 * scale)
                .rotationEffect(.radians(t * 5))
        case .speaking:
            ForEach(0..<2, id: \.self) { i in
                let p = (t * 0.9 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                Circle()
                    .stroke(tint.opacity(0.55 * (1 - p)), lineWidth: 1.5)
                    .frame(width: (14 + 22 * p) * scale, height: (14 + 22 * p) * scale)
            }
        case .idle where model.attention:
            let p = (t * 0.7).truncatingRemainder(dividingBy: 1)
            Circle()
                .stroke(tint.opacity(0.6 * (1 - p)), lineWidth: 1.5)
                .frame(width: (14 + 18 * p) * scale, height: (14 + 18 * p) * scale)
        case .idle where model.agentsWorking > 0:
            // A slow orbit: work is happening in the background.
            Circle()
                .trim(from: 0, to: 0.18)
                .stroke(Color(hex: c.colorWorking).opacity(0.9), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: 19 * scale, height: 19 * scale)
                .rotationEffect(.radians(t * 1.6))
        default:
            EmptyView()
        }
    }
}
