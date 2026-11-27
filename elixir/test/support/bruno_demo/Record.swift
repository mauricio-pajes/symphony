import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

final class RecordingDelegate: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    var finished = false

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("Screen stream stopped: \(error.localizedDescription)\n", stderr)
    }

    func recordingOutputDidFinishRecording(_ output: SCRecordingOutput) {
        finished = true
    }

    func recordingOutput(_ output: SCRecordingOutput, didFailWithError error: Error) {
        fputs("Recording failed: \(error.localizedDescription)\n", stderr)
        exit(2)
    }
}

@main
struct Main {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let arguments = CommandLine.arguments
        guard arguments.count == 6, let windowID = UInt32(arguments[1]),
              let duration = Double(arguments[5]), duration > 0
        else {
            fputs("Usage: record WINDOW_ID OUTPUT.mp4 STOPFILE x,y,width,height seconds\n", stderr)
            exit(1)
        }

        let coordinates = arguments[4].split(separator: ",").compactMap { Double($0) }
        let destination = URL(fileURLWithPath: arguments[2])
        let stopPath = arguments[3]
        let files = FileManager.default
        guard coordinates.count == 4, coordinates[2] > 0, coordinates[3] > 0,
              !files.fileExists(atPath: destination.path), !files.fileExists(atPath: stopPath)
        else {
            fputs("Use a positive crop and fresh output paths.\n", stderr)
            exit(1)
        }

        let crop = CGRect(x: coordinates[0], y: coordinates[1], width: coordinates[2], height: coordinates[3])
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            fputs("Bruno window is no longer available.\n", stderr)
            exit(3)
        }

        let config = SCStreamConfiguration()
        config.width = Int(crop.width * 2)
        config.height = Int(crop.height * 2)
        config.sourceRect = crop
        config.minimumFrameInterval = CMTime(value: 1, timescale: 12)
        config.showsCursor = true
        config.showMouseClicks = false
        config.capturesAudio = false
        config.captureMicrophone = false
        config.includeChildWindows = false
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        config.shouldBeOpaque = true

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let delegate = RecordingDelegate()
        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        let outputConfiguration = SCRecordingOutputConfiguration()
        outputConfiguration.outputURL = destination
        outputConfiguration.videoCodecType = .h264
        outputConfiguration.outputFileType = .mp4
        try stream.addRecordingOutput(SCRecordingOutput(configuration: outputConfiguration, delegate: delegate))
        try await stream.startCapture()
        print("READY \(windowID)")
        fflush(stdout)

        let deadline = Date().addingTimeInterval(duration)
        while !delegate.finished && Date() < deadline && !files.fileExists(atPath: stopPath) {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        if !delegate.finished {
            try await stream.stopCapture()
            for _ in 0..<80 {
                if delegate.finished { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        guard delegate.finished else {
            fputs("Recording could not be finalized.\n", stderr)
            exit(4)
        }
        print("FINALIZED \(destination.path)")
    }
}
