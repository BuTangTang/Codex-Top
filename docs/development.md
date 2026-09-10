# 开发与打包

macOS 14+，Swift 6；当前本机验证工具链为 Swift 6.1.2 / macOS 15.7.9 arm64。SwiftUI 做内容，AppKit 做窗口，系统 SQLite 做只读数据接入，无第三方 Swift 运行依赖。

```sh
swift test
bash scripts/build-app.sh --demo
bash scripts/build-app.sh
```

产物在 `dist/`，不提交 Git。演示包和实际应用使用不同 bundle ID 与设置目录。修改后退出旧应用、再复制新包、重新打开，避免检查到仍在运行的旧二进制。

```sh
# ZIP 和校验值；默认本机架构
bash scripts/package.sh --demo
bash scripts/package.sh
# 同时构建 Apple silicon 和 Intel
bash scripts/package.sh --universal
```

可设置 `VERSION=0.1.0-dev`、`CONFIGURATION=release`。`SIGN_IDENTITY` 可指定本机已有签名身份；默认 `-` 是 ad-hoc 签名，不能等同 Developer ID 分发或 Apple 公证。签名身份、证书和本机设置不得提交。脚本不发布 GitHub Release，也不申请证书或公证。

核心测试使用合成数据库/日志，覆盖有界增量读取、乱序/半行、生命周期、未知、配额、父子任务、选择规则、旧设置、缩放和多屏几何。它们不代替打包应用的拖动、悬停、真实跳转和硬件验收。

开发顺序与未完成事项见 [STATUS](STATUS.md) 和 [M2 实测](validation/M2.md)。提交前运行测试、release 构建与本阶段实际检查，更新文档；不要用旧截图或概念图代替当前产物。

## GitHub Actions

当前只提供 `docs/ci/macos-build.yml.example` 模板，尚未启用（当前登录缺少 workflow scope）。启用后代码 push 到 main 或提出 PR 时，工作流执行测试与 universal 打包，保存 ZIP、校验值以及对应提交的源码 ZIP。文档改动不触发构建。手动也可从 Actions 运行。当前远程验证结果见 [M3](validation/M3.md)。产物保留 14 天，属于构建检查产物，不自动发布正式版本。

### 独立账户读取诊断

`swift run codex-top-inspect --account-usage` 只执行官方账户额度读取，不扫描任务或发送消息；输出来源、观察时间、窗口分钟数和耗时，不输出账户标识、余额原响应或凭据。只有需要真实额度诊断时运行，任务扫描与账户请求有不同周期。


## 生成分享 DMG

```sh
swift test
VERSION=0.1.0-beta.1 bash scripts/build-app.sh --universal
bash scripts/build-dmg.sh
```

DMG 脚本复用现有真实 universal 应用，拒绝 Demo，检查版本、两个架构的最低 macOS 和签名。产物含应用、Applications 链接与安装说明，输出到 `dist/`，另附可移植的 SHA-256 文件；不会包含本地任务、账户或偏好。发布前还需只读挂载检查内容并卸载，实际软件截图须与概念图分开标注。
