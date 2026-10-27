import AppKit
import SwiftUI

/// Dev only. Every mood side by side, live, in `MascotGalleryView`, plus PNG stills.
enum MascotGallery {
    static let samples: [(name: String, mood: MascotMood)] = [
        ("idle", .idle),
        ("thinking", .thinking),
        ("working", .working),
        ("bobbing", .bobbing(orb: MascotOrb(id: "a", host: "pc"))),
        ("juggling", .juggling(orbs: [MascotOrb(id: "a", host: "mac"), MascotOrb(id: "b", host: "pc"),
                                      MascotOrb(id: "c", host: "pc"), MascotOrb(id: "d", host: "mac")])),
        ("needsInput", .needsInput),
        ("done", .done),
        ("error", .error),
        ("sleeping", .sleeping),
    ]

    /// CROSSAGENT_MASCOT_GALLERY=1 asks for the gallery. The app opens it as a dev tab.
    static var isRequested: Bool { ProcessInfo.processInfo.environment["CROSSAGENT_MASCOT_GALLERY"] == "1" }

    /// CROSSAGENT_MASCOT_SNAPSHOT=<dir> writes stills and quits.
    @MainActor static func writeSnapshotsIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["CROSSAGENT_MASCOT_SNAPSHOT"], !dir.isEmpty else { return }
        writeSnapshots(to: URL(fileURLWithPath: dir))
        NSApp.terminate(nil)
    }

    /// One PNG per mood at 512 px on the reference's dark backdrop, plus a contact sheet.
    @MainActor static func writeSnapshots(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let backdrop = NSColor(hex: "#0b0b0b").cgColor
        var stills: [CGImage] = []
        for s in samples {
            guard let img = MascotRig.still(s.mood, side: 512, background: backdrop) else { continue }
            write(img, to: dir.appendingPathComponent("\(s.name).png"))
            if let small = MascotRig.still(s.mood, side: 240, background: backdrop) { stills.append(small) }
        }
        if let sheet = contactSheet(stills, columns: 3) { write(sheet, to: dir.appendingPathComponent("sheet.png")) }
    }

    private static func contactSheet(_ images: [CGImage], columns: Int) -> CGImage? {
        guard let first = images.first else { return nil }
        let w = first.width, h = first.height
        let rows = (images.count + columns - 1) / columns
        guard let ctx = CGContext(data: nil, width: w * columns, height: h * rows, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for (i, img) in images.enumerated() {
            let r = i / columns, c = i % columns
            ctx.draw(img, in: CGRect(x: c * w, y: (rows - 1 - r) * h, width: w, height: h))
        }
        return ctx.makeImage()
    }

    private static func write(_ image: CGImage, to url: URL) {
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// Every mood animating side by side, at the canvas size and big. Click them to try the tricks.
struct MascotGalleryView: View {
    /// Show just this mood (by name) instead of all of them. Defaults to CROSSAGENT_MASCOT_GALLERY_STATE.
    var only: String? = ProcessInfo.processInfo.environment["CROSSAGENT_MASCOT_GALLERY_STATE"]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                ForEach(MascotGallery.samples.filter { only == nil || $0.name == only }, id: \.name) { s in
                    VStack(spacing: 8) {
                        HStack(alignment: .bottom, spacing: 14) {
                            MascotLayer(source: .fixed(s.mood), scale: 0.75)
                            MascotLayer(source: .fixed(s.mood), scale: 1.5)
                        }
                        Text(s.name).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: Palette.radius).fill(Palette.pane))
                }
            }
            .padding(16)
        }
        .background(Palette.window)
    }
}
