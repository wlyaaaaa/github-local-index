# Index Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add repeatable local scripts that refresh the public GitHub index and scheduled task health documents.

**Architecture:** Two focused PowerShell scripts collect read-only state and write public Markdown summaries. A dependency-free PowerShell test harness verifies URL parsing, Markdown generation, and scheduled task result classification.

**Tech Stack:** PowerShell 7/Windows PowerShell compatible syntax, Git CLI, GitHub CLI, Windows Scheduled Tasks cmdlets, Markdown.

## Global Constraints

- The repository is public; never write secrets, full `.env`, OAuth JSON, task XML, raw logs, screenshots, or token values.
- Scripts must not auto-commit, auto-push business repositories, or modify scheduled tasks.
- All generated diagnostics must remain human-readable Markdown under the existing directory structure.

---

### Task 1: Add Test Harness

**Files:**
- Create: `tests/Run-UnitTests.ps1`

**Interfaces:**
- Consumes: exported functions from `tools/Update-GitHubIndex.ps1` and `tools/Update-ScheduledTaskHealth.ps1`
- Produces: a single command that exits non-zero on failed assertions

- [x] **Step 1: Write failing tests**

```powershell
.\tests\Run-UnitTests.ps1
```

Expected before implementation: fails because the scripts or functions are missing.

### Task 2: GitHub Index Refresh Script

**Files:**
- Create: `tools/Update-GitHubIndex.ps1`
- Modify: generated Markdown under `00_总览/`, `01_仓库索引/`, and `02_同步诊断/`

**Interfaces:**
- Produces: `Normalize-GitHubRepoSlug`, `ConvertTo-GitHubIndexRows`, `Write-GitHubIndexDocuments`

- [x] **Step 1: Implement pure parsing and formatting functions**
- [x] **Step 2: Implement `gh` and local clone scanning**
- [x] **Step 3: Write generated Markdown documents**
- [x] **Step 4: Run unit tests and a dry refresh**

### Task 3: Scheduled Task Health Script

**Files:**
- Create: `tools/Update-ScheduledTaskHealth.ps1`
- Modify: `04_计划任务/计划任务健康摘要.md`
- Modify: `04_计划任务/计划任务异常清单.md`

**Interfaces:**
- Produces: `ConvertTo-TaskResultAssessment`, `Write-ScheduledTaskDocuments`

- [x] **Step 1: Implement return-code classifier**
- [x] **Step 2: Query matching local scheduled tasks read-only**
- [x] **Step 3: Write public task health docs**
- [x] **Step 4: Run unit tests and real local refresh**

### Task 4: Documentation And Verification

**Files:**
- Modify: `README.md`
- Modify: `03_推送决策/已推送记录.md`

**Interfaces:**
- Consumes: refreshed Markdown outputs
- Produces: commit-ready public index update

- [x] **Step 1: Document the script entrypoints**
- [x] **Step 2: Run `git diff --check`**
- [x] **Step 3: Run secret-pattern scan**
- [x] **Step 4: Commit and push `github-local-index`**
