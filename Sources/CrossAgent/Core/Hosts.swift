import Foundation

struct Host: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case local, ssh }

    var id: String
    var name: String
    var type: Kind
    var target: String?
    var accent: String

    var isLocal: Bool { type == .local }
}

struct HostsFile: Codable {
    var hosts: [Host]
}

enum HostStore {
    static let defaults: [Host] = [
        Host(id: "mac", name: "This Mac", type: .local, target: nil, accent: "#6ea8fe"),
        Host(id: "pc", name: "Linux PC", type: .ssh, target: "pc", accent: "#5fd39a"),
    ]

    static var configDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/crossagent", isDirectory: true)
    }

    static var fileURL: URL { configDir.appendingPathComponent("hosts.json") }

    /// Loads hosts.json, writing the defaults first if it does not exist yet.
    static func load() -> [Host] {
        let url = fileURL
        if let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(HostsFile.self, from: data),
           !file.hosts.isEmpty {
            return file.hosts.filter { SessionName.isValid($0.id) }
        }
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if !FileManager.default.fileExists(atPath: url.path),
           let data = try? enc.encode(HostsFile(hosts: defaults)) {
            try? data.write(to: url)
        }
        return defaults
    }
}
