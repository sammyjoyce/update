import Foundation
import Testing
@testable import UpdateCore

@Test func selectorParserRejectsUnsafePercentEncodedSelectors() throws {
    let result = SelectorParser.parse("path:/Applications/%2e%2e/Evil.app")
    switch result {
    case .success:
        Issue.record("Expected unsafe selector parsing to fail")
    case .failure(let error):
        #expect(error.code == "unsafe_selector")
    }
}

@Test func planPreconditionValidationDetectsVersionDrift() {
    let record = AppRecord(
        appId: "app_123",
        name: "Example",
        bundleId: "com.example.app",
        path: "/Applications/Example.app",
        installedVersion: "1.0.0",
        selectedCandidate: UpdateCandidate(provider: .brew, executor: .brew_cask, availableVersion: "1.2.0")
    )
    let matching = PlanPrecondition(appId: "app_123", installedVersion: "1.0.0", candidateVersion: "1.2.0", provider: .brew)
    let drifted = PlanPrecondition(appId: "app_123", installedVersion: "0.9.0", candidateVersion: "1.2.0", provider: .brew)

    #expect(matching.validate(against: record))
    #expect(!drifted.validate(against: record))
}

@Test func fieldMaskRetainsRequestedNestedFieldsOnly() throws {
    let value = try JSONValue.from(
        AppRecord(
            appId: "app_123",
            name: "Chrome",
            bundleId: "com.google.Chrome",
            path: "/Applications/Google Chrome.app",
            installedVersion: "1.0.0",
            selectedCandidate: UpdateCandidate(provider: .brew, executor: .brew_cask, availableVersion: "1.1.0")
        )
    )

    let masked = FieldMask.apply(fields: ["app_id", "selected_candidate.provider"], to: value)
    #expect(MutationSupportLike.string(masked["app_id"]) == "app_123")
    #expect(MutationSupportLike.string(masked["selected_candidate"]?["provider"]) == "brew")
    #expect(masked["name"] == nil)
}

private enum MutationSupportLike {
    static func string(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let value): return value
        default: return nil
        }
    }
}
