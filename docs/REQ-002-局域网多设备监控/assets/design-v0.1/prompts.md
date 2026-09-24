# 详细设计 v0.1 补图与原始提示词

> 账号范围已按用户确认简化；本组设置图的“修改密码”不再属于首版。使用[当前设置图及提示词](../design-v0.2/prompts.md)。项目与审批图继续使用；以下提示词保留为生成历史。

2026-09-24，使用内置 imagegen 生成，以下为本轮完整提示词。两张补图属于待审核设计，不替换已确认的 U-01，不表示产品已经实现。

- [项目与审批](01-projects-approval.png)：电脑详情、选择项目、待处理操作。
- [常用设置](02-settings.png)：通知设置、连接设置、账号与安全。
- 样式参考：[U-01 登录与设置](../ui-2026-09-24/02-login-create-settings.png)。以样式参考输入生成新的配套页面，保留三屏布局、白灰蓝配色和中文密度。
- 两张均为 1536 × 1024，已检查文字、主导航缺席、来源标签、单次审批、独立账号提示和底部按钮无遮挡。图片内在线、已允许、已连接均为示例状态。
- 具体逻辑和异常状态以[详细设计](../../detailed-design.md)为准；设置图未穷尽开户、改密、外观等所有状态。图内“团队服务”仅是服务显示名，不表示跨账号团队共享。

## 图 1

```text
Use case: ui-mockup. Create a NEW companion design board for Codex Top, using the supplied board only as STYLE REFERENCE. Preserve its exact compact white/cool-gray surfaces, bright blue accent #0866FF, crisp Chinese typography, restrained lines and rounded controls, three equal front-on Android phones side by side. Do NOT copy its login/new/my content. Landscape 3:2 opaque pale gray background, modest title, three large portrait phones, clean exact Chinese text, high legibility, small labels outside screens. 16dp margins, 16sp body, small topbars, minimum 48dp tap areas, no enormous hero cards, no QR, no cloud-vs-computer sessions, no Happier/CLI/Relay/MCP, no decorative gradients. All three are SECONDARY pages with back arrows, NO bottom main navigation. Do not put content under the system safe area. Footer small “设计草案 · 示例数据”. This is a concept, not an implemented product. Board title “Codex Top · 项目与审批”. LEFT phone labeled “07 电脑详情”: back and title “电脑详情”, small laptop outline, “MacBook Pro”, green dot “在线”, rows “最近连接  刚刚”, “Codex  可用”, “项目  3 个”, then blue text action “查看此电脑会话”, and section “项目” with compact rows “Codex Top”, “消息助手”, “文档工具” each folder icon and chevron. No takeover or edit-device actions. CENTER phone labeled “08 选择项目”: back and title “选择项目”, subtitle “MacBook Pro”, compact search “搜索项目”, three compact project rows “Codex Top” selected with blue check, “消息助手”, “文档工具”; short footnote “仅显示这台电脑可访问的项目”; regular height blue button near bottom “确定项目”. No path inputs, no fake directory explorer. RIGHT phone labeled “09 待处理操作”: back and title “待处理操作”, small subtitle “MacBook Pro · Codex Top”, task “登录页调整”, small amber label “等待你的决定”, clear action summary “运行项目测试”, a modest read-only details box with exact command “npm test”, project “Codex Top”, scope “本次操作”. Explanation “允许后将在这台电脑上继续执行。” Secondary note “仅针对当前操作生效”. Two equal normal-height buttons at bottom “拒绝” neutral outlined and “允许本次” blue filled. No always allow, no blanket settings change, no large warning illustration. This is the target interaction only, not evidence approval integration works.
```

## 图 2

```text
Use case: ui-mockup. Create a NEW companion design board for Codex Top, using the supplied board only as STYLE REFERENCE. Preserve its exact compact white/cool-gray surfaces, bright blue accent #0866FF, crisp Chinese typography, restrained lines and rounded controls, three equal front-on Android phones side by side. Do NOT copy its login/new/my content. Landscape 3:2 opaque pale gray background, modest title, three large portrait phones, clean exact Chinese text, high legibility, small labels outside screens. 16dp margins, 16sp body, small topbars, minimum 48dp tap areas, no enormous hero cards, no QR, no cloud-vs-computer sessions, no Happier/CLI/Relay/MCP, no decorative gradients. All three are SECONDARY pages with back arrows, NO bottom main navigation. Do not put content under the system safe area. Footer small “设计草案 · 示例数据”. This is a concept, not an implemented product. Board title “Codex Top · 常用设置”. LEFT phone labeled “10 通知设置”: back and title “通知设置”, group row “系统通知权限” with right “已允许” and chevron, then “任务完成”, “需要你确认”, “任务异常” each enabled blue toggle, “声音与振动” row right “系统设置” and chevron. Small helper “点击通知会直接打开对应对话”. Include small secondary “发送测试通知” text action and footnote “测试结果以本机实际收到为准”. No claim background delivery guaranteed and no first-run bombardment. CENTER phone labeled “11 连接设置”: back and title “连接设置”, compact service row “当前服务  团队服务”, small green-dot status “已连接”, timestamp “最近同步  刚刚”, subdued “检查连接” row; near bottom separate link “更换服务地址” and helper “更换后需要重新登录”. NO IP or localhost and no fake domain needed. It is okay for this technical field to live one level deeper. RIGHT phone labeled “12 账号与安全”: back and title “账号与安全”, small round avatar, “测试账号”, label “独立账号”, compact rows “账号  test-user”, “修改密码” chevron, then concise explanation “仅访问自己账号下的电脑、项目和会话”. Separate quiet “退出登录” row near bottom. No QR, no public signup, no key display, no recovery guarantee, no team-sharing toggle. Password details will be separately specified in the design document.
```

