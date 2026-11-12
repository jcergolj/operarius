# Operarius

Take a GitHub issue from implementation to PR with OpenCode.

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

1. Check setup, implement the issue, and run project checks.
2. Run fresh standards, spec, and security review subagents; apply relevant fixes.
3. Require an unchanged, clean review and passing checks within three rounds.
4. Commit, push, and open a PR—or deliver directly with `--ship`.

Each implementation/review phase starts a fresh session. Output stays in the current terminal. After PR creation, a fresh interactive session waits for your instructions; further commits and pushes require your approval. Without an interactive terminal, the script prints a saved launcher. Retrospectives are optional and user-requested.

## Safety

- Automated phases use `--auto`. Trust your repository, issue, skills, and check command; this is not a sandbox.
- Failures preserve changes and logs. Inspect them and continue manually; do not blindly rerun delivery.
- Logs and handoffs live under `${XDG_STATE_HOME:-~/.local/state}/operarius/` and may contain private code.

## Tests

```bash
bash tests/run.sh
shellcheck bin/operare tests/*.sh
```

Tests use local Git repositories and mocked tools—no paid AI calls or network requests.
