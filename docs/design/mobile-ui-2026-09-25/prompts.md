# 手机设计图生成提示词

2026-09-25，使用内置 imagegen 生成三套候选；均为合成内容的概念图，右侧为动画关键帧，不代表运行效果或实现验收。

## A · 清透秩序

Use case: ui-mockup.
Create one exquisitely designed high-fidelity mobile UI concept board for the Chinese app “Codex Top”. This is candidate A, titled exactly “A · 清透秩序”. The user dislikes their existing generic UI and clumsy animations; make this feel like a professionally art-directed shipping productivity app.
Board: wide landscape, very high resolution, quiet pale neutral background. Two large front-facing Android screen artboards, WITHOUT realistic hardware, approximately 393x852 logical proportions, occupy the left 72%; a narrow right column contains a legible three-frame motion storyboard with UI fragments. Generous spacing between artboards, small tasteful headings outside screens. Do not make a marketing poster.
Design A: beautiful paper-white flat interface, graphite Chinese system typography, crisp thin separators, careful optical alignment, blue #1766F5 with small restrained orange accent #D97706. Minimal rounded shapes; NO repeated raised cards, shadows, gradients, glass, giant dashboard metrics, decorative illustrations. A small blue C mark with an orange dot is the existing brand motif. Crisp contemporary typography; title 19sp semibold centered, rows 16sp medium, secondary 12–13sp, generous touch areas. Task rows approximately 76dp.
App product constraints: homepage is ONE unified chronological conversation list, no category tabs, no status segmentation, no project/computer selectors, no visible new conversation button. Search is an icon at upper right. Centered title “会话”. Bottom navigation exactly “会话” “电脑” “我的”. Every row shows task title, compact project and computer source, a small meaningful icon AND textual task state. State must never be communicated by color alone. Running uses a small blue double arc, waiting amber, completed green check, unknown neutral hollow indicator. Do not confuse online computer status with task status. Do not display percentage progress.
Screen 1 home:
title “会话”.
Six compact rows in this precise order:
“修复消息重复” / “Codex Top · MacBook” / “运行中” / “刚刚”
“调整登录页面” / “Codex Top · 办公室电脑” / “待处理” / “14:05”
“整理项目文档” / “Codex Top · MacBook” / “已完成” / “13:42”
“优化列表滚动” / “移动端 · MacBook” / “已完成” / “13:18”
“检查通知跳转” / “移动端 · 办公室电脑” / “状态未知” / “昨天”
“完善外观设置” / “Codex Top · MacBook” / “已完成” / “昨天”.
First line title left time right; second line source left status right. Small status arc can sit before title; avoid duplicate huge icons.
Screen 2 conversation detail: back arrow, centered “修复消息重复”, more icon. Tiny source subtitle “Codex Top · MacBook”. A right-aligned light blue compact user message “帮我检查重复发送的问题。” An assistant response as clean left-aligned readable text on white, NOT a giant rounded chat bubble: “已定位到重连后的重复提交。” followed by one collapsed technical disclosure “查看执行过程” and response “正在调整发送逻辑，并检查断线恢复。” A subtle blue running indicator “运行中” near message bottom. Fixed bottom composer with “继续补充…” and small blue send icon, clean safe area. Conversation screen hides bottom tab bar.
Right column title “动效分镜”. Three horizontal tiny row fragments, ordered top down: “运行中” with dual arc at 0° and caption “0 ms”; “运行中” rotated arc and caption “120 ms”; green check “已完成” caption “240 ms”. Same row position across frames, only indicator and text crossfade/morph, NO bouncing. Footer annotation “圆环收束为勾，列表位置保持稳定”. Add board footnote “概念设计 · 动效为关键帧示意”.
All visible text must be polished, legible simplified Chinese. Screen interiors look practical, refined and buildable. No full file paths, credentials, code internals, tool jargon, English UI controls, assistant marketing text, or unrequested features.

## B · 柔和流动

Use case: ui-mockup.
Create a sophisticated high-fidelity mobile app concept board for Chinese “Codex Top”, candidate B, exact title “B · 柔和流动”. Make a distinct, delightful premium product design, not a recolor of a standard inbox.
Composition: wide landscape, high resolution. Two large straight-on Android screen artboards (393x852 logical aspect) on the left, no phone hardware or perspective, plus a compact motion storyboard on the right. Cool very pale gray presentation background, fine small board labels.
Visual concept: a soft blue-gray continuous surface #F3F6FC, dark slate #182338 Chinese system type, white content sheet seamlessly docked below a centered compact header. The content sheet fills the page and has only softly rounded TOP corners, no floating card stacks. Blue #3E6AF2 focal accent. Warm amber reserved for waiting state. The current running conversation has one subtle pale-blue horizontal row treatment with a slender blue left rail; other rows are flat on white, no shadows, no individual card outlines. Slightly wider row spacing than a messenger, excellent touch ergonomics. No glass blur, neon, gradients, giant headers, dashboard metrics. Small existing blue C/orange dot logo, if useful, never repeated as avatars.
Homepage contract: a SINGLE chronological list, title “会话” centered, search icon upper right, no category tabs and no computer/project selector or create button. Bottom navigation labels exactly “会话” “电脑” “我的”, in a stable full-width bottom surface; active icon occupies a SMALL pale-blue rounded capsule, not a giant floating dock. Every task has a title, source, textual state and a subtle graphic status cue. Do not show fake progress percentages.
Screen 1 home: five well-spaced rows.
“修复消息重复” with source “Codex Top · MacBook”, state “运行中”, time “刚刚”.
“调整登录页面” with “Codex Top · 办公室电脑”, “待处理”, “14:05”.
“整理项目文档” with “Codex Top · MacBook”, “已完成”, “13:42”.
“优化列表滚动” with “移动端 · MacBook”, “已完成”, “13:18”.
“检查通知跳转” with “移动端 · 办公室电脑”, “状态未知”, “昨天”.
Use a 20dp status motif at left, title and source in the center, short state and time aligned right. Running motif is two thin offset blue arcs; waiting is an amber small open circle with center dot; completed a small green check; unknown a gray question indicator. Row height around 94dp, all titles remain readable. Single continuous list.
Screen 2 is detail “调整登录页面”: compact top bar back and more. Under title a small line “Codex Top · 办公室电脑”. User message, compact pale blue bubble aligned right: “把登录页简化成账号和密码。” Assistant text, readable on white: “页面调整已准备好。” followed by “需要你确认是否应用这次修改。” Then an inline approval surface just above the input area, pale warm tone, exact title “等待你的确认”, description “应用登录页面的修改”, two clear buttons “拒绝” and “允许一次”. This is a conceptual approval state, not a claim of implemented capability. Composer fixed at bottom with “继续补充…” and blue send icon. No bottom tabs in detail.
Storyboard right column exact heading “动效分镜”: 3 frames of a task row transforming into the detail sheet, with captions “按下 0 ms”, “展开 120 ms”, “进入 260 ms”. Show the same row title maintaining spatial continuity, gentle blue selection background, content sheet expanding, tiny restrained transition arrows outside UI. Specify through small annotation “从点按位置展开，松手即可接续”. Bottom footer “概念设计 · 动效为关键帧示意”.
Make Chinese accurate and visually beautiful. Avoid repeated cards, cartoon graphics, giant chat avatars, bouncy motion, progress meters, unnecessary instructions, long diagnostic status or technical jargon.

## C · 夜间专注

Use case: ui-mockup.
Design one stunning high-fidelity Chinese mobile UI concept board for “Codex Top”, exact title “C · 夜间专注”. This should feel like a precision-built nighttime coding companion with exceptional reading comfort. No generic cyberpunk dashboard.
Layout: wide landscape high resolution board. Two large front-facing Android UI artboards at left, logical 393x852 proportions, no rendered phone hardware; a narrow right-side motion storyboard. Board background medium muted blue gray so the dark screens have clear edges. Small refined labels outside screens.
Visual identity: true dark navy #111827 canvas, layered slate #1C2535 used sparingly, soft white #ECF1F8 primary text, secondary #AAB7CA with good contrast, restrained cornflower blue #7FAAFF for active controls; warm amber waiting state and soft mint green completed state. Typography is sharply composed Chinese system sans, task title 16sp medium, source and state 12–13sp, center header 19sp. Design personality comes from exceptionally clear type and a fine status gutter at the LEFT of the list. NO neon glow, gradients, terminal styling, monospace body, decorative grids, giant cards, dashboard statistics, or glass blur.
Screen 1: centered “会话”, upper right search icon. Single unified chronological conversation list, no status tabs, filters, computer selector, create button or sections. A thin status gutter contains tiny purposeful blue double-arc / amber dot / green check / gray hollow indicators. Each item has first line title left, time right; second line source left and status TEXT right. Consistent 82dp rows separated by subtle tonal hairlines, first running row has a very subtle slate fill extending across whole width, no floating cards.
Rows in order:
“修复消息重复” / “Codex Top · MacBook” / “运行中” / “刚刚”
“调整登录页面” / “Codex Top · 办公室电脑” / “待处理” / “14:05”
“整理项目文档” / “Codex Top · MacBook” / “已完成” / “13:42”
“优化列表滚动” / “移动端 · MacBook” / “已完成” / “13:18”
“检查通知跳转” / “移动端 · 办公室电脑” / “状态未知” / “昨天”
“完善外观设置” / “Codex Top · MacBook” / “已完成” / “昨天”.
Bottom nav exactly “会话” “电脑” “我的”, thin line icons, no floating pill bar. Preserve very small blue C/orange-dot brand identity where suitable. Do not show percentage progress.
Screen 2 detail title “修复消息重复”, back arrow and more. Source subtitle “Codex Top · MacBook”. Restrained user bubble aligned right, slate-blue fill: “帮我检查重复发送的问题。” Assistant full-width readable content on dark ground, unboxed: “已修复重复提交。” A small green completed indicator with “本轮已完成”. Then text “重连后会保留发送记录，避免同一条消息重复提交。” A collapsed technical line “查看执行过程” with chevron, followed by a small neutral code snippet surface containing only “requestId” and “deduplicate()” as sample code. Small copy icon if needed. Composer fixed at bottom “继续补充…” with soft-blue send button; no bottom navigation in detail.
Storyboard on right, heading “动效分镜”: three frames of a small composer/input strip and one new user bubble, labels “发送 0 ms”, “衔接 100 ms”, “落位 220 ms”. Illustrate bubble moving the short distance up from composer with continuity and no rubber bouncing; background chat text stays still. Small caption “消息从输入框自然进入对话”. Board footer “概念设计 · 动效为关键帧示意”.
Prioritize beautifully readable Chinese and exact states. Source and computer online state must never stand in for task state. No fabricated percent progress or system technical vocabulary, no secret paths or real task text. All example content is synthetic.

