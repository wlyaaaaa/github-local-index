# Project Entry Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `E:\GitHub总索引` the required entrypoint for Git project changes, while making `E:\PCConfig` the required machine-configuration lookup when local paths or infrastructure are involved.

**Architecture:** `GitHub总索引` owns project discovery, Git state, visibility, and push gates. `PCConfig` owns machine paths, migrations, scheduled-task references, recovery records, and absolute-path dependencies. Individual projects still own their business rules and tests.

**Tech Stack:** Markdown rules, public index documentation, PowerShell unit test verification.

## Global Constraints

- `E:\GitHub总索引` is the project entry and public gate; it must not store secrets or raw private materials.
- `E:\PCConfig` is the machine configuration center; it must not become the default project entry.
- Specific projects still own their own `AGENTS.md`, README, scripts, and tests.
- If a project change touches absolute paths, scheduled tasks, local data sources, cross-drive migration, backup/restore, or local toolchain assumptions, the agent must check PCConfig.

---

### Task 1: Update GitHub Index Gate

**Files:**
- Modify: `E:\GitHub总索引\AGENTS.md`
- Modify: `E:\GitHub总索引\README.md`
- Modify: `E:\GitHub总索引\00_总览\当前同步看板.md`
- Modify: `E:\GitHub总索引\02_同步诊断\本机配置状态.md`

**Interfaces:**
- Consumes: existing GitHub index rules
- Produces: explicit project-entry and PCConfig-query gate

- [x] **Step 1: Add project entry gate to AGENTS**

- [x] **Step 2: Add concise usage flow to README**

- [x] **Step 3: Add dashboard row and priority item**

- [x] **Step 4: Add PCConfig relationship note to machine config status**

### Task 2: Update PCConfig Boundary

**Files:**
- Modify: `E:\PCConfig\AGENTS.md`
- Modify: `E:\PCConfig\README.md`
- Create: `E:\PCConfig\docs\governance\project_entry_boundary.md`

**Interfaces:**
- Consumes: PCConfig scope rules
- Produces: clear statement that PCConfig is not the project entry

- [x] **Step 1: Add boundary to PCConfig AGENTS**

- [x] **Step 2: Add boundary to PCConfig README**

- [x] **Step 3: Add detailed governance note**

### Task 3: Verify And Publish GitHub Index

**Files:**
- Verify: `E:\GitHub总索引`

**Interfaces:**
- Consumes: updated public index files
- Produces: pushed GitHub index commit

- [x] **Step 1: Run GitHub index unit tests**

```powershell
pwsh -NoProfile -File .\tests\Run-UnitTests.ps1
```

- [x] **Step 2: Run git diff checks**

```powershell
git diff --check
```

- [x] **Step 3: Stage explicit files, commit, and push**

Commit message:

```text
docs: add project entry gate
```
