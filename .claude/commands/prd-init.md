Start a new feature PRD using a questions-first approach.

## Rules

- Do NOT write the PRD yet.
- Do NOT make assumptions about scope, users, or tech.
- The most dangerous thing in AI-assisted development is the model making assumptions.
  Every question you ask is an assumption you are NOT making.

## Steps

0. Reset feature-scoped git grants. A new PRD starts with every history-changing git action prompting again:
   ```bash
   rm -f .ai-template/grants.local
   ```
   Run it exactly as written, as its own command, never chained with others: chained, git-guard
   asks for approval.
   If a grant existed, tell the user it was removed.

1. Ask the user for a one-sentence description of the feature or idea, and for any related
   ticket IDs (optional — zero, one, or several).

1a. **Track selection** (skip with `--from-spike`). Read only the files the description names, to
   judge the size. Do not explore further. Classify:
   - **Quick:** a change to an existing repository, expected to fit within `pr_size_budget`, that
     adds no new module, API, or data schema.
   - **Spike:** the outcome is uncertain, and the user wants to test an idea before writing a spec.
   - **Standard:** everything else.

   In ONE message: `Suggested track: <X> — <one-line reason>`, then that track's proposal:
   - Quick: the spec and branch per `.claude/commands/quick.md` Draft steps 4–6.
   - Spike: a one-paragraph hypothesis and the spike branch (`.claude/commands/branch.md`, type `spike`).
   - Standard: "Continue with the PRD questions."

   Close with: "Reply **yes** to accept, or name another track." On "yes": Quick → `quick.md`
   After approval; Spike → `.claude/commands/spike.md` Start step 3 (hypothesis already shown);
   Standard → step 2. Another track → show that track's proposal and wait again.
   Steps 2–9 apply to Standard only.

2. Ask clarifying questions ONE per message, at most 5, one per category, in this order:
   - **Who** — Which users or personas does this affect? What is their context?
   - **Why** — What problem does this solve? What happens if it's not built?
   - **Success** — How will we know it worked? What is the measurable outcome?
   - **Scope** — What is explicitly OUT of scope for this version?
   - **Constraints** — Deadline, tech stack, team dependencies, or budget limits?

   - Skip a category only when the one-sentence description already answers it. Note the answer
     taken from the description.
   - Each question offers 2–5 options, or asks for a short answer. Mark one option **Recommended**,
     with a one-line reason. Reply "yes" to accept the Recommended option.

3. Wait for the answer to each question before asking the next. Do not proceed until every
   category is answered or skipped.

4. Summarize your understanding in 3–5 sentences. Then list each answer, and name each skipped
   category with the answer taken from the description:
   "Based on your answers, here's what I understand: [summary]. Is this correct?"

5. Wait for confirmation. If the user corrects you, update your understanding and confirm again.

6. Offer a docs branch before writing anything. The PRD should land on it, not on the base branch.
   - Ask: "Create a branch `docs/...` for this PRD? (recommended)"
   - If yes, follow `.claude/commands/branch.md` with type `docs`, the feature name, and the tickets.
     A slash command cannot invoke another one, so run those steps inline.
   - If no, or if this is not a git repository, continue without a branch.

7. Only after confirmation — generate the PRD using the structure in `templates/PRD.md`.
   - Fill in every section, including `**Tickets:**` (leave it empty if there are none).
   - If a section truly has no answer yet, mark it `TBD — needs answer before TRD`.
   - Do NOT use vague language: no "fast", "simple", "easy" without a definition.

8. Save the PRD to `projects/<feature-name>/PRD.md`.
   - Use kebab-case for the feature name directory.

9. Output: "PRD saved to `projects/<feature-name>/PRD.md`. Run `/prd-review` before generating the TRD."

## Promotion: `/prd-init --from-spike <branch>`

Run from the base branch.
- Find the note: `git diff --name-only <base>...<branch>`, the `projects/*/SPIKE.md` the branch
  adds, then `git show <branch>:<path>`.
- If its Recommendation is not `Promote`, stop: "The spike note does not recommend promotion."
- Use the note as the step 1 description (tickets from its `**Tickets:**`), and skip categories it
  answers. Set the PRD's Track line to `**Track:** Standard (promoted from spike <branch>)`.
- Never copy, merge, or cherry-pick spike code. It is re-implemented through the Standard flow.
