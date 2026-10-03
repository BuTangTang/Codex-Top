import XCTest
@testable import GoalEditWorkflow

/// 只使用内存合成来源，执行真实协调器；不连接应用、网络、进程、数据库或设备。
@MainActor
final class GoalEditWorkflowTests: XCTestCase {
    /// 合成固定身份，不含真实账号、来源路径或会话标识。
    private func identity(_ suffix: String = "a") -> GoalIdentity {
        GoalIdentity(account: "account-\(suffix)", sourceMachine: "source-\(suffix)",
                     thread: "thread-\(suffix)", connection: "connection-\(suffix)")
    }

    /// 创建原样可比较的目标；用量与更新时间可以独立变化。
    private func goal(_ objective: String = "原目标", status: GoalStatus = .blocked,
                      budget: Int64? = nil, tokens: Int64? = 3, seconds: Int64? = 4,
                      updatedAt: Int64? = 7) -> GoalFact {
        .available(GoalSnapshot(content: GoalContent(objective: objective, status: status, tokenBudget: budget),
                                tokensUsed: tokens, timeUsedSeconds: seconds, updatedAt: updatedAt))
    }

    /// 构造仅有合成内存能力的适配器，便于每例独立计数。
    private func adapter(_ fact: GoalFact? = nil) -> FixtureAdapter {
        FixtureAdapter(identity: identity(), fact: fact ?? goal())
    }

    /// 替换正文保留受阻状态与空预算，回读才返回 verified。
    func testReplacePreservesStatusAndNullableBudget() async {
        let adapter = adapter()
        let session = GoalEditSession(adapter: adapter, expected: adapter.fact)
        let result = await session.replaceObjective("新目标\n保持换行 👋", expectedStatus: .blocked)
        XCTAssertEqual(result, .verified(goal("新目标\n保持换行 👋")))
        XCTAssertEqual(adapter.readCalls, 2)
        XCTAssertEqual(adapter.replaceCalls, 1)
        XCTAssertTrue(session.didInvokeAction)
        XCTAssertFalse(session.isWorking)
        XCTAssertEqual(adapter.lastExpected?.status, .blocked)
        XCTAssertNil(adapter.lastExpected?.tokenBudget)
    }

    /// 零预算与非零预算均原样传递，没有默认值或清空行为。
    func testBudgetZeroAndNonzeroRemainDistinctFromNil() async {
        for budget: Int64? in [nil, 0, 10_000] {
            let adapter = adapter(goal(budget: budget))
            let session = GoalEditSession(adapter: adapter, expected: adapter.fact)
            let result = await session.replaceObjective("新目标", expectedStatus: .blocked)
            XCTAssertEqual(result, .verified(goal("新目标", budget: budget)))
            XCTAssertEqual(adapter.lastExpected?.tokenBudget, budget)
        }
    }

    /// 用户没有选择改变目标状态，六种原状态在正文替换后都保持。
    func testEveryExistingGoalStatusIsPreserved() async {
        for status in GoalStatus.allCases {
            let adapter = adapter(goal(status: status))
            let session = GoalEditSession(adapter: adapter, expected: adapter.fact)
            let result = await session.replaceObjective("新目标", expectedStatus: status)
            XCTAssertEqual(result, .verified(goal("新目标", status: status)))
        }
    }

    /// 未知或明确无目标不能从编辑动作隐式新建目标。
    func testUnavailableBaselineDoesNotReadOrMutate() async {
        for fact in [GoalFact.none, .unknown] {
            let adapter = adapter(fact)
            let session = GoalEditSession(adapter: adapter, expected: fact)
            let result = await session.replaceObjective("新目标", expectedStatus: .blocked)
            XCTAssertEqual(result, .notPerformed(.unavailableBaseline))
            XCTAssertEqual(adapter.readCalls, 0)
            XCTAssertEqual(adapter.replaceCalls, 0)
            XCTAssertFalse(session.didInvokeAction)
        }
    }

    /// 空正文和擅自激活被挡在动作之前，不读取或改写任何目标。
    func testInvalidObjectiveAndUnexpectedStatusDoNotMutate() async {
        let adapter = adapter()
        let blank = GoalEditSession(adapter: adapter, expected: adapter.fact)
        let invalid = await blank.replaceObjective(" \n\t", expectedStatus: .blocked)
        XCTAssertEqual(invalid, .notPerformed(.invalidObjective))
        let activation = GoalEditSession(adapter: adapter, expected: adapter.fact)
        let mismatch = await activation.replaceObjective("新目标", expectedStatus: .active)
        XCTAssertEqual(mismatch, .notPerformed(.unexpectedStatus))
        XCTAssertEqual(adapter.readCalls, 0)
        XCTAssertEqual(adapter.replaceCalls, 0)
    }

    /// 来源四个维度各自变化都会拒绝，不能只按标题或线程相同推断归属。
    func testEachIdentityFieldIsCheckedBeforeRead() async {
        let identities = [
            GoalIdentity(account: "other", sourceMachine: "source-a", thread: "thread-a", connection: "connection-a"),
            GoalIdentity(account: "account-a", sourceMachine: "other", thread: "thread-a", connection: "connection-a"),
            GoalIdentity(account: "account-a", sourceMachine: "source-a", thread: "other", connection: "connection-a"),
            GoalIdentity(account: "account-a", sourceMachine: "source-a", thread: "thread-a", connection: "other")
        ]
        for changed in identities {
            let adapter = adapter()
            let session = GoalEditSession(adapter: adapter, expected: adapter.fact)
            adapter.identity = changed
            let result = await session.delete()
            XCTAssertEqual(result, .notPerformed(.identityChanged))
            XCTAssertEqual(adapter.readCalls, 0)
            XCTAssertEqual(adapter.deleteCalls, 0)
        }
    }

    /// 前置读取返回之前换来源，即使拿到匹配的目标也不能派发。
    func testIdentityChangedDuringPreflightDoesNotMutate() async {
        let adapter = adapter()
        let session = GoalEditSession(adapter: adapter, expected: adapter.fact)
        adapter.onRead = { [self] _ in
            adapter.identity = identity("b")
            return goal()
        }
        let result = await session.delete()
        XCTAssertEqual(result, .notPerformed(.identityChanged))
        XCTAssertEqual(adapter.deleteCalls, 0)
        XCTAssertFalse(session.didInvokeAction)
    }

    /// 前置读取抛错或明确未知都表明未执行，不伪装成删除成功。
    func testPreflightReadFailureAndUnknownAreNotPerformed() async {
        let throwing = adapter()
        throwing.onRead = { _ in throw FixtureError.failure }
        let failureSession = GoalEditSession(adapter: throwing, expected: throwing.fact)
        let failure = await failureSession.delete()
        XCTAssertEqual(failure, .notPerformed(.readFailed))
        XCTAssertEqual(throwing.deleteCalls, 0)
        let unknown = adapter()
        let unknownSession = GoalEditSession(adapter: unknown, expected: unknown.fact)
        unknown.fact = .unknown
        let result = await unknownSession.delete()
        XCTAssertEqual(result, .notPerformed(.unknownGoal))
        XCTAssertEqual(unknown.deleteCalls, 0)
    }

    /// 同秒正文、状态、预算变化以及目标消失均冲突；updatedAt 不充当修订号。
    func testPreflightContentChangesConflictEvenWithSameTimestamp() async {
        let changes = [goal("其它目标"), goal(status: .active), goal(budget: 0), .none]
        for changed in changes {
            let adapter = adapter()
            let session = GoalEditSession(adapter: adapter, expected: adapter.fact)
            adapter.fact = changed
            let result = await session.replaceObjective("新目标", expectedStatus: .blocked)
            XCTAssertEqual(result, .conflict(changed))
            XCTAssertEqual(adapter.replaceCalls, 0)
        }
    }

    /// 仅用量和时间前进不制造冲突；正文替换保留当前计数，不写回基线旧计数。
    func testCountersAdvanceWithoutConflictOrRollback() async {
        let adapter = adapter()
        let session = GoalEditSession(adapter: adapter, expected: adapter.fact)
        adapter.fact = goal(tokens: 9, seconds: 12, updatedAt: 8)
        let result = await session.replaceObjective("新目标", expectedStatus: .blocked)
        XCTAssertEqual(result, .verified(goal("新目标", tokens: 9, seconds: 12, updatedAt: 8)))
        XCTAssertEqual(adapter.replaceCalls, 1)
    }

    /// 首次 await 前锁定意图，并发点击不增加读取或派发；完成后重复点击复用结果。
    func testDuplicateAndConcurrentActionsDispatchOnce() async {
        let adapter = adapter()
        let session = GoalEditSession(adapter: adapter, expected: adapter.fact)
        let gate = SuspensionGate()
        adapter.onRead = { call in
            if call == 1 { await gate.wait() }
            return adapter.fact
        }
        let first = Task { await session.replaceObjective("新目标", expectedStatus: .blocked) }
        await gate.untilWaiting()
        let duplicate = await session.replaceObjective("新目标", expectedStatus: .blocked)
        let different = await session.delete()
        let checking = await session.recheck()
        XCTAssertEqual(duplicate, .notPerformed(.operationInProgress))
        XCTAssertEqual(different, .notPerformed(.differentAction))
        XCTAssertEqual(checking, .notPerformed(.operationInProgress))
        XCTAssertEqual(adapter.readCalls, 1)
        gate.open()
        let firstResult = await first.value
        let repeated = await session.replaceObjective("新目标", expectedStatus: .blocked)
        XCTAssertEqual(firstResult, .verified(goal("新目标")))
        XCTAssertEqual(repeated, firstResult)
        XCTAssertEqual(adapter.readCalls, 2)
        XCTAssertEqual(adapter.replaceCalls, 1)
        XCTAssertEqual(adapter.deleteCalls, 0)
    }

    /// 动作调用边界之前已经登记 didInvokeAction，回调重入不会派发第二次。
    func testActionIsRecordedBeforeEnteringAdapter() async {
        let adapter = adapter()
        let session = GoalEditSession(adapter: adapter, expected: adapter.fact)
        adapter.onDelete = { _ in
            XCTAssertTrue(session.didInvokeAction)
            let duplicate = await session.delete()
            XCTAssertEqual(duplicate, .notPerformed(.operationInProgress))
            adapter.fact = .none
        }
        let result = await session.delete()
        XCTAssertEqual(result, .verified(.none))
        XCTAssertEqual(adapter.deleteCalls, 1)
    }

    /// 动作已执行但返回抛错保持未知；主动核对只读，同一按钮也不能重投。
    func testActionThrowsAfterMutationAndRecheckNeverRetries() async {
        let adapter = adapter()
        let session = GoalEditSession(adapter: adapter, expected: adapter.fact)
        adapter.onDelete = { _ in
            adapter.fact = .none
            throw FixtureError.failure
        }
        let result = await session.delete()
        XCTAssertEqual(result, .unknown)
        XCTAssertEqual(adapter.readCalls, 1)
        let repeated = await session.delete()
        XCTAssertEqual(repeated, .unknown)
        XCTAssertEqual(adapter.deleteCalls, 1)
        let checked = await session.recheck()
        XCTAssertEqual(checked, .verified(.none))
        XCTAssertEqual(adapter.readCalls, 2)
        XCTAssertEqual(adapter.deleteCalls, 1)
    }

    /// 动作只返回不保证保存，必须回读到真实目标变化才验证。
    func testAcknowledgedWithoutMutationRemainsUnknown() async {
        let adapter = adapter()
        let session = GoalEditSession(adapter: adapter, expected: adapter.fact)
        adapter.onReplace = { _, _ in }
        let result = await session.replaceObjective("新目标", expectedStatus: .blocked)
        XCTAssertEqual(result, .unknown)
        XCTAssertEqual(adapter.readCalls, 2)
        XCTAssertEqual(adapter.replaceCalls, 1)
    }

    /// 回读正文、状态或预算不匹配以及未知和无目标均不可冒称修改成功。
    func testReadbackMismatchAlwaysUnknown() async {
        let mismatches = [goal("其它目标"), goal("新目标", status: .active),
                          goal("新目标", budget: 0), .none, .unknown]
        for mismatch in mismatches {
            let adapter = adapter()
            let session = GoalEditSession(adapter: adapter, expected: adapter.fact)
            adapter.onReplace = { _, _ in adapter.fact = mismatch }
            let result = await session.replaceObjective("新目标", expectedStatus: .blocked)
            XCTAssertEqual(result, .unknown)
            XCTAssertEqual(adapter.replaceCalls, 1)
        }
    }

    /// 回读异常不会把动作抛回未执行；随后核对只追加读取。
    func testReadbackFailureCanOnlyBeRechecked() async {
        let adapter = adapter()
        let session = GoalEditSession(adapter: adapter, expected: adapter.fact)
        adapter.onRead = { call in
            if call == 2 { throw FixtureError.failure }
            return adapter.fact
        }
        let result = await session.delete()
        XCTAssertEqual(result, .unknown)
        XCTAssertTrue(session.didInvokeAction)
        let checked = await session.recheck()
        XCTAssertEqual(checked, .verified(.none))
        XCTAssertEqual(adapter.readCalls, 3)
        XCTAssertEqual(adapter.deleteCalls, 1)
    }

    /// 动作返回时来源已变，不继续读取新来源；结果只能未知。
    func testIdentityChangedAfterActionDoesNotReadAnotherSource() async {
        let adapter = adapter()
        let session = GoalEditSession(adapter: adapter, expected: adapter.fact)
        adapter.onDelete = { [self] _ in
            adapter.identity = identity("b")
            adapter.fact = .none
        }
        let result = await session.delete()
        XCTAssertEqual(result, .unknown)
        XCTAssertEqual(adapter.readCalls, 1)
        let checked = await session.recheck()
        XCTAssertEqual(checked, .unknown)
        XCTAssertEqual(adapter.readCalls, 1)
    }

    /// 回读返回途中切换来源，即使目标为 none 也不能验证删除。
    func testIdentityChangedDuringReadbackCannotVerify() async {
        let adapter = adapter()
        let session = GoalEditSession(adapter: adapter, expected: adapter.fact)
        adapter.onRead = { [self] call in
            if call == 2 { adapter.identity = identity("b") }
            return adapter.fact
        }
        let result = await session.delete()
        XCTAssertEqual(result, .unknown)
        XCTAssertEqual(adapter.deleteCalls, 1)
    }

    /// 删除后明确 none 才验证，unknown 与仍有目标都不能冒称删除。
    func testDeleteRequiresExplicitAbsence() async {
        for actual in [GoalFact.none, .unknown, goal()] {
            let adapter = adapter()
            let session = GoalEditSession(adapter: adapter, expected: adapter.fact)
            adapter.onDelete = { _ in adapter.fact = actual }
            let result = await session.delete()
            XCTAssertEqual(result, actual == .none ? .verified(.none) : .unknown)
            XCTAssertEqual(adapter.deleteCalls, 1)
        }
    }

    /// 前置失败不因重复按钮或核对绕过；需要显式开启新的编辑会话。
    func testPreflightFailureConsumesSessionWithoutHiddenRetry() async {
        let adapter = adapter()
        let session = GoalEditSession(adapter: adapter, expected: adapter.fact)
        adapter.fact = .unknown
        let result = await session.delete()
        adapter.fact = goal()
        let repeated = await session.delete()
        let checked = await session.recheck()
        XCTAssertEqual(result, .notPerformed(.unknownGoal))
        XCTAssertEqual(repeated, result)
        XCTAssertEqual(checked, .notPerformed(.actionNotInvoked))
        XCTAssertEqual(adapter.readCalls, 1)
        XCTAssertEqual(adapter.deleteCalls, 0)
    }

    /// 核对结果未知也不清除原意图，随后不同动作不能复用本会话派发。
    func testRecheckDoesNotUnlockAnotherAction() async {
        let adapter = adapter()
        let session = GoalEditSession(adapter: adapter, expected: adapter.fact)
        _ = await session.delete()
        adapter.fact = goal("别人新建的目标")
        let checked = await session.recheck()
        let another = await session.replaceObjective("另一个新目标", expectedStatus: .blocked)
        XCTAssertEqual(checked, .unknown)
        XCTAssertEqual(another, .notPerformed(.differentAction))
        XCTAssertEqual(adapter.deleteCalls, 1)
        XCTAssertEqual(adapter.replaceCalls, 0)
        XCTAssertEqual(session.result, .unknown)
    }
}

/// 固定合成异常，不携带正文、路径或任何外部错误信息。
private enum FixtureError: Error { case failure }

/// 可注入读写时序的内存替身，不提供真实系统能力。
@MainActor
private final class FixtureAdapter: GoalEditAdapter {
    var identity: GoalIdentity
    var fact: GoalFact
    var readCalls = 0
    var replaceCalls = 0
    var deleteCalls = 0
    var lastExpected: GoalContent?
    var onRead: (@MainActor (Int) async throws -> GoalFact)?
    var onReplace: (@MainActor (String, GoalContent) async throws -> Void)?
    var onDelete: (@MainActor (GoalContent) async throws -> Void)?

    /// 每个测试使用新实例，计数与回调不跨场景共享。
    init(identity: GoalIdentity, fact: GoalFact) {
        self.identity = identity
        self.fact = fact
    }

    /// 执行可控合成读取，调用编号用于区分前置与后置读回。
    func readGoal() async throws -> GoalFact {
        readCalls += 1
        if let onRead { return try await onRead(readCalls) }
        return fact
    }

    /// 默认合成替换保留当前用量和来源时间，证明协调器没有传入旧计数回写。
    func replaceObjective(_ objective: String, preserving expected: GoalContent) async throws {
        replaceCalls += 1
        lastExpected = expected
        if let onReplace { try await onReplace(objective, expected); return }
        guard case let .available(current) = fact else { throw FixtureError.failure }
        fact = .available(GoalSnapshot(content: GoalContent(objective: objective, status: expected.status,
                                                          tokenBudget: expected.tokenBudget),
                                       tokensUsed: current.tokensUsed, timeUsedSeconds: current.timeUsedSeconds,
                                       updatedAt: current.updatedAt))
    }

    /// 默认只清除目标，线程身份保持不变。
    func deleteGoal(expected: GoalContent) async throws {
        deleteCalls += 1
        lastExpected = expected
        if let onDelete { try await onDelete(expected); return }
        fact = .none
    }
}

/// 用 continuation 精确控制重入，不靠真实等待、轮询或外部时间。
@MainActor
private final class SuspensionGate {
    private var suspension: CheckedContinuation<Void, Never>?
    private var waitingObservers: [CheckedContinuation<Void, Never>] = []
    private var waiting = false

    /// 暂停一次合成读取并通知测试，确保重复点击发生在动作前的真实 await 边界。
    func wait() async {
        await withCheckedContinuation { continuation in
            suspension = continuation
            waiting = true
            waitingObservers.forEach { $0.resume() }
            waitingObservers.removeAll()
        }
    }

    /// 等待读取进入暂停点，无忙循环也不依赖睡眠长短。
    func untilWaiting() async {
        if waiting { return }
        await withCheckedContinuation { waitingObservers.append($0) }
    }

    /// 恢复被暂停的合成读取，不创建第二次请求。
    func open() {
        suspension?.resume()
        suspension = nil
    }
}
