Start a new feature PRD using a questions-first approach.

## Rules

- Do NOT write the PRD yet.
- Do NOT make assumptions about scope, users, or tech.
- The most dangerous thing in AI-assisted development is the model making assumptions.
  Every question you ask is an assumption you are NOT making.

## Steps

1. Ask the user for a one-sentence description of the feature or idea.

2. Based on their answer, ask exactly 5 clarifying questions. Cover:
   - **Who** — Which users or personas does this affect? What is their context?
   - **Why** — What problem does this solve? What happens if it's not built?
   - **Success** — How will we know it worked? What is the measurable outcome?
   - **Scope** — What is explicitly OUT of scope for this version?
   - **Constraints** — Deadline, tech stack, team dependencies, or budget limits?

3. Wait for the user's answers. Do not proceed until all 5 are answered.

4. Summarize your understanding in 3–5 sentences:
   "Based on your answers, here's what I understand: [summary]. Is this correct?"

5. Wait for confirmation. If the user corrects you, update your understanding and confirm again.

6. Only after confirmation — generate the PRD using the structure in `templates/PRD.md`.
   - Fill in every section.
   - If a section truly has no answer yet, mark it `TBD — needs answer before TRD`.
   - Do NOT use vague language: no "fast", "simple", "easy" without a definition.

7. Save the PRD to `projects/<feature-name>/PRD.md`.
   - Use kebab-case for the feature name directory.

8. Output: "PRD saved to `projects/<feature-name>/PRD.md`. Run `/prd-review` before generating the TRD."
