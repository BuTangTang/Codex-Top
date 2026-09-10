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
