// HiddenBlocksApp.swift — app entry point.
//
// Sets up the audio session so project sound plays even with the
// silent switch on, and so the editor's sound recorder can capture
// the microphone (video sensing / sound recording features).

import SwiftUI
import AVFoundation

@main
struct HiddenBlocksApp: App {
    init() {
        // .playAndRecord (not .playback) because the editor both plays
        // project audio and records via getUserMedia (sound recorder,
        // video-sensing audio). Default to speaker so playback is loud.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            // Audio is best-effort at launch; the web view will retry
            // when the editor first plays or records sound.
            print("HiddenBlocks: audio session setup failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
