import Foundation
import Testing
@testable import Cascade

/// The app's agent CLIs are its drivers (`AgentDrivers.all`). The lists that name them as cases,
/// what a session runs and what Settings manages, must name each, and name no other.
@Test func everyAgentCLIIsASessionAgentAndAManagedTool() {
    let drivers = Set(AgentDrivers.all.map(\.cli))
    #expect(Set(SessionAgent.allCases.compactMap { $0.driver?.cli }) == drivers)
    #expect(Set(SessionAgent.allCases.filter { $0 != .shell }.map(\.rawValue)) == drivers)
    #expect(Set(ManagedCLI.allCases.compactMap { $0.agent?.cli }) == drivers)
    #expect(ManagedCLI.allCases.filter(\.supportsHooks).map(\.rawValue).allSatisfy(drivers.contains))
}

@Test func aCLINobodyKnowsIsRunAsTheDefaultButMarkedAsAShell() {
    #expect(AgentDrivers.of("gemini") == nil && AgentDrivers.of(nil) == nil)
    #expect(AgentDrivers.driver(for: nil).cli == AgentDrivers.primary.cli)
    #expect(PageSessionMark(cli: "gemini").asset == nil && PageSessionMark(cli: nil).glyph == "❯")
    #expect(SessionAgent.primary.driver?.cli == AgentDrivers.primary.cli)
}

@Test func usageIsReadUnderEachCLIsID() throws {
    let json = #"{"agents":{"codex":{"usage":{"tokens":5,"cost":1},"limits":{"session":{"usedPct":40,"resetsAt":null,"label":null}}}},"asOf":"now"}"#
    let usage = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
    #expect(usage.usage(of: "codex")?.tokens == 5 && usage.limits(of: "codex")?.session?.usedPct == 40)
    #expect(usage.usage(of: "claude") == nil)
}
