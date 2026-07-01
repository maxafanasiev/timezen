import Foundation

// MARK: - API envelope wrappers

/// Most SolidTime endpoints wrap a single resource in `{ "data": ... }`.
struct DataEnvelope<T: Decodable>: Decodable {
    let data: T
}

/// Collection endpoints return `{ "data": [...], "meta": {...} }`.
struct CollectionEnvelope<T: Decodable>: Decodable {
    let data: [T]
}

// MARK: - User

struct User: Decodable, Identifiable {
    let id: String
    let name: String
    let email: String
    let profilePhotoUrl: String?
    let timezone: String?

    enum CodingKeys: String, CodingKey {
        case id, name, email, timezone
        case profilePhotoUrl = "profile_photo_url"
    }
}

// MARK: - Membership (organization the user belongs to)

struct Membership: Decodable, Identifiable, Hashable {
    let id: String            // member_id used when creating time entries
    let organization: Organization
    let role: String?

    struct Organization: Decodable, Hashable {
        let id: String
        let name: String
        let currency: String?
    }

    var organizationId: String { organization.id }
    var organizationName: String { organization.name }
}

// MARK: - Time entry

struct TimeEntry: Decodable, Identifiable, Hashable {
    let id: String
    let start: String
    let end: String?
    let duration: Int?
    let description: String?
    let taskId: String?
    let projectId: String?
    let organizationId: String?
    let userId: String?
    let tags: [String]
    let billable: Bool?

    enum CodingKeys: String, CodingKey {
        case id, start, end, duration, description, tags, billable
        case taskId = "task_id"
        case projectId = "project_id"
        case organizationId = "organization_id"
        case userId = "user_id"
    }

    var startDate: Date? { SolidTimeFormatters.parse(start) }
    var endDate: Date? { end.flatMap(SolidTimeFormatters.parse) }
    var isRunning: Bool { end == nil }
}

// MARK: - Project / Task / Tag / Client

struct Project: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let color: String
    let clientId: String?
    let isArchived: Bool?
    let isBillable: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, color
        case clientId = "client_id"
        case isArchived = "is_archived"
        case isBillable = "is_billable"
    }
}

struct ProjectTask: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let isDone: Bool?
    let projectId: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case isDone = "is_done"
        case projectId = "project_id"
    }
}

struct Tag: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
}

struct Client: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
}
