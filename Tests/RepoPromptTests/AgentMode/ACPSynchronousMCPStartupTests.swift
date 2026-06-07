import Foundation
@testable import RepoPrompt
import XCTest

final class ACPSynchronousMCPStartupTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    func testOpenCodeStyleSessionNewWaitsForMCPInitializeAndToolsList() async throws {
        let workspace = try makeTemporaryDirectory()
        let recordURL = workspace.appendingPathComponent("opencode-startup.jsonl")
        let acpScriptURL = try makeACPServerScript()
        let mcpScriptURL = try makeMCPServerScript()
        let request = makeRunRequest(agentKind: .openCode, workspacePath: workspace.path)
        let provider = SynchronousStartupFakeACPProvider(
            providerID: .openCode,
            commandPath: acpScriptURL.path,
            environment: [
                "ACP_STARTUP_STYLE": "opencode",
                "ACP_RECORD_PATH": recordURL.path
            ],
            mcpServer: RepoPromptMCPServerConfiguration(
                name: "RepoPromptFixture",
                command: mcpScriptURL.path
            )
        )
        let controller = try ACPAgentSessionController(
            provider: provider,
            runRequest: request,
            requestTimeouts: .init(bootstrapSeconds: 2)
        )

        let bootstrap = try await controller.bootstrap()
        await controller.shutdown()

        XCTAssertEqual(bootstrap.sessionID, "opencode-session")
        XCTAssertEqual(
            recordedEvents(at: recordURL),
            ["session_new_started", "mcp_initialize_completed", "mcp_tools_list_completed", "session_new_response"]
        )
    }

    func testCursorStyleSessionNewCatchesSynchronousMCPStartupFailureAndReturns() async throws {
        let workspace = try makeTemporaryDirectory()
        let recordURL = workspace.appendingPathComponent("cursor-startup.jsonl")
        let acpScriptURL = try makeACPServerScript()
        let mcpScriptURL = try makeMCPServerScript()
        let request = makeRunRequest(agentKind: .cursor, workspacePath: workspace.path)
        let provider = SynchronousStartupFakeACPProvider(
            providerID: .cursor,
            commandPath: acpScriptURL.path,
            environment: [
                "ACP_STARTUP_STYLE": "cursor",
                "ACP_RECORD_PATH": recordURL.path
            ],
            mcpServer: RepoPromptMCPServerConfiguration(
                name: "RepoPromptFixture",
                command: mcpScriptURL.path,
                args: ["--fail"]
            )
        )
        let controller = try ACPAgentSessionController(
            provider: provider,
            runRequest: request,
            requestTimeouts: .init(bootstrapSeconds: 2)
        )

        let bootstrap = try await controller.bootstrap()
        await controller.shutdown()

        XCTAssertEqual(bootstrap.sessionID, "cursor-session")
        XCTAssertEqual(
            recordedEvents(at: recordURL),
            ["session_new_started", "mcp_startup_failed", "session_new_response"]
        )
    }

    private func makeRunRequest(agentKind: AgentProviderKind, workspacePath: String) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: agentKind,
            modelString: nil,
            workspacePath: workspacePath,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ACPSynchronousMCPStartupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    private func makeACPServerScript() throws -> URL {
        let directory = try makeTemporaryDirectory()
        let scriptURL = directory.appendingPathComponent("fake_synchronous_acp.py")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import os
        import subprocess
        import sys

        style = os.environ.get("ACP_STARTUP_STYLE", "opencode")
        record_path = os.environ["ACP_RECORD_PATH"]

        def record(event):
            with open(record_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps({"event": event}) + "\n")

        def respond(request_id, result=None, error=None):
            payload = {"jsonrpc": "2.0", "id": request_id}
            if error is not None:
                payload["error"] = error
            else:
                payload["result"] = result or {}
            print(json.dumps(payload), flush=True)

        def start_mcp(server):
            env = os.environ.copy()
            for entry in server.get("env") or []:
                env[entry["name"]] = entry["value"]
            process = subprocess.Popen(
                [server["command"], *(server.get("args") or [])],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=env,
            )
            try:
                process.stdin.write(json.dumps({
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": {
                        "protocolVersion": "2025-11-25",
                        "capabilities": {},
                        "clientInfo": {"name": style, "version": "fixture"},
                    },
                }) + "\n")
                process.stdin.flush()
                if not process.stdout.readline():
                    raise RuntimeError("MCP initialize failed")
                record("mcp_initialize_completed")
                process.stdin.write(json.dumps({
                    "jsonrpc": "2.0",
                    "method": "notifications/initialized",
                    "params": {},
                }) + "\n")
                process.stdin.write(json.dumps({
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/list",
                    "params": {},
                }) + "\n")
                process.stdin.flush()
                if not process.stdout.readline():
                    raise RuntimeError("MCP tools/list failed")
                record("mcp_tools_list_completed")
            finally:
                if process.stdin:
                    process.stdin.close()
                process.terminate()
                process.wait(timeout=1)

        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            method = request.get("method")
            params = request.get("params") or {}
            if method == "initialize":
                respond(request.get("id"), {"agentCapabilities": {"loadSession": False}, "authMethods": []})
            elif method == "session/new":
                record("session_new_started")
                try:
                    start_mcp((params.get("mcpServers") or [])[0])
                except Exception:
                    record("mcp_startup_failed")
                    if style == "opencode":
                        respond(request.get("id"), error={"code": -32000, "message": "MCP startup failed"})
                        continue
                record("session_new_response")
                respond(request.get("id"), {"sessionId": style + "-session"})
            else:
                respond(request.get("id"), {})
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func makeMCPServerScript() throws -> URL {
        let directory = try makeTemporaryDirectory()
        let scriptURL = directory.appendingPathComponent("fake_mcp_server.py")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import sys

        if "--fail" in sys.argv:
            sys.exit(7)

        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            request_id = request.get("id")
            method = request.get("method")
            if request_id is None:
                continue
            if method == "initialize":
                result = {
                    "protocolVersion": "2025-11-25",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "RepoPromptFixture", "version": "1"},
                }
            elif method == "tools/list":
                result = {"tools": [{
                    "name": "read_file",
                    "description": "fixture",
                    "inputSchema": {"type": "object", "properties": {}},
                }]}
            else:
                result = {}
            print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}), flush=True)
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func recordedEvents(at url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return text.split(whereSeparator: { $0.isNewline }).compactMap { line in
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return object["event"] as? String
        }
    }
}

private struct SynchronousStartupFakeACPProvider: ACPAgentProvider {
    let providerID: ACPProviderID
    let commandPath: String
    let environment: [String: String]
    let mcpServer: RepoPromptMCPServerConfiguration

    func support(for request: ACPRunRequest) async -> ACPSupportResult {
        .supported
    }

    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        ACPLaunchConfiguration(
            providerID: providerID,
            command: commandPath,
            arguments: [],
            environment: environment,
            workingDirectory: request.workspacePath,
            additionalPathHints: [],
            enableDebugLogging: false
        )
    }

    func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer _: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        ACPSessionConfiguration(
            mode: .new,
            workingDirectory: request.workspacePath ?? FileManager.default.temporaryDirectory.path,
            mcpServers: [mcpServer]
        )
    }

    func buildPromptBlocks(
        for message: AgentMessage,
        request: ACPRunRequest
    ) throws -> [[String: Any]] {
        [["type": "text", "text": message.userMessage]]
    }

    func normalizeSessionUpdate(
        _ payload: [String: Any],
        sessionID: String
    ) -> [NormalizedAgentRuntimeEvent] {
        []
    }

    func normalizeError(_ error: Error) -> Error {
        error
    }
}
