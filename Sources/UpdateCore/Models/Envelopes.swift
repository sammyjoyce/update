import Foundation

// MARK: - JSON Envelopes

public struct ItemEnvelope: Codable, Sendable {
    public var contractVersion: String = "1.0"
    public var kind: String = "item"
    public var item: JSONValue
    public var warnings: [WarningObject]

    public init(item: JSONValue, warnings: [WarningObject] = []) {
        self.item = item
        self.warnings = warnings
    }
}

public struct CollectionEnvelope: Codable, Sendable {
    public var contractVersion: String = "1.0"
    public var kind: String = "collection"
    public var items: [JSONValue]
    public var nextCursor: String?
    public var returnedCount: Int
    public var appliedFields: [String]?
    public var warnings: [WarningObject]

    public init(
        items: [JSONValue],
        nextCursor: String? = nil,
        appliedFields: [String]? = nil,
        warnings: [WarningObject] = []
    ) {
        self.items = items
        self.nextCursor = nextCursor
        self.returnedCount = items.count
        self.appliedFields = appliedFields
        self.warnings = warnings
    }
}

public struct MutationEnvelope: Codable, Sendable {
    public var contractVersion: String = "1.0"
    public var kind: String = "mutation"
    public var command: String
    public var dryRun: Bool
    public var plan: JSONValue?
    public var results: [MutationResult]
    public var summary: MutationSummary
    public var warnings: [WarningObject]

    public init(
        command: String,
        dryRun: Bool,
        plan: JSONValue? = nil,
        results: [MutationResult] = [],
        summary: MutationSummary? = nil,
        warnings: [WarningObject] = []
    ) {
        self.command = command
        self.dryRun = dryRun
        self.plan = plan
        self.results = results
        self.summary = summary ?? MutationSummary.from(results: results)
        self.warnings = warnings
    }
}

public struct MutationResult: Codable, Sendable {
    public var appId: String
    public var selector: String
    public var status: ItemStatus
    public var message: String
    public var details: JSONValue?

    public init(
        appId: String, selector: String, status: ItemStatus,
        message: String, details: JSONValue? = nil
    ) {
        self.appId = appId
        self.selector = selector
        self.status = status
        self.message = message
        self.details = details
    }
}

public struct MutationSummary: Codable, Sendable {
    public var status: SummaryStatus
    public var updated: Int
    public var unchanged: Int
    public var failed: Int
    public var returnedCount: Int

    public init(status: SummaryStatus, updated: Int = 0, unchanged: Int = 0, failed: Int = 0, returnedCount: Int = 0) {
        self.status = status
        self.updated = updated
        self.unchanged = unchanged
        self.failed = failed
        self.returnedCount = returnedCount
    }

    public static func from(results: [MutationResult]) -> MutationSummary {
        let updated = results.filter { [.updated, .adopted, .planned].contains($0.status) }.count
        let unchanged = results.filter { [.up_to_date, .ignored, .skipped].contains($0.status) }.count
        let failed = results.filter {
            [.permission_denied, .tool_missing, .download_failed,
             .validation_failed, .precondition_failed, .runtime_failed].contains($0.status)
        }.count
        let status: SummaryStatus
        if failed == 0 { status = .success }
        else if updated > 0 { status = .partial }
        else { status = .failed }
        return MutationSummary(
            status: status, updated: updated, unchanged: unchanged,
            failed: failed, returnedCount: results.count
        )
    }
}

// MARK: - Warning

public struct WarningObject: Codable, Sendable {
    public var code: String
    public var message: String
    public var details: [String: JSONValue]?

    public init(code: String, message: String, details: [String: JSONValue]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

// MARK: - Error envelope

public struct ErrorEnvelope: Codable, Sendable {
    public var error: ErrorDetail

    public init(_ err: ErrorDetail) { self.error = err }
    public init(_ err: UpdateError) { self.error = err.toDetail() }
}

public struct ErrorDetail: Codable, Sendable {
    public var code: String
    public var message: String
    public var hint: String?
    public var details: [String: JSONValue]?
    public var traceId: String?

    public init(
        code: String, message: String, hint: String? = nil,
        details: [String: JSONValue]? = nil, traceId: String? = nil
    ) {
        self.code = code
        self.message = message
        self.hint = hint
        self.details = details
        self.traceId = traceId
    }
}

// MARK: - NDJSON events

public enum NDJSONEvent: Sendable {
    case item(JSONValue)
    case plan(JSONValue)
    case result(MutationResult)
    case warning(WarningObject)
    case error(ErrorDetail)
    case summary(NDJSONSummary)

    public func toJSONValue() -> JSONValue {
        switch self {
        case .item(let val):
            return .object(["type": "item", "item": val])
        case .plan(let val):
            return .object(["type": "plan", "plan": val])
        case .result(let r):
            return .object([
                "type": "result",
                "app_id": .string(r.appId),
                "selector": .string(r.selector),
                "status": .string(r.status.rawValue),
                "message": .string(r.message),
            ])
        case .warning(let w):
            return .object([
                "type": "warning",
                "warning": .object(["code": .string(w.code), "message": .string(w.message)]),
            ])
        case .error(let e):
            return .object([
                "type": "error",
                "error": .object(["code": .string(e.code), "message": .string(e.message)]),
            ])
        case .summary(let s):
            return .object([
                "type": "summary",
                "returned_count": .int(s.returnedCount),
                "next_cursor": s.nextCursor.map { .string($0) } ?? .null,
            ])
        }
    }
}

public struct NDJSONSummary: Sendable {
    public var returnedCount: Int
    public var nextCursor: String?

    public init(returnedCount: Int, nextCursor: String? = nil) {
        self.returnedCount = returnedCount
        self.nextCursor = nextCursor
    }
}
