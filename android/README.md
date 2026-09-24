# Codex Top 安卓客户端

原生 Java / Android Views 客户端，最低 Android 11，当前版本 1.0.1。主仓库的 macOS 工程与运行实例保持原样；佳明接入按用户要求不在本轮范围内。

## 当前能做什么

- 填写自有 HTTPS 服务地址，以账号密码登录；只加密保存本服务会话，不保存密码。
- 单页紧凑通知列表，仅显示完成、待确认、失败；两行包含任务名称、状态、来源和时间，点开查看详情，右上角进入设置。取消统计、筛选、设备管理及底部导航。
- 列表使用现有快照中每个任务最近状态，不是持久通知历史或送达回执。离线/过期明确标记，详情缺少开始时间显示 `--:--`。
- 启动图标使用与桌面相同的蓝环橙点原图，适配安卓图标遮罩。
- 检查通知权限、发送明确标为测试的本机通知。
- 登录后主动开启最长一小时的后台轮询提醒，15 秒一次；新完成、待处理和错误事件使用通用文字通知，同一事件不重复提醒。
- 退出当前手机并请求服务器撤销会话；断网时明确提示远端撤销未确认。
- 无服务器时可进入明确标为合成数据的“示例模式”，不读取真实 Codex 数据。

仅沿用登录、读取状态、退出三个接口，没有新增后端接口。账号服务器、电脑上传任务、电脑二维码授权、未来手机消息转发与全天持续推送尚未接入。本目录里的 Python 服务只用于本机合成联调，不能部署成生产账号服务，也不能由联调通过宣称真实任务链路已完成。

## 构建 APK

前提：JDK 17、Android SDK 平台 35 / Build Tools 35，环境变量 `JAVA_HOME` 指向 JDK，`ANDROID_HOME` 指向 SDK。Gradle Wrapper 固定 8.9，包含官方 SHA-256 校验。首次构建需要网络下载依赖。

1. 在本目录执行 `./gradlew testDebugUnitTest lintDebug assembleDebug assembleRelease`。
2. 确认测试和检查成功；调试 APK 位于 `app/build/outputs/apk/debug/app-debug.apk`。
3. `assembleRelease` 只验证正式配置构建，产物未签名；正式分发需配置自己的签名，禁止把私钥提交到 Git。

如果 SDK/JDK 路径缺失，先配置上述环境变量再重试。不要把含本机完整路径的 `local.properties`、构建目录、会话或原始诊断提交到仓库。

## 安装到小米 15

1. 手机开启开发者选项和 USB 调试，连接电脑并接受该电脑的调试授权。
2. 电脑运行 `adb devices`，预期设备状态为 `device`。后续命令中的 `<设备>` 替换为对应设备 ID，勿把 ID 写入公开报告。
3. 执行 `adb -s <设备> install -r app/build/outputs/apk/debug/app-debug.apk`，成功应返回 `Success`。
4. 若小米返回 `INSTALL_FAILED_USER_RESTRICTED`，在手机允许 USB 安装。仍受限时，可将 APK 复制到手机下载目录，使用系统安装界面手动安装；不要绕过系统安全检查。
5. 打开 Codex Top。未部署服务时点“先体验示例”；有服务时填写管理员提供的地址和账号。

调试包包名为 `com.butang.codextop.debug`，与未来正式包独立。只有调试包允许 `127.0.0.1`、`localhost`、模拟器宿主 `10.0.2.2` 的 HTTP 联调；正式包只接受 HTTPS，并阻止截图和最近任务缩略图暴露内容。自动点击真机还需要用户开启小米的“USB 调试（安全设置）”。

## 本机接口联调

前提：Python 3.9+；只能使用合成账号，不要输入真实密码。接口定义见 [API.md](API.md)。

1. 在仓库根目录运行 `python3 android/tools/fixture_server.py`。它只监听 Mac 回环地址的 18765 端口，不监听局域网、不接触 Ubuntu/PVTC。
2. 运行 `adb -s <设备> reverse tcp:18765 tcp:18765`，通过 USB 将手机本机端口连接到测试服务。
3. 在调试 App 输入 `http://127.0.0.1:18765`，测试账号 `mobile-test`，测试密码 `fixture-only-password`。这些是刻意公开的合成测试凭据，不是生产默认密码。
4. 登录后应显示带“合成”字样的两台设备和四条任务；离线电脑的任务不计入实时运行数。
5. 执行 `./gradlew assembleDebugAndroidTest`，安装对应测试 APK 后运行 `adb -s <设备> shell am instrument -w com.butang.codextop.debug.test/com.butang.codextop.ContractTest`。只在独立调试安装上运行，它会清理该调试包的合成会话。
6. 测试结束退出 App 登录，停止 Python 进程，执行 `adb -s <设备> reverse --remove tcp:18765`，恢复手机原有设置。原始截图/XML 留在忽略目录中。

预期测试涵盖错误密码拒绝、会话撤销、Android Keystore 加解密、协议异常与真实 Activity 导航。端口已占用时先核对所属进程，不停止其他服务；没有启动 fixture 时网络测试会失败，不代表生产服务器故障。

## 通知验收

1. 在右上角“设置”里点“发送测试通知”，允许系统通知后再次发送；确认通知栏出现“测试通知”。这只验证手机本机通知。
2. 用合成服务登录，开启“一小时提醒”；应出现可停止的常驻通知。首次取得快照必须静默。
3. 在忽略目录 `.local/android-qa/fixture-state.json` 写入新的 `phase`（`waiting` / `completed` / `failed`）、唯一 `event` 与当前毫秒时间 `eventAt`，观察新提醒。重复同一内容不应新增通知。
4. 将等待变成新的完成事件，或写入 `offline: true`，确认旧等待提醒被替换或取消。
5. 分别验证锁屏、网络中断/恢复、手动停止和退出登录；不要用 HTTP 成功推定手机提醒出现。勿扰下声音和振动遵循系统设置。

该方式依赖系统调度与网络，未承诺持续实时推送；一小时上限和 Android 系统服务超时都会停止监控，进程被杀后不自动重启。全天通知、厂商推送/其他长连接方案留到服务端阶段明确，不使用不匹配的服务类型规避系统限制。

验收记录见 [手机初版验收](../docs/validation/android-mobile.md)。技术依据：[Android Keystore](https://developer.android.com/privacy-and-security/keystore)、[通知权限](https://developer.android.com/develop/ui/compose/notifications/notification-permission)、[前台服务时限](https://developer.android.com/develop/background-work/services/fgs/timeout)、[Gradle 校验值](https://gradle.org/release-checksums/)。
