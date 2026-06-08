# UI Delegation Guide

Guidelines for delegating frontend/UI implementation tasks to cheap workers. Derived from
real production experience building a FastAPI + Vue + D3 application (aiworld project,
2026-05).

## When To Delegate UI Work

Delegate:
- Project scaffolding (vite/vue/react init, venv setup, dependency installation)
- CRUD pages, form views, list views, routing boilerplate
- Terminal API endpoints (FastAPI/Express) that serve JSON
- Pages with a clear design spec (mockup screenshots, JSX prototypes, component schemas)

Do NOT delegate:
- Interaction-heavy D3/canvas visualizations where library semantics matter (force layout,
  zoom, drag) — unless you can give extremely precise instructions
- Subtle CSS layout fixes (a 3-line tweak is faster to do yourself than to brief a worker)
- Cross-component state bugs (worker lacks the full app context)

## Prompt Quality Matters Enormously

Measured improvement from generic to precise prompts:

| Prompt style | Worker score | Fixes needed |
|---|---|---|
| Generic ("implement D3 graph") | 7/10 | ~20 lines of fixes, fundamental bugs |
| Precise (schema + constraints + anti-patterns) | 9/10 | 0 fixes needed |

### What Makes a Precise UI Prompt

1. **Give the exact data schema** — paste the JSON structure, not a description of it.

2. **Name the anti-patterns explicitly** — if a library has a common footgun, call it out:
   ```
   D3 力导向图：绝对不要设 node.fx / node.fy，让力模拟自由运行
   ```

3. **Specify numeric parameters** — don't say "spread nodes out", say:
   ```
   charge: -200, linkDistance: 80, collision radius: 30
   ```

4. **Reference previous bugs** — if the worker type has a pattern of mistakes, warn:
   ```
   上次踩的坑：Vite 需要配 host: '127.0.0.1' 否则只绑 IPv6
   ```

5. **State what NOT to use** — when a simpler approach exists:
   ```
   走势图用纯 SVG 手绘即可，不需要 D3
   ```

6. **Give the output format** — exact file paths, component names, route paths.

## Worker Strengths & Weaknesses for UI Tasks

### DeepSeek (DS) — tested extensively

Strong at:
- Project scaffolding and boilerplate (venv, npm, TypeScript config, routing)
- Terminal API code (FastAPI endpoints, CORS, JSON serving)
- Translating a clear data schema into Vue/React components
- CSS layout following a described structure
- Form controls, lists, cards, progress bars

Weak at:
- D3 force simulation semantics (pinned all nodes with fx/fy, defeating the layout)
- Windows-specific quirks (IPv6-only binding, process cleanup)
- Complex interactive library integration where the "wrong" code still runs silently
- Knowing when a feature is unnecessary (over-engineers if not constrained)

### Implication for Task Design

Split complex UI into:
1. **Scaffolding + structure** → delegate to DS (high ROI, reliable)
2. **Interactive visualization** → either do yourself, or delegate with extremely precise
   instructions including parameter values and explicit prohibitions
3. **Polish/tweaks** → do yourself (faster than writing a prompt)

## Acceptance Checklist for UI Tasks

In addition to the standard Implementation Task checklist:

- [ ] App actually loads in the browser (not just "npm run dev succeeds")
- [ ] API endpoints return correct JSON (curl/fetch verify)
- [ ] Interactive elements respond (click filters, switch tabs, hover tooltips)
- [ ] No browser console errors
- [ ] Colors match the design intent (especially domain conventions like red=up, green=down
      for A-share markets)
- [ ] Responsive to window resize (no overflow, no missing scroll)
- [ ] No stale dev server processes left running

## Cost Analysis

Typical UI delegation token savings:

| Task type | Worker writes | Main brain reviews | Token saving |
|---|---|---|---|
| Project scaffold (8+ files, 600+ lines) | ~600 lines | Read 1 file + 6 edits | ~70-80% |
| Full page (single .vue, ~350 lines) | ~350 lines | Read + 3 edits | ~60-70% |
| Data extraction (read many articles → JSON) | Reads 100KB+ source | Reads 12KB output | ~90% |

The cheap worker's per-token cost is ~1/30 of the main brain, so even if the worker reads
the same amount, the total cost is dramatically lower.

## Template: Precise UI Page Prompt

```
在 [项目路径] 中实现 [页面名] 页面（[组件名].vue），替换当前的占位页。

## 数据源
[API 端点，完整 JSON schema 示例]

## 页面布局
[分区描述：header / sidebar / main / footer]
[每个区域的具体组件和数据绑定]

## 样式要求
[CSS 变量，颜色约定，设计风格]

## 关键注意事项（上次踩的坑）
1. [具体禁止项]
2. [环境配置项]
3. [进程清理要求]

## 报告
完成后报告：创建/修改了哪些文件、[具体验证项]
```


