# Operarius

Open one fresh interactive OpenCode session that takes a GitHub issue from implementation to PR.

```bash
operare 123                   # Laravel → PR
operare 123 --generic         # Other languages → PR
operare 123 --ship            # Laravel → direct delivery
operare 123 --generic --ship   # Other languages → direct delivery
```

**`--ship` pushes directly to the default branch and closes the issue without further confirmation.** Without it, you review and merge the PR yourself.

## Setup

Requires Linux, Bash 4+, Git, `jq`, `sha256sum`, OpenCode V2, authenticated `gh`, and your project's build/test tools.

Install these skills and configure the reviewer:

- [Matt Pocock's `code-review`](https://github.com/mattpocock/skills), supporting uncommitted/new files and separate standards/spec reviewers.
- A **`security-auditor` subagent**.
- **Laravel:** [`laravel-full-stack`](https://github.com/jcergolj/ai-framework/tree/master/skills/laravel-full-stack), Composer, and a `composer analyse` script.
- **Other languages:** Matt's `tdd` skill and `OPERARIUS_CHECK_COMMAND`, covering your project's required build, lint, and test steps.

Skills default to `~/.opencode/skills/<name>/SKILL.md`; override with `OPERARIUS_SKILLS_DIR`. OpenCode uses its configured model.

```bash
git clone https://github.com/jcergolj/operarius.git
cd operarius
mkdir -p ~/.local/bin
ln -s "$PWD/bin/operare" ~/.local/bin/operare
```

Ensure `~/.local/bin` is on your `PATH`. Run from your project's clean, up-to-date default branch with an `origin` remote.

For non-Laravel projects, configure checks in your shell or project environment:

```bash
export OPERARIUS_CHECK_COMMAND='cargo test'
operare 123 --generic
```

Checks run in Bash from the repository root; combine required steps with `&&`. Laravel always runs `composer analyse`.

## Workflow

1. Bash checks setup and the issue, then opens `opencode --auto --prompt …` (equivalent to `oa`).
2. In that session, implement the issue and run project checks.
3. Run fresh standards, spec, and security review subagents; apply relevant fixes.
4. Require an unchanged, clean review and passing checks within three rounds.
5. Commit, push, and open a PR—or deliver directly with `--ship`.

The same interactive session handles the entire workflow in the current terminal, then waits for your instructions after delivery. Further changes, commits, and pushes require your approval. Only review subagents use fresh child sessions. Retrospectives are optional and user-requested.

Run from an interactive terminal. A saved `workflow.sh` launcher and the full prompt are printed before OpenCode starts, including if launch fails. The launcher starts a fresh session, not a resume: inspect existing changes and delivery state before rerunning it.

## Safety

- The session uses `--auto`. Trust your repository, issue, skills, and check command; this is not a sandbox.
- Bash enforces preflight only. The workflow prompt instructs the agent to enforce checks, reviews, Git invariants, and delivery ordering; these are no longer enforced by a Bash orchestrator.
- On failure, the agent is instructed to preserve changes and evidence. Inspect them and continue manually; do not blindly rerun delivery.
- Workflow instructions and agent-written evidence live under `${XDG_STATE_HOME:-~/.local/state}/operarius/` and may contain private code.

## Tests

```bash
bash tests/run.sh
shellcheck bin/operare tests/*.sh
```

Tests cover preflight, the immediate fresh interactive launch, saved launchers, and workflow instructions using local Git repositories and mocked tools—no paid AI calls or network requests. They do not simulate or verify the agent's execution of the workflow.
