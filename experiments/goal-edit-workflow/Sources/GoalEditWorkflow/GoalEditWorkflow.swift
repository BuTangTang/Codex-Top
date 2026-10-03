/// 一次编辑所绑定的合成来源。连接代次也参与比较，不用标题或目标正文猜测归属。
public struct GoalIdentity: Equatable, Sendable {
    public let account: String
    public let sourceMachine: String
    public let thread: String
    public let connection: String

    /// 固定账号、来源电脑、会话及连接身份；这些值只由注入的合成适配器提供。
    public init(account: String, sourceMachine: String, thread: String, connection: String) {
        self.account = account
        self.sourceMachine = sourceMachine
        self.thread = thread
        self.connection = connection
    }
}

/// 沿用已有目标状态；操作结果不混入此枚举，也不因编辑默认切换为进行中。
public enum GoalStatus: String, CaseIterable, Sendable {
    case active, paused, blocked, usageLimited, budgetLimited, complete
}

/// 可比较的目标原值；预算空值原样保留，不把未知值解释为零或无限。
public struct GoalContent: Equatable, Sendable {
    public let objective: String
    public let status: GoalStatus
    public let tokenBudget: Int64?

    /// 保存目标正文、原状态及可空预算；没有可编辑用量或计时字段。
    public init(objective: String, status: GoalStatus, tokenBudget: Int64?) {
        self.objective = objective
        self.status = status
        self.tokenBudget = tokenBudget
    }
}

/// 一次合成读取结果。更新时间和用量只供展示，不充当修订号或写入字段。
public struct GoalSnapshot: Equatable, Sendable {
    public let content: GoalContent
    public let tokensUsed: Int64?
    public let timeUsedSeconds: Int64?
    public let updatedAt: Int64?

    /// 原样保存可空计数；协调器比较时只检查 content，允许用量自然前进。
    public init(content: GoalContent, tokensUsed: Int64? = nil,
                timeUsedSeconds: Int64? = nil, updatedAt: Int64? = nil) {
        self.content = content
        self.tokensUsed = tokensUsed
        self.timeUsedSeconds = timeUsedSeconds
        self.updatedAt = updatedAt
    }
}

/// 目标事实保持三态；none 是来源明确无目标，unknown 不能替代 none。
public enum GoalFact: Equatable, Sendable {
    case available(GoalSnapshot)
    case none
    case unknown
}

/// 明确没有调用动作的原因，和调用后无法确定结果分开。
public enum GoalNotPerformedReason: Equatable, Sendable, CustomStringConvertible {
    case unavailableBaseline
    case identityChanged
    case readFailed
    case unknownGoal
    case differentAction
    case operationInProgress
    case invalidObjective
    case unexpectedStatus
    case actionNotInvoked

    /// 固定中文说明只描述本次实验结果，不泄露适配器错误或目标正文。
    public var description: String {
        switch self {
        case .unavailableBaseline: return "没有可编辑的原目标，未执行。"
        case .identityChanged: return "来源或会话已变化，未执行。"
        case .readFailed: return "操作前读取失败，未执行。"
        case .unknownGoal: return "操作前目标未知，未执行。"
        case .differentAction: return "本次编辑会话已登记另一操作，未重复执行。"
        case .operationInProgress: return "本次操作正在处理，未重复执行。"
        case .invalidObjective: return "目标正文为空，未执行。"
        case .unexpectedStatus: return "预期状态与原目标不同，未执行。"
        case .actionNotInvoked: return "本次未调用目标动作，无需核对操作结果。"
        }
    }
}

/// verified 只表示同一合成来源的回读满足后置条件，不表示真实 Codex 已接通。
public enum GoalOperationResult: Equatable, Sendable {
    case verified(GoalFact)
    case unknown
    case conflict(GoalFact)
    case notPerformed(GoalNotPerformedReason)
}

/// 仅供独立合成窗口注入。此包不提供真实应用、进程、数据库、网络或设备适配器。
@MainActor
public protocol GoalEditAdapter: AnyObject {
    var identity: GoalIdentity { get }

    /// 读取当前合成目标，不把界面草稿当作已保存事实。
    func readGoal() async throws -> GoalFact

    /// 合成动作仅替换正文，保留 expected 的状态和预算；不得回写原计数。
    func replaceObjective(_ objective: String, preserving expected: GoalContent) async throws

    /// 删除 expected 指向的合成目标；不删除线程或其它数据。
    func deleteGoal(expected: GoalContent) async throws
}

/// 单次编辑会话：至多调用一次动作，未知结果只能回读；不承诺跨重启恰好一次。
@MainActor
public final class GoalEditSession {
    public let expectedIdentity: GoalIdentity
    public let expected: GoalFact
    public private(set) var isWorking = false
    public private(set) var didInvokeAction = false
    public private(set) var result: GoalOperationResult?

    private let adapter: any GoalEditAdapter
    private var intent: Intent?

    /// 只登记明确动作的参数，不把重试、状态修改或预算修改作为隐式动作。
    private enum Intent: Equatable {
        case replace(String, GoalStatus)
        case delete
    }

    /// 固定开始编辑时的事实和身份。调用方必须提供权威合成读取，不能传入旧缓存冒充当前。
    public init(adapter: any GoalEditAdapter, expected: GoalFact) {
        self.adapter = adapter
        self.expectedIdentity = adapter.identity
        self.expected = expected
    }

    /// 提交一次正文替换；显式预期状态必须与基线相同，状态与预算均保持原值。
    public func replaceObjective(_ objective: String, expectedStatus: GoalStatus) async -> GoalOperationResult {
        await perform(.replace(objective, expectedStatus))
    }

    /// 用户明确删除原目标后调用一次，不增加另一轮确认，也不删除会话。
    public func delete() async -> GoalOperationResult {
        await perform(.delete)
    }

    /// 仅回读已调用动作的结果，不重新执行动作；同一时刻只允许一个操作或核对。
    public func recheck() async -> GoalOperationResult {
        guard !isWorking else { return .notPerformed(.operationInProgress) }
        guard didInvokeAction, let intent else { return .notPerformed(.actionNotInvoked) }
        isWorking = true
        defer { isWorking = false }
        let outcome = await verify(intent)
        result = outcome
        return outcome
    }

    /// 在首个 await 前登记意图，防止主线程重入派发第二次；前置失败也不隐式换成另一动作。
    private func perform(_ requested: Intent) async -> GoalOperationResult {
        if let intent {
            guard intent == requested else { return .notPerformed(.differentAction) }
            guard !isWorking else { return .notPerformed(.operationInProgress) }
            return result ?? .unknown
        }
        intent = requested
        isWorking = true
        defer { isWorking = false }
        let outcome = await execute(requested)
        result = outcome
        return outcome
    }

    /// 前置回读失败明确未执行；一旦进入适配器动作，即使其抛错也保留未知，不猜测未派发。
    private func execute(_ requested: Intent) async -> GoalOperationResult {
        guard case let .available(original) = expected else {
            return .notPerformed(.unavailableBaseline)
        }
        if case let .replace(objective, status) = requested {
            guard !objective.allSatisfy(\.isWhitespace) else { return .notPerformed(.invalidObjective) }
            guard status == original.content.status else { return .notPerformed(.unexpectedStatus) }
        }
        guard adapter.identity == expectedIdentity else { return .notPerformed(.identityChanged) }
        let current: GoalFact
        do {
            current = try await adapter.readGoal()
        } catch {
            return .notPerformed(adapter.identity == expectedIdentity ? .readFailed : .identityChanged)
        }
        guard adapter.identity == expectedIdentity else { return .notPerformed(.identityChanged) }
        switch current {
        case .unknown: return .notPerformed(.unknownGoal)
        case .none: return .conflict(current)
        case let .available(value):
            guard value.content == original.content else { return .conflict(current) }
        }

        // 此处之后没有主线程挂起点再进入动作。适配器内部的并发变化仍须由适配器处理；
        // 读前后核对并非生产 CAS，也不能防止其它程序的同内容删除重建。
        didInvokeAction = true
        do {
            switch requested {
            case let .replace(objective, _):
                try await adapter.replaceObjective(objective, preserving: original.content)
            case .delete:
                try await adapter.deleteGoal(expected: original.content)
            }
        } catch {
            return .unknown
        }
        return await verify(requested)
    }

    /// 操作之后核对同来源事实；正文、状态和预算需匹配，计数自然增加不影响结果。
    private func verify(_ requested: Intent) async -> GoalOperationResult {
        guard adapter.identity == expectedIdentity else { return .unknown }
        let current: GoalFact
        do {
            current = try await adapter.readGoal()
        } catch {
            return .unknown
        }
        guard adapter.identity == expectedIdentity else { return .unknown }
        switch (requested, current) {
        case (.delete, .none): return .verified(current)
        case let (.replace(objective, _), .available(actual)):
            guard case let .available(original) = expected,
                  actual.content.objective == objective,
                  actual.content.status == original.content.status,
                  actual.content.tokenBudget == original.content.tokenBudget else { return .unknown }
            return .verified(current)
        default: return .unknown
        }
    }
}
