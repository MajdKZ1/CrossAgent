import SwiftUI

/// Both machines as one computer: combined numbers on top, then one half per machine,
/// joined at the seam by the Crossover Portal. Equatable on the combined model, so it
/// only rebuilds when a number it shows can have changed.
struct SuperMaxCard: View, Equatable {
    var model: SuperMax

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            totals
            halves
            Text(tagline)
                .font(.system(size: 11))
                .foregroundStyle(Palette.faint)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: Palette.radius + 2, style: .continuous)
                .fill(Palette.pane)
                .overlay(
                    // A faint wash of each machine's colour from its own side.
                    RoundedRectangle(cornerRadius: Palette.radius + 2, style: .continuous)
                        .fill(LinearGradient(colors: wash, startPoint: .leading, endPoint: .trailing))
                )
        )
        .overlay(RoundedRectangle(cornerRadius: Palette.radius + 2, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
    }

    private var wash: [Color] {
        let colors = model.machines.map { SuperMaxColor.accent($0).opacity($0.online ? 0.05 : 0.015) }
        return colors.count >= 2 ? [colors.first!, .clear, colors.last!] : [.clear, .clear]
    }

    private var tagline: String {
        let n = model.machines.count
        return n == 2 ? "Two machines working as one through CrossAgent" : "\(n) machines working as one through CrossAgent"
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("SUPER-MAX COMPUTER")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Palette.text)
            Spacer()
            Text("\(model.online) of \(model.machines.count) online")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(model.online == model.machines.count ? Palette.muted : Palette.warning)
        }
    }

    // MARK: Totals

    private var totals: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 12) {
            Stat(label: "Cores", value: model.threads > 0 ? SuperMaxFormat.coresThreads(model.cores, model.threads) : "--",
                 detail: model.machines.filter(\.online).compactMap { m in m.specs.map { "\(m.name) \($0.cores)c" } }.joined(separator: " + "))
            Stat(label: "CPU", value: SuperMaxFormat.percent(model.cpu),
                 color: model.cpu.map { ActivityColor.level(LoadLevel.cpu($0)) }, detail: "weighted by threads")
            Stat(label: "Memory", value: model.memTotal > 0 ? SuperMaxFormat.memPair(model.memUsed, model.memTotal) : "--",
                 color: model.memTotal > 0 ? ActivityColor.level(LoadLevel.mem(Double(model.memUsed) / Double(model.memTotal))) : nil,
                 detail: model.memTotal > 0 ? "\(SuperMaxFormat.percent(Double(model.memUsed) / Double(model.memTotal))) used" : " ")
            gpuStat
            Stat(label: "Storage", value: model.diskTotal > 0 ? SuperMaxFormat.storage(model.diskFree) : "--",
                 detail: model.diskTotal > 0 ? "free of \(SuperMaxFormat.storage(model.diskTotal))" : " ")
            Stat(label: "Peak temp", value: model.peak.map { ActivityFormat.degrees($0.celsius.rounded()) } ?? "--",
                 color: model.peak.map { ActivityColor.level(LoadLevel.temp($0.temp)) },
                 detail: model.peak.map { "\($0.machine) \($0.temp.label)" } ?? " ")
        }
    }

    private var gpuStat: some View {
        let unified = model.unifiedTotal > 0 ? "\(SuperMaxFormat.gibNumber(model.unifiedTotal)) GB unified" : nil
        let count = model.gpuCount == 1 ? "1 GPU" : "\(model.gpuCount) GPUs"
        if model.vramTotal > 0 {
            let used = model.vramUsed.map { SuperMaxFormat.gibNumber($0) + " / " } ?? ""
            return Stat(label: "VRAM", value: "\(used)\(SuperMaxFormat.gibNumber(model.vramTotal)) GB",
                        detail: [unified.map { "+ \($0)" }, count].compactMap { $0 }.joined(separator: " · "))
        }
        return Stat(label: "GPU memory", value: unified ?? "--", detail: model.gpuCount > 0 ? count : " ")
    }

    // MARK: Halves

    private var halves: some View {
        HStack(alignment: .center, spacing: 0) {
            ForEach(Array(model.machines.enumerated()), id: \.element.id) { i, m in
                if i > 0 { seam(model.machines[i - 1], m) }
                MachineHalf(machine: m).frame(maxWidth: .infinity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The hairline between two halves with the portal ring on it.
    private func seam(_ a: SuperMax.Machine, _ b: SuperMax.Machine) -> some View {
        VStack(spacing: 6) {
            Rectangle().fill(Palette.hairline).frame(width: 1)
            PortalRing(state: a.online && b.online ? .steady : .off, size: 26,
                       leading: SuperMaxColor.accent(a), trailing: SuperMaxColor.accent(b))
                .help(a.online && b.online ? "Crossover Portal: linked" : "Crossover Portal: waiting for both machines")
            Rectangle().fill(Palette.hairline).frame(width: 1)
        }
        .frame(width: 96)
    }
}

enum SuperMaxColor {
    /// The machine's host colour, with the theme's override when it has one.
    static func accent(_ m: SuperMax.Machine) -> Color {
        Palette.accent(Host(id: m.id, name: m.name, type: .local, target: nil, accent: m.accent))
    }
}

/// One big number with a small label above and a line of detail below.
private struct Stat: View {
    var label: String
    var value: String
    var color: Color?
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Palette.faint)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(value == "--" ? Palette.faint : (color ?? Palette.text))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One machine's side of the card.
private struct MachineHalf: View {
    var machine: SuperMax.Machine

    private var m: SuperMax.Machine { machine }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Dot(color: m.online ? SuperMaxColor.accent(m) : Palette.faint, size: 8)
                Text(m.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.text)
                Text(m.specs.map { SuperMaxFormat.cpuName($0.cpuModel) } ?? "")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if !m.online {
                    Text(m.note ?? "offline").font(.system(size: 11)).foregroundStyle(Palette.faint).lineLimit(1)
                }
            }
            row("CPU", m.specs.map { SuperMaxFormat.coresThreads($0.cores, $0.threads) } ?? "--",
                right: SuperMaxFormat.percent(m.cpu), fraction: m.cpu, level: m.cpu.map(LoadLevel.cpu))
            let memFrac = m.memUsed.map { m.memTotal > 0 ? Double($0) / Double(m.memTotal) : 0 }
            row("Memory", m.memUsed.map { SuperMaxFormat.memPair($0, m.memTotal) } ?? (m.memTotal > 0 ? "\(SuperMaxFormat.gibNumber(m.memTotal)) GB" : "--"),
                right: memFrac.map { SuperMaxFormat.percent($0) } ?? "", fraction: memFrac, level: memFrac.map(LoadLevel.mem))
            ForEach(Array(m.gpus.enumerated()), id: \.offset) { _, g in gpuRow(g) }
            let diskFrac = m.diskFree.flatMap { free in m.diskTotal.map { $0 > 0 ? 1 - Double(free) / Double($0) : 0 } }
            row("Disk", m.diskFree.map { "\(SuperMaxFormat.storage($0)) free" } ?? "--",
                right: m.diskTotal.map { "of \(SuperMaxFormat.storage($0))" } ?? "", fraction: diskFrac,
                level: diskFrac.map { LoadLevel.of($0, warn: 0.85, danger: 0.95) }, rightColor: Palette.muted)
            row("Hottest", m.peak.map { "\(ActivityFormat.degrees($0.celsius.rounded())) \($0.label)" } ?? "--",
                right: "", fraction: nil, level: nil, valueColor: m.peak.map { ActivityColor.level(LoadLevel.temp($0)) })
        }
        .padding(.horizontal, 4)
        .opacity(m.online ? 1 : 0.6)
    }

    private func gpuRow(_ g: SuperMax.GPU) -> some View {
        var name = SuperMaxFormat.gpuName(g.name)
        if let c = g.cores { name += " · \(c)-core" }
        let mem: String? = g.unified
            ? g.memUsed.map { "\(ActivityFormat.bytes($0)) in use" }
            : g.memTotal.map { t in g.memUsed.map { "\(SuperMaxFormat.gibNumber($0)) / \(SuperMaxFormat.gibNumber(t)) GB VRAM" } ?? "\(SuperMaxFormat.gibNumber(t)) GB VRAM" }
        return VStack(alignment: .leading, spacing: 3) {
            row("GPU", name, right: g.util.map { SuperMaxFormat.percent($0) } ?? "", fraction: g.util, level: g.util.map(LoadLevel.cpu))
            if let mem {
                HStack(spacing: 0) {
                    Spacer().frame(width: 62)
                    Text(mem + (g.unified ? " (unified)" : "")).foregroundStyle(Palette.faint)
                    Spacer(minLength: 4)
                    if let c = g.celsius { Text(ActivityFormat.degrees(c.rounded())).foregroundStyle(Palette.faint) }
                }
                .font(.system(size: 10.5).monospacedDigit())
                .lineLimit(1)
            }
        }
    }

    private func row(_ label: String, _ value: String, right: String, fraction: Double?, level: Int?,
                     valueColor: Color? = nil, rightColor: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Text(label).foregroundStyle(Palette.muted).frame(width: 62, alignment: .leading)
                Text(value).foregroundStyle(valueColor ?? Palette.text).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                Text(right).foregroundStyle(rightColor ?? level.map(ActivityColor.level) ?? Palette.muted)
            }
            .font(.system(size: 11.5).monospacedDigit())
            if let fraction {
                MiniBar(fraction: fraction, color: ActivityColor.level(level ?? 0)).padding(.leading, 62)
            }
        }
    }
}

/// A 3 pt track with a fill. Static shapes, no animation.
private struct MiniBar: View {
    var fraction: Double
    var color: Color

    var body: some View {
        GeometryReader { geo in
            Capsule().fill(Palette.chip)
                .overlay(alignment: .leading) {
                    Capsule().fill(color.opacity(0.85)).frame(width: max(3, geo.size.width * min(1, max(0, fraction))))
                }
        }
        .frame(height: 3)
    }
}
