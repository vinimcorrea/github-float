import AppKit
import Foundation

/// Original synthesized sounds, one per kind of event. Rendered to WAV at build time (`--render-sounds`)
/// so notifications can use them and respect Focus.
enum SoundKind: String, CaseIterable {
    case attention, bad, good, info

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

/// A set of bundled sounds. `custom` sounds are the user's own files.
enum SoundPack: String, CaseIterable {
    case synth, meme

    var title: String { self == .synth ? "GitHub Float Synth" : "Meme Pack" }

    func fileName(_ kind: SoundKind) -> String {
        self == .synth ? "GitHubFloat-\(kind.rawValue).wav" : "GitHubFloat-\(rawValue)-\(kind.rawValue).wav"
    }

    /// What each meme sound is, shown in the Preview menu.
    func label(_ kind: SoundKind) -> String {
        guard self == .meme else { return kind.title }
        switch kind {
        case .attention: return "Airhorn (needs you)"
        case .good: return "Ta-da! (approved / merged)"
        case .bad: return "Sad trombone (changes requested / CI failing)"
        case .info: return "Dramatic boom (comment)"
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

    static func samples(_ kind: SoundKind, pack: SoundPack = .synth) -> [Float] {
        switch pack {
        case .synth: return finish(synthDry(kind), echo: 0.28, reverb: 0.22, warmth: 0.45, drive: 1.4)
        case .meme: return memeSamples(kind)
        }
    }

    private static func synthDry(_ kind: SoundKind) -> [Double] {
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

        return dry
    }

    /// Shared master chain: echo, a small Schroeder reverb, a warming low-pass, soft saturation and a fade-out.
    private static func finish(_ dry: [Double], echo echoGain: Double, reverb: Double, warmth: Double, drive: Double) -> [Float] {
        let sr = sampleRate
        var wet = dry
        let echo = Int(0.15 * sr)
        if echoGain > 0 { for i in echo..<wet.count { wet[i] += echoGain * wet[i - echo] } }
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
        var mix = wet.indices.map { wet[$0] + reverb * verb[$0] }

        // Warm it up: tame the top end and add gentle saturation.
        var y = 0.0
        for i in mix.indices { y += warmth * (mix[i] - y); mix[i] = y }
        let peak = mix.map(abs).max() ?? 1
        mix = mix.map { tanh(drive * $0 / peak) / tanh(drive) }

        let fade = Int(0.08 * sr)
        return mix.enumerated().map { i, v in
            let f = i > mix.count - fade ? Double(mix.count - i) / Double(fade) : 1
            return Float(v * 0.6 * f)
        }
    }

    // MARK: Meme pack (original takes on classic meme tropes)

    private static func memeSamples(_ kind: SoundKind) -> [Float] {
        switch kind {
        case .attention:
            // Airhorn: two short blasts and a long one, a raspy brass chord.
            var out = buffer(1.6)
            for (start, dur) in [(0.0, 0.12), (0.2, 0.12), (0.4, 0.6)] {
                sawStack(&out, at: start, for: dur, freqs: [466.16, 587.33, 698.46], detune: 0.007, gain: 0.8, attack: 0.006, release: 0.03,
                         pitch: { t in 0.93 + 0.07 * min(1, t / 0.035) + 0.004 * sin(2 * .pi * 7 * t) },
                         cutoff: { _, _ in 2_800 }, resonance: 0.6)
            }
            return finish(out, echo: 0, reverb: 0.15, warmth: 0.55, drive: 2.6)
        case .good:
            // Ta-da!: a short brass pickup into a held major chord.
            var out = buffer(1.7)
            brass(&out, at: 0, for: 0.12, [392.0, 493.88, 587.33], gain: 0.7)
            brass(&out, at: 0.15, for: 0.75, [523.25, 659.25, 783.99, 1046.5], gain: 0.8, vibrato: true)
            sine(&out, at: 0.15, for: 0.8, from: 130.81, to: 130.81, gain: 0.5)
            return finish(out, echo: 0.15, reverb: 0.3, warmth: 0.45, drive: 1.5)
        case .bad:
            // Sad trombone: four descending "wah"s, the last one long and wobbly.
            var out = buffer(2.6)
            let notes: [(Double, Double, Double)] = [(293.66, 0, 0.28), (277.18, 0.33, 0.28), (261.63, 0.66, 0.28), (246.94, 0.99, 1.0)]
            for (i, (f, start, dur)) in notes.enumerated() {
                let last = i == notes.count - 1
                sawStack(&out, at: start, for: dur, freqs: [f], detune: 0.003, gain: 0.9, attack: 0.02, release: 0.08,
                         pitch: { t in (0.96 + 0.04 * min(1, t / 0.05)) * (last && t > 0.15 ? 1 + 0.025 * sin(2 * .pi * 6 * (t - 0.15)) : 1) },
                         cutoff: { t, f in f * (1.3 + 4.5 * sin(.pi * min(1, t / (last ? 0.5 : dur)))) }, resonance: 0.5)
            }
            return finish(out, echo: 0, reverb: 0.25, warmth: 0.5, drive: 1.6)
        case .info:
            // Dramatic boom: a deep pitch-dropping thud with a big tail.
            var out = buffer(1.5)
            sine(&out, at: 0, for: 0.9, from: 130, to: 42, gain: 1, decay: 0.35)
            sine(&out, at: 0, for: 0.6, from: 260, to: 84, gain: 0.45, decay: 0.2)
            for i in 0..<Int(0.012 * sampleRate) { out[i] += 0.5 * Double.random(in: -1...1) * (1 - Double(i) / (0.012 * sampleRate)) }
            return finish(out, echo: 0, reverb: 0.4, warmth: 0.3, drive: 3)
        }
    }

    private static func buffer(_ seconds: Double) -> [Double] { [Double](repeating: 0, count: Int(seconds * sampleRate)) }

    private static func brass(_ out: inout [Double], at start: Double, for dur: Double, _ freqs: [Double], gain: Double, vibrato: Bool = false) {
        sawStack(&out, at: start, for: dur, freqs: freqs, detune: 0.004, gain: gain, attack: 0.02, release: 0.08,
                 pitch: { t in vibrato && t > 0.15 ? 1 + 0.005 * sin(2 * .pi * 5.5 * t) : 1 },
                 cutoff: { t, f in f * (1.5 + 3.5 * min(1, t / 0.06)) }, resonance: 0.7)
    }

    /// Detuned saw chord through a state-variable low-pass, with pitch and cutoff envelopes.
    private static func sawStack(_ out: inout [Double], at start: Double, for dur: Double, freqs: [Double], detune: Double,
                                 gain: Double, attack: Double, release: Double,
                                 pitch: (Double) -> Double, cutoff: (Double, Double) -> Double, resonance: Double) {
        let sr = sampleRate
        let s0 = Int(start * sr), n = Int((dur + release * 5) * sr)
        var phases = [Double](repeating: 0, count: freqs.count * 2).enumerated().map { Double($0.offset) * 0.137 }
        var low = 0.0, band = 0.0
        for i in 0..<n where s0 + i < out.count {
            let t = Double(i) / sr
            let m = pitch(t)
            var v = 0.0
            for (k, f) in freqs.enumerated() {
                for (j, d) in [1 - detune, 1 + detune].enumerated() {
                    let idx = k * 2 + j
                    phases[idx] = (phases[idx] + f * m * d / sr).truncatingRemainder(dividingBy: 1)
                    v += 2 * phases[idx] - 1
                }
            }
            v /= Double(freqs.count * 2)
            let fc = 2 * sin(.pi * min(5_500, cutoff(t, freqs[0] * m)) / sr)
            low += fc * band
            band += fc * (v - low - resonance * band)
            let env = min(1, t / attack) * (t > dur ? exp(-(t - dur) / release) : 1)
            out[s0 + i] += gain * env * low
        }
    }

    private static func sine(_ out: inout [Double], at start: Double, for dur: Double, from f0: Double, to f1: Double,
                             gain: Double, decay: Double? = nil) {
        let sr = sampleRate
        let s0 = Int(start * sr), n = Int(dur * sr)
        var phase = 0.0
        for i in 0..<n where s0 + i < out.count {
            let t = Double(i) / sr
            phase += f0 * pow(f1 / f0, min(1, t / 0.4)) / sr
            let env = min(1, t / 0.003) * (decay.map { exp(-t / $0) } ?? (1 - Double(i) / Double(n)))
            out[s0 + i] += gain * env * sin(2 * .pi * phase)
        }
    }

    // MARK: Files and playback

    static func wav(_ kind: SoundKind, pack: SoundPack = .synth) -> Data {
        let pcm = samples(kind, pack: pack).map { Int16(max(-1, min(1, $0)) * Float(Int16.max)) }
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
        for pack in SoundPack.allCases {
            for k in SoundKind.allCases {
                try? wav(k, pack: pack).write(to: url.appendingPathComponent(pack.fileName(k)))
            }
        }
    }

    /// Bundled file name for a sound style, if it has one ("synth" or "meme").
    static func bundledName(_ kind: SoundKind, style: String) -> String? {
        guard let pack = SoundPack(rawValue: style) else { return nil }
        let name = pack.fileName(kind)
        return Bundle.main.url(forResource: name, withExtension: nil) == nil ? nil : name
    }

    // MARK: Custom sounds

    static let customExtensions = ["wav", "aiff", "aif", "caf", "mp3", "m4a"]

    /// ~/Library/Application Support/GitHubFloat/Sounds, with a short guide on first use.
    static var customFolder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitHubFloat/Sounds", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let guide = """
            Drop your own sounds here and pick Sound → Custom Sounds in GitHub Float.
            Name them after the event (any of: \(customExtensions.joined(separator: ", "))):

              attention.mp3  needs you (needs a reviewer, re-review requested)
              good.mp3       approved, merged, moved forward
              bad.mp3        changes requested, CI failing
              info.mp3       comments and other updates

            Missing files fall back to the GitHub Float Synth sounds.
            """
            try? guide.write(to: dir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        }
        return dir
    }

    static func customFile(_ kind: SoundKind) -> URL? {
        customExtensions.lazy.map { customFolder.appendingPathComponent("\(kind.rawValue).\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static var playing: [NSSound] = []

    /// Plays a sound directly (previews, custom sounds, and when notifications are off).
    static func play(_ kind: SoundKind, style: String = Settings.shared.soundStyle) {
        let pack = SoundPack(rawValue: style) ?? .synth
        let file = (style == "custom" ? customFile(kind) : nil)
            ?? Bundle.main.url(forResource: pack.fileName(kind), withExtension: nil)
        let sound = file.flatMap { NSSound(contentsOf: $0, byReference: true) } ?? NSSound(data: wav(kind, pack: pack))
        guard let sound else { return }
        playing.removeAll { !$0.isPlaying }
        playing.append(sound)
        sound.play()
    }
}
