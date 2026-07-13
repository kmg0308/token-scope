import Foundation
import TokenMeterCore

extension TokenMeterSelfTest {
    static func runParserTests() throws {
        try codexParserUsesDeltasAndSkipsRepeatedTotals()
        try codexParserComputesTotalWhenTotalTokensAreMissing()
        try codexParserSkipsUsageRecordsWithoutValidTimestamps()
        try codexParserUsesInvalidTimestampTotalsOnlyAsDeltaBaselines()
        try codexParserRejectsOutOfRangeCanonicalSeconds()
        try codexParserSkipsInheritedUsageInForkedSessions()
        try claudeParserDeduplicatesRequestIDs()
        try claudeParserFallsBackFromEmptyRequestID()
        try claudeParserSkipsUsageRecordsWithoutValidTimestamps()
        try claudeParserAllowsValidDuplicateAfterInvalidRecord()
        try claudeParserIgnoresMalformedNumericTokenFields()
    }

    static func codexParserUsesDeltasAndSkipsRepeatedTotals() throws {
        let url = temporaryFile("""
        {"timestamp":"2026-01-01T00:00:00.000Z","payload":{"type":"session_meta","cwd":"/tmp/project","model":"gpt-5.2-codex"}}
        {"timestamp":"2026-01-01T00:00:01.000Z","payload":{"info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":5,"output_tokens":2,"reasoning_output_tokens":1,"total_tokens":12},"last_token_usage":{"input_tokens":10,"cached_input_tokens":5,"output_tokens":2,"reasoning_output_tokens":1,"total_tokens":12}}}}
        {"timestamp":"2026-01-01T00:00:02.000Z","payload":{"info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":5,"output_tokens":2,"reasoning_output_tokens":1,"total_tokens":12},"last_token_usage":{"input_tokens":10,"cached_input_tokens":5,"output_tokens":2,"reasoning_output_tokens":1,"total_tokens":12}}}}
        {"timestamp":"2026-01-01T00:00:03.000Z","payload":{"info":{"total_token_usage":{"input_tokens":18,"cached_input_tokens":8,"output_tokens":4,"reasoning_output_tokens":1,"total_tokens":22},"last_token_usage":{"input_tokens":8,"cached_input_tokens":3,"output_tokens":2,"reasoning_output_tokens":0,"total_tokens":10}}}}
        """)

        let events = try TokenLogParser.parseCodexFile(at: url)
        try expect(events.count == 2, "Codex event count")
        try expect(events.map(\.usage.total) == [12, 10], "Codex deltas")
        try expect(events.first?.projectPath == "/tmp/project", "Codex project")
        try expect(events.first?.model == "gpt-5.2-codex", "Codex model")
    }

    static func codexParserComputesTotalWhenTotalTokensAreMissing() throws {
        let url = temporaryFile("""
        {"timestamp":"2026-01-01T00:00:00.000Z","payload":{"type":"session_meta","cwd":"/tmp/project","model":"gpt-5.2-codex"}}
        {"timestamp":"2026-01-01T00:00:01.000Z","payload":{"info":{"last_token_usage":{"input_tokens":12,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":1}}}}
        """)

        let events = try TokenLogParser.parseCodexFile(at: url)
        try expect(events.count == 1, "Codex missing total event count")
        try expect(events.first?.usage.total == 15, "Codex missing total falls back to component sum")
        try expect(events.first?.usage.cachedInput == 2, "Codex missing total keeps cached input")
        try expect(events.first?.usage.reasoning == 1, "Codex missing total keeps reasoning")
    }

    static func codexParserSkipsUsageRecordsWithoutValidTimestamps() throws {
        let url = temporaryFile("""
        {"timestamp":"2026-01-01T00:00:00.000Z","payload":{"type":"session_meta","cwd":"/tmp/project","model":"gpt-5.2-codex"}}
        {"timestamp":"not-a-date","payload":{"info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0}}}}
        {"payload":{"timestamp":"also-not-a-date","info":{"last_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0}}}}
        {"payload":{"timestamp":"2026-01-01T00:00:01.000Z","info":{"last_token_usage":{"input_tokens":3,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0}}}}
        """)

        let events = try TokenLogParser.parseCodexFile(at: url)
        try expect(events.count == 1, "Codex parser skips invalid timestamp usage records")
        try expect(events.first?.usage.total == 3, "Codex parser keeps valid timestamp usage record")
        try expect(events.first?.timestamp == isoDate("2026-01-01T00:00:01.000Z"), "Codex parser uses valid payload timestamp")
    }

    static func codexParserUsesInvalidTimestampTotalsOnlyAsDeltaBaselines() throws {
        let url = temporaryFile("""
        {"timestamp":"2026-01-01T00:00:00.000Z","payload":{"type":"session_meta","cwd":"/tmp/project","model":"gpt-5.2-codex"}}
        {"timestamp":"not-a-date","payload":{"info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":100}}}}
        {"timestamp":"2026-01-01T00:00:01.000Z","payload":{"info":{"total_token_usage":{"input_tokens":110,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":110}}}}
        """)

        let events = try TokenLogParser.parseCodexFile(at: url)
        try expect(events.count == 1, "Codex invalid timestamp total is not emitted")
        try expect(events.first?.usage.total == 10, "Codex invalid timestamp total still prevents overcounting")
    }

    static func codexParserRejectsOutOfRangeCanonicalSeconds() throws {
        let url = temporaryFile("""
        {"timestamp":"2026-01-01T00:00:60.000Z","payload":{"info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0}}}}
        {"timestamp":"2026-01-01T00:00:59.000Z","payload":{"info":{"last_token_usage":{"input_tokens":4,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0}}}}
        """)

        let events = try TokenLogParser.parseCodexFile(at: url)
        try expect(events.count == 1, "Codex parser rejects out-of-range canonical seconds")
        try expect(events.first?.usage.total == 4, "Codex parser keeps valid canonical seconds")
        try expect(events.first?.timestamp == isoDate("2026-01-01T00:00:59.000Z"), "Codex parser keeps valid second timestamp")
    }

    static func codexParserSkipsInheritedUsageInForkedSessions() throws {
        let url = temporaryFile("""
        {"timestamp":"2026-01-01T00:00:10.000Z","type":"session_meta","payload":{"id":"01900000-2000-7000-8000-000000000000","session_id":"01900000-1000-7000-8000-000000000000","forked_from_id":"01900000-1000-7000-8000-000000000000","cwd":"/tmp/project","model":"gpt-5.2-codex"}}
        {"timestamp":"2026-01-01T00:00:10.000Z","type":"session_meta","payload":{"id":"01900000-1000-7000-8000-000000000000","session_id":"01900000-1000-7000-8000-000000000000"}}
        {"timestamp":"2026-01-01T00:00:10.001Z","type":"event_msg","payload":{"type":"task_started","turn_id":"01900000-1001-7000-8000-000000000000"}}
        {"timestamp":"2026-01-01T00:00:10.001Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":5,"output_tokens":2,"reasoning_output_tokens":1,"total_tokens":12},"last_token_usage":{"input_tokens":10,"cached_input_tokens":5,"output_tokens":2,"reasoning_output_tokens":1,"total_tokens":12}}}}
        {"timestamp":"2026-01-01T00:00:10.002Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":18,"cached_input_tokens":8,"output_tokens":4,"reasoning_output_tokens":1,"total_tokens":22},"last_token_usage":{"input_tokens":8,"cached_input_tokens":3,"output_tokens":2,"reasoning_output_tokens":0,"total_tokens":10}}}}
        {"timestamp":"2026-01-01T00:00:10.100Z","type":"event_msg","payload":{"type":"task_started","turn_id":"01900000-2001-7000-8000-000000000000"}}
        {"timestamp":"2026-01-01T00:00:11.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":24,"cached_input_tokens":11,"output_tokens":5,"reasoning_output_tokens":1,"total_tokens":29},"last_token_usage":{"input_tokens":6,"cached_input_tokens":3,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":7}}}}
        """)

        let events = try TokenLogParser.parseCodexFile(at: url)
        try expect(events.count == 1, "Codex fork parser excludes inherited token records")
        try expect(events.first?.usage.total == 7, "Codex fork parser keeps only the child task usage")
        try expect(events.first?.timestamp == isoDate("2026-01-01T00:00:11.000Z"), "Codex fork parser keeps the child task timestamp")
    }

    static func claudeParserDeduplicatesRequestIDs() throws {
        let url = temporaryFile("""
        {"timestamp":"2026-01-01T00:00:00.000Z","sessionId":"s1","requestId":"r1","uuid":"u1","cwd":"/tmp/project","type":"assistant","message":{"model":"claude-opus","usage":{"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"output_tokens":4}}}
        {"timestamp":"2026-01-01T00:00:01.000Z","sessionId":"s1","requestId":"r1","uuid":"u2","cwd":"/tmp/project","type":"assistant","message":{"model":"claude-opus","usage":{"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"output_tokens":4}}}
        {"timestamp":"2026-01-01T00:00:02.000Z","sessionId":"s1","requestId":"r2","uuid":"u3","cwd":"/tmp/project","type":"assistant","message":{"model":"claude-opus","usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":5,"output_tokens":5}}}
        """)

        let events = try TokenLogParser.parseClaudeFile(at: url)
        try expect(events.count == 2, "Claude event count")
        try expect(events.map(\.usage.total) == [10, 20], "Claude totals")
        try expect(events.first?.source == .claude, "Claude source")
    }

    static func claudeParserFallsBackFromEmptyRequestID() throws {
        let url = temporaryFile("""
        {"timestamp":"2026-01-01T00:00:00.000Z","sessionId":"","requestId":"","uuid":"u1","cwd":"/tmp/project","type":"assistant","message":{"model":"claude-opus","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}
        {"timestamp":"2026-01-01T00:00:01.000Z","sessionId":"","requestId":"","uuid":"u2","cwd":"/tmp/project","type":"assistant","message":{"model":"claude-opus","usage":{"input_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}
        """)

        let events = try TokenLogParser.parseClaudeFile(at: url)
        try expect(events.count == 2, "Claude empty request id falls back to uuid")
        try expect(events.map(\.usage.total) == [1, 2], "Claude empty request id keeps both events")
        try expect(events.allSatisfy { $0.sessionId == "sample" }, "Claude empty session id falls back to filename")
    }

    static func claudeParserSkipsUsageRecordsWithoutValidTimestamps() throws {
        let url = temporaryFile("""
        {"timestamp":"not-a-date","sessionId":"s1","requestId":"invalid","uuid":"u1","cwd":"/tmp/project","type":"assistant","message":{"model":"claude-opus","usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}
        {"timestamp":"2026-01-01T00:00:00.000Z","sessionId":"s1","requestId":"valid","uuid":"u2","cwd":"/tmp/project","type":"assistant","message":{"model":"claude-opus","usage":{"input_tokens":4,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}
        """)

        let events = try TokenLogParser.parseClaudeFile(at: url)
        try expect(events.count == 1, "Claude parser skips invalid timestamp usage records")
        try expect(events.first?.id != nil, "Claude parser keeps valid timestamp usage record")
        try expect(events.first?.usage.total == 4, "Claude parser keeps valid timestamp total")
        try expect(events.first?.timestamp == isoDate("2026-01-01T00:00:00.000Z"), "Claude parser uses valid timestamp")
    }

    static func claudeParserAllowsValidDuplicateAfterInvalidRecord() throws {
        let url = temporaryFile("""
        {"timestamp":"not-a-date","sessionId":"s1","requestId":"same-request","uuid":"u1","cwd":"/tmp/project","type":"assistant","message":{"model":"claude-opus","usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}
        {"timestamp":"2026-01-01T00:00:00.000Z","sessionId":"s1","requestId":"zero-first","uuid":"u2","cwd":"/tmp/project","type":"assistant","message":{"model":"claude-opus","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}
        {"timestamp":"2026-01-01T00:00:01.000Z","sessionId":"s1","requestId":"same-request","uuid":"u3","cwd":"/tmp/project","type":"assistant","message":{"model":"claude-opus","usage":{"input_tokens":4,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}
        {"timestamp":"2026-01-01T00:00:02.000Z","sessionId":"s1","requestId":"zero-first","uuid":"u4","cwd":"/tmp/project","type":"assistant","message":{"model":"claude-opus","usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}
        """)

        let events = try TokenLogParser.parseClaudeFile(at: url)
        try expect(events.map(\.usage.total) == [4, 5], "Claude invalid or zero duplicate records do not hide later valid usage")
        try expect(
            events.map(\.timestamp) == [
                isoDate("2026-01-01T00:00:01.000Z"),
                isoDate("2026-01-01T00:00:02.000Z")
            ],
            "Claude duplicate recovery keeps valid timestamps"
        )
    }

    static func claudeParserIgnoresMalformedNumericTokenFields() throws {
        let url = temporaryFile("""
        {"timestamp":"2026-01-01T00:00:00.000Z","sessionId":"s1","requestId":"malformed-number","uuid":"u1","cwd":"/tmp/project","type":"assistant","message":{"model":"claude-opus","usage":{"input_tokens":true,"cache_creation_input_tokens":1.5,"cache_read_input_tokens":9223372036854775808,"output_tokens":4}}}
        {"timestamp":"2026-01-01T00:00:01.000Z","sessionId":"s1","requestId":"negative-component","uuid":"u2","cwd":"/tmp/project","type":"assistant","message":{"model":"claude-opus","usage":{"input_tokens":-100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}
        """)

        let events = try TokenLogParser.parseClaudeFile(at: url)
        try expect(events.map(\.usage.total) == [4, 5], "Claude parser ignores malformed numeric token fields")
        try expect(events.first?.usage.input == 0, "Claude parser ignores boolean token fields")
        try expect(events.first?.usage.cacheCreation == 0, "Claude parser ignores decimal token fields")
        try expect(events.first?.usage.cacheRead == 0, "Claude parser ignores overflowing token fields")
        try expect(events.last?.usage.input == 0, "Claude parser clamps negative token fields")
    }
}
