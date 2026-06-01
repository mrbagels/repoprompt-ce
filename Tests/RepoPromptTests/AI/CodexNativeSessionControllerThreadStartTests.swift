import Foundation
@testable import RepoPrompt
import XCTest

final class CodexNativeSessionControllerThreadStartTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testFreshThreadStartEphemeralJSONRPCShapeMatrix() async throws {
        let rows: [(label: String, options: CodexNativeSessionController.Options?, instructions: String, expectedEphemeral: Bool?)] = [
            ("opted-in standard chat", makeStandardChatOptions(startNewThreadsEphemerally: true), "Oracle", true),
            ("default standard chat", makeStandardChatOptions(startNewThreadsEphemerally: false), "Chat", nil),
            ("Agent Mode default", nil, "Agent", nil)
        ]

        for row in rows {
            let (controller, recordURL) = try await makeController(options: row.options)

            _ = try await controller.startOrResume(existing: nil, baseInstructions: row.instructions)
            await controller.shutdown()

            let params = try recordedParams(for: "thread/start", at: recordURL)
            if let expectedEphemeral = row.expectedEphemeral {
                XCTAssertEqual(params["ephemeral"] as? Bool, expectedEphemeral, row.label)
            } else {
                XCTAssertNil(params["ephemeral"], row.label)
            }
        }
    }

    func testResumeNeverIncludesEphemeralWhenFreshStartsAreOptedIn() async throws {
        let (controller, recordURL) = try await makeController(options: makeStandardChatOptions(startNewThreadsEphemerally: true))
        let existing = CodexNativeSessionController.SessionRef(
            conversationID: "existing-thread",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil
        )

        _ = try await controller.startOrResume(existing: existing, baseInstructions: "Oracle")
        await controller.shutdown()

        let params = try recordedParams(for: "thread/resume", at: recordURL)
        XCTAssertNil(params["ephemeral"])
    }

    func testAgentModeDefaultCarriesGoalFeatureConfigToStartAndResume() async throws {
        let options = CodexNativeSessionController.Options.agentModeDefault(
            forceExperimentalSteering: false,
            approvalPolicyProvider: { .never },
            sandboxModeProvider: { .readOnly },
            approvalReviewerProvider: { .user },
            goalSupportEnabledProvider: { true },
            computerUseEnabledProvider: { false }
        )

        let (startController, startRecordURL) = try await makeController(options: options)
        _ = try await startController.startOrResume(existing: nil, baseInstructions: "Agent")
        await startController.shutdown()

        try assertGoalFeatureEnabledAndComputerUseDisabled(
            in: recordedParams(for: "thread/start", at: startRecordURL),
            label: "thread/start"
        )

        let (resumeController, resumeRecordURL) = try await makeController(options: options)
        let existing = CodexNativeSessionController.SessionRef(
            conversationID: "existing-thread",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil
        )
        _ = try await resumeController.startOrResume(existing: existing, baseInstructions: "Agent")
        await resumeController.shutdown()

        try assertGoalFeatureEnabledAndComputerUseDisabled(
            in: recordedParams(for: "thread/resume", at: resumeRecordURL),
            label: "thread/resume"
        )
    }

    private func makeStandardChatOptions(startNewThreadsEphemerally: Bool) -> CodexNativeSessionController.Options {
        CodexNativeSessionController.Options(
            requestTimeout: 5,
            configOverridesProvider: { [:] },
            approvalPolicyProvider: { .never },
            sandboxModeProvider: { .readOnly },
            approvalReviewerProvider: { .user },
            authTokensRefreshHandler: nil,
            startNewThreadsEphemerally: startNewThreadsEphemerally
        )
    }

    private func makeController(
        options: CodexNativeSessionController.Options?
    ) async throws -> (CodexNativeSessionController, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexNativeSessionControllerThreadStartTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let recordURL = directory.appendingPathComponent("requests.jsonl")
        let executableURL = try makeFakeCodexAppServer(in: directory, recordURL: recordURL)
        let client = CodexAppServerClient()
        await client.updateConfig(
            CodexAppServerClient.Config(
                commandName: executableURL.path,
                additionalPathHints: [],
                requestTimeout: 5,
                workingDirectory: directory.path
            )
        )

        let controller = CodexNativeSessionController(
            client: client,
            runID: UUID(),
            tabID: UUID(),
            windowID: 0,
            workspacePath: directory.path,
            options: options,
            clientShutdownBehavior: .stopOnShutdown
        )
        return (controller, recordURL)
    }

    private func makeFakeCodexAppServer(in directory: URL, recordURL: URL) throws -> URL {
        let scriptURL = directory.appendingPathComponent("fake-codex")
        let script = """
        #!/usr/bin/env python3
        import json
        import sys

        record_path = \(String(reflecting: recordURL.path))

        def respond(request_id, result):
            print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}), flush=True)

        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            method = request.get("method")
            params = request.get("params") or {}
            with open(record_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps({"method": method, "params": params}) + "\\n")
            if "id" not in request:
                continue
            if method == "thread/start":
                respond(request["id"], {"thread": {"id": "fresh-thread", "status": "idle", "turns": []}})
            elif method == "thread/resume":
                respond(request["id"], {"thread": {"id": params.get("threadId", "resumed-thread"), "status": "idle", "turns": []}})
            else:
                respond(request["id"], {})
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func recordedParams(for method: String, at recordURL: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: recordURL)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let lineData = try XCTUnwrap(String(line).data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: lineData) as? [String: Any])
            if object["method"] as? String == method {
                return try XCTUnwrap(object["params"] as? [String: Any])
            }
        }
        XCTFail("No \(method) request was recorded")
        return [:]
    }

    private func assertGoalFeatureEnabledAndComputerUseDisabled(
        in params: [String: Any],
        label: String
    ) throws {
        let config = try XCTUnwrap(params["config"] as? [String: Any], label)
        XCTAssertEqual(config["features.goals"] as? Bool, true, label)
        XCTAssertEqual(config["features.computer_use"] as? Bool, false, label)
    }
}
