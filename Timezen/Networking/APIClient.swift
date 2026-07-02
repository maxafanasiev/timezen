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
                     limit: Int = 100) async throws -> [TimeEntry] {
        var query = [URLQueryItem(name: "limit", value: String(min(limit, 500)))]  // API caps limit at 500
        if let memberId { query.append(URLQueryItem(name: "member_id", value: memberId)) }
        // Date-range filter uses the `start` (>=) and `end` (<=) query params.
        if let from { query.append(URLQueryItem(name: "start", value: SolidTimeFormatters.string(from: from))) }
        if let to { query.append(URLQueryItem(name: "end", value: SolidTimeFormatters.string(from: to))) }
        let data = try await send(try request("GET", "/organizations/\(organizationId)/time-entries", query: query))
        return try decode(CollectionEnvelope<TimeEntry>.self, from: data).data
    }

    func projects(organizationId: String) async throws -> [Project] {
        let data = try await send(try request("GET", "/organizations/\(organizationId)/projects"))
        return try decode(CollectionEnvelope<Project>.self, from: data).data
    }

    func tasks(organizationId: String) async throws -> [ProjectTask] {
        let data = try await send(try request("GET", "/organizations/\(organizationId)/tasks"))
        return try decode(CollectionEnvelope<ProjectTask>.self, from: data).data
    }

    func tags(organizationId: String) async throws -> [Tag] {
        let data = try await send(try request("GET", "/organizations/\(organizationId)/tags"))
        return try decode(CollectionEnvelope<Tag>.self, from: data).data
    }

    func clients(organizationId: String) async throws -> [Client] {
        let data = try await send(try request("GET", "/organizations/\(organizationId)/clients"))
        return try decode(CollectionEnvelope<Client>.self, from: data).data
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

    private struct ProjectPayload: Encodable { let name: String; let color: String; let is_billable: Bool }
    private struct TaskPayload: Encodable { let name: String; let project_id: String }
    private struct TagPayload: Encodable { let name: String }

    func createProject(organizationId: String, name: String, color: String, isBillable: Bool) async throws -> Project {
        let body = try JSONEncoder().encode(ProjectPayload(name: name, color: color, is_billable: isBillable))
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
