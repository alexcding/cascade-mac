import Foundation

struct PtySnapshot: Sendable {
    static let revision = "82938b633ba646db38591d969c3c526332bd7e65-taskhub-appearance-v3"
    static let limit = 192 * 1024 * 1024
    static let chunkBytes = 128 * 1024

    struct Header: Decodable, Sendable {
        let token: UInt64
        let size: Int
        let chunkBytes: Int
        let seq: UInt64
        let stateSeq: UInt64
        let cols: UInt16
        let rows: UInt16
        let revision: String
        var geometry: PtyGeometry? = nil
        var appearance: PtyAppearance? = nil

        func validate() throws {
            try appearance?.validate()
            if appearance != nil, geometry == nil { throw PtyError.connection("Snapshot appearance requires native geometry ownership.") }
            if let geometry {
                try geometry.validate()
                guard geometry.cols == cols, geometry.rows == rows else {
                    throw PtyError.connection("The snapshot geometry does not match its grid dimensions.")
                }
            }
            guard token > 0, size > 0, size <= PtySnapshot.limit,
                  chunkBytes == PtySnapshot.chunkBytes, revision == PtySnapshot.revision,
                  seq <= stateSeq, stateSeq < UInt64.max,
                  cols > 0, rows > 0, cols <= 4096, rows <= 4096,
                  UInt32(cols) * UInt32(rows) <= 1024 * 1024 else {
                throw PtyError.connection("The daemon returned an incompatible or invalid terminal snapshot header.")
            }
        }
    }

    struct Chunk: Decodable, Sendable {
        let token: UInt64
        let offset: Int
        let bytes: Data
        let done: Bool
    }

    let header: Header
    let bytes: Data
}

// One immutable capture per connection. Requesting chunks keeps a large snapshot
// out of the socket's bounded outbox; validation precedes every buffer append.
struct PtySnapshotDownloader: Sendable {
    let client: PtydClient

    func fetch(term: String) async throws -> PtySnapshot {
        let header: PtySnapshot.Header = try await client.request(.init(op: "snapshotBegin", term: term))
        do {
            try header.validate()
            var bytes = Data()
            bytes.reserveCapacity(header.size)
            while bytes.count < header.size {
                try Task.checkCancellation()
                let chunk: PtySnapshot.Chunk = try await client.request(.init(
                    op: "snapshotRead", token: header.token, offset: bytes.count))
                let expected = min(header.chunkBytes, header.size - bytes.count)
                guard chunk.token == header.token, chunk.offset == bytes.count,
                      chunk.bytes.count == expected,
                      chunk.done == (bytes.count + expected == header.size) else {
                    throw PtyError.connection("The daemon returned an incomplete or out-of-order terminal snapshot chunk.")
                }
                bytes.append(chunk.bytes)
            }
            let _: Bool? = try await client.request(.init(op: "snapshotEnd", token: header.token))
            return PtySnapshot(header: header, bytes: bytes)
        } catch {
            // Cancellation still sends the release; request() checks cancellation
            // after receiving its reply. Disconnect also frees the daemon capture.
            let _: Bool? = try? await client.request(.init(op: "snapshotEnd", token: header.token))
            throw error
        }
    }
}
