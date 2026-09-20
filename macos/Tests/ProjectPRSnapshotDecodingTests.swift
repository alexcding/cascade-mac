import Foundation
import Testing

struct ProjectPRSnapshotDecodingTests {
    @Test func snapshotsWithoutRefreshMetadataKeepCardsAndErrors() throws {
        let data = Data(#"""
        {"prs":[{"number":619,"title":"Cached pull request","url":"https://github.com/example/repo/pull/619","state":"OPEN"}],
         "lastSynced":"2026-09-14T12:00:00Z","error":"Background sync failed"}
        """#.utf8)
        let snapshot = try JSONDecoder().decode(ProjectPRSnapshot.self, from: data)
        #expect(snapshot.prs.first?.number == 619)
        #expect(snapshot.lastSynced == "2026-09-14T12:00:00Z")
        #expect(snapshot.error == "Background sync failed")
        #expect(!snapshot.refreshing)
    }

    @Test(arguments: [true, false]) func refreshMetadataIsPreserved(_ refreshing: Bool) throws {
        let data = Data("{\"prs\":[],\"refreshing\":\(refreshing)}".utf8)
        let snapshot = try JSONDecoder().decode(ProjectPRSnapshot.self, from: data)
        #expect(snapshot.prs.isEmpty)
        #expect(snapshot.refreshing == refreshing)
    }

    @Test func missingPullRequestsStillRejectsInvalidResponses() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ProjectPRSnapshot.self, from: Data(#"{"refreshing":false}"#.utf8))
        }
    }
}
