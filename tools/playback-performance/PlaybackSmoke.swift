import AppKit
import AVFoundation
import Foundation

@main struct PlaybackSmoke {
    @MainActor static func main() async throws {
        precondition(CommandLine.arguments.count == 2, "Pass a local video of at least 12 seconds")
        let fixture = URL(filePath: CommandLine.arguments[1])
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let defaults = UserDefaults.standard
        let keys = ["lastMediaPath", "playerWorkspaceMode", "videoAppearance", "videoAppearanceEnabled"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        var models: [AppModel] = (0..<3).map { _ in AppModel(autoloadLastVideo: false) }
        weak var releasedModel = models[2]
        let layers = models.map { model in
            model.openLibraryVideo(fixture)
            model.videoAppearance = VideoAppearance()
            let layer = AVPlayerLayer(player: model.player)
            layer.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
            model.player.play()
            return layer
        }
        try await Task.sleep(for: .seconds(4))
        let times = models.map { $0.player.currentTime().seconds }
        precondition(times.allSatisfy { $0.isFinite && $0 > 1 }, "all 3 players must advance: \(times)")
        print("PASS: three concurrent AVPlayers advance: \(times)")
        models[0].videoAppearance = VideoAppearance(contrast: 1.15, saturation: 1.2, sharpness: 0.5)
        models[1].seekVideo(to: 6)
        models[2].closePlayerWindow()
        precondition(models[2].player.currentItem == nil)
        layers[2].player = nil
        models.removeLast()
        try await Task.sleep(for: .seconds(3))
        precondition(releasedModel == nil, "closed idle model must release; background tasks must not retain it")
        precondition(models[0].player.currentTime().seconds > times[0] + 1)
        precondition(models[1].player.currentTime().seconds >= 6)
        precondition(models[0].player.currentItem?.videoComposition != nil)
        precondition(models[1].player.currentItem?.videoComposition == nil)
        print("PASS: independent effects and seek; closing third player releases its model and decoder")
        for model in models { model.closePlayerWindow() }
        for layer in layers { layer.player = nil }
        print("PASS: all players cleaned up")
    }
}
