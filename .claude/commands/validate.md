Run the full 5-layer validation pipeline.

Layers 1–3 are automated (agent handles, iterates until green).
Layers 4–5 require you — the agent provides structure and assists.

## Pipeline

```
Layer 1: Type checking + linting    → /validate-lint    (automated, agent iterates)
Layer 2: Unit tests                 → /validate-unit    (automated, agent iterates)
Layer 3: Integration / E2E          → /validate-e2e     (automated, agent iterates)
Layer 4: Code review                → /validate-review  (you drive, AI assists)
Layer 5: Manual testing             → /validate-manual  (you test, AI provides checklist)
```

## Execution

Run layers in order. Do not advance to the next layer until the current one is green.

1. Run `/validate-lint` → wait for ✅
2. Run `/validate-unit` → wait for ✅
3. Run `/validate-e2e`  → wait for ✅
4. Run `/validate-review` → address all issues → confirm ✅
5. Run `/validate-manual` → complete checklist → confirm ✅

## Final Summary

After all layers pass, output:

```
Validation Summary
─────────────────────────────────────────────────────────
Layer 1 — Type check + lint    ✅  0 errors
Layer 2 — Unit tests           ✅  X passing
Layer 3 — Integration / E2E    ✅  X scenarios passing
Layer 4 — Code review          ✅  Reviewed, issues resolved
Layer 5 — Manual testing       ✅  All scenarios passed
─────────────────────────────────────────────────────────
Feature is validated. Ready for PR.
```
