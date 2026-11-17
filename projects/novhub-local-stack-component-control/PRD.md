# PRD: novhub-local-stack Component Control

**Status:** Draft
**Author:** Jason Rivero
**Date:** 2026-11-17
**Tickets:** (none)
**Track:** Standard
**Related TRD:** Not yet created

---

## Problem Statement

`novhub-local-stack`'s `run-novhub.sh` only offers whole-stack `up`/`down`/`status` — it runs
every component in a fixed order (`opensearch`, `novdata`, `novapi`, `novapp`, `plcsim`,
`plcnode`, `luna`) with no way to target just one. When the operator only needs a subset (e.g.
OpenSearch + NovApi + NovApp, without NovData/PLCSIM/plc-node/LUNA), the only options today are
to run the whole-stack command anyway — touching components that weren't asked for — or to
hand-type the raw underlying `docker`/`npm`/`curl` commands from scratch each time, bypassing
the existing idempotency and checks entirely.

Separately, the existing step scripts (`steps/*.sh`) are sourced-only — they cannot be run or
inspected on their own — and their console output doesn't consistently narrate what each check
or action is doing before showing its result, which makes it hard to learn how the stack
actually starts, or to trust what a given run did.

If this isn't built: the operator keeps choosing between over-broad whole-stack runs and
error-prone manual command sequences, and learning/debugging the stack means reading source
rather than watching a script explain itself as it runs.

## Users & Personas

| Persona | Description | Primary Need |
|---------|-------------|---------------|
| Repo operator/learner | The sole developer who runs and is learning `novhub-local-stack` on their own dev machine | Start, stop, or check exactly the components needed — no more, no less — with visible, step-by-step console output explaining each check and its result |

## Goals

1. Every component (`opensearch`, `novdata`, `novapi`, `novapp`, `plcsim`, `plcnode`, `luna`,
   `sync`) has its own directly-runnable script supporting `start`/`stop`/`status` and
   `--help`/`-h`, callable without going through `run-novhub.sh`.
2. `run-novhub.sh start|stop|status [component]` dispatches to exactly one component's script
   when a component name is given, or runs the full fixed-order sequence when it is omitted —
   with identical behavior/output to calling that component's script directly.
3. Every check and action prints what it is checking/doing and the result before moving on (no
   silent steps), and every already-satisfied check prints `already ...` and changes nothing.

## Non-Goals (Explicitly Out of Scope)

- Changing any component's internal logic: NovData's replication-row verification, NovApi's
  migration/seeding logic, PLCSIM/plc-node's real build+install steps, LUNA's manual-only
  reminder, NovApp's `.env` handling.
- Adding any new component to the stack.
- Enforcing dependency ordering beyond the existing fixed list order — e.g. `start novapp`
  directly, without `novapi` already up, is allowed; the script does not block it or
  auto-start dependencies.
- Keeping a backward-compatible `up`/`down` alias for the renamed verbs.
- An automated test suite — this repo has none (Bash scripts, no runner applies, per
  `CLAUDE.md` Structural Overrides); validation stays manual, done by the operator once the
  code is stable.

## User Stories

### Must Have (P0)

- As the operator, I want to run a component's own script directly (e.g.
  `./novhub-local-stack/opensearch.sh start`) so I can bring up just that component and watch
  its own output.
- As the operator, I want `run-novhub.sh start <component>` to behave identically to running
  that component's script directly, so there's one consistent interface either way.
- As the operator, I want `run-novhub.sh start` with no component to bring up the whole stack
  in the existing fixed order, so the "just bring everything up" case still works unchanged.
- As the operator, I want every check and action to print what it's doing and the result, so I
  can learn how the stack actually starts instead of trusting a black box.
- As the operator, I want idempotent no-ops clearly labeled `already ...`, so re-running
  `start`/`stop` never surprises me with an unexpected change.
- As the operator, I want `--help`/`-h` on every component script and on `run-novhub.sh`
  describing the verbs and valid component names, so I don't have to read source to know usage.
- As the operator, I want `status <component>` to report only that component, changing nothing.

### Should Have (P1)

(none)

### Nice to Have (P2)

- As the operator, I want the README updated with this usage pattern, consistent with the
  manual OpenSearch operations section already there.

## Acceptance Criteria

- GIVEN OpenSearch, NovApi, and NovApp are all stopped, WHEN I run
  `./novhub-local-stack/novapi.sh start`, THEN only NovApi (and its own `cloud_db_dev` Postgres
  container) starts; OpenSearch, NovApp, NovData, PLCSIM, plc-node, and LUNA are unaffected.
- GIVEN the same stopped state, WHEN I run `./novhub-local-stack/run-novhub.sh start novapi`,
  THEN the result is identical to running `novapi.sh start` directly — same console narration,
  same end state.
- GIVEN a component is already fully up to date, WHEN I run its `start` again, THEN it prints
  `already ...` for every already-satisfied check, makes no changes, and exits 0.
- GIVEN the whole stack is down, WHEN I run `run-novhub.sh start` with no component, THEN every
  component starts in the existing fixed order (`opensearch`, `novdata`, `novapi`, `novapp`,
  `plcsim`, `plcnode`, `luna`), stopping at the first real failure exactly as today's `up` does.
- GIVEN any component script, WHEN I run it with `-h`/`--help`, THEN usage text is printed and
  no state changes; the same is true for `run-novhub.sh -h`/`--help`.
- GIVEN I run `run-novhub.sh status novapp`, THEN only NovApp's status check runs — no state
  changes to any component — and the output names what it checked and the result.
- GIVEN I run `run-novhub.sh start <unknown-name>`, THEN it errors clearly naming the unknown
  component and lists the valid component names, without starting anything.

## Constraints

- **Deadline:** None specified.
- **Tech stack:** Bash, matching this repo's existing convention — no new runtime dependencies,
  no framework, no package manager.
- **Dependencies:** None external — this is a reshaping of this repo's own existing
  `steps/*.sh`/`run-novhub.sh`/`lib/common.sh` files.
- **Other:** Personal, single-operator repo — no team or process dependencies. No automated
  test framework exists or is being added; validation is a manual pass by the operator once the
  code is stable (per `CLAUDE.md` Structural Overrides and standing feedback from this project).

## Open Questions

(none — all answered above)
