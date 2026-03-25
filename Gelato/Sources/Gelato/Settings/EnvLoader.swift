import Foundation

enum EnvLoader {
    static func load() -> [String: String] {
        for url in candidateURLs() {
            guard let data = try? Data(contentsOf: url),
                  let content = String(data: data, encoding: .utf8) else {
                continue
            }
            return parse(content)
        }
        return [:]
    }

    private static func candidateURLs() -> [URL] {
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Gelato/.env")
        let home = fm.homeDirectoryForCurrentUser.appendingPathComponent(".gelato.env")

        return [
            cwd.appendingPathComponent(".env"),
            cwd.deletingLastPathComponent().appendingPathComponent(".env"),
            appSupport,
            home
        ].compactMap { $0 }
    }

    private static func parse(_ content: String) -> [String: String] {
        var result: [String: String] = [:]

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else {
                continue
            }

            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)

            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }

            result[key] = value
        }

        return result
    }
}
