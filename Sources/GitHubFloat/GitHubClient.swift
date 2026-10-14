import Foundation

// MARK: - GraphQL payload

struct GQLResponse: Decodable {
    let data: DataNode?
    let errors: [GQLError]?
}

struct GQLError: Decodable { let message: String }

struct DataNode: Decodable {
    let viewer: Viewer
    let owner: Owner?
    struct Viewer: Decodable { let login: String }
    struct Owner: Decodable { let projectV2: ProjectNode? }
}

struct ProjectNode: Decodable {
    let title: String
    let url: String
    let statusField: StatusField?
    let mine: Items?
    let open: Items?

    struct StatusField: Decodable { let options: [StatusOption]? }
    struct Items: Decodable {
        let pageInfo: PageInfo
        let nodes: [ItemNode]
    }
    struct PageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }
}

struct StatusOption: Decodable, Hashable {
    let name: String
    let color: String
}

struct ItemNode: Decodable {
    let id: String
    let status: NameValue?
    let content: ContentNode?
    struct NameValue: Decodable {
        let name: String?
        let updatedAt: String?
    }
}

struct Connection<T: Decodable>: Decodable { let nodes: [T?]? }

struct RepoNode: Decodable { let name: String }

struct LoginNode: Decodable { let login: String }

struct PRNode: Decodable {
    let number: Int
    let title: String
    let url: String
    let state: String
    let isDraft: Bool
    let reviewDecision: String?
    let author: PRNode.Review.Author?
    let repository: RepoNode
    let assignees: Connection<LoginNode>?
    let reviewRequests: Connection<ReviewRequest>?
    let latestReviews: Connection<Review>?
    let commits: Connection<CommitWrap>?

    struct ReviewRequest: Decodable {
        let requestedReviewer: Reviewer?
        struct Reviewer: Decodable {
            let login: String?
            let name: String?
        }
    }
    struct Review: Decodable {
        let author: Author?
        let state: String
        struct Author: Decodable { let login: String }
    }
    struct CommitWrap: Decodable {
        let commit: Commit
        struct Commit: Decodable { let statusCheckRollup: Rollup? }
        struct Rollup: Decodable { let state: String }
    }
}

struct ContentNode: Decodable {
    let typename: String
    let number: Int?
    let title: String?
    let url: String?
    let issueState: String?
    let repository: RepoNode?
    let assignees: [String]
    let closingPRs: [PRNode]
    let pr: PRNode?

    enum CodingKeys: String, CodingKey {
        case typename = "__typename", number, title, url, issueState, repository, assignees
        case closedByPullRequestsReferences
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        typename = try c.decode(String.self, forKey: .typename)
        number = try c.decodeIfPresent(Int.self, forKey: .number)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        issueState = try c.decodeIfPresent(String.self, forKey: .issueState)
        repository = try c.decodeIfPresent(RepoNode.self, forKey: .repository)
        assignees = try c.decodeIfPresent(Connection<LoginNode>.self, forKey: .assignees)?.nodes?.compactMap { $0?.login } ?? []
        let refs = try c.decodeIfPresent(Connection<PRNode>.self, forKey: .closedByPullRequestsReferences)
        closingPRs = refs?.nodes?.compactMap { $0 } ?? []
        pr = typename == "PullRequest" ? try PRNode(from: decoder) : nil
    }
}

// MARK: - Client

enum GHError: LocalizedError {
    case noToken
    case http(Int, String)
    case graphql(String)
    case projectNotFound

    var errorDescription: String? {
        switch self {
        case .noToken: return "No GitHub token. Run `gh auth login` or set GH_TOKEN."
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(160))"
        case .graphql(let msg): return msg
        case .projectNotFound: return "Project not found. Check the project URL and that your token can read it."
        }
    }
}

struct BoardSnapshot {
    let viewer: String
    let projectTitle: String
    let projectURL: String
    let statusOptions: [StatusOption]
    let mine: [ItemNode]
    let open: [ItemNode]
}

actor GitHubClient {
    private var token: String?

    /// Both tabs are fetched in a single request through two filtered aliases.
    private static let query = """
    query($owner:String!, $number:Int!, $qMine:String!, $qOpen:String!, $cMine:String, $cOpen:String, $withMine:Boolean!, $withOpen:Boolean!) {
      viewer { login }
      owner: repositoryOwner(login:$owner) {
        ... on Organization { projectV2(number:$number) { ...Board } }
        ... on User { projectV2(number:$number) { ...Board } }
      }
    }
    fragment Board on ProjectV2 {
      title url
      statusField: field(name:"Status") { ... on ProjectV2SingleSelectField { options { name color } } }
      mine: items(first:50, after:$cMine, query:$qMine) @include(if:$withMine) { ...Items }
      open: items(first:50, after:$cOpen, query:$qOpen) @include(if:$withOpen) { ...Items }
    }
    fragment Items on ProjectV2ItemConnection {
      pageInfo { hasNextPage endCursor }
      nodes {
        id
        status: fieldValueByName(name:"Status") { ... on ProjectV2ItemFieldSingleSelectValue { name updatedAt } }
        content {
          __typename
          ... on DraftIssue { title assignees(first:10) { nodes { login } } }
          ... on Issue {
            number title url issueState: state repository { name }
            assignees(first:10) { nodes { login } }
            closedByPullRequestsReferences(first:5, includeClosedPrs:true) { nodes { ...PR } }
          }
          ... on PullRequest { ...PR }
        }
      }
    }
    fragment PR on PullRequest {
      number title url state isDraft reviewDecision
      author { login }
      repository { name }
      assignees(first:10) { nodes { login } }
      reviewRequests(first:10) { nodes { requestedReviewer { ... on User { login } ... on Team { name } ... on Mannequin { login } } } }
      latestReviews(first:10) { nodes { author { login } state } }
      commits(last:1) { nodes { commit { statusCheckRollup { state } } } }
    }
    """

    func fetchBoard(owner: String, number: Int, mineFilter: String, openFilter: String) async throws -> BoardSnapshot {
        var cMine: String?, cOpen: String?
        var withMine = true, withOpen = true
        var mine: [ItemNode] = [], open: [ItemNode] = []
        var first: (DataNode.Viewer, ProjectNode)?
        for _ in 0..<10 where withMine || withOpen {
            var vars: [String: Any] = ["owner": owner, "number": number, "qMine": mineFilter, "qOpen": openFilter,
                                       "withMine": withMine, "withOpen": withOpen]
            if let cMine { vars["cMine"] = cMine }
            if let cOpen { vars["cOpen"] = cOpen }
            let (viewer, p) = try await request(vars)
            if first == nil { first = (viewer, p) }
            if withMine, let m = p.mine {
                mine += m.nodes
                cMine = m.pageInfo.endCursor
                withMine = m.pageInfo.hasNextPage && cMine != nil
            } else { withMine = false }
            if withOpen, let o = p.open {
                open += o.nodes
                cOpen = o.pageInfo.endCursor
                withOpen = o.pageInfo.hasNextPage && cOpen != nil
            } else { withOpen = false }
        }
        guard let (viewer, project) = first else { throw GHError.projectNotFound }
        return BoardSnapshot(viewer: viewer.login,
                             projectTitle: project.title,
                             projectURL: project.url,
                             statusOptions: project.statusField?.options ?? [],
                             mine: mine,
                             open: open)
    }

    private func request(_ vars: [String: Any]) async throws -> (DataNode.Viewer, ProjectNode) {
        let body = try JSONSerialization.data(withJSONObject: ["query": Self.query, "variables": vars])

        for attempt in 0..<2 {
            var req = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
            req.httpMethod = "POST"
            req.httpBody = body
            req.timeoutInterval = 30
            req.setValue("bearer \(try resolveToken())", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("GitHubFloat", forHTTPHeaderField: "User-Agent")

            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 && attempt == 0 { token = nil; continue }
            guard code == 200 else { throw GHError.http(code, String(decoding: data, as: UTF8.self)) }

            let decoded = try JSONDecoder().decode(GQLResponse.self, from: data)
            if let d = decoded.data, let project = d.owner?.projectV2 { return (d.viewer, project) }
            if let msg = decoded.errors?.map(\.message).joined(separator: "\n") { throw GHError.graphql(msg) }
            throw GHError.projectNotFound
        }
        throw GHError.noToken
    }

    private func resolveToken() throws -> String {
        if let token { return token }
        let env = ProcessInfo.processInfo.environment
        let candidates: [() -> String?] = [
            { env["GH_TOKEN"] },
            { env["GITHUB_TOKEN"] },
            // Apps launched from Finder don't inherit the shell env, so ask a login shell.
            { Self.shell("gh auth token", interactive: false) },
            { Self.shell("gh auth token", interactive: true) },
        ]
        for c in candidates {
            if let t = c()?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.contains(" ") {
                token = t
                return t
            }
        }
        throw GHError.noToken
    }

    private static func shell(_ command: String, interactive: Bool) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [interactive ? "-lic" : "-lc", command]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        // Interactive shells may print banners; the token is the last line.
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline).last.map(String.init)
    }
}
