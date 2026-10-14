import AppKit
import Foundation

/// Original synthesized sounds (short glassy bells, mallets and pops), one per kind of event. Rendered to WAV at build time (`--render-sounds`)
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

    /// The score of each sound: short, rising, rounded "reward" tones.
    fileprivate var notes: [Note] {
        switch self {
        case .attention:
            // A quick "ti-ti-ding" up a major triad; the last note rings.
            return [Note(.g4, at: 0, for: 0.08, voice: .bell, gain: 0.55),
                    Note(.b4, at: 0.07, for: 0.08, voice: .bell, gain: 0.6),
                    Note(.d5, at: 0.14, for: 0.42, voice: .bell, gain: 0.8),
                    Note(.g3, at: 0.14, for: 0.32, voice: .keys, gain: 0.25)]
        case .good:
            // The satisfying "correct!": a bright rising fifth with a sparkle on top.
            return [Note(.e5, at: 0, for: 0.12, voice: .bell, gain: 0.7),
                    Note(.b5, at: 0.09, for: 0.45, voice: .bell, gain: 0.85),
                    Note(.e4, at: 0.09, for: 0.38, voice: .keys, gain: 0.3)]
        case .bad:
            // A soft, rounded "bonk-bonk": falling, short and friendly.
            return [Note(.d4, at: 0, for: 0.13, voice: .marimba, gain: 0.8),
                    Note(.a3, at: 0.12, for: 0.3, voice: .marimba, gain: 0.85),
                    Note(.a2, at: 0.12, for: 0.28, voice: .keys, gain: 0.3)]
        case .info:
            // A bubbly "pop".
            return [Note(.e4, at: 0, for: 0.1, voice: .pop, gain: 0.9),
                    Note(.b4, at: 0.025, for: 0.14, voice: .bell, gain: 0.2)]
        }
    }
}

enum Voice { case bell, marimba, keys, pop }

struct Note {
    let freq: Double, start: Double, dur: Double, voice: Voice, gain: Double
    init(_ freq: Double, at start: Double, for dur: Double, voice: Voice, gain: Double = 1) {
        (self.freq, self.start, self.dur, self.voice, self.gain) = (freq, start, dur, voice, gain)
    }
}

private extension Double {
    static let a2 = 110.0, g3 = 196.0, a3 = 220.0
    static let d4 = 293.66, e4 = 329.63, g4 = 392.0, b4 = 493.88
    static let d5 = 587.33, e5 = 659.25, b5 = 987.77
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
            var phase = 0.0
            for i in 0..<n where s0 + i < dry.count {
                let t = Double(i) / sr
                let release = t > note.dur ? exp(-(t - note.dur) / 0.02) : 1
                var v = 0.0
                switch note.voice {
                case .bell:
                    // Glassy bell: fundamental, a soft octave and a quick shimmer partial.
                    let attack = min(1, t / 0.007)
                    let body = exp(-t / (note.dur * 0.5))
                    v = attack * (sin(2 * .pi * f * t) * body
                        + 0.15 * sin(2 * .pi * f * 2 * t) * exp(-t / (note.dur * 0.2)))
                case .marimba:
                    let attack = min(1, t / 0.006)
                    v = attack * (sin(2 * .pi * f * t) * exp(-t / (note.dur * 0.45))
                        + 0.1 * sin(2 * .pi * f * 3.93 * t) * exp(-t / 0.015))
                case .keys:
                    let attack = min(1, t / 0.006)
                    let index = 0.5 * exp(-t / 0.06) + 0.05
                    v = attack * sin(2 * .pi * f * t + index * sin(2 * .pi * f * t)) * exp(-t / (note.dur * 0.5))
                case .pop:
                    // A sine whose pitch jumps up an octave in a few ms: the "bubble" sound.
                    phase += f * (1 + 1.2 * (1 - exp(-t / 0.012))) / sr
                    v = min(1, t / 0.004) * sin(2 * .pi * phase) * exp(-t / 0.04)
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
        var mix = wet.indices.map { wet[$0] + 0.08 * verb[$0] }

        // Warm it up: tame the top end and add gentle saturation.
        var y = 0.0
        for i in mix.indices { y += 0.3 * (mix[i] - y); mix[i] = y }
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
