import Foundation
import Testing
@testable import Cascade

struct ActivityEventPayloadTests {
    // The Rust and Node backends broadcast the log row verbatim: payload is a JSON string.
    @Test func decodesStringPayloadFromServerEvent() throws {
        let data = Data(#"{"event":{"created_at":"2026-09-15T03:07:38.624Z","level":"info","payload":"{\"repo\":\"acme/widgets\"}","type":"forwarder_started"},"type":"activity"}"#.utf8)
        let event = try JSONDecoder().decode(ServerEvent.self, from: data)
        #expect(event.event?.type == "forwarder_started")
        #expect(event.event?.payload?.repo == "acme/widgets")
        #expect(event.event?.message.title == "Webhook forwarding started")
    }

    @Test func decodesObjectPayload() throws {
        let data = Data(#"{"type":"sync_failed","payload":{"repo":"o/r","error":"Offline"}}"#.utf8)
        let event = try JSONDecoder().decode(ActivityEvent.self, from: data)
        #expect(event.payload?.error == "Offline")
    }

    /// What the backend caught up on after a gap: each change is marked quiet, and one line
    /// counts them, naming only what there was.
    @Test func decodesACatchUpAndItsQuietLines() throws {
        let quiet = try JSONDecoder().decode(ActivityEvent.self, from: Data(#"{"type":"pr_opened","payload":"{\"repo\":\"o/r\",\"pr\":{\"number\":7,\"title\":\"T\"},\"quiet\":true}"}"#.utf8))
        #expect(quiet.payload?.quiet == true)
        let counted = try JSONDecoder().decode(ActivityEvent.self, from: Data(#"{"type":"prs_caught_up","payload":{"repo":"o/r","opened":2,"closed":0,"merged":1}}"#.utf8))
        #expect(counted.payload?.quiet == nil)
        #expect(counted.message.title == "Pull requests changed in r")
        #expect(counted.message.body == "2 opened · 1 merged")
    }

    @Test func toleratesUnparseablePayload() throws {
        for json in [#"{"type":"x","payload":"not json"}"#, #"{"type":"x","payload":42}"#, #"{"type":"x","payload":null}"#, #"{"type":"x"}"#] {
            let event = try JSONDecoder().decode(ActivityEvent.self, from: Data(json.utf8))
            #expect(event.payload == nil)
        }
    }
}
