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

    @Test func toleratesUnparseablePayload() throws {
        for json in [#"{"type":"x","payload":"not json"}"#, #"{"type":"x","payload":42}"#, #"{"type":"x","payload":null}"#, #"{"type":"x"}"#] {
            let event = try JSONDecoder().decode(ActivityEvent.self, from: Data(json.utf8))
            #expect(event.payload == nil)
        }
    }
}
