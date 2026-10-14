import AppKit
import Foundation

/// Original 8-bit (chiptune) sounds, one per kind of event. Rendered to WAV at build time (`--render-sounds`)
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

    /// The original 8-bit "score" of each sound.
    fileprivate var notes: [Note] {
        switch self {
        case .attention:
            // Two bright blips and a held top note: "hey, over here!"
            return [Note(.e6, at: 0, for: 0.055, wave: .pulse25),
                    Note(.e6, at: 0.075, for: 0.055, wave: .pulse25),
                    Note(.a6, at: 0.15, for: 0.26, wave: .pulse25, vibrato: true)]
        case .good:
            // Fast rising arpeggio that lands on a shimmering high note.
            let run: [Double] = [.c5, .e5, .g5, .c6, .e6, .g6]
            return run.enumerated().map { Note($1, at: Double($0) * 0.045, for: 0.05, wave: .pulse12) }
                + [Note(.c7, at: 0.27, for: 0.32, wave: .pulse12, gain: 0.8, vibrato: true),
                   Note(.c5, at: 0.27, for: 0.32, wave: .triangle, gain: 0.9)]
        case .bad:
            // A falling "wah-wah": two low notes and a sliding drop.
            return [Note(.g4, at: 0, for: 0.12, wave: .pulse50),
                    Note(.d4s, at: 0.14, for: 0.12, wave: .pulse50),
                    Note(.c4, at: 0.28, for: 0.34, wave: .pulse50, slideTo: 196.0 * 0.75, vibrato: true),
                    Note(.c3, at: 0.28, for: 0.34, wave: .triangle, gain: 0.9)]
        case .info:
            // A tiny upward "bloop".
            return [Note(880, at: 0, for: 0.07, wave: .pulse25, slideTo: 1568),
                    Note(.g6, at: 0.08, for: 0.06, wave: .pulse25, gain: 0.6)]
        }
    }
}

enum Wave { case pulse12, pulse25, pulse50, triangle }

struct Note {
    let freq: Double, start: Double, dur: Double, wave: Wave, gain: Double, slideTo: Double?, vibrato: Bool
    init(_ freq: Double, at start: Double, for dur: Double, wave: Wave, gain: Double = 1, slideTo: Double? = nil, vibrato: Bool = false) {
        (self.freq, self.start, self.dur, self.wave, self.gain, self.slideTo, self.vibrato) = (freq, start, dur, wave, gain, slideTo, vibrato)
    }
}

private extension Double {
    static let c3 = 130.81, c4 = 261.63, d4s = 311.13, g4 = 392.0
    static let c5 = 523.25, e5 = 659.25, g5 = 783.99
    static let c6 = 1046.5, e6 = 1318.51, g6 = 1567.98, a6 = 1760.0, c7 = 2093.0
}

enum Sounds {
    static let sampleRate = 44_100.0

    static func samples(_ kind: SoundKind) -> [Float] {
        let length = (kind.notes.map { $0.start + $0.dur }.max() ?? 0) + 0.03
        var out = [Double](repeating: 0, count: Int(length * sampleRate))

        for note in kind.notes {
            let s0 = Int(note.start * sampleRate)
            let n = Int(note.dur * sampleRate)
            var phase = 0.0
            for i in 0..<n where s0 + i < out.count {
                let t = Double(i) / sampleRate
                let progress = Double(i) / Double(n)
                var f = note.slideTo.map { note.freq * pow($0 / note.freq, progress) } ?? note.freq
                if note.vibrato, t > 0.06 { f *= 1 + 0.012 * sin(2 * .pi * 9 * t) }
                phase = (phase + f / sampleRate).truncatingRemainder(dividingBy: 1)
                let v: Double
                switch note.wave {
                case .pulse12: v = phase < 0.125 ? 1 : -1
                case .pulse25: v = phase < 0.25 ? 1 : -1
                case .pulse50: v = phase < 0.5 ? 1 : -1
                case .triangle: v = 4 * abs(phase - 0.5) - 1
                }
                // NES-style stepped volume: quick attack, short sustain, linear release in 16 steps.
                let release = max(0, (progress - 0.55) / 0.45)
                let env = min(1, t / 0.003) * (1 - (release * 15).rounded(.down) / 16)
                let level = note.wave == .triangle ? 0.55 : 0.32
                out[s0 + i] += level * note.gain * env * v
            }
        }

        // Light smoothing so square edges don't sound harsh on laptop speakers.
        var y = 0.0
        for i in out.indices { y += 0.6 * (out[i] - y); out[i] = y }

        let peak = out.map(abs).max() ?? 1
        let fade = Int(0.01 * sampleRate)
        return out.enumerated().map { i, v in
            let f = i > out.count - fade ? Double(out.count - i) / Double(fade) : 1
            return Float(v / peak * 0.6 * f)
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
