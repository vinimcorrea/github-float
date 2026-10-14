import AppKit
import Foundation

/// Original synthesized UI sounds, one per kind of event. Rendered to WAV at build time (`--render-sounds`)
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

    /// Notes as (frequency Hz, start s, duration s, gain).
    fileprivate var notes: [(Double, Double, Double, Double)] {
        switch self {
        case .attention: return [(659.25, 0, 0.11, 0.8), (987.77, 0.09, 0.30, 0.9)]
        case .good: return [(523.25, 0, 0.12, 0.6), (659.25, 0.07, 0.12, 0.65), (783.99, 0.14, 0.14, 0.7), (1046.5, 0.21, 0.45, 0.75)]
        case .bad: return [(392.0, 0, 0.16, 0.85), (293.66, 0.13, 0.40, 0.9)]
        case .info: return [(1760.0, 0, 0.22, 0.45)]
        }
    }

    /// Metallic FM shimmer amount and its ratio.
    fileprivate var fm: (index: Double, ratio: Double) {
        switch self {
        case .attention: return (1.2, 2.0)
        case .good: return (0.8, 3.0)
        case .bad: return (2.2, 1.5)
        case .info: return (0.6, 3.5)
        }
    }
}

enum Sounds {
    static let sampleRate = 44_100.0

    static func samples(_ kind: SoundKind) -> [Float] {
        let tail = 0.45
        let length = (kind.notes.map { $0.1 + $0.2 }.max() ?? 0) + tail
        var out = [Double](repeating: 0, count: Int(length * sampleRate))
        let (index, ratio) = kind.fm

        for (freq, start, dur, gain) in kind.notes {
            let s0 = Int(start * sampleRate)
            let n = Int((dur + 0.25) * sampleRate)
            for i in 0..<n where s0 + i < out.count {
                let t = Double(i) / sampleRate
                let attack = min(1, t / 0.004)
                let env = attack * exp(-t / (dur * 0.45))
                let modEnv = exp(-t / 0.06)
                let mod = index * modEnv * sin(2 * .pi * freq * ratio * t)
                let tone = sin(2 * .pi * freq * t + mod) + 0.25 * sin(2 * .pi * freq * 2.001 * t) * exp(-t / 0.05)
                out[s0 + i] += gain * env * tone
            }
        }

        // Ping-pong-ish echo for a spacious, "sci-fi console" tail.
        let delay = Int(0.11 * sampleRate)
        for i in delay..<out.count { out[i] += 0.32 * out[i - delay] }

        // Gentle one-pole low-pass to take the edge off.
        var y = 0.0
        let a = 0.5
        for i in out.indices { y += a * (out[i] - y); out[i] = y }

        // Normalize and fade out.
        let peak = out.map(abs).max() ?? 1
        let fade = Int(0.05 * sampleRate)
        return out.enumerated().map { i, v in
            let f = i > out.count - fade ? Double(out.count - i) / Double(fade) : 1
            return Float(v / peak * 0.7 * f)
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
