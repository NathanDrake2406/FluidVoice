import Foundation
import XCTest

@testable import FluidVoice_Debug

@MainActor
final class DictationE2ETests: XCTestCase {
    private let enableTranscriptionSoundsKey = "EnableTranscriptionSounds"
    private let transcriptionStartSoundKey = "TranscriptionStartSound"
    private let dictationPromptProfilesKey = "DictationPromptProfiles"
    private let appPromptBindingsKey = "AppPromptBindings"
    private let selectedDictationPromptIDKey = "SelectedDictationPromptID"
    private let selectedEditPromptIDKey = "SelectedEditPromptID"
    private let defaultDictationPromptOverrideKey = "DefaultDictationPromptOverride"
    private let defaultEditPromptOverrideKey = "DefaultEditPromptOverride"

    func testTranscriptionStartSound_noneOptionHasNoFile() {
        XCTAssertEqual(SettingsStore.TranscriptionStartSound.none.displayName, "None")
        XCTAssertNil(SettingsStore.TranscriptionStartSound.none.soundFileName)
    }

    func testTranscriptionStartSound_legacyDisabledToggleMigratesToNone() {
        self.withRestoredDefaults(keys: [self.enableTranscriptionSoundsKey, self.transcriptionStartSoundKey]) {
            let defaults = UserDefaults.standard
            defaults.set(false, forKey: self.enableTranscriptionSoundsKey)
            defaults.set(SettingsStore.TranscriptionStartSound.fluidSfx1.rawValue, forKey: self.transcriptionStartSoundKey)

            let value = SettingsStore.shared.transcriptionStartSound

            XCTAssertEqual(value, .none)
            XCTAssertNil(defaults.object(forKey: self.enableTranscriptionSoundsKey))
            XCTAssertEqual(defaults.string(forKey: self.transcriptionStartSoundKey), SettingsStore.TranscriptionStartSound.none.rawValue)
        }
    }

    func testTranscriptionStartSound_legacyEnabledToggleKeepsSelectedSound() {
        self.withRestoredDefaults(keys: [self.enableTranscriptionSoundsKey, self.transcriptionStartSoundKey]) {
            let defaults = UserDefaults.standard
            defaults.set(true, forKey: self.enableTranscriptionSoundsKey)
            defaults.set(SettingsStore.TranscriptionStartSound.fluidSfx2.rawValue, forKey: self.transcriptionStartSoundKey)

            let value = SettingsStore.shared.transcriptionStartSound

            XCTAssertEqual(value, .fluidSfx2)
            XCTAssertNil(defaults.object(forKey: self.enableTranscriptionSoundsKey))
            XCTAssertEqual(defaults.string(forKey: self.transcriptionStartSoundKey), SettingsStore.TranscriptionStartSound.fluidSfx2.rawValue)
        }
    }

    func testDictationEndToEnd_whisperTiny_transcribesFixture() async throws {
        // Arrange
        SettingsStore.shared.shareAnonymousAnalytics = false
        SettingsStore.shared.selectedSpeechModel = .whisperTiny

        let modelDirectory = Self.modelDirectoryForRun()
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let provider = WhisperProvider(modelDirectory: modelDirectory)

        // Act
        try await provider.prepare()
        let samples = try AudioFixtureLoader.load16kMonoFloatSamples(named: "dictation_fixture", ext: "wav")
        let result = try await provider.transcribe(samples)

        // Assert
        let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(raw.isEmpty, "Expected non-empty transcription text.")

        let normalized = Self.normalize(raw)
        XCTAssertTrue(normalized.contains("hello"), "Expected transcription to contain 'hello'. Got: \(raw)")
        XCTAssertTrue(normalized.contains("fluid"), "Expected transcription to contain 'fluid'. Got: \(raw)")
        XCTAssertTrue(
            normalized.contains("voice") || normalized.contains("fluidvoice") || normalized.contains("boys"),
            "Expected transcription to contain 'voice' (or a close variant like 'boys'). Got: \(raw)"
        )
    }

    func testAppPromptBinding_profileOverridesModeSelection() {
        self.withPromptSettingsRestored {
            let settings = SettingsStore.shared

            let global = SettingsStore.DictationPromptProfile(
                name: "Global Dictate",
                prompt: "Global dictate prompt",
                mode: .dictate
            )
            let mail = SettingsStore.DictationPromptProfile(
                name: "Mail Dictate",
                prompt: "Mail dictate prompt",
                mode: .dictate
            )

            settings.dictationPromptProfiles = [global, mail]
            settings.selectedDictationPromptID = global.id
            settings.appPromptBindings = [
                SettingsStore.AppPromptBinding(
                    mode: .dictate,
                    appBundleID: "com.apple.mail",
                    appName: "Mail",
                    promptID: mail.id
                ),
            ]

            let mailResolution = settings.promptResolution(for: .dictate, appBundleID: "com.apple.mail")
            XCTAssertEqual(mailResolution.source, .appBindingProfile)
            XCTAssertEqual(mailResolution.profile?.id, mail.id)

            let notesResolution = settings.promptResolution(for: .dictate, appBundleID: "com.apple.notes")
            XCTAssertEqual(notesResolution.source, .selectedProfile)
            XCTAssertEqual(notesResolution.profile?.id, global.id)
        }
    }

    func testAppPromptBinding_defaultFallbackIgnoresGlobalSelection() {
        self.withPromptSettingsRestored {
            let settings = SettingsStore.shared

            let global = SettingsStore.DictationPromptProfile(
                name: "Global Dictate",
                prompt: "Global dictate prompt",
                mode: .dictate
            )

            settings.dictationPromptProfiles = [global]
            settings.selectedDictationPromptID = global.id
            settings.appPromptBindings = [
                SettingsStore.AppPromptBinding(
                    mode: .dictate,
                    appBundleID: "com.apple.mail",
                    appName: "Mail",
                    promptID: nil
                ),
            ]

            let mailResolution = settings.promptResolution(for: .dictate, appBundleID: "com.apple.mail")
            XCTAssertEqual(mailResolution.source, .appBindingDefault)
            XCTAssertNil(mailResolution.profile)
            XCTAssertEqual(
                mailResolution.systemPrompt,
                SettingsStore.defaultSystemPromptText(for: .dictate)
            )

            let otherResolution = settings.promptResolution(for: .dictate, appBundleID: "com.apple.notes")
            XCTAssertEqual(otherResolution.source, .selectedProfile)
            XCTAssertEqual(otherResolution.profile?.id, global.id)
        }
    }

    func testAppPromptBindings_reconcileInvalidPromptAndLegacyMode() {
        self.withPromptSettingsRestored {
            let settings = SettingsStore.shared

            let editProfile = SettingsStore.DictationPromptProfile(
                name: "Edit",
                prompt: "Edit prompt",
                mode: .edit
            )
            settings.dictationPromptProfiles = [editProfile]
            settings.appPromptBindings = [
                SettingsStore.AppPromptBinding(
                    mode: .rewrite,
                    appBundleID: " COM.APPLE.SAFARI ",
                    appName: "Safari",
                    promptID: "missing-profile"
                ),
            ]

            settings.reconcilePromptStateAfterProfileChanges()

            guard let binding = settings.appPromptBindings.first else {
                XCTFail("Expected normalized app prompt binding")
                return
            }

            XCTAssertEqual(binding.mode, .edit)
            XCTAssertEqual(binding.appBundleID, "com.apple.safari")
            XCTAssertNil(binding.promptID)
        }
    }

    private static func modelDirectoryForRun() -> URL {
        // Use a stable path on CI so GitHub Actions cache can speed up runs.
        if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" ||
            ProcessInfo.processInfo.environment["CI"] == "true"
        {
            guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                preconditionFailure("Could not find caches directory")
            }
            return caches.appendingPathComponent("WhisperModels")
        }

        // Local runs: isolate per test execution.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluidVoiceTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return base.appendingPathComponent("WhisperModels", isDirectory: true)
    }

    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let noPunct = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.punctuationCharacters.contains(scalar) { return " " }
            return Character(scalar)
        }
        let collapsed = String(noPunct)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return collapsed
    }

    private func withRestoredDefaults(keys: [String], run: () -> Void) {
        let defaults = UserDefaults.standard
        var snapshot: [String: Any] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) {
                snapshot[key] = value
            }
        }

        defer {
            for key in keys {
                if let previous = snapshot[key] {
                    defaults.set(previous, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        run()
    }

    private func withPromptSettingsRestored(run: () -> Void) {
        self.withRestoredDefaults(
            keys: [
                self.dictationPromptProfilesKey,
                self.appPromptBindingsKey,
                self.selectedDictationPromptIDKey,
                self.selectedEditPromptIDKey,
                self.defaultDictationPromptOverrideKey,
                self.defaultEditPromptOverrideKey,
            ],
            run: run
        )
    }
}

private final class MockLLMURLProtocol: URLProtocol {
    struct MockResponse {
        let statusCode: Int
        let headers: [String: String]
        let body: Data

        init(statusCode: Int, headers: [String: String] = [:], body: Data) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
        }
    }

    private static let queue = DispatchQueue(label: "MockLLMURLProtocol.queue")
    private static var requestHandler: ((URLRequest, Int) throws -> MockResponse)?
    private static var recordedRequests: [URLRequest] = []

    static func configure(handler: @escaping (URLRequest, Int) throws -> MockResponse) {
        self.queue.sync {
            self.recordedRequests = []
            self.requestHandler = handler
        }
    }

    static func reset() {
        self.queue.sync {
            self.recordedRequests = []
            self.requestHandler = nil
        }
    }

    static var requests: [URLRequest] {
        self.queue.sync {
            self.recordedRequests
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        let (handler, requestIndex) = Self.queue.sync { () -> (((URLRequest, Int) throws -> MockResponse)?, Int) in
            let index = Self.recordedRequests.count
            Self.recordedRequests.append(self.request)
            return (Self.requestHandler, index)
        }

        guard let handler else {
            self.client?.urlProtocol(
                self,
                didFailWithError: NSError(domain: "MockLLMURLProtocol", code: -1, userInfo: [NSLocalizedDescriptionKey: "No request handler configured"])
            )
            return
        }

        do {
            let mock = try handler(self.request, requestIndex)
            guard let url = self.request.url,
                  let response = HTTPURLResponse(url: url, statusCode: mock.statusCode, httpVersion: nil, headerFields: mock.headers)
            else {
                self.client?.urlProtocol(
                    self,
                    didFailWithError: NSError(domain: "MockLLMURLProtocol", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to build HTTPURLResponse"])
                )
                return
            }

            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !mock.body.isEmpty {
                self.client?.urlProtocol(self, didLoad: mock.body)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class LLMClientRoutingTests: XCTestCase {
    override func tearDown() {
        MockLLMURLProtocol.reset()
        super.tearDown()
    }

    func testAnthropicProvider_routesToMessagesWithAnthropicHeaders() async throws {
        MockLLMURLProtocol.configure { _, _ in
            let payload: [String: Any] = [
                "id": "msg_1",
                "type": "message",
                "role": "assistant",
                "content": [[
                    "type": "text",
                    "text": "Anthropic ok",
                ]],
            ]

            let data = try JSONSerialization.data(withJSONObject: payload)
            return MockLLMURLProtocol.MockResponse(statusCode: 200, body: data)
        }

        let client = self.makeClient()
        let config = LLMClient.Config(
            messages: [["role": "user", "content": "Hello"]],
            providerID: "anthropic",
            model: "claude-3-5-sonnet-latest",
            baseURL: "https://api.anthropic.com/v1",
            apiKey: "anthropic-test-key",
            streaming: false
        )

        let response = try await client.call(config)
        XCTAssertEqual(response.content, "Anthropic ok")

        let requests = MockLLMURLProtocol.requests
        XCTAssertEqual(requests.count, 1)

        guard let request = requests.first else {
            XCTFail("Expected one captured request")
            return
        }

        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "anthropic-test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testOpenAICompatibleProvider_fallsBackFromResponsesToChatCompletions() async throws {
        MockLLMURLProtocol.configure { _, requestIndex in
            if requestIndex == 0 {
                let body = Data("{\"error\":\"responses endpoint not supported\"}".utf8)
                return MockLLMURLProtocol.MockResponse(statusCode: 404, body: body)
            }

            let payload: [String: Any] = [
                "choices": [[
                    "message": [
                        "role": "assistant",
                        "content": "Fallback response",
                    ],
                ]],
            ]

            let data = try JSONSerialization.data(withJSONObject: payload)
            return MockLLMURLProtocol.MockResponse(statusCode: 200, body: data)
        }

        let client = self.makeClient()
        let config = LLMClient.Config(
            messages: [["role": "user", "content": "Hello"]],
            providerID: "openai",
            model: "gpt-4o-mini",
            baseURL: "https://api.openai.com/v1",
            apiKey: "openai-test-key",
            streaming: false
        )

        let response = try await client.call(config)
        XCTAssertEqual(response.content, "Fallback response")

        let requests = MockLLMURLProtocol.requests
        XCTAssertEqual(requests.count, 2)

        guard requests.count == 2 else {
            XCTFail("Expected responses request then chat completions fallback")
            return
        }

        XCTAssertEqual(requests[0].url?.path, "/v1/responses")
        XCTAssertEqual(requests[1].url?.path, "/v1/chat/completions")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer openai-test-key")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer openai-test-key")

        let firstBody = try self.decodeJSONBody(from: requests[0])
        XCTAssertNotNil(firstBody["input"])
        XCTAssertNil(firstBody["messages"])

        let secondBody = try self.decodeJSONBody(from: requests[1])
        XCTAssertNotNil(secondBody["messages"])
    }

    func testAnthropicPayload_normalizesToolCallsAndFiltersOpenAIOnlyExtras() async throws {
        MockLLMURLProtocol.configure { _, _ in
            let payload: [String: Any] = [
                "type": "message",
                "content": [[
                    "type": "text",
                    "text": "Done",
                ]],
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            return MockLLMURLProtocol.MockResponse(statusCode: 200, body: data)
        }

        let client = self.makeClient()

        let tools: [[String: Any]] = [
            [
                "type": "function",
                "function": [
                    "name": "get_weather",
                    "description": "Get weather by city",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "city": ["type": "string"],
                        ],
                        "required": ["city"],
                    ],
                ],
            ],
        ]

        let messages: [[String: Any]] = [
            ["role": "system", "content": "System behavior"],
            ["role": "user", "content": "Find weather"],
            [
                "role": "assistant",
                "content": "Checking weather",
                "tool_calls": [
                    [
                        "id": "call_weather",
                        "type": "function",
                        "function": [
                            "name": "get_weather",
                            "arguments": "{\"city\":\"Paris\"}",
                        ],
                    ],
                ],
            ],
            [
                "role": "tool",
                "tool_call_id": "call_weather",
                "content": "{\"temp_c\":21}",
            ],
        ]

        let config = LLMClient.Config(
            messages: messages,
            providerID: "anthropic",
            model: "claude-3-5-sonnet-latest",
            baseURL: "https://api.anthropic.com/v1",
            apiKey: "anthropic-test-key",
            streaming: false,
            tools: tools,
            temperature: 0.2,
            maxTokens: 512,
            extraParameters: [
                "reasoning_effort": "high",
                "enable_thinking": true,
                "metadata": ["source": "tests"],
            ]
        )

        _ = try await client.call(config)

        guard let request = MockLLMURLProtocol.requests.first else {
            XCTFail("Expected one captured request")
            return
        }

        let body = try self.decodeJSONBody(from: request)
        XCTAssertEqual(body["system"] as? String, "System behavior")
        XCTAssertEqual(body["max_tokens"] as? Int, 512)
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertNil(body["enable_thinking"])

        let metadata = body["metadata"] as? [String: String]
        XCTAssertEqual(metadata?["source"], "tests")

        guard let bodyTools = body["tools"] as? [[String: Any]],
              let firstTool = bodyTools.first
        else {
            XCTFail("Expected normalized anthropic tool payload")
            return
        }

        XCTAssertEqual(firstTool["name"] as? String, "get_weather")
        let inputSchema = firstTool["input_schema"] as? [String: Any]
        XCTAssertEqual(inputSchema?["type"] as? String, "object")

        guard let bodyMessages = body["messages"] as? [[String: Any]] else {
            XCTFail("Expected anthropic messages array")
            return
        }

        let assistantMessage = bodyMessages.first { ($0["role"] as? String) == "assistant" }
        let assistantBlocks = assistantMessage?["content"] as? [[String: Any]]
        let toolUseBlock = assistantBlocks?.first { ($0["type"] as? String) == "tool_use" }
        XCTAssertEqual(toolUseBlock?["id"] as? String, "call_weather")
        XCTAssertEqual(toolUseBlock?["name"] as? String, "get_weather")
        let toolUseInput = toolUseBlock?["input"] as? [String: Any]
        XCTAssertEqual(toolUseInput?["city"] as? String, "Paris")

        let toolResultMessage = bodyMessages.first { message in
            guard let blocks = message["content"] as? [[String: Any]] else { return false }
            return blocks.contains { ($0["type"] as? String) == "tool_result" }
        }
        let toolResultBlocks = toolResultMessage?["content"] as? [[String: Any]]
        let toolResult = toolResultBlocks?.first { ($0["type"] as? String) == "tool_result" }
        XCTAssertEqual(toolResult?["tool_use_id"] as? String, "call_weather")
    }

    func testAnthropicStreaming_parsesThinkingTextAndToolArguments() async throws {
        MockLLMURLProtocol.configure { _, _ in
            let events: [[String: Any]] = [
                [
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": [
                        "type": "thinking_delta",
                        "thinking": "Plan first.",
                    ],
                ],
                [
                    "type": "content_block_start",
                    "index": 1,
                    "content_block": [
                        "type": "tool_use",
                        "id": "toolu_1",
                        "name": "lookup",
                    ],
                ],
                [
                    "type": "content_block_delta",
                    "index": 1,
                    "delta": [
                        "type": "input_json_delta",
                        "partial_json": "{\"city\":\"Paris\"}",
                    ],
                ],
                [
                    "type": "content_block_delta",
                    "index": 2,
                    "delta": [
                        "type": "text_delta",
                        "text": "It is sunny.",
                    ],
                ],
            ]

            var streamText = ""
            for event in events {
                let eventData = try JSONSerialization.data(withJSONObject: event)
                let eventLine = String(decoding: eventData, as: UTF8.self)
                streamText += "data: \(eventLine)\\n\\n"
            }
            streamText += "data: [DONE]\\n\\n"

            return MockLLMURLProtocol.MockResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: Data(streamText.utf8)
            )
        }

        let client = self.makeClient()
        let config = LLMClient.Config(
            messages: [["role": "user", "content": "Weather in Paris?"]],
            providerID: "anthropic",
            model: "claude-3-5-sonnet-latest",
            baseURL: "https://api.anthropic.com/v1",
            apiKey: "anthropic-test-key",
            streaming: true
        )

        let response = try await client.call(config)

        XCTAssertEqual(response.thinking, "Plan first.")
        XCTAssertEqual(response.content, "It is sunny.")
        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls.first?.id, "toolu_1")
        XCTAssertEqual(response.toolCalls.first?.name, "lookup")
        XCTAssertEqual(response.toolCalls.first?.arguments["city"] as? String, "Paris")
    }

    func testAnthropicStreaming_parsesToolArgumentsWhenStartBlockContainsEmptyInput() async throws {
        MockLLMURLProtocol.configure { _, _ in
            let events: [[String: Any]] = [
                [
                    "type": "content_block_start",
                    "index": 0,
                    "content_block": [
                        "type": "tool_use",
                        "id": "toolu_2",
                        "name": "lookup",
                        "input": [:],
                    ],
                ],
                [
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": [
                        "type": "input_json_delta",
                        "partial_json": "{\"city\":\"Berlin\"}",
                    ],
                ],
                [
                    "type": "content_block_delta",
                    "index": 1,
                    "delta": [
                        "type": "text_delta",
                        "text": "Done.",
                    ],
                ],
            ]

            var streamText = ""
            for event in events {
                let eventData = try JSONSerialization.data(withJSONObject: event)
                let eventLine = String(decoding: eventData, as: UTF8.self)
                streamText += "data: \(eventLine)\\n\\n"
            }
            streamText += "data: [DONE]\\n\\n"

            return MockLLMURLProtocol.MockResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: Data(streamText.utf8)
            )
        }

        let client = self.makeClient()
        let config = LLMClient.Config(
            messages: [["role": "user", "content": "Weather in Berlin?"]],
            providerID: "anthropic",
            model: "claude-3-5-sonnet-latest",
            baseURL: "https://api.anthropic.com/v1",
            apiKey: "anthropic-test-key",
            streaming: true
        )

        let response = try await client.call(config)

        XCTAssertEqual(response.content, "Done.")
        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls.first?.id, "toolu_2")
        XCTAssertEqual(response.toolCalls.first?.arguments["city"] as? String, "Berlin")
    }

    private func makeClient() -> LLMClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockLLMURLProtocol.self]
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        return LLMClient(session: session)
    }

    private func decodeJSONBody(from request: URLRequest) throws -> [String: Any] {
        guard let body = request.httpBody else {
            XCTFail("Expected HTTP body")
            return [:]
        }
        guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            XCTFail("Expected JSON dictionary body")
            return [:]
        }
        return json
    }
}
