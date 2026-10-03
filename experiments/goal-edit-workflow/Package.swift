// swift-tools-version: 6.0
import PackageDescription

// 独立验证包不属于正式 App 的依赖，不访问真实 Codex 或连接组件。
let package = Package(
    name: "GoalEditWorkflowExperiment",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GoalEditWorkflow", targets: ["GoalEditWorkflow"]),
        .executable(name: "GoalEditFixture", targets: ["GoalEditFixture"])
    ],
    targets: [
        .target(name: "GoalEditWorkflow"),
        .executableTarget(name: "GoalEditFixture", dependencies: ["GoalEditWorkflow"]),
        .testTarget(name: "GoalEditWorkflowTests", dependencies: ["GoalEditWorkflow"])
    ]
)
