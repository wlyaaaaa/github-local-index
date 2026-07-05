# User Automation Map Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a public, repeatable map of user-created Windows scheduled tasks and repository-level scheduled task recommendations.

**Architecture:** Extend the existing PowerShell refresh workflow with a focused script that classifies user automation tasks, redacts action details, infers purpose, and writes two Markdown reports. Keep repository recommendations rule-based and conservative.

**Tech Stack:** PowerShell, Windows Scheduled Tasks cmdlets, GitHub index Markdown, existing lightweight `tests/Run-UnitTests.ps1`.

## Global Constraints

- The repository is public; never write secrets, full `.env`, OAuth JSON, task XML, raw logs, screenshots, or token values.
- This task must not create, update, enable, disable, or delete Windows scheduled tasks.
- Action details must be public summaries only: executable name, sanitized root path, and repository hint are allowed; full command arguments are not.
- New scheduled task recommendations must be written as suggestions, not executed.

---

### Task 1: Classification Tests

**Files:**
- Modify: `tests/Run-UnitTests.ps1`
- Create: `tools/Update-UserAutomationMap.ps1`

**Interfaces:**
- Produces: `Test-IsUserAutomationTask`, `Get-PublicActionSummary`, `Get-TaskPurposeInference`, `Get-RepositoryTaskRecommendation`

- [x] **Step 1: Add tests for user automation classification, action redaction, purpose inference, and repository recommendation.**
- [x] **Step 2: Run tests and verify they fail before implementation.**

### Task 2: User Automation Map Script

**Files:**
- Create: `tools/Update-UserAutomationMap.ps1`
- Modify: `04_计划任务/用户自动化任务地图.md`
- Modify: `04_计划任务/仓库计划任务建议.md`

**Interfaces:**
- Consumes: Windows Scheduled Tasks cmdlets and known local GitHub clone index.
- Produces: two public Markdown reports.

- [ ] **Step 1: Implement pure classifiers and redaction helpers.**
- [ ] **Step 2: Implement read-only scheduled task collection.**
- [ ] **Step 3: Implement repository recommendation rules.**
- [ ] **Step 4: Write Markdown outputs.**

### Task 3: Integrate And Verify

**Files:**
- Modify: `README.md`
- Modify: `04_计划任务/计划任务健康摘要.md`
- Modify: `03_推送决策/已推送记录.md`

**Interfaces:**
- Consumes: generated Markdown reports and subagent read-only findings.
- Produces: committed and pushed public index update.

- [ ] **Step 1: Add README entry for the new script.**
- [ ] **Step 2: Run unit tests, `git diff --check`, and public secret-pattern scan.**
- [ ] **Step 3: Commit and push `wlyaaaaa/github-local-index`.**

