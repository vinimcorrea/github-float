import AppKit
import Foundation

/// Original synthesized reward sounds (glockenspiel, marimba, soft keys), one per kind of event. Rendered to WAV at build time (`--render-sounds`)
/// so notifications can use them and respect Focus.
enum SoundKind: String, CaseIterable {
    case attention, bad, good, info

    var fileName: String { "GitHubFloat-\(rawValue).wav" }

    var title: String {
        switch self {
        case .attention: return "Needs you"
        case .good: return "Approved / merged"
        case .bad: return "Changes requested / CI failing"
        case .info: return "Comment"
        }
    }

    /// The score of each sound, following the classic reward recipe: short (200–800 ms), rising major intervals,
    /// bright bell/marimba timbres with a fast attack and gentle decay, and nothing harsh.
    fileprivate var notes: [Note] {
        switch self {
        case .attention:
            // G → C resolution on a bright bell: "something for you".
            return [Note(.g5, at: 0, for: 0.14, voice: .glock, gain: 0.7),
                    Note(.c6, at: 0.1, for: 0.5, voice: .glock, gain: 0.85),
                    Note(.c5, at: 0.1, for: 0.45, voice: .keys, gain: 0.3)]
        case .good:
            // C → E → G landing on a full chord with a subtle sparkle: "goal achieved".
            return [Note(.c5, at: 0, for: 0.12, voice: .glock, gain: 0.6),
                    Note(.e5, at: 0.075, for: 0.12, voice: .glock, gain: 0.65),
                    Note(.g5, at: 0.15, for: 0.6, voice: .glock, gain: 0.8),
                    Note(.c6, at: 0.15, for: 0.6, voice: .glock, gain: 0.45),
                    Note(.e5, at: 0.15, for: 0.55, voice: .keys, gain: 0.3),
                    Note(.c4, at: 0.15, for: 0.55, voice: .keys, gain: 0.3),
                    Note(.g6, at: 0.2, for: 0.25, voice: .sparkle, gain: 0.12),
                    Note(.c7, at: 0.26, for: 0.2, voice: .sparkle, gain: 0.08)]
        case .bad:
            // A low, muted falling tone: noticeable, never a buzzer.
            return [Note(.e4, at: 0, for: 0.14, voice: .muted, gain: 0.8),
                    Note(.c4, at: 0.12, for: 0.3, voice: .muted, gain: 0.85)]
        case .info:
            // One soft marimba pluck: "noted".
            return [Note(.e5, at: 0, for: 0.22, voice: .marimba, gain: 0.8)]
        }
    }
}

enum Voice { case glock, marimba, keys, muted, sparkle }

struct Note {
    let freq: Double, start: Double, dur: Double, voice: Voice, gain: Double
    init(_ freq: Double, at start: Double, for dur: Double, voice: Voice, gain: Double = 1) {
        (self.freq, self.start, self.dur, self.voice, self.gain) = (freq, start, dur, voice, gain)
    }
}

private extension Double {
    static let c4 = 261.63, e4 = 329.63
    static let c5 = 523.25, e5 = 659.25, g5 = 783.99
    static let c6 = 1046.5, g6 = 1567.98, c7 = 2093.0
}

enum Sounds {
    static let sampleRate = 44_100.0

    static func samples(_ kind: SoundKind) -> [Float] {
        let sr = sampleRate
        let length = (kind.notes.map { $0.start + $0.dur }.max() ?? 0) + 0.25
        var dry = [Double](repeating: 0, count: Int(length * sr))

        for note in kind.notes {
            let s0 = Int(note.start * sr)
            let n = Int((note.dur + 0.08) * sr)
            let f = note.freq
            for i in 0..<n where s0 + i < dry.count {
                let t = Double(i) / sr
                let release = t > note.dur ? exp(-(t - note.dur) / 0.025) : 1
                let w = 2 * Double.pi * f * t
                var v = 0.0
                switch note.voice {
                case .glock:
                    // Glockenspiel-like bell: fast (but click-free) attack, inharmonic 2.76 partial that fades quickly.
                    v = min(1, t / 0.0015) * (sin(w) * exp(-t / (note.dur * 0.55))
                        + 0.22 * sin(2.76 * w) * exp(-t / 0.06)
                        + 0.05 * sin(5.4 * w) * exp(-t / 0.015))
                case .marimba:
                    v = min(1, t / 0.0015) * (sin(w) * exp(-t / (note.dur * 0.4))
                        + 0.18 * sin(3.93 * w) * exp(-t / 0.02)
                        + 0.1 * sin(2 * w) * exp(-t / 0.05))
                case .keys:
                    // Soft electric-piano body under the bells.
                    let index = 0.6 * exp(-t / 0.08) + 0.08
                    v = min(1, t / 0.005) * sin(w + index * sin(w)) * exp(-t / (note.dur * 0.5))
                case .muted:
                    // Wood-block-like thud: mostly fundamental, very short overtone.
                    v = min(1, t / 0.002) * (sin(w) * exp(-t / (note.dur * 0.35))
                        + 0.12 * sin(2 * w) * exp(-t / 0.02))
                case .sparkle:
                    v = min(1, t / 0.003) * sin(w) * exp(-t / (note.dur * 0.3))
                }
                dry[s0 + i] += note.gain * release * v
            }
        }

        // Space: a small Schroeder reverb.
        let wet = dry
        var verb = [Double](repeating: 0, count: wet.count)
        for ms in [29.7, 37.1, 41.1, 43.7] {
            let d = Int(ms / 1000 * sr)
            var comb = [Double](repeating: 0, count: wet.count)
            for i in wet.indices { comb[i] = wet[i] + (i >= d ? 0.78 * comb[i - d] : 0) }
            for i in verb.indices { verb[i] += comb[i] / 4 }
        }
        for (ms, g) in [(5.0, 0.7), (1.7, 0.7)] {
            let d = Int(ms / 1000 * sr)
            var out = verb
            for i in d..<verb.count { out[i] = -g * verb[i] + verb[i - d] + g * out[i - d] }
            verb = out
        }
        var mix = wet.indices.map { wet[$0] + 0.12 * verb[$0] }

        // Warm it up: tame the top end and add gentle saturation.
        var y = 0.0
        for i in mix.indices { y += 0.5 * (mix[i] - y); mix[i] = y }
        let peak = mix.map(abs).max() ?? 1
        mix = mix.map { tanh(1.1 * $0 / peak) / tanh(1.1) }

        let fade = Int(0.08 * sr)
        return mix.enumerated().map { i, v in
            let f = i > mix.count - fade ? Double(mix.count - i) / Double(fade) : 1
            return Float(v * 0.45 * f)
        }
    }

    static func wav(_ kind: SoundKind) -> Data {
        let pcm = samples(kind).map { Int16(max(-1, min(1, $0)) * Float(Int16.max)) }
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(pcm.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        pcm.forEach { u16(UInt16(bitPattern: $0)) }
        return d
    }

    static func render(to dir: String) {
        let url = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for k in SoundKind.allCases {
            try? wav(k).write(to: url.appendingPathComponent(k.fileName))
        }
    }

    /// True when the sound is bundled, so a notification can play it.
    static func isBundled(_ kind: SoundKind) -> Bool {
        Bundle.main.url(forResource: kind.fileName, withExtension: nil) != nil
    }

    private static var playing: [NSSound] = []

    static func play(_ kind: SoundKind) {
        let sound = Bundle.main.url(forResource: kind.fileName, withExtension: nil).flatMap { NSSound(contentsOf: $0, byReference: true) }
            ?? NSSound(data: wav(kind))
        guard let sound else { return }
        playing.removeAll { !$0.isPlaying }
        playing.append(sound)
        sound.play()
    }
}
