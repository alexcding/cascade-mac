import Foundation

struct LogEntry: Decodable, Identifiable, Equatable, Sendable {
    let seq: Int
    let category: String
    let level: String
    let type: String?
    let payload: String?
    let created_at: String
    let title: String
    let detail: String
    /// The event's own one-line summary, without the raw-payload fallback `detail` uses.
    let summary: String
    let link: String?
    let jiraKey: String?
    var id: Int { seq }
    var date: Date? { backendTimestamp(created_at) }
    var timestamp: String { date?.formatted(date: .abbreviated, time: .shortened) ?? created_at }

    enum CodingKeys: String, CodingKey { case seq, category, level, type, payload, created_at }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        seq = try values.decode(Int.self, forKey: .seq)
        category = try values.decode(String.self, forKey: .category)
        level = try values.decode(String.self, forKey: .level)
        type = try values.decodeIfPresent(String.self, forKey: .type)
        payload = try values.decodeIfPresent(String.self, forKey: .payload)
        created_at = try values.decode(String.self, forKey: .created_at)
        // Decoded on APIClient's actor, including event interpretation and JSON formatting.
        let data = Data((payload ?? "").utf8)
        let eventPayload = try? JSONDecoder().decode(ActivityEvent.Payload.self, from: data)
        let notice = ActivityEvent(type: type ?? "", payload: eventPayload, created_at: created_at).message
        title = notice.title
        summary = notice.body
        if !notice.body.isEmpty { detail = notice.body }
        else if let object = try? JSONSerialization.jsonObject(with: data),
                JSONSerialization.isValidJSONObject(object),
                let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
                let text = String(data: formatted, encoding: .utf8) { detail = text }
        else { detail = payload ?? "" }
        link = notice.url
        jiraKey = eventPayload?.key
    }
}

protocol LogService: Sendable {
    func entries(category: String, errorsOnly: Bool) async throws -> [LogEntry]
    func categories() async throws -> [String]
    func clear(category: String) async throws
}

struct APILogService: LogService {
    let api: APIClient
    func entries(category: String, errorsOnly: Bool) async throws -> [LogEntry] {
        var query = ["category": category, "limit": "200"]
        if errorsOnly { query["level"] = "error" }
        return try await api.get(APIClient.query(Routes.LOGS, query))
    }
    func categories() async throws -> [String] { try await api.get(Routes.LOGS_CATEGORIES) }
    func clear(category: String) async throws {
        let _: OperationOK = try await api.request(Routes.LOGS_CLEAR, method: "POST", body: ["category": category])
    }
}
