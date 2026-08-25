import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case notAuthenticated
    case unauthorized          // 401 — token invalid/expired → sign out
    case forbidden             // 403 — authenticated but not permitted → keep session
    case http(Int, String?)
    case decoding(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The server URL is not valid."
        case .notAuthenticated: return "You are not signed in."
        case .unauthorized: return "The API token was rejected (401). Check the token and server URL."
        case .forbidden: return "You don't have permission to do that in this organization (403)."
        case .http(let code, let message):
            return message ?? "The server returned an error (\(code))."
        case .decoding(let error): return "Could not read the server response. \(error.localizedDescription)"
        case .transport(let error): return error.localizedDescription
        }
    }
}

/// Talks to a self-hosted SolidTime instance. Base URL is the instance host;
/// all calls hit `<host>/api/v1/...` with a Bearer personal access token.
struct APIClient {
    let baseURL: URL          // e.g. https://my.solidtime.example
    let token: String

    private var session: URLSession { .shared }

    // MARK: Request building

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("api/v1" + path), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw APIError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        req.timeoutInterval = 30
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw APIError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.http(-1, "No HTTP response")
        }
        switch http.statusCode {
        case 200...299:
            return data
        case 401:
            throw APIError.unauthorized
        case 403:
            throw APIError.forbidden
        default:
            throw APIError.http(http.statusCode, serverMessage(from: data))
        }
    }

    private func serverMessage(from data: Data) -> String? {
        struct ErrorBody: Decodable { let message: String? }
        return try? JSONDecoder().decode(ErrorBody.self, from: data).message
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// Collection endpoints are paginated (15 per page by default on a stock server), so
    /// a single request would silently show only the first page of projects, tasks, tags,
    /// clients or members.
    private struct PaginatedEnvelope<T: Decodable>: Decodable {
        let data: [T]
        let meta: Meta?

        struct Meta: Decodable {
            let currentPage: Int?
            let lastPage: Int?
            let total: Int?

            enum CodingKeys: String, CodingKey {
                case currentPage = "current_page"
                case lastPage = "last_page"
                case total
            }
        }
    }

    /// Walk every page of a collection endpoint.
    private func allPages<T: Decodable>(_ type: T.Type, _ path: String,
                                        query: [URLQueryItem] = []) async throws -> [T] {
        var items: [T] = []
        var page = 1
        let pageLimit = 50          // safety bound; 50 pages is far past any sane setup
        while page <= pageLimit {
            var pageQuery = query
            pageQuery.append(URLQueryItem(name: "page", value: String(page)))
            let data = try await send(try request("GET", path, query: pageQuery))
            let envelope = try decode(PaginatedEnvelope<T>.self, from: data)
            items.append(contentsOf: envelope.data)
            // Stop when the server reports the last page, or when it doesn't paginate.
            guard let last = envelope.meta?.lastPage, page < last, !envelope.data.isEmpty else { break }
            page += 1
        }
        return items
    }

    // MARK: - Endpoints

    func me() async throws -> User {
        let data = try await send(try request("GET", "/users/me"))
        return try decode(DataEnvelope<User>.self, from: data).data
    }

    func memberships() async throws -> [Membership] {
        let data = try await send(try request("GET", "/users/me/memberships"))
        return try decode(CollectionEnvelope<Membership>.self, from: data).data
    }

    /// The currently running time entry for the signed-in user, or nil if none.
    func activeTimeEntry() async throws -> TimeEntry? {
        do {
            let data = try await send(try request("GET", "/users/me/time-entries/active"))
            // `data` may be null when nothing is running.
            struct OptionalEnvelope: Decodable { let data: TimeEntry? }
            return try decode(OptionalEnvelope.self, from: data).data
        } catch APIError.http(404, _) {
            return nil
        }
    }

    /// The signed-in member's own time entries. Filtering by `member_id` is what the
    /// `time-entries:view:own` permission authorizes, so this works for employees too
    /// (an unfiltered list requires `view:all` and 403s for non-admins).
    func timeEntries(organizationId: String,
                     memberId: String? = nil,
                     from: Date? = nil,
                     to: Date? = nil,
                     limit: Int = 100,
                     offset: Int = 0) async throws -> [TimeEntry] {
        var query = [URLQueryItem(name: "limit", value: String(min(limit, 500)))]  // API caps limit at 500
        if offset > 0 { query.append(URLQueryItem(name: "offset", value: String(offset))) }
        if let memberId { query.append(URLQueryItem(name: "member_id", value: memberId)) }
        // Date-range filter uses the `start` (>=) and `end` (<=) query params.
        if let from { query.append(URLQueryItem(name: "start", value: SolidTimeFormatters.string(from: from))) }
        if let to { query.append(URLQueryItem(name: "end", value: SolidTimeFormatters.string(from: to))) }
        let data = try await send(try request("GET", "/organizations/\(organizationId)/time-entries", query: query))
        return try decode(CollectionEnvelope<TimeEntry>.self, from: data).data
    }

    /// Organization settings (currency, what employees are allowed to do).
    func organization(id: String) async throws -> OrganizationDetail {
        let data = try await send(try request("GET", "/organizations/\(id)"))
        return try decode(DataEnvelope<OrganizationDetail>.self, from: data).data
    }

    /// Organization members. Requires `members:view` — employees get a 403.
    func members(organizationId: String) async throws -> [Member] {
        try await allPages(Member.self, "/organizations/\(organizationId)/members")
    }

    /// Server-side aggregation of time entries.
    ///
    /// Grouping keys are ids (`project_id`, `user_id`) or `yyyy-MM-dd` days. `cost` comes
    /// back in cents, computed from the billable rate stored on each entry, and is null
    /// when the caller isn't allowed to see rates. Without `memberId` this reports on the
    /// whole organization and needs `time-entries:view:all` (403 for employees).
    func aggregate(organizationId: String,
                   group: String,
                   subGroup: String? = nil,
                   memberId: String? = nil,
                   projectIds: [String] = [],
                   from: Date? = nil,
                   to: Date? = nil,
                   fillGaps: Bool = false) async throws -> TimeAggregate {
        var query = [URLQueryItem(name: "group", value: group)]
        if let subGroup { query.append(URLQueryItem(name: "sub_group", value: subGroup)) }
        if let memberId { query.append(URLQueryItem(name: "member_id", value: memberId)) }
        // Project ids are OR-combined; the literal "none" selects entries without a project.
        for id in projectIds { query.append(URLQueryItem(name: "project_ids[]", value: id)) }
        if let from { query.append(URLQueryItem(name: "start", value: SolidTimeFormatters.string(from: from))) }
        if let to { query.append(URLQueryItem(name: "end", value: SolidTimeFormatters.string(from: to))) }
        if fillGaps { query.append(URLQueryItem(name: "fill_gaps_in_time_groups", value: "true")) }
        let data = try await send(try request("GET", "/organizations/\(organizationId)/time-entries/aggregate", query: query))
        return try decode(DataEnvelope<TimeAggregate>.self, from: data).data
    }

    func projects(organizationId: String) async throws -> [Project] {
        try await allPages(Project.self, "/organizations/\(organizationId)/projects")
    }

    func tasks(organizationId: String) async throws -> [ProjectTask] {
        try await allPages(ProjectTask.self, "/organizations/\(organizationId)/tasks")
    }

    func tags(organizationId: String) async throws -> [Tag] {
        try await allPages(Tag.self, "/organizations/\(organizationId)/tags")
    }

    func clients(organizationId: String) async throws -> [Client] {
        try await allPages(Client.self, "/organizations/\(organizationId)/clients")
    }

    // MARK: Mutations

    struct TimeEntryPayload: Encodable {
        var memberId: String?
        var projectId: String?
        var taskId: String?
        var start: String
        var end: String?
        var billable: Bool
        var description: String?
        var tags: [String]?

        enum CodingKeys: String, CodingKey {
            case start, end, billable, description, tags
            case memberId = "member_id"
            case projectId = "project_id"
            case taskId = "task_id"
        }
    }

    /// Start (or log) a time entry. Pass `end == nil` to start a running timer.
    func createTimeEntry(organizationId: String, payload: TimeEntryPayload) async throws -> TimeEntry {
        let body = try JSONEncoder().encode(payload)
        let data = try await send(try request("POST", "/organizations/\(organizationId)/time-entries", body: body))
        return try decode(DataEnvelope<TimeEntry>.self, from: data).data
    }

    /// Update a time entry — used to stop a running timer by setting `end`.
    func updateTimeEntry(organizationId: String, id: String, payload: TimeEntryPayload) async throws -> TimeEntry {
        let body = try JSONEncoder().encode(payload)
        let data = try await send(try request("PUT", "/organizations/\(organizationId)/time-entries/\(id)", body: body))
        return try decode(DataEnvelope<TimeEntry>.self, from: data).data
    }

    func deleteTimeEntry(organizationId: String, id: String) async throws {
        _ = try await send(try request("DELETE", "/organizations/\(organizationId)/time-entries/\(id)"))
    }

    // MARK: Create project / task / tag

    private struct ProjectPayload: Encodable {
        let name: String
        let color: String
        let isBillable: Bool
        /// Public projects are visible to every member of the organization; private ones
        /// only to admins and the members assigned to them. The API defaults to private.
        let isPublic: Bool
        let clientId: String?

        enum CodingKeys: String, CodingKey {
            case name, color
            case isBillable = "is_billable"
            case isPublic = "is_public"
            case clientId = "client_id"
        }

        // `client_id` is validated as "present": the key has to be in the body even when
        // there's no client, so nil is encoded as an explicit null rather than omitted.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(color, forKey: .color)
            try c.encode(isBillable, forKey: .isBillable)
            try c.encode(isPublic, forKey: .isPublic)
            if let clientId { try c.encode(clientId, forKey: .clientId) }
            else { try c.encodeNil(forKey: .clientId) }
        }
    }
    private struct TaskPayload: Encodable { let name: String; let project_id: String }
    private struct TagPayload: Encodable { let name: String }

    func createProject(organizationId: String, name: String, color: String,
                       isBillable: Bool, isPublic: Bool, clientId: String? = nil) async throws -> Project {
        // The API's colour rule is `^#[0-9a-f]{6}$` — uppercase hex is rejected.
        let payload = ProjectPayload(name: name, color: color.lowercased(),
                                     isBillable: isBillable, isPublic: isPublic, clientId: clientId)
        let body = try JSONEncoder().encode(payload)
        let data = try await send(try request("POST", "/organizations/\(organizationId)/projects", body: body))
        return try decode(DataEnvelope<Project>.self, from: data).data
    }

    func createTask(organizationId: String, name: String, projectId: String) async throws -> ProjectTask {
        let body = try JSONEncoder().encode(TaskPayload(name: name, project_id: projectId))
        let data = try await send(try request("POST", "/organizations/\(organizationId)/tasks", body: body))
        return try decode(DataEnvelope<ProjectTask>.self, from: data).data
    }

    func createTag(organizationId: String, name: String) async throws -> Tag {
        let body = try JSONEncoder().encode(TagPayload(name: name))
        let data = try await send(try request("POST", "/organizations/\(organizationId)/tags", body: body))
        return try decode(DataEnvelope<Tag>.self, from: data).data
    }
}
