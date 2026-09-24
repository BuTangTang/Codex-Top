import SwiftUI
import CodexTopCore

/// 在原设置窗口中提供紧凑的账号入口，不创建第二个监控界面。
struct MobileAccountSection: View {
    @ObservedObject var account: MobileAccountStore
    @State private var loginName = ""
    @State private var password = ""
    @State private var showConnection = false
    @State private var confirmLogout = false

    var body: some View {
        Section("账号与手机连接") {
            HStack(spacing: 8) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 28, height: 28)
                Text("Codex Top").font(.headline)
                Spacer()
                Text("与手机使用同一账号").font(.caption).foregroundStyle(.secondary)
            }
            if account.hasLogin {
                LabeledContent("账号", value: account.session?.loginName ?? (account.session == nil ? "登录状态待核实" : "已登录账号"))
                LabeledContent("电脑", value: account.session?.host ?? Host.current().localizedName ?? "本机")
                LabeledContent("连接组件", value: account.loginNeedsVerification ? "待核实" : account.session?.daemonRunning == true ? "已启动" : "未启动")
                LabeledContent("Codex", value: account.codexIsOpen ? "已打开" : "未打开")
                HStack {
                    Button("刷新连接") { account.refresh(connectIfNeeded: true) }.disabled(account.busy)
                    Spacer()
                    Button("退出当前账号", role: .destructive) { confirmLogout = true }.disabled(account.busy)
                }
            } else {
                TextField("账号", text: $loginName).textContentType(.username)
                    .accessibilityIdentifier("mobile-account-name").disabled(account.busy)
                SecureField("密码", text: $password).textContentType(.password)
                    .accessibilityIdentifier("mobile-account-password").disabled(account.busy)
                Text("登录后，手机可以访问当前系统用户的 Codex 会话。不同人员请使用各自的系统用户。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("登录并连接", action: submitLogin)
                        .buttonStyle(.borderedProminent)
                        .disabled(account.busy || loginName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || account.serverAddress.isEmpty)
                        .accessibilityIdentifier("mobile-account-login")
                    if account.busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("核实登录") { account.refresh() }.disabled(account.busy || account.serverAddress.isEmpty)
                }
            }
            if let notice = account.notice {
                Text(notice).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("连接设置", isExpanded: $showConnection) {
                TextField("HTTPS 服务地址", text: $account.serverAddress)
                    .accessibilityIdentifier("mobile-account-server").disabled(account.busy || account.hasLogin)
                if account.hasLogin {
                    Text("退出当前端后可修改服务地址。").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("保存连接", action: account.saveConnection).disabled(account.busy || account.serverAddress.isEmpty)
                }
            }
        }
        .confirmationDialog("退出这台电脑的 Codex Top 账号？", isPresented: $confirmLogout) {
            Button("退出当前账号", role: .destructive, action: account.logout)
        } message: {
            Text("本机远程连接将停止，手机和其他电脑的登录不会退出。本机任务监控继续保留。")
        }
        .onDisappear { password = "" }
    }

    /// 将密码交给本次登录后立即清空输入框，后续仅保留组件管理的登录状态。
    private func submitLogin() {
        account.login(name: loginName, password: password)
        password = ""
    }
}
