import Foundation
@testable import RepoPrompt
import XCTest

final class OpenCodeACPLaunchResolverTests: XCTestCase {
    func testMakeLaunchConfigurationResolvesExplicitPathWithoutPriorProbe() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory)
        let resolver = OpenCodeACPLaunchResolver()
        let provider = OpenCodeACPAgentProvider(
            config: OpenCodeAgentConfig(
                commandName: executable.path,
                additionalPathHints: [],
                includeRepoPromptMCPServer: false,
                includeManagedConfigOverlay: false
            ),
            launchResolver: resolver
        )

        let launch = try provider.makeLaunchConfiguration(for: makeRunRequest(workspacePath: directory.path))

        XCTAssertEqual(launch.command, executable.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertEqual(launch.arguments, ["acp"])
        XCTAssertEqual(launch.expectedExecutableIdentity?.canonicalPath, launch.command)
    }

    func testBareCommandUsesCapturedEnvironmentAndCachesCanonicalPathForSpawn() async throws {
        let directory = try makeTemporaryDirectory()
        let probePathRecord = directory.appendingPathComponent("probe-path")
        let executable = try makeExecutable(in: directory, marker: probePathRecord)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = directory.path
        environment["SHELL"] = "/bin/false"
        let capturedEnvironment = environment
        let resolver = OpenCodeACPLaunchResolver(environmentProvider: { _ in capturedEnvironment })
        let config = OpenCodeAgentConfig(
            commandName: "opencode",
            additionalPathHints: [],
            includeRepoPromptMCPServer: false,
            includeManagedConfigOverlay: false
        )

        let support = await resolver.probeSupport(for: config)
        let launch = try resolver.resolvedLaunch(for: config)
        let probedPath = try String(contentsOf: probePathRecord, encoding: .utf8)

        XCTAssertEqual(support, .supported)
        XCTAssertEqual(launch.command, executable.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertEqual(probedPath, launch.command)
    }

    func testRepeatedProbeRefreshesCurrentEnvironmentBeforeSpawn() async throws {
        let firstDirectory = try makeTemporaryDirectory()
        let secondDirectory = try makeTemporaryDirectory()
        let firstExecutable = try makeExecutable(in: firstDirectory)
        let secondExecutable = try makeExecutable(in: secondDirectory)
        let environmentBox = OpenCodeTestEnvironmentBox(environment: [
            "PATH": firstDirectory.path,
            "SHELL": "/bin/false"
        ])
        let resolver = OpenCodeACPLaunchResolver(environmentProvider: { _ in
            await environmentBox.current()
        })
        let config = OpenCodeAgentConfig(commandName: "opencode", additionalPathHints: [])

        let firstSupport = await resolver.probeSupport(for: config)
        let firstLaunch = try resolver.resolvedLaunch(for: config)
        XCTAssertEqual(firstSupport, .supported)
        XCTAssertEqual(firstLaunch.command, firstExecutable.resolvingSymlinksInPath().path)

        await environmentBox.set([
            "PATH": secondDirectory.path,
            "SHELL": "/bin/false"
        ])
        let secondSupport = await resolver.probeSupport(for: config)
        let secondLaunch = try resolver.resolvedLaunch(for: config)
        XCTAssertEqual(secondSupport, .supported)
        XCTAssertEqual(secondLaunch.command, secondExecutable.resolvingSymlinksInPath().path)
    }

    func testBareCommandWithoutSuccessfulPreflightFailsClosed() {
        let resolver = OpenCodeACPLaunchResolver(environmentProvider: { _ in [:] })

        XCTAssertThrowsError(
            try resolver.resolvedLaunch(
                for: OpenCodeAgentConfig(commandName: "opencode", additionalPathHints: [])
            )
        ) { error in
            guard case OpenCodeACPLaunchResolutionError.environmentDiscoveryRequired = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testFailedProbeDoesNotLeaveSpawnableCacheAndReplacementCanRecover() async throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory, exitStatus: 2)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = directory.path
        environment["SHELL"] = "/bin/false"
        let capturedEnvironment = environment
        let resolver = OpenCodeACPLaunchResolver(environmentProvider: { _ in capturedEnvironment })
        let config = OpenCodeAgentConfig(commandName: "opencode", additionalPathHints: [])

        guard case .unsupported = await resolver.probeSupport(for: config) else {
            return XCTFail("Expected failed support probe")
        }
        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config)) { error in
            guard case OpenCodeACPLaunchResolutionError.environmentDiscoveryRequired = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        try FileManager.default.removeItem(at: executable)
        let replacement = try makeExecutable(in: directory)
        let replacementSupport = await resolver.probeSupport(for: config)
        XCTAssertEqual(replacementSupport, .supported)
        XCTAssertEqual(
            try resolver.resolvedLaunch(for: config).command,
            replacement.resolvingSymlinksInPath().standardizedFileURL.path
        )
    }

    func testCachedIdentityDriftFailsBeforeSpawn() async throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory)
        let resolver = OpenCodeACPLaunchResolver()
        let config = OpenCodeAgentConfig(commandName: executable.path, additionalPathHints: [])

        let support = await resolver.probeSupport(for: config)
        XCTAssertEqual(support, .supported)
        try FileManager.default.removeItem(at: executable)
        _ = try makeExecutable(in: directory, output: "replacement OpenCode ACP")

        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config)) { error in
            guard case ExecutableFileIdentityError.identityChanged = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func makeRunRequest(workspacePath: String) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: .openCode,
            modelString: nil,
            workspacePath: workspacePath,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeACPLaunchResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    @discardableResult
    private func makeExecutable(
        in directory: URL,
        marker: URL? = nil,
        output: String = "OpenCode ACP support",
        exitStatus: Int32 = 0
    ) throws -> URL {
        let executable = directory.appendingPathComponent("opencode")
        var lines = ["#!/bin/sh"]
        if let marker {
            lines.append("printf '%s' \"$0\" > '\(marker.path)'")
        }
        lines.append("printf '%s\\n' '\(output)'")
        lines.append("exit \(exitStatus)")
        try lines.joined(separator: "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }
}

private actor OpenCodeTestEnvironmentBox {
    private var environment: [String: String]

    init(environment: [String: String]) {
        self.environment = environment
    }

    func current() -> [String: String] {
        environment
    }

    func set(_ environment: [String: String]) {
        self.environment = environment
    }
}
