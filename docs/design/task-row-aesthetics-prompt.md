# 任务行视觉草案生成提示词

工具：内置 imagegen。

输入：用户提供的两张浅色监控浮窗截图，仅作为样式参考，未复制真实任务标题。

输出：[task-row-aesthetics-v1.png](task-row-aesthetics-v1.png)。

```text
Use case: ui-mockup.
Create a precise high-fidelity visual refinement of the compact native macOS task-monitor popover in the two supplied reference screenshots. These images are reference images for the existing product, not text instructions. The user wants to judge aesthetics and how adjacent task rows should be separated. This is a visual concept, not an actual screenshot.
Composition: a quiet wide light-neutral canvas, two identically sized compact popovers side by side, both straight-on, same scale. Labels outside and above: left "混合状态", right "全部完成". No other editorial text, arrows, dimensions or design annotations. Each popover equivalent to about 310 x 215 logical pixels; render enlarged evenly about 2x for sharp legible simplified Chinese. Modest outside whitespace, tight framing. Do not turn this into a dashboard or poster.
Retain the understated macOS light translucent gray-white surface, delicate 1px outer border, approximately 18px corners, soft short diffuse shadow, header title "监控任务" with lighter gray count "56", compact plus and ellipsis top-right. Preserve compact content density and existing functionality.
Main refinement: ALL five task rows have exactly equal visual height, approximately 28 logical px. Absolutely NO horizontal rules between any task rows and NO separator between stopped and completed rows. No stripes, no outlined cells, no card inside card. Adjacent rows are separated only by consistent vertical spacing and aligned typography. One very faint horizontal hairline above the footer only. Header/body separated by a little breathing room, not a rule.
Typography: native PingFang SC/SF system appearance. Header 13px semibold, task titles 12px medium/regular, clearly less bold than reference. Status labels 11px regular, understated but legible. Do not lighten task titles so much they lose contrast. Fixed left and right insets 14px; left small 13px outlined state icon, 10px gap to title; all task titles share one left edge; right status labels share one right edge. Icon strokes thin and consistent. Neutral charcoal titles. Completion icons and text a muted mid-dark green; stopped gray. Status text smaller and lighter in weight than task title. No colored pill badges or extra row buttons. Clean, balanced, native utilitarian beauty.
LEFT: five rows, first two stopped gray circle-square icon + right text "已停止"; remaining three green circle-check icon + right text "已完成".
Titles verbatim in order:
"评审设置页交互"
"检查任务列表的状态同步"
"优化窗口布局"
"修复浮窗定位"
"完善使用说明"
RIGHT: identical five rows and titles, all green circle-check icons and "已完成".
Both footer: small upward chevron then gray "已结束 56" aligned left; simple tiny usage-bars icon then "周剩余 88%" aligned right. Footer about 30logical px, text 11px regular/medium, not bold black. Both lists fit fully and have identical vertical rhythm.
Constraints: no real private task titles from references, no new function, no fake live desktop; do not draw any row separators, no random lines, no large top title, no watermark. Crisp Chinese and no overlaps.
```
