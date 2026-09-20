import Foundation
import Testing

@Test func boardBridgeAcceptsOnlyTicketLinksFromItsOwnMainDocument() throws {
    let page = try #require(URL(string: "http://127.0.0.1:12345/native/board.html?project=p"))
    let link: [String: Any] = ["type": "openTicket", "url": "https://jira.test/browse/REC-42", "title": "REC-42", "external": false]
    #expect(BoardTicketLink.parse(link, source: page, expected: page, mainFrame: true)?.title == "REC-42")
    #expect(BoardTicketLink.parse(link, source: page, expected: page, mainFrame: false) == nil)
    #expect(BoardTicketLink.parse(link, source: URL(string: "http://127.0.0.1:12345/other"), expected: page, mainFrame: true) == nil)
    #expect(BoardTicketLink.parse(link, source: URL(string: "http://127.0.0.1:54321/native/board.html?project=p"), expected: page, mainFrame: true) == nil)
    for raw in ["file:///tmp/local", "javascript:alert(1)", "https://user:secret@jira.test/browse/REC-42", "https://github.com/o/r/pull/1"] {
        var invalid = link; invalid["url"] = raw
        #expect(BoardTicketLink.parse(invalid, source: page, expected: page, mainFrame: true) == nil)
    }
    var oversized = link; oversized["title"] = String(repeating: "x", count: 9000)
    #expect(BoardTicketLink.parse(oversized, source: page, expected: page, mainFrame: true) == nil)
}
