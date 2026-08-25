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

// MARK: - Organization member (admin views)

/// A member of the organization, as returned by `/organizations/{id}/members`.
/// Listing members requires admin/manager permissions; employees get a 403.
struct Member: Decodable, Identifiable, Hashable {
    let id: String              // membership id (used as member_id in filters)
    let userId: String
    let name: String
    let email: String
    let role: String?
    let isPlaceholder: Bool?
    /// Billable rate in cents per hour, or nil when the member inherits a rate.
    let billableRate: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, email, role
        case userId = "user_id"
        case isPlaceholder = "is_placeholder"
        case billableRate = "billable_rate"
    }
}

// MARK: - Aggregated report

/// One node of the `/time-entries/aggregate` response tree.
///
/// `key` is the grouping value: a project id, a user id, or a `yyyy-MM-dd` day,
/// depending on `groupedType` of the parent. `cost` is in cents and is null when
/// the server decides the caller may not see billable rates.
struct TimeAggregate: Decodable, Hashable {
    let key: String?
    let seconds: Int
    let cost: Int?
    let groupedType: String?
    let groupedData: [TimeAggregate]?

    enum CodingKeys: String, CodingKey {
        case key, seconds, cost
        case groupedType = "grouped_type"
        case groupedData = "grouped_data"
    }

    var children: [TimeAggregate] { groupedData ?? [] }
}

/// A dashboard report built from the server-side aggregation endpoint.
///
/// Time comes back already summed per group; `cost` is in cents and is nil whenever
/// the server withholds billable rates, in which case the money columns stay hidden.
struct OrgReport {
    struct Slice: Identifiable, Hashable {
        let key: String?        // project id / user id; nil = "no project"
        let seconds: Int
        let cost: Int?
        var id: String { key ?? "__none__" }
    }

    struct Day: Identifiable, Hashable {
        let day: Date
        let projects: [Slice]
        var id: Date { day }
        var seconds: Int { projects.reduce(0) { $0 + $1.seconds } }
    }

    var totalSeconds: Int
    var totalCost: Int?
    var days: [Day]
    var projects: [Slice]
    var members: [Slice]

    var showsCost: Bool { totalCost != nil }

    /// Build from `group=day&sub_group=project` and `group=user` aggregations.
    init(byDay: TimeAggregate, byMember: TimeAggregate) {
        totalSeconds = byDay.seconds
        totalCost = byDay.cost

        days = byDay.children.compactMap { node in
            guard let key = node.key, let day = SolidTimeFormatters.parseDayKey(key) else { return nil }
            let projects = node.children
                .map { Slice(key: $0.key, seconds: $0.seconds, cost: $0.cost) }
                .filter { $0.seconds > 0 }
            return Day(day: day, projects: projects)
        }
        .sorted { $0.day < $1.day }

        // Roll the per-day breakdown up into per-project totals.
        var projectSeconds: [String: Int] = [:]
        var projectCost: [String: Int] = [:]
        var costKnown = false
        for day in days {
            for slice in day.projects {
                let id = slice.id
                projectSeconds[id, default: 0] += slice.seconds
                if let cost = slice.cost {
                    projectCost[id, default: 0] += cost
                    costKnown = true
                }
            }
        }
        projects = projectSeconds
            .map { id, seconds in
                Slice(key: id == "__none__" ? nil : id,
                      seconds: seconds,
                      cost: costKnown ? (projectCost[id] ?? 0) : nil)
            }
            .sorted { ($0.seconds, $1.id) > ($1.seconds, $0.id) }

        members = byMember.children
            .map { Slice(key: $0.key, seconds: $0.seconds, cost: $0.cost) }
            .filter { $0.seconds > 0 }
            .sorted { ($0.seconds, $1.id) > ($1.seconds, $0.id) }
    }

    /// Demo/offline construction.
    init(totalSeconds: Int, totalCost: Int?, days: [Day], projects: [Slice], members: [Slice]) {
        self.totalSeconds = totalSeconds
        self.totalCost = totalCost
        self.days = days
        self.projects = projects
        self.members = members
    }
}

// MARK: - Organization settings

/// `/organizations/{id}` — the settings that decide what an employee may do.
struct OrganizationDetail: Decodable {
    let id: String
    let name: String
    let currency: String?
    let currencySymbol: String?
    /// Employees may manage tasks in projects they can access when this is on.
    let employeesCanManageTasks: Bool?
    let employeesCanSeeBillableRates: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, currency
        case currencySymbol = "currency_symbol"
        case employeesCanManageTasks = "employees_can_manage_tasks"
        case employeesCanSeeBillableRates = "employees_can_see_billable_rates"
    }
}
