import AppKit
import AVFoundation

enum TapSoundChoice: String, CaseIterable {
    case thock, click, pop, wood, boop, squeak

    var title: String {
        switch self {
        case .thock: return "Thock"
        case .click: return "Click"
        case .pop: return "Pop"
        case .wood: return "Wood block"
        case .boop: return "Boop"
        case .squeak: return "Squeak"
        }
    }
}

final class TapSound {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffers: [TapSoundChoice: AVAudioPCMBuffer] = [:]
    private var choice: TapSoundChoice
    private var idleStop: DispatchWorkItem?

    var enabled = true

    init(_ choice: TapSoundChoice = Preferences.tapSound) {
        self.choice = choice
        for c in TapSoundChoice.allCases {
            if let buffer = TapSound.read(c) {
                buffers[c] = buffer
            }
        }
        engine.attach(player)
        let format = buffers.values.first?.format ?? AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    func load(_ choice: TapSoundChoice) {
        self.choice = choice
    }

    func warm() {
        start()
    }

    func play() {
        guard enabled, let buffer = buffers[choice] else {
            return
        }
        start()
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying {
            player.play()
        }
    }

    private func start() {
        if !engine.isRunning {
            try? engine.start()
        }
        idleStop?.cancel()
        let stop = DispatchWorkItem { [weak self] in
            self?.player.stop()
            self?.engine.pause()
        }
        idleStop = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: stop)
    }

    private static func read(_ choice: TapSoundChoice) -> AVAudioPCMBuffer? {
        let name = "tap_\(choice.rawValue)"
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [
            Bundle.main.url(forResource: name, withExtension: "wav"),
            exeDir.appendingPathComponent("\(name).wav"),
            exeDir.appendingPathComponent("assets/sounds/\(name).wav"),
            URL(fileURLWithPath: "assets/sounds/\(name).wav"),
        ].compactMap { $0 }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            guard let file = try? AVAudioFile(forReading: url),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                continue
            }
            if (try? file.read(into: buffer)) != nil {
                return buffer
            }
        }
        return nil
    }
}
