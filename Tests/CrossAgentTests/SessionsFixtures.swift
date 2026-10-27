import Foundation
@testable import CrossAgent

/// Scrubbed samples from throwaway Claude Code 2.1.311 sessions:
/// - background: `claude -p` on the Mac, two background Agent calls (named reader, lister).
/// - teammate: interactive on the Mac in tmux, a permission prompt, an AskUserQuestion
///   and one in-process teammate (sleeper).
/// - foreground: `claude -p` on the PC, two foreground Agent calls with no name field.
enum SessionsFixtures {
    struct Sample {
        var dir: String
        var sessionId: String
        var cwd: String
    }

    static let background = Sample(dir: "background", sessionId: "c9bc5b47-e5f7-49b4-9c45-82855815aa07", cwd: "/private/tmp/ca-sess-probe")
    static let teammate = Sample(dir: "teammate", sessionId: "a5772ce1-8e92-4d0e-abca-380eb673cf9e", cwd: "/private/tmp/ca-sess-probe2")
    static let foreground = Sample(dir: "foreground", sessionId: "652c9655-d89d-475a-a59e-9b64d19a30f4", cwd: "/tmp/ca-sess-probe-pc")
    static let all = [background, teammate, foreground]

    static var base: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("Sessions")
    }

    static func data(_ path: String) -> Data {
        try! Data(contentsOf: base.appendingPathComponent(path))
    }

    static func lines(_ path: String) -> [Data] {
        data(path).split(separator: 0x0A).map { Data($0) }
    }

    /// Subagent files of a sample: agentId to (lines, meta).
    static func subagents(_ s: Sample) -> [(id: String, lines: [Data], meta: SubagentMeta)] {
        let dir = base.appendingPathComponent(s.dir + "/subagents")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") }.sorted().compactMap { n in
            guard let id = ClaudePaths.agentId(fileName: n),
                  let meta = SubagentMeta.parse(data("\(s.dir)/subagents/agent-\(id).meta.json")) else { return nil }
            return (id, lines("\(s.dir)/subagents/\(n)"), meta)
        }
    }

    /// Every item of a sample, main and subagents, in time order, as a feed sees them.
    static func items(_ s: Sample) -> [TranscriptItem] {
        var p = TranscriptParser()
        var out = p.parse(lines: lines(s.dir + "/main.jsonl"))
        for sub in subagents(s) {
            var sp = TranscriptParser(agentId: sub.id)
            out += sp.parse(lines: sub.lines)
        }
        FeedDecoder.sortItems(&out)
        return out
    }

    /// A fake ~/.claude with all three samples under projects/. Caller removes it.
    static func makeRoot() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ca-sessions-test-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        for s in all {
            let proj = root.appendingPathComponent("projects/" + ClaudePaths.projectSlug(cwd: s.cwd))
            let subs = proj.appendingPathComponent(s.sessionId + "/subagents")
            try fm.createDirectory(at: subs, withIntermediateDirectories: true)
            try data(s.dir + "/main.jsonl").write(to: proj.appendingPathComponent(s.sessionId + ".jsonl"))
            let src = base.appendingPathComponent(s.dir + "/subagents")
            for n in try fm.contentsOfDirectory(atPath: src.path) {
                try fm.copyItem(at: src.appendingPathComponent(n), to: subs.appendingPathComponent(n))
            }
        }
        return root
    }
}
