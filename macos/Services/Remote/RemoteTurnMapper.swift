import Foundation

/// Cuts the chat's turns down to what a phone shows: the conversation's last turns, each block
/// capped, file-change bodies left on the Mac.
enum RemoteTurnMapper {
    struct Limits: Equatable, Sendable {
        var text = 16_000
        var thinking = 2_000
        var field = 2_000
        var output = 4_000

        /// A turn that still does not fit a record gets these.
        static let tight = Limits(text: 4_000, thinking: 0, field: 500, output: 0)
    }

    /// `known` is the order each turn already mirrored was given: a turn keeps its place, so one
    /// without a time is not sent again just because the window of turns moved on.
    static func turns(_ turns: [TranscriptTurn], session: String, host: String, known: [String: Double] = [:],
                      limits: Limits = Limits()) -> [RemoteTurn] {
        var previous = 0.0
        return turns.suffix(RemoteSchema.turnsPerSession).map { turn in
            // Turns sort by time; one without a time goes just after the one before it.
            let stamp = known[turn.id] ?? turn.date.map { $0.timeIntervalSince1970 * 1000 } ?? previous + 1
            let order = max(stamp, previous + 0.001)
            previous = order
            return fitted(turn, session: session, host: host, order: order, limits: limits)
        }
    }

    private static func fitted(_ turn: TranscriptTurn, session: String, host: String, order: Double, limits: Limits) -> RemoteTurn {
        let mapped = map(turn, session: session, host: host, order: order, limits: limits)
        if fits(mapped) { return mapped }
        var tight = map(turn, session: session, host: host, order: order, limits: .tight)
        // A turn of hundreds of tool calls can outgrow a record even cut down: its earliest
        // blocks go, and the first one left says so.
        while !fits(tight), tight.blocks.count > 1 {
            tight.blocks.removeFirst(max(1, tight.blocks.count / 4))
            tight.blocks[0].truncated = true
        }
        return tight
    }

    private static func fits(_ turn: RemoteTurn) -> Bool {
        ((try? RemoteCodec.encoder.encode(turn).count) ?? .max) <= RemoteSchema.maxPayload
    }

    private static func map(_ turn: TranscriptTurn, session: String, host: String, order: Double, limits: Limits) -> RemoteTurn {
        RemoteTurn(id: turn.id, session: session, host: host, role: turn.role == .user ? .user : .assistant,
                   timestamp: turn.date, order: order,
                   blocks: turn.blocks.compactMap { block(of: $0, limits: limits) })
    }

    private static func block(of block: TranscriptBlock, limits: Limits) -> RemoteTurn.Block? {
        var cut = false
        func fit(_ value: String?, _ limit: Int) -> String? {
            guard let value else { return nil }
            guard value.count > limit else { return value }
            cut = true
            return limit > 0 ? String(value.prefix(limit)) + "…" : nil
        }
        var result: RemoteTurn.Block
        switch block.type {
        case .text:
            result = .init(type: .text, text: fit(block.text, limits.text))
        case .thinking:
            guard limits.thinking > 0 else { return nil }
            result = .init(type: .thinking, text: fit(block.text, limits.thinking))
        case .tool:
            result = .init(type: .tool, name: block.name, summary: fit(block.summary, limits.field),
                           command: fit(block.command, limits.field), path: block.path,
                           output: fit(block.output, limits.output), isError: block.isError, kind: block.kind)
        }
        result.truncated = cut ? true : nil
        return result
    }
}
