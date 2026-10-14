import AppKit
import Foundation

/// Original synthesized sounds (warm synth voices, chip-style melodies), one per kind of event. Rendered to WAV at build time (`--render-sounds`)
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

    /// The original score of each sound: playful chip-style melodies played on warm synth voices.
    fileprivate var notes: [Note] {
        switch self {
        case .attention:
            // A friendly "hey!": a quick pickup into a held fifth, over a soft sub.
            return [Note(.d5, at: 0, for: 0.09, voice: .pluck, gain: 0.8),
                    Note(.a5, at: 0.09, for: 0.42, voice: .pluck, vibrato: true),
                    Note(.a5, at: 0.09, for: 0.42, voice: .bell, gain: 0.25),
                    Note(.d3, at: 0, for: 0.5, voice: .sub, gain: 0.5)]
        case .good:
            // Rising major-seventh run that lands on a glowing chord.
            let run: [Double] = [.c5, .e5, .g5, .b5]
            return run.enumerated().map { Note($1, at: Double($0) * 0.065, for: 0.12, voice: .pluck, gain: 0.75) }
                + [Note(.d6, at: 0.26, for: 0.55, voice: .pluck, vibrato: true),
                   Note(.g5, at: 0.26, for: 0.55, voice: .pluck, gain: 0.45),
                   Note(.d6, at: 0.26, for: 0.55, voice: .bell, gain: 0.3),
                   Note(.c3, at: 0.26, for: 0.6, voice: .sub, gain: 0.6)]
        case .bad:
            // Two minor steps down and a tired pitch drop.
            return [Note(.a4, at: 0, for: 0.16, voice: .pluck, gain: 0.85, bright: 0.6),
                    Note(.f4, at: 0.17, for: 0.45, voice: .pluck, bright: 0.5, slideTo: .f4 * 0.94),
                    Note(.a2, at: 0, for: 0.62, voice: .sub, gain: 0.7, slideTo: .a2 * 0.89)]
        case .info:
            // A soft "bloop" with an octave sparkle.
            return [Note(.e5, at: 0, for: 0.16, voice: .pluck, gain: 0.8, bright: 0.7, slideFrom: .e5 * 0.94),
                    Note(.e6, at: 0.02, for: 0.2, voice: .bell, gain: 0.22)]
        }
    }
}

enum Voice { case pluck, bell, sub }

struct Note {
    let freq: Double, start: Double, dur: Double, voice: Voice, gain: Double, bright: Double
    let slideTo: Double?, slideFrom: Double?, vibrato: Bool
    init(_ freq: Double, at start: Double, for dur: Double, voice: Voice, gain: Double = 1, bright: Double = 1,
         slideTo: Double? = nil, slideFrom: Double? = nil, vibrato: Bool = false) {
        (self.freq, self.start, self.dur, self.voice, self.gain, self.bright) = (freq, start, dur, voice, gain, bright)
        (self.slideTo, self.slideFrom, self.vibrato) = (slideTo, slideFrom, vibrato)
    }
}

private extension Double {
    static let a2 = 110.0, c3 = 130.81, d3 = 146.83
    static let f4 = 349.23, a4 = 440.0
    static let c5 = 523.25, d5 = 587.33, e5 = 659.25, g5 = 783.99, a5 = 880.0, b5 = 987.77
    static let d6 = 1174.66, e6 = 1318.51
}

enum Sounds {
    static let sampleRate = 44_100.0

    static func samples(_ kind: SoundKind) -> [Float] {
        let sr = sampleRate
        let length = (kind.notes.map { $0.start + $0.dur }.max() ?? 0) + 0.7
        var dry = [Double](repeating: 0, count: Int(length * sr))

        for note in kind.notes {
            let s0 = Int(note.start * sr)
            let n = Int((note.dur + 0.15) * sr)
            var phases = [0.0, 0.31, 0.67]
            var low = 0.0, band = 0.0
            for i in 0..<n where s0 + i < dry.count {
                let t = Double(i) / sr
                let p = min(1, t / note.dur)
                var f = note.freq
                if let to = note.slideTo { f *= pow(to / note.freq, p * p) }
                if let from = note.slideFrom { f = from * pow(note.freq / from, min(1, t / 0.04)) }
                if note.vibrato, t > 0.12 { f *= 1 + 0.006 * sin(2 * .pi * 5.5 * t) * min(1, (t - 0.12) / 0.15) }

                // Soft attack, smooth exponential decay, gentle release past the note end.
                let attack = min(1, t / (note.voice == .sub ? 0.015 : 0.006))
                let decay = exp(-t / (note.dur * (note.voice == .bell ? 0.35 : 0.6)))
                let release = t > note.dur ? exp(-(t - note.dur) / 0.04) : 1
                let env = attack * decay * release

                var v = 0.0
                switch note.voice {
                case .pluck:
                    // Two slightly detuned saws (chorus) through a low-pass filter that closes after the pluck.
                    for (k, detune) in [0.996, 1.004].enumerated() {
                        phases[k] = (phases[k] + f * detune / sr).truncatingRemainder(dividingBy: 1)
                        v += 2 * phases[k] - 1
                    }
                    v *= 0.5
                    let cutoff = min(5_500, f * (1.2 + 5 * note.bright * exp(-t / 0.07)))
                    let fc = 2 * sin(.pi * cutoff / sr)
                    low += fc * band
                    let high = v - low - 0.9 * band
                    band += fc * high
                    v = low
                case .bell:
                    phases[0] = (phases[0] + f / sr).truncatingRemainder(dividingBy: 1)
                    phases[1] = (phases[1] + f * 2.76 / sr).truncatingRemainder(dividingBy: 1)
                    v = sin(2 * .pi * phases[0]) + 0.2 * sin(2 * .pi * phases[1]) * exp(-t / 0.05)
                case .sub:
                    phases[0] = (phases[0] + f / sr).truncatingRemainder(dividingBy: 1)
                    v = sin(2 * .pi * phases[0])
                }
                dry[s0 + i] += note.gain * env * v
            }
        }

        // Space: a soft echo plus a small Schroeder reverb.
        var wet = dry
        let echo = Int(0.15 * sr)
        for i in echo..<wet.count { wet[i] += 0.28 * wet[i - echo] }
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
        var mix = wet.indices.map { wet[$0] + 0.22 * verb[$0] }

        // Warm it up: tame the top end and add gentle saturation.
        var y = 0.0
        for i in mix.indices { y += 0.45 * (mix[i] - y); mix[i] = y }
        let peak = mix.map(abs).max() ?? 1
        mix = mix.map { tanh(1.4 * $0 / peak) / tanh(1.4) }

        let fade = Int(0.08 * sr)
        return mix.enumerated().map { i, v in
            let f = i > mix.count - fade ? Double(mix.count - i) / Double(fade) : 1
            return Float(v * 0.6 * f)
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
