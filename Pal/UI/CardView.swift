import SwiftUI

/// The light glass card: what you asked, the short answer, the detail, and a few small buttons.
struct CardView: View {
    static let margin: CGFloat = 18 // room for the shadow and the slide-in

    @ObservedObject var model: PalModel
    @ObservedObject var settings: PalSettings
    var actions: CardActions
    var onHeight: (CGFloat) -> Void
    @State private var hovering = false
    @State private var copied = false

    private var c: PalConfig { settings.config }
    private var anchor: UnitPoint {
        switch (c.dotCorner.isTop, c.dotCorner.isRight) {
        case (true, true): .topTrailing
        case (true, false): .topLeading
        case (false, true): .bottomTrailing
        case (false, false): .bottomLeading
        }
    }
    private var alignment: Alignment {
        Alignment(horizontal: c.dotCorner.isRight ? .trailing : .leading, vertical: c.dotCorner.isTop ? .top : .bottom)
    }

    var body: some View {
        ZStack(alignment: alignment) {
            if model.cardVisible {
                card
                    .transition(.asymmetric(insertion: .scale(scale: 0.92, anchor: anchor).combined(with: .opacity), removal: .opacity))
            }
        }
        .frame(width: c.cardWidth, alignment: alignment)
        .frame(maxHeight: .infinity, alignment: alignment)
        .padding(Self.margin)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: model.cardVisible)
    }

    private var glass: Glass {
        switch c.cardTint {
        case .clear: .clear
        case .light: .regular.tint(.white.opacity(0.18))
        case .dark: .regular.tint(.black.opacity(0.35))
        }
    }

    private var card: some View {
        ScrollView(.vertical) {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .glassEffect(glass, in: .rect(cornerRadius: 22))
        .environment(\.colorScheme, c.cardTint == .dark ? .dark : (c.cardTint == .light ? .light : .light))
        .overlay(alignment: .topTrailing) {
            if hovering {
                iconButton("xmark", help: "Close (Esc)", action: actions.close)
                    .padding(10)
                    .transition(.opacity)
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.caption.isEmpty {
                Text(model.caption)
                    .font(.system(size: c.cardTextSize - 1.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.trailing, 22)
            }
            if !model.headline.isEmpty {
                Text(model.headline)
                    .font(.system(size: c.cardTextSize + 1.5, weight: .semibold))
                    .foregroundStyle(model.cardKind == .error ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.activity.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(model.activity.prefix(1).uppercased() + model.activity.dropFirst() + "…")
                        .font(.system(size: c.cardTextSize - 1.5))
                        .foregroundStyle(.secondary)
                }
            }
            if !model.detail.isEmpty {
                MarkdownBlock(text: model.detail, size: c.cardTextSize)
            }
            if showsFooter { footer }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }

    private var showsFooter: Bool { !model.headline.isEmpty && model.activity.isEmpty }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(model.footnote)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            if model.cardSessionID != nil {
                pillButton("Open", icon: "arrow.up.right", action: actions.open)
            }
            iconButton(model.cardSpeaking ? "stop.fill" : "speaker.wave.2", help: model.cardSpeaking ? "Stop" : "Read aloud", action: actions.play)
            iconButton(copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                actions.copy()
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            }
        }
        .padding(.top, 2)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(help)
    }

    private func pillButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// Just enough markdown for short answers: paragraphs, bullets, numbered lists, headings, inline styles.
struct MarkdownBlock: View {
    let text: String
    var size: CGFloat = 13.5

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                row(line)
            }
        }
        .font(.system(size: size))
        .lineSpacing(1.5)
    }

    private var lines: [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    @ViewBuilder
    private func row(_ line: String) -> some View {
        if let rest = strip(line, prefixes: ["- ", "* ", "• "]) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•").foregroundStyle(.secondary)
                inline(rest)
            }
        } else if let m = line.firstMatch(of: /^(\d+)[.)]\s+(.*)$/) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(m.1).").foregroundStyle(.secondary).monospacedDigit()
                inline(String(m.2))
            }
        } else if let m = line.firstMatch(of: /^#{1,6}\s+(.*)$/) {
            inline(String(m.1)).font(.system(size: size, weight: .semibold)).padding(.top, 2)
        } else {
            inline(line)
        }
    }

    private func inline(_ s: String) -> some View {
        let attr = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        return Text(attr)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func strip(_ line: String, prefixes: [String]) -> String? {
        for p in prefixes where line.hasPrefix(p) { return String(line.dropFirst(p.count)) }
        return nil
    }
}
