import SwiftUI

enum Phase: Equatable {
    case idle
    case listening
    case thinking
    case speaking
    case error
}

/// What the card is showing.
enum CardKind: Equatable {
    case answer, agent, timer, notice, error
}

/// Everything the dot and the card render from.
final class PalModel: ObservableObject {
    @Published var phase: Phase = .idle
    /// 0…1 microphone level while listening.
    @Published var level: CGFloat = 0
    @Published var liveTranscript = ""

    // Card
    @Published var cardVisible = false
    @Published var cardKind: CardKind = .answer
    /// Small header, e.g. "Agent · Watch sessions" or the question you asked.
    @Published var caption = ""
    @Published var headline = ""
    @Published var detail = ""
    /// Live activity line while working, e.g. "searching the web".
    @Published var activity = ""
    @Published var footnote = ""
    @Published var cardSessionID: String?
    @Published var cardSpeaking = false

    // Dot extras
    @Published var dotHovered = false
    /// Agents currently working.
    @Published var agentsWorking = 0
    /// Something arrived that you haven't looked at.
    @Published var attention = false

    var copyText: String { detail.isEmpty ? headline : "\(headline)\n\n\(detail)" }
}
