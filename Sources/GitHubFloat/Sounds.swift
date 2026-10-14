import AppKit
import Foundation

/// Original synthesized sounds (soft mallets and electric-piano tones), one per kind of event. Rendered to WAV at build time (`--render-sounds`)
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

    /// The score of each sound: soft mallet and electric-piano tones on consonant (major pentatonic) intervals.
    fileprivate var notes: [Note] {
        switch self {
        case .attention:
            // A gentle, rising "ding-ding": a fifth then a sixth, like a friendly doorbell.
            return [Note(.g5, at: 0, for: 0.5, voice: .kalimba, gain: 0.8),
                    Note(.d6, at: 0.13, for: 0.6, voice: .kalimba, gain: 0.75),
                    Note(.g4, at: 0, for: 0.7, voice: .keys, gain: 0.35),
                    Note(.d5, at: 0.13, for: 0.7, voice: .keys, gain: 0.3)]
        case .good:
            // A quick rolled major chord that blooms: C E G C.
            let roll: [Double] = [.c5, .e5, .g5, .c6]
            return roll.enumerated().flatMap { i, f in
                [Note(f, at: Double(i) * 0.06, for: 0.9 - Double(i) * 0.06, voice: .keys, gain: 0.55),
                 Note(f * 2, at: Double(i) * 0.06, for: 0.5, voice: .kalimba, gain: 0.35)]
            } + [Note(.e6, at: 0.26, for: 0.7, voice: .kalimba, gain: 0.45)]
        case .bad:
            // Soft and low, never alarming: a falling fourth on warm keys.
            return [Note(.a4, at: 0, for: 0.45, voice: .keys, gain: 0.8),
                    Note(.e4, at: 0.16, for: 0.8, voice: .keys, gain: 0.8),
                    Note(.a3, at: 0.16, for: 0.8, voice: .keys, gain: 0.35)]
        case .info:
            // A single soft marimba drop.
            return [Note(.e6, at: 0, for: 0.35, voice: .marimba, gain: 0.7),
                    Note(.e5, at: 0, for: 0.45, voice: .keys, gain: 0.25)]
        }
    }
}

enum Voice { case kalimba, marimba, keys }

struct Note {
    let freq: Double, start: Double, dur: Double, voice: Voice, gain: Double
    init(_ freq: Double, at start: Double, for dur: Double, voice: Voice, gain: Double = 1) {
        (self.freq, self.start, self.dur, self.voice, self.gain) = (freq, start, dur, voice, gain)
    }
}

private extension Double {
    static let a3 = 220.0, e4 = 329.63, g4 = 392.0, a4 = 440.0
    static let c5 = 523.25, d5 = 587.33, e5 = 659.25, g5 = 783.99
    static let c6 = 1046.5, d6 = 1174.66, e6 = 1318.51
}

enum Sounds {
    static let sampleRate = 44_100.0

    static func samples(_ kind: SoundKind) -> [Float] {
        let sr = sampleRate
        let length = (kind.notes.map { $0.start + $0.dur }.max() ?? 0) + 0.6
        var dry = [Double](repeating: 0, count: Int(length * sr))

        for note in kind.notes {
            let s0 = Int(note.start * sr)
            let n = Int((note.dur + 0.1) * sr)
            let f = note.freq
            for i in 0..<n where s0 + i < dry.count {
                let t = Double(i) / sr
                let release = t > note.dur ? exp(-(t - note.dur) / 0.03) : 1
                var v = 0.0
                switch note.voice {
                case .kalimba:
                    // Pure fundamental plus quickly fading upper partials: a soft, round "tine".
                    let attack = min(1, t / 0.004)
                    v = attack * (sin(2 * .pi * f * t) * exp(-t / (note.dur * 0.45))
                        + 0.18 * sin(2 * .pi * f * 5.4 * t) * exp(-t / 0.025)
                        + 0.06 * sin(2 * .pi * f * 2 * t) * exp(-t / 0.12))
                case .marimba:
                    let attack = min(1, t / 0.003)
                    v = attack * (sin(2 * .pi * f * t) * exp(-t / (note.dur * 0.35))
                        + 0.25 * sin(2 * .pi * f * 3.93 * t) * exp(-t / 0.03))
                case .keys:
                    // Rhodes-like FM: the bell-ish bite fades out, leaving a warm sine.
                    let attack = min(1, t / 0.008)
                    let index = 1.1 * exp(-t / 0.12) + 0.15
                    v = attack * sin(2 * .pi * f * t + index * sin(2 * .pi * f * t)) * exp(-t / (note.dur * 0.55))
                }
                dry[s0 + i] += note.gain * release * v
            }
        }

        // Space: a soft echo plus a small Schroeder reverb.
        var wet = dry
        let echo = Int(0.15 * sr)
        for i in echo..<wet.count { wet[i] += 0.12 * wet[i - echo] }
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
        var mix = wet.indices.map { wet[$0] + 0.18 * verb[$0] }

        // Warm it up: tame the top end and add gentle saturation.
        var y = 0.0
        for i in mix.indices { y += 0.6 * (mix[i] - y); mix[i] = y }
        let peak = mix.map(abs).max() ?? 1
        mix = mix.map { tanh(1.1 * $0 / peak) / tanh(1.1) }

        let fade = Int(0.08 * sr)
        return mix.enumerated().map { i, v in
            let f = i > mix.count - fade ? Double(mix.count - i) / Double(fade) : 1
            return Float(v * 0.5 * f)
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
