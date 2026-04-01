import ArgumentParser
import Foundation

enum AliasSupport {
    static func run(prefix: [String], passthrough: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = prefix + passthrough
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw ExitCode(process.terminationStatus)
        }
    }
}

struct ListAlias: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Alias for update apps list.")
    @Argument(parsing: .captureForPassthrough) var passthrough: [String] = []
    mutating func run() async throws { try AliasSupport.run(prefix: ["apps", "list"], passthrough: passthrough) }
}

struct CheckAlias: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "check", abstract: "Alias for update apps check.")
    @Argument(parsing: .captureForPassthrough) var passthrough: [String] = []
    mutating func run() async throws { try AliasSupport.run(prefix: ["apps", "check"], passthrough: passthrough) }
}

struct SourcesAlias: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sources", abstract: "Alias for update apps sources.")
    @Argument(parsing: .captureForPassthrough) var passthrough: [String] = []
    mutating func run() async throws { try AliasSupport.run(prefix: ["apps", "sources"], passthrough: passthrough) }
}

struct UpdateAlias: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Alias for update apps update.")
    @Argument(parsing: .captureForPassthrough) var passthrough: [String] = []
    mutating func run() async throws { try AliasSupport.run(prefix: ["apps", "update"], passthrough: passthrough) }
}

struct AdoptAlias: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "adopt", abstract: "Alias for update apps adopt.")
    @Argument(parsing: .captureForPassthrough) var passthrough: [String] = []
    mutating func run() async throws { try AliasSupport.run(prefix: ["apps", "adopt"], passthrough: passthrough) }
}

struct IgnoreAlias: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ignore", abstract: "Alias for update ignores add.")
    @Argument(parsing: .captureForPassthrough) var passthrough: [String] = []
    mutating func run() async throws { try AliasSupport.run(prefix: ["ignores", "add"], passthrough: passthrough) }
}

struct UnignoreAlias: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "unignore", abstract: "Alias for update ignores remove.")
    @Argument(parsing: .captureForPassthrough) var passthrough: [String] = []
    mutating func run() async throws { try AliasSupport.run(prefix: ["ignores", "remove"], passthrough: passthrough) }
}

struct SkipAlias: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "skip", abstract: "Alias for update skips add.")
    @Argument(parsing: .captureForPassthrough) var passthrough: [String] = []
    mutating func run() async throws { try AliasSupport.run(prefix: ["skips", "add"], passthrough: passthrough) }
}

struct UnskipAlias: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "unskip", abstract: "Alias for update skips remove.")
    @Argument(parsing: .captureForPassthrough) var passthrough: [String] = []
    mutating func run() async throws { try AliasSupport.run(prefix: ["skips", "remove"], passthrough: passthrough) }
}

