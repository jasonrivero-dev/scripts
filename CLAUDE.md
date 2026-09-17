# Project Rules

## Methodology: Plan → Implement → Validate (PIV)

Never skip phases. Never assume. Always review before advancing.

## Phase Gates

| From  | To   | Gate Command    | Rule                                      |
|-------|------|-----------------|-------------------------------------------|
| Idea  | PRD  | `/prd-init`     | Ask questions first, never assume         |
| PRD   | TRD  | `/prd-review`   | PRD must be reviewed and confirmed        |
| TRD   | Code | `/trd-review`   | Plan must be confirmed before any coding  |
| Code  | Done | `/validate`     | All 5 layers must pass                    |

## The Five Rules

1. **Questions before PRD.** Use `/prd-init`. Ask before writing.
2. **Review PRD before TRD.** Use `/prd-review`. No TRD without a signed-off PRD.
3. **Review plan before executing.** Use `/trd-review`. No code without a confirmed TRD.
4. **Reset context between phases.** Use `/prime` to load only what's needed per phase.
5. **Commit frequently.** Every logical unit of work gets a commit. Git log is your memory.

## Commit Convention

```
<type>(<scope>): <description>

Types: feat | fix | refactor | test | docs | chore
```

Example: `feat(todos): add repository layer with create and findByUserId`

## Project Structure

```
projects/<feature-name>/
  PRD.md     — product requirements (WHAT, not HOW)
  TRD.md     — technical requirements (HOW)
```

Templates live in `templates/`. Copy them when starting a new feature.

If this project does not follow the default structure, check `## Structural Overrides` below
before assuming any file paths or commands from this template are correct as written.

## What Belongs in CLAUDE.md

- Global rules and methodology (always here)
- `## Application Overview` — maintained by `/project-init`, describes what the app actually does, for repos where the template is adopted mid-project
- `## Project State` — maintained by `/sync`, reflects current architecture and features
- `## Structural Overrides` — maintained by `/project-init`, reflects decisions to deviate from template defaults
- Rules learned from past mistakes (`## System Evolution`)

Do NOT add:
- Feature-specific context (put it in `projects/<feature>/`)
- Full implementation decisions (those belong in TRDs and commit messages)

## Security

### .env files

- Never read, log, print, or commit `.env` files or any file containing secrets.
- If a `.env` file is needed to understand config shape, read `.env.example` instead.
- Always confirm `.env` is in `.gitignore` before the first commit on any project.
- If a `.env` file is accidentally staged, stop immediately and ask the user how to proceed.

### Credentials and secrets

- Never hardcode credentials, API keys, tokens, passwords, or connection strings in source code.
- All secrets must be referenced via environment variables (`process.env.VAR`, `os.environ["VAR"]`, etc.).
- If you encounter a hardcoded secret anywhere — in code, comments, test fixtures, or config files —
  treat it as a high-severity finding and stop to report it before continuing.
- Sensitive values must never appear in log output, error messages, or API responses.

### Secure-by-default reminders

These are enforced at three points in the PIV workflow:
- **Plan** (`/trd-generate`): identify sensitive data flows and define how secrets are managed.
- **Implement** (`/implement`): no hardcoded secrets; use env vars; check `.gitignore` before first commit.
- **Validate** (`/validate-review`): scan diff for credentials and sensitive data exposure.

## Sub-Agent Policy

Sub-agents are for research only — codebase exploration, reading docs, scanning files.
Never use sub-agents to write production code.

## System Evolution

Every mistake the agent makes is an opportunity to add a rule here so it never makes
that mistake again. This file compounds over time.

---

## Application Overview

> Populated by `/project-init` from this repo's `README.md` (and any pre-existing `CLAUDE.md`)
> when the template is adopted on a project that already has code.
> If empty, this is a fresh project with no existing application yet.

**What this app does:** (not yet defined — run `/project-init` if this template was adopted
on an existing codebase)

**Domain / users:** (none yet)

**Main components:** (none yet)

---

## Structural Overrides

> Populated by `/project-init` when this project intentionally diverges from template defaults.
> If empty, all template command defaults apply as-is.

| Convention | Template Default | This Project | Reason | Date |
|------------|-----------------|--------------|--------|------|
| (none yet — run `/project-init` on first setup) | | | | |

---

## Project State

> Maintained by `/sync`. Run `/sync` after each TRD approval, architectural change, or deprecation.
> Last updated: (not yet synced — run `/sync` after the first TRD is approved)

### Architecture

(Not yet defined. Will be populated after first `/sync`.)

### Active Features

| Feature | Status | Key Additions |
|---------|--------|---------------|
| (none yet) | | |

### Deprecated

| Item | Replaced By | Since |
|------|-------------|-------|
| (none yet) | | |

### Key Architectural Decisions

> Decisions made in TRDs that every future feature must follow.

(None yet. Will be populated from TRD Stack Decisions after first `/sync`.)
