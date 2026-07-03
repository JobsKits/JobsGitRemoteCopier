//
//  GitRemoteResolver.swift
//  JobsGitRemoteCopyFinderSync
//
//  Created by Jobs on 2026年6月27日，星期六.
//

import Foundation

struct GitRemoteResolver {
    func remoteURLString(from folderURL: URL) throws -> String {
        let repositoryURL = try repositoryRoot(startingAt: folderURL)

        do {
            return try preferredRemoteURLString(from: repositoryURL)
        } catch {
            if let fallbackRemoteURLString = submoduleRemoteURL(for: repositoryURL) {
                return fallbackRemoteURLString
            } else {
                throw error
            }
        }
    }

    func webURL(from folderURL: URL) throws -> URL {
        try webURL(fromRemoteURLString: remoteURLString(from: folderURL))
    }
}

private extension GitRemoteResolver {
    func preferredRemoteURLString(from repositoryURL: URL) throws -> String {
        let gitDirectoryURL = try gitDirectoryURL(for: repositoryURL)
        let config = try gitConfig(from: gitDirectoryURL)
        let branchName = branchName(from: gitDirectoryURL)
        return try config.preferredRemoteURL(branchName: branchName)
    }

    enum ResolverError: LocalizedError {
        case notGitRepository(URL)
        case missingConfig(URL)
        case missingRemote(URL)
        case unsupportedRemoteURL(String)

        var errorDescription: String? {
            switch self {
            case .notGitRepository(let url):
                return "不是 Git 仓库或仓库子目录：\(url.path)"
            case .missingConfig(let url):
                return "没有找到 Git 配置文件：\(url.path)"
            case .missingRemote(let url):
                return "仓库没有配置 remote：\(url.path)"
            case .unsupportedRemoteURL(let remoteURL):
                return "暂不支持这个 remote 地址：\(remoteURL)"
            }
        }
    }

    struct GitConfig {
        var branchRemotes: [String: String] = [:]
        var remoteURLs: [String: String] = [:]
        var remoteOrder: [String] = []
        var submodulePaths: [String: String] = [:]
        var submoduleURLs: [String: String] = [:]
        var submoduleOrder: [String] = []

        func preferredRemoteURL(branchName: String?) throws -> String {
            if let branchName, let remoteName = branchRemotes[branchName], let remoteURL = remoteURLs[remoteName] {
                return remoteURL
            }

            if let originURL = remoteURLs["origin"] {
                return originURL
            }

            if let firstRemote = remoteOrder.first, let remoteURL = remoteURLs[firstRemote] {
                return remoteURL
            }

            throw ResolverError.missingRemote(URL(fileURLWithPath: ""))
        }

    }

    func repositoryRoot(startingAt folderURL: URL) throws -> URL {
        var currentURL = folderURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: currentURL.path, isDirectory: &isDirectory)

        if exists && !isDirectory.boolValue {
            currentURL.deleteLastPathComponent()
        }

        while currentURL.path != "/" {
            let gitPathURL = currentURL.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: gitPathURL.path) {
                return currentURL
            }
            currentURL.deleteLastPathComponent()
        }

        throw ResolverError.notGitRepository(folderURL)
    }

    func gitDirectoryURL(for repositoryURL: URL) throws -> URL {
        let gitPathURL = repositoryURL.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false

        if FileManager.default.fileExists(atPath: gitPathURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return gitPathURL
        }

        let dotGitText = try String(contentsOf: gitPathURL, encoding: .utf8)
        let prefix = "gitdir:"
        let trimmedText = dotGitText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.lowercased().hasPrefix(prefix) else {
            throw ResolverError.notGitRepository(repositoryURL)
        }

        let rawPath = String(trimmedText.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return absoluteFileURL(path: rawPath, relativeTo: repositoryURL, isDirectory: true)
    }

    func gitConfig(from gitDirectoryURL: URL) throws -> GitConfig {
        let configURLs = candidateConfigURLs(gitDirectoryURL: gitDirectoryURL)

        for configURL in configURLs where FileManager.default.fileExists(atPath: configURL.path) {
            let configText = try String(contentsOf: configURL, encoding: .utf8)
            return parseConfig(configText)
        }

        throw ResolverError.missingConfig(gitDirectoryURL)
    }

    func candidateConfigURLs(gitDirectoryURL: URL) -> [URL] {
        var urls = [gitDirectoryURL.appendingPathComponent("config")]
        let commonDirURL = gitDirectoryURL.appendingPathComponent("commondir")

        guard let commonDirText = try? String(contentsOf: commonDirURL, encoding: .utf8) else { return urls }

        let commonDirPath = commonDirText.trimmingCharacters(in: .whitespacesAndNewlines)
        let commonGitURL = absoluteFileURL(path: commonDirPath, relativeTo: gitDirectoryURL, isDirectory: true)
        urls.append(commonGitURL.appendingPathComponent("config"))
        return urls
    }

    func submoduleRemoteURL(for repositoryURL: URL) -> String? {
        var parentURL = repositoryURL.deletingLastPathComponent().standardizedFileURL

        while parentURL.path != "/" {
            let gitmodulesURL = parentURL.appendingPathComponent(".gitmodules")

            if FileManager.default.fileExists(atPath: gitmodulesURL.path),
               let gitmodulesText = try? String(contentsOf: gitmodulesURL, encoding: .utf8),
               let remoteURL = submoduleRemoteURL(
                in: parseConfig(gitmodulesText),
                repositoryURL: repositoryURL,
                parentURL: parentURL
               ) {
                return remoteURL
            }

            parentURL.deleteLastPathComponent()
        };return nil
    }

    func submoduleRemoteURL(in config: GitConfig, repositoryURL: URL, parentURL: URL) -> String? {
        let repositoryPath = normalizedDirectoryPath(repositoryURL)

        for submoduleName in config.submoduleOrder {
            guard let submodulePath = config.submodulePaths[submoduleName],
                  let submoduleURL = config.submoduleURLs[submoduleName] else { continue }

            let candidateURL = absoluteFileURL(path: submodulePath, relativeTo: parentURL, isDirectory: true)
            if normalizedDirectoryPath(candidateURL) == repositoryPath {
                return submoduleURL
            }
        };return nil
    }

    func branchName(from gitDirectoryURL: URL) -> String? {
        let headURL = gitDirectoryURL.appendingPathComponent("HEAD")
        guard let headText = try? String(contentsOf: headURL, encoding: .utf8) else { return nil }

        let prefix = "ref: refs/heads/"
        let trimmedText = headText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.hasPrefix(prefix) else { return nil };return String(trimmedText.dropFirst(prefix.count))
    }

    func parseConfig(_ text: String) -> GitConfig {
        var config = GitConfig()
        var sectionName = ""
        var subsectionName: String?

        for line in text.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") || trimmedLine.hasPrefix(";") {
                continue
            }

            if trimmedLine.hasPrefix("[") && trimmedLine.hasSuffix("]") {
                let section = parseSection(trimmedLine)
                sectionName = section.name
                subsectionName = section.subsection
                continue
            }

            guard let equalIndex = trimmedLine.firstIndex(of: "=") else { continue }
            let key = trimmedLine[..<equalIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = trimmedLine[trimmedLine.index(after: equalIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)

            if sectionName == "remote", key == "url", let remoteName = subsectionName {
                if config.remoteURLs[remoteName] == nil {
                    config.remoteOrder.append(remoteName)
                }
                config.remoteURLs[remoteName] = value
            } else if sectionName == "branch", key == "remote", let branchName = subsectionName {
                config.branchRemotes[branchName] = value
            } else if sectionName == "submodule", let submoduleName = subsectionName {
                if config.submodulePaths[submoduleName] == nil && config.submoduleURLs[submoduleName] == nil {
                    config.submoduleOrder.append(submoduleName)
                }

                if key == "path" {
                    config.submodulePaths[submoduleName] = value
                } else if key == "url" {
                    config.submoduleURLs[submoduleName] = value
                }
            }
        };return config
    }

    func parseSection(_ line: String) -> (name: String, subsection: String?) {
        let body = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let quoteStart = body.firstIndex(of: "\""), let quoteEnd = body.lastIndex(of: "\""), quoteStart != quoteEnd else {
            return (body, nil)
        }

        let name = body[..<quoteStart].trimmingCharacters(in: .whitespacesAndNewlines)
        let subsectionStart = body.index(after: quoteStart)
        let subsection = String(body[subsectionStart..<quoteEnd])
        return (name, subsection)
    }

    func webURL(fromRemoteURLString remoteURLString: String) throws -> URL {
        let remoteURL = remoteURLString.trimmingCharacters(in: .whitespacesAndNewlines)

        if let azureURL = azureWebURL(from: remoteURL) {
            return azureURL
        }

        if remoteURL.hasPrefix("http://") || remoteURL.hasPrefix("https://") {
            return try httpWebURL(from: remoteURL)
        }

        if remoteURL.hasPrefix("git://") {
            let webURLString = cleanRepositoryURLString("https://" + remoteURL.dropFirst("git://".count))
            if let webURL = URL(string: webURLString) {
                return webURL
            }
        }

        if let captures = capture(pattern: #"^[^@]+@([^:]+):(.+)$"#, in: remoteURL) {
            let webURLString = cleanRepositoryURLString("https://\(captures[0])/\(captures[1])")
            if let webURL = URL(string: webURLString) {
                return webURL
            }
        }

        if let captures = capture(pattern: #"^ssh://(?:[^@/]+@)?([^/:]+)(?::[0-9]+)?/(.+)$"#, in: remoteURL) {
            let webURLString = cleanRepositoryURLString("https://\(captures[0])/\(captures[1])")
            if let webURL = URL(string: webURLString) {
                return webURL
            }
        }

        throw ResolverError.unsupportedRemoteURL(remoteURLString)
    }

    func azureWebURL(from remoteURL: String) -> URL? {
        let patterns = [
            #"^git@ssh\.dev\.azure\.com:v3/([^/]+)/([^/]+)/(.+)$"#,
            #"^ssh://git@ssh\.dev\.azure\.com(?::[0-9]+)?/v3/([^/]+)/([^/]+)/(.+)$"#
        ]

        for pattern in patterns {
            guard let captures = capture(pattern: pattern, in: remoteURL) else { continue }
            let webURLString = cleanRepositoryURLString("https://dev.azure.com/\(captures[0])/\(captures[1])/_git/\(captures[2])")
            return URL(string: webURLString)
        };return nil
    }

    func httpWebURL(from remoteURL: String) throws -> URL {
        guard var components = URLComponents(string: remoteURL) else {
            throw ResolverError.unsupportedRemoteURL(remoteURL)
        }
        components.user = nil
        components.password = nil

        guard let cleanedString = components.string.map(cleanRepositoryURLString), let webURL = URL(string: cleanedString) else {
            throw ResolverError.unsupportedRemoteURL(remoteURL)
        };return webURL
    }

    func cleanRepositoryURLString(_ value: String) -> String {
        var cleanedValue = value

        if cleanedValue.hasSuffix(".git") {
            cleanedValue.removeLast(4)
        }

        while cleanedValue.hasSuffix("/") {
            cleanedValue.removeLast()
        };return cleanedValue
    }

    func capture(pattern: String, in value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range) else { return nil };return (1..<match.numberOfRanges).compactMap { index in
            guard let captureRange = Range(match.range(at: index), in: value) else { return nil };return String(value[captureRange])
        }
    }

    func absoluteFileURL(path: String, relativeTo baseURL: URL, isDirectory: Bool) -> URL {
        let expandedPath = (path as NSString).expandingTildeInPath
        let absolutePath = expandedPath.hasPrefix("/") ? expandedPath : (baseURL.path as NSString).appendingPathComponent(expandedPath)
        return URL(fileURLWithPath: absolutePath, isDirectory: isDirectory).standardizedFileURL
    }

    func normalizedDirectoryPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path

        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        };return path
    }
}
