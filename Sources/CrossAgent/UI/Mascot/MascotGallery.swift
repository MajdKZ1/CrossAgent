import AppKit
import SwiftUI

/// Dev only. CROSSAGENT_MASCOT_GALLERY=1 opens a window with every mood at 1x and 2x.
/// CROSSAGENT_MASCOT_GALLERY_STATE=<name> shows just that one.
/// CROSSAGENT_MASCOT_SNAPSHOT=<dir> writes PNGs of the gallery and a frame sheet, then quits.
enum MascotGallery {
    static let samples: [(name: String, mood: MascotMood)] = [
        ("idle", .idle),
        ("thinking", .thinking),
        ("working", .working),
        ("bobbing", .bobbing(orb: "pc")),
        ("juggling", .juggling(orbs: ["mac", "pc", "pc", "mac", "pc"])),
        ("needsInput", .needsInput),
        ("done", .done),
        ("error", .error),
        ("sleeping", .sleeping),
    ]

    private static var window: NSWindow?

    @MainActor static func openIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["CROSSAGENT_MASCOT_SNAPSHOT"], !dir.isEmpty {
            writeSnapshots(to: URL(fileURLWithPath: dir))
            NSApp.terminate(nil)
            return
        }
        guard env["CROSSAGENT_MASCOT_GALLERY"] == "1" else { return }
        let only = env["CROSSAGENT_MASCOT_GALLERY_STATE"]
        let list = samples.filter { only == nil || $0.name == only }

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Patch"
        w.isReleasedWhenClosed = false
        w.backgroundColor = Theme.window
        w.contentView = NSHostingView(rootView: GalleryView(samples: list, live: true, date: Date()))
        w.center()
        // Stay out of the way: behind whatever the user is doing.
        w.orderBack(nil)
        window = w
    }

    /// Gallery at a few moments, plus every frame of every mood at 4x.
    @MainActor static func writeSnapshots(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        for k in 0..<4 {
            let view = GalleryView(samples: samples, live: false, date: start.addingTimeInterval(Double(k) * 0.37))
            write(view, to: dir.appendingPathComponent("gallery-\(k).png"))
        }
        write(FrameSheet(), to: dir.appendingPathComponent("frames.png"))
    }

    @MainActor private static func write<V: View>(_ view: V, to url: URL) {
        let r = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        r.scale = 1
        guard let cg = r.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}

private struct GalleryView: View {
    var samples: [(name: String, mood: MascotMood)]
    /// Live animates; otherwise draws the frame at `date`.
    var live: Bool
    var date: Date

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
            ForEach(samples, id: \.name) { s in
                VStack(spacing: 8) {
                    HStack(alignment: .bottom, spacing: 14) {
                        sprite(s.mood, scale: 1)
                        sprite(s.mood, scale: 2)
                    }
                    Text(s.name).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: Palette.radius).fill(Palette.pane))
            }
        }
        .padding(16)
        .frame(width: 720)
        .background(Palette.window)
    }

    @ViewBuilder private func sprite(_ mood: MascotMood, scale: CGFloat) -> some View {
        if live {
            MascotSprite(source: .fixed(mood), scale: scale)
        } else {
            let s = MascotSource.fixed(mood).state(at: date)
            MascotCanvas(mood: s.mood, frame: s.frame, scale: scale)
        }
    }
}

/// Every frame of every mood in a row, big, for judging the art.
private struct FrameSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(MascotGallery.samples, id: \.name) { s in
                HStack(spacing: 4) {
                    Text(s.name).font(.system(size: 10)).foregroundStyle(Palette.muted).frame(width: 70, alignment: .leading)
                    ForEach(0..<min(MascotArt.script(s.mood).frames.count, 15), id: \.self) { i in
                        MascotCanvas(mood: s.mood, frame: i, scale: 4)
                            .background(Palette.pane)
                    }
                }
            }
        }
        .padding(10)
        .background(Palette.window)
    }
}
