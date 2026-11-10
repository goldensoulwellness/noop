import AVFoundation
import Foundation
#if os(iOS)
import AudioToolbox
import UIKit
#endif

/// "Where's my phone?" from the wrist: a loud chime the phone plays when the strap is double-tapped,
/// the way an Apple Watch pings a lost iPhone. The sound is synthesised in memory (no asset to ship),
/// and on iOS it goes out through the `.playback` category so it is heard with the ring switch on
/// silent — a phone lost under a cushion is usually a phone on silent.
@MainActor
enum PhonePing {
    private static var player: AVAudioPlayer?

    /// Three rising two-note chimes over about three seconds, plus a vibration on iOS.
    static func play() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.duckOthers])
        try? session.setActive(true)
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        #endif
        guard let p = try? AVAudioPlayer(data: chime) else { return }
        p.volume = 1
        p.prepareToPlay()
        p.play()
        player = p
    }

    /// Cached PCM WAV of the chime: 44.1 kHz, mono, 16-bit.
    private static let chime: Data = {
        let rate = 44_100.0
        let total = Int(rate * 3.2)
        var samples = [Int16](repeating: 0, count: total)
        // Each ping: a short A6 then a longer E7, both with a quick decay — bright enough to carry
        // through a bag or a couch, short enough not to be alarming.
        let notes: [(start: Double, hz: Double, len: Double)] = (0..<3).flatMap { i -> [(Double, Double, Double)] in
            let t = Double(i) * 1.0
            return [(t, 1_760, 0.18), (t + 0.16, 2_637, 0.45)]
        }
        for n in notes {
            let from = Int(n.start * rate), count = Int(n.len * rate)
            for k in 0..<count where from + k < total {
                let t = Double(k) / rate
                let env = exp(-t * 7) * min(1, t * 400)
                let v = sin(2 * .pi * n.hz * t) * env * 0.85
                let mixed = Double(samples[from + k]) / 32_767 + v
                samples[from + k] = Int16(max(-1, min(1, mixed)) * 32_767)
            }
        }
        return wav(samples: samples, rate: Int(rate))
    }()

    private static func wav(samples: [Int16], rate: Int) -> Data {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let bytes = samples.count * 2
        d.append("RIFF".data(using: .ascii)!); u32(36 + bytes); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(bytes)
        samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }
}
