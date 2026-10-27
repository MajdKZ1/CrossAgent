#!/usr/bin/env swift
// Records one window (never the whole screen) to a .mov with ScreenCaptureKit.
//
//   swift scripts/record-window.swift <window-id> <seconds> <out.mov> [fps]
//
// The window id is a CGWindowID (the debug app's `windowID` automation command prints
// it). The pointer is never drawn. Needs Screen Recording permission for whatever
// runs this (System Settings > Privacy & Security > Screen Recording).

import AppKit
import AVFoundation
import Foundation
import ScreenCaptureKit

// ScreenCaptureKit needs a window server connection, which a plain script doesn't have.
_ = NSApplication.shared

let args = CommandLine.arguments
guard args.count >= 4, let windowID = UInt32(args[1]), let seconds = Double(args[2]) else {
    FileHandle.standardError.write("usage: record-window.swift <window-id> <seconds> <out.mov> [fps]\n".data(using: .utf8)!)
    exit(2)
}
let out = URL(fileURLWithPath: args[3])
let fps = args.count > 4 ? Int32(args[4]) ?? 60 : 60

final class Delegate: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    var finished: (() -> Void)?
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { finished?() }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        FileHandle.standardError.write("recording failed: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write("stream stopped: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

let delegate = Delegate()

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            FileHandle.standardError.write("no on-screen window with id \(windowID)\n".data(using: .utf8)!)
            exit(1)
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true

        try? FileManager.default.removeItem(at: out)
        let recConfig = SCRecordingOutputConfiguration()
        recConfig.outputURL = out
        recConfig.outputFileType = .mov
        recConfig.videoCodecType = .hevc

        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        let recording = SCRecordingOutput(configuration: recConfig, delegate: delegate)
        try stream.addRecordingOutput(recording)
        try await stream.startCapture()
        FileHandle.standardError.write("recording window \(windowID) (\(config.width)x\(config.height) @ \(fps) fps) for \(seconds) s\n".data(using: .utf8)!)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        delegate.finished = { print(out.path); exit(0) }
        try await stream.stopCapture()
        // Give the file a moment to close if the delegate callback is slow.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        print(out.path)
        exit(0)
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}
RunLoop.main.run()
