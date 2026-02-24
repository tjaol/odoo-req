# MEMORY.md

## Rule 6 — 双层记忆存储（铁律）
- 每次遇到坑/经验教训，必须在继续下一个话题前，立即写入 LanceDB 两层记忆：
  1) Technical layer（category: fact, importance ≥ 0.8）
     - Pitfall: [symptom]
     - Cause: [root cause]
     - Fix: [solution]
     - Prevention: [how to avoid]
  2) Principle layer（category: decision, importance ≥ 0.85）
     - Decision principle ([tag]): [behavioral rule]
     - Trigger: [when it applies]
     - Action: [what to do]
- 每次写入后，立刻用 anchor keywords 执行 `memory_recall` 验证可检索。
- 若检索不到：重写并重新写入，直到能检索到。
- 缺少任意一层视为未完成，不得进入下一话题。
- 相关经验需同步更新对应 SKILL.md，避免复发。

## Rule 7 — LanceDB 卫生
- 记忆条目必须短小、原子化（< 500 chars）。
- 禁止存原始长对话总结、大段文本、重复内容。
- 优先使用结构化格式，并带检索关键词。

## Rule 8 — Recall before retry
- 任何工具失败、重复报错、或异常行为出现时，重试前必须先 `memory_recall`。
- 检索关键词应包含：错误信息、工具名、症状。
- 先查已知解法，禁止盲目重试。

## Rule 10 — 编辑前确认目标代码库
- 处理 memory 插件时，先确认正在修改的目标包（如 memory-lancedb-pro vs 内置 memory-lancedb）。
- 必须先做 `memory_recall` + 文件系统搜索，避免改错仓库。

## Rule 20 — 插件代码变更必须清 jiti 缓存（MANDATORY）
- 修改 `plugins/` 下任何 `.ts` 文件后，在 `openclaw gateway restart` 前必须执行：
  - `rm -rf /tmp/jiti/`
- 原因：jiti 会缓存编译后的 TS，仅重启可能加载旧代码。
- 仅配置变更（config-only）不需要清缓存。
