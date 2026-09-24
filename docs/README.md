# 文档入口

Codex Top：把 Codex 任务放在 Mac 屏幕顶部，也可以将同一份列表置顶悬浮。

- [English project README](../README.en.md)
- [当前状态与续做记录](STATUS.md)：接续开发先读这里。
- [已接收回答的状态同步](validation/accepted-question-replies.md)：修复回答已提交而仍长时间待处理的问题，保留现有界面。
- [REQ-002 多电脑 Codex 会话、手机通知与对话](REQ-002-局域网多设备监控/requirement.md)：依据需求 v0.10、[设计 v0.2](REQ-002-局域网多设备监控/detailed-design.md)及[五组 tasks](REQ-002-局域网多设备监控/tasks/progress.md)实施并进行本机联调，原生新建按 D-05 暂缓。D-06独立手机UI、D-07仅简体中文的[本批验证](validation/codextop-mobile-ui-2026-09-24.md)已记录，当前 APK 尚未通过整体视觉验收。[首页精简讨论](REQ-002-局域网多设备监控/homepage-revision-draft.md)、[原六页提示词](REQ-002-局域网多设备监控/assets/ui-2026-09-24/prompts.md)、[简化账号设置图](REQ-002-局域网多设备监控/assets/design-v0.2/prompts.md)和[手机验收记录](validation/happier-mobile.md)保留依据；[主管记录](REQ-002-局域网多设备监控/supervision.md)顶部为当前写权，旧实施及[开源调研](REQ-002-局域网多设备监控/opensource-research.md)为历史参考。
- [REQ-002 独立部署包审查](validation/codextop-deploy-package-2026-09-24.md)：24项本地检查及两项故障修复复核通过；未构建镜像或部署，真实恢复和公网验收待完成。
- [build 36 可选渐隐双弧](validation/twin-arc-orb.md)：保留经典圆环，新增 D4 双弧及固定运行数，移除机器人原型。
- [build 31 统一浅色实色外观](validation/solid-light-theme.md)：监控、菜单及主题快照共用不透明浅白，保留三项主题和原有布局。
- [build 30 双列快捷菜单](validation/quick-menu-grid.md)：四模式 2×2、主题横排、208pt 宽和固定字号；只调整菜单。
- [build 29 紧凑菜单与浮窗动效](validation/compact-menu-motion.md)：144pt 菜单、12pt 字号、固定顶部的浮窗视口动画与模式淡入淡出。
- [build 27 展开响应、自动整理与菜单](validation/expansion-performance.md)：按需加载、布局稳定、7 天自动移出、底边去重影与实色同层菜单。
- [build 18 列表与比例验收](validation/task-list-refinement.md)：稳定滚动、手动整理、新 100% 基准与设置实时预览。
- [任务行视觉方案](design/task-row-aesthetics.md)：行间留白、字重与对齐的概念来源，已实施。
- [任务移出监控方案](design/task-retention-proposal.md)：右键移出与选择器批量整理，已实施。
- [D-70 紧凑任务布局](validation/compact-layout.md)：单行结束任务、双行活动任务和合并底栏；已随 build 18 收口。
- [1.0.0 build 15 跨屏拖动](validation/cross-screen-drag.md)：系统窗口服务接管展开区和圆环拖动，用户实测确认正常。
- [1.0.0 build 12 统一屏幕字号](validation/unified-typography.md)：保留外接屏紧凑字号，内置屏同步缩小；旧/新真实包同屏对照。
- [1.0.0 build 11 圆环展开与拖动](validation/orb-drag.md)：动画期间立即拖动、原生整点坐标、内置屏与外接屏验收。
- [1.0.0 build 10 恢复初版尺寸](validation/appearance-restore.md)：按用户指定时间点恢复按钮和文字，保留两入口功能。
- [1.0.0 build 9 两按钮与文字层级](validation/header-actions.md)：四模式实机图、内置/外接屏检查及最终包证据。
- [1.0.0 显示位置菜单](validation/1.0.0.md)：单按钮入口、菜单关闭保护、白色图标、取消置顶返回与可见任务数。
- [待处理复查与来源任务跳转](validation/waiting-navigation.md)：build 3 的修正、长等待回复回归、未复现边界与单条问题定位限制。
- [使用说明](usage.md)
- [小红书分享介绍与实际截图](share/xiaohongshu/README.md)：三张原生桌面截图（圆环、展开、钉住）、精简文案及历史竞品对比参考。
- [开发与打包](development.md)
- [v0.1.0 版本说明与下载](https://github.com/BuTangTang/Codex-Top/releases/tag/v0.1.0)：回复刷新、计时回查、缩放快捷键、单浮窗与运行提示。
- [v0.1.0-beta.4 预发布说明](releases/0.1.0-beta.4.md)：设置在鼠标所在屏幕打开。
- [v0.1.0-beta.3 预发布说明](releases/0.1.0-beta.3.md)：主题轮廓修复、双语说明与实际刘海截图。
- [v0.1.0-beta.1 预发布说明](releases/0.1.0-beta.1.md)：DMG 安装、版本内容与验收限制。
- [v0.1.0-beta.2 预发布说明](releases/0.1.0-beta.2.md)：D-49–D-51 内容与最终验收范围；保留 beta.1 附件。
- [M2 实机验收及待检查项](validation/M2.md)
- [圆环原位变形与状态动画](validation/M2-circle.md)
- [刘海、圆环提醒与轮廓修订](validation/notch-orb-refinement.md)
- [M3 打包与真实接入验收](validation/M3.md)
- [R01–R19 验收证据与缺项](validation/acceptance-matrix.md)

- [需求与验收标准](REQ-001-任务监控/requirement.md)
- [详细设计](REQ-001-任务监控/detailed-design.md)
- [阶段进度](REQ-001-任务监控/tasks/progress.md)
- [M1 数据接入与核心规则](REQ-001-任务监控/tasks/M1-数据接入.md)
- [M2 原生窗口与交互](REQ-001-任务监控/tasks/M2-界面交互.md)
- [M3 打包与真实验收](REQ-001-任务监控/tasks/M3-交付验收.md)
- [设计概念](design/README.md)
- [应用 Logo 与生成提示词](design/logo-v1.md)
- [Logo 安装与启动台核对](validation/app-icon.md)

- [Windows 版完整开发提示词](handoff/windows-implementation-prompts.md)
- [独立额度与流量核对](validation/account-refresh-traffic.md)

当前源码与本机安装为 v1.0.0 build 36。D-80 保留经典圆环、新增渐隐双弧并移除机器人原型；既有窗口布局、开合动画和任务逻辑保持。构建与当前实际检查范围见 [本轮验收](validation/twin-arc-orb.md)；历史完整连续动画与跨屏验收不借用本轮结论。中英文 README 四模式图片仍对应 build 10。公开 Release 附件未变。

- [beta.2 最终测试、实际截图与分发校验](validation/beta2.md)

- [beta.3 主题轮廓修复与实际核对](validation/beta3.md)

- [beta.4 设置定位与实际核对](validation/beta4.md)

- [beta.5 候选阶段验收记录](validation/beta5.md)

- [旧自研手机消息中转服务](../relay/README.md)：仅保留历史成果，不作为当前 Happier 方案的交付或部署入口。
