import Compression
import Foundation

/// A zip archive's files, read in place. Each entry is inflated on its own and may not grow past
/// the size the archive declares for it, so a small archive cannot unpack into a large one; the
/// caller caps the declared sizes. Reads what `.vsix` packages use — stored and deflated
/// entries — and refuses encryption and ZIP64.
struct ZipArchive {
    struct Entry: Sendable {
        let name: String
        /// Its unpacked size, as the archive declares it.
        let size: Int
        let isDirectory: Bool
        /// A symbolic link, from the Unix mode an archive made on Unix records.
        let isLink: Bool
        fileprivate let compressedSize: Int
        fileprivate let method: UInt16
        fileprivate let localHeader: Int
    }

    enum Failure: Error { case malformed, unsupported, tooLarge }

    let entries: [Entry]
    private let data: Data

    init(contentsOf url: URL) throws {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        entries = try Self.centralDirectory(of: data)
    }

    /// An entry's unpacked bytes; `tooLarge` if they outgrow its declared size.
    func contents(of entry: Entry) throws -> Data {
        let header = entry.localHeader
        guard try data.uint32(at: header) == 0x0403_4b50 else { throw Failure.malformed }
        let start = header + 30 + Int(try data.uint16(at: header + 26)) + Int(try data.uint16(at: header + 28))
        guard start + entry.compressedSize <= data.count else { throw Failure.malformed }
        let packed = data[(data.startIndex + start)..<(data.startIndex + start + entry.compressedSize)]
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.size else { throw Failure.malformed }
            return Data(packed)
        case 8:
            return try Self.inflate(packed, size: entry.size)
        default:
            throw Failure.unsupported
        }
    }

    private static func centralDirectory(of data: Data) throws -> [Entry] {
        // The end record is the last 22 bytes, or sits before a comment of up to 64 KB.
        guard data.count >= 22 else { throw Failure.malformed }
        var end = data.count - 22
        let lowest = max(0, end - 0xFFFF)
        while try data.uint32(at: end) != 0x0605_4b50 {
            guard end > lowest else { throw Failure.malformed }
            end -= 1
        }
        let count = Int(try data.uint16(at: end + 10))
        var position = Int(try data.uint32(at: end + 16))
        guard count != 0xFFFF, position != 0xFFFF_FFFF else { throw Failure.unsupported }
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            guard try data.uint32(at: position) == 0x0201_4b50 else { throw Failure.malformed }
            let madeBy = try data.uint16(at: position + 4), flags = try data.uint16(at: position + 8)
            let method = try data.uint16(at: position + 10)
            let compressed = try data.uint32(at: position + 20), size = try data.uint32(at: position + 24)
            let nameLength = Int(try data.uint16(at: position + 28))
            let skip = nameLength + Int(try data.uint16(at: position + 30)) + Int(try data.uint16(at: position + 32))
            let attributes = try data.uint32(at: position + 38), local = try data.uint32(at: position + 42)
            guard flags & 1 == 0, compressed != 0xFFFF_FFFF, size != 0xFFFF_FFFF, local != 0xFFFF_FFFF else { throw Failure.unsupported }
            guard position + 46 + nameLength <= data.count else { throw Failure.malformed }
            let nameStart = data.startIndex + position + 46
            let name = String(decoding: data[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            let isLink = madeBy >> 8 == 3 && (attributes >> 16) & 0o170000 == 0o120000
            entries.append(Entry(name: name, size: Int(size), isDirectory: name.hasSuffix("/"), isLink: isLink,
                                 compressedSize: Int(compressed), method: method, localHeader: Int(local)))
            position += 46 + skip
        }
        return entries
    }

    /// Raw DEFLATE, fed a piece at a time so an entry that outgrows `size` stops early.
    private static func inflate(_ packed: Data, size: Int) throws -> Data {
        var output = Data()
        output.reserveCapacity(size)
        let filter = try OutputFilter(.decompress, using: .zlib) { chunk in
            guard let chunk else { return }
            guard output.count + chunk.count <= size else { throw Failure.tooLarge }
            output.append(chunk)
        }
        var offset = packed.startIndex
        while offset < packed.endIndex {
            let next = min(offset + 65_536, packed.endIndex)
            try filter.write(packed[offset..<next])
            offset = next
        }
        try filter.finalize()
        guard output.count == size else { throw Failure.malformed }
        return output
    }
}

private extension Data {
    func uint16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { throw ZipArchive.Failure.malformed }
        let base = startIndex + offset
        return UInt16(self[base]) | UInt16(self[base + 1]) << 8
    }

    func uint32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { throw ZipArchive.Failure.malformed }
        let base = startIndex + offset
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[base + $1]) << (8 * $1) }
    }
}
