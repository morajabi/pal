import AVFoundation
import CoreAudio
import AudioToolbox

struct VoiceOption: Identifiable, Hashable {
    var id: String
    var name: String
    var language: String
    var quality: String
}

/// Text-to-speech with the user's chosen system voice. Skips speaking when the Mac is muted.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    var onSpeakingChanged: ((Bool) -> Void)?
    private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    var isSpeaking: Bool { synth.isSpeaking }

    /// Returns false if nothing was spoken (muted, empty).
    @discardableResult
    func speak(_ text: String, force: Bool = false) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, force || !Self.outputIsSilent() else { return false }
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: t)
        u.voice = Self.voice(PalSettings.c.ttsVoice)
        u.rate = Float(PalSettings.c.ttsRate)
        u.prefersAssistiveTechnologySettings = false
        synth.speak(u)
        return true
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        DispatchQueue.main.async { self.onSpeakingChanged?(true) }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        DispatchQueue.main.async { self.onSpeakingChanged?(s.isSpeaking) }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        DispatchQueue.main.async { self.onSpeakingChanged?(false) }
    }

    // MARK: Voices

    /// Installed voices for the user's languages, best quality first.
    static func voices() -> [VoiceOption] {
        let langs = Set(Locale.preferredLanguages.map { String($0.prefix(2)) } + ["en"])
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) && langs.contains(String($0.language.prefix(2))) }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
            .map { v in
                let q: String
                switch v.quality {
                case .premium: q = "Premium"
                case .enhanced: q = "Enhanced"
                default: q = "Standard"
                }
                return VoiceOption(id: v.identifier, name: v.name, language: v.language, quality: q)
            }
    }

    /// The chosen voice, or the best installed one for the user's language.
    static func voice(_ id: String) -> AVSpeechSynthesisVoice? {
        if !id.isEmpty, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        let lang = AVSpeechSynthesisVoice.currentLanguageCode()
        let pool = AVSpeechSynthesisVoice.speechVoices().filter { !$0.voiceTraits.contains(.isNoveltyVoice) && $0.language == lang }
        return pool.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: lang)
    }

    static let downloadVoicesURL = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")!

    /// True when the default output device is muted or at zero volume.
    static func outputIsSilent() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr else {
            return false
        }
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device, &addr),
           AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &muted) == noErr, muted != 0 {
            return true
        }
        var volume: Float32 = 1
        size = UInt32(MemoryLayout<Float32>.size)
        addr.mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        if AudioObjectHasProperty(device, &addr),
           AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &volume) == noErr, volume < 0.01 {
            return true
        }
        return false
    }
}
