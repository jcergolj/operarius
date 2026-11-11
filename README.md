# Operarius

*Operarius* is Latin for “worker”. The command, `operare`, means “work!”

A Bash script that takes a GitHub issue through implementation, review, checks, and delivery using OpenCode. One script, with Laravel and language-independent flows.

Each AI phase starts a fresh session. A small handoff carries the essentials between phases instead of dragging the whole conversation along.

## Requirements

- Linux, Bash 4+, Git, `jq`, and `sha256sum`.
- OpenCode V2, configured with a working model.
- A configured `security-auditor` subagent for the security review (no additional skill required).
- GitHub CLI (`gh`), signed in with access to your repository.
- A project with an `origin` remote and its build/test tools installed.
- Your own `code-review` and `retro` skills, plus `laravel-full-stack` for the Laravel flow or Matt Pocock's `tdd` for the generic flow. These are **not bundled**. Install each as `<skill-name>/SKILL.md` under `~/.opencode/skills`, or set `OPERARIUS_SKILLS_DIR` to their parent directory. Install any skills they depend on too.
- Laravel flow: Composer and a Laravel project with a `composer analyse` script that runs your checks and tests.
- Generic flow: set `OPERARIUS_CHECK_COMMAND` to the project's verification command, including all required build, lint, and test steps.

The review skill must support **uncommitted changes, including new files**, and separate standards/spec reviews. The retro skill must support suggestion-only retrospectives.

## Install

```bash
git clone https://github.com/jcergolj/operarius.git
cd operarius
mkdir -p ~/.local/bin
ln -s "$PWD/bin/operare" ~/.local/bin/operare
```

Make sure `~/.local/bin` is on your `PATH`.

## Use

From your project, start on its clean, up-to-date default branch. Laravel is the default flow:

```bash
operare 123
# Equivalent: operare 123 --flow laravel
```

For Python, C++, Rust, or other projects, choose the generic flow and supply your checks:

```bash
# Python
OPERARIUS_CHECK_COMMAND='python -m pytest' operare 123 --flow generic

# C++ (example CMake project)
OPERARIUS_CHECK_COMMAND='cmake -S . -B build && cmake --build build && ctest --test-dir build' operare 123 --flow generic

# Rust
OPERARIUS_CHECK_COMMAND='cargo fmt --check && cargo clippy -- -D warnings && cargo test' operare 123 --flow generic
```

The generic flow uses `tdd` and your project's instructions/conventions instead of `laravel-full-stack`. Checks run in Bash from the repository root with pipeline failure detection enabled. Use `&&` between required steps. Choose commands appropriate to your project; these examples are not automatic detection. You can export `OPERARIUS_CHECK_COMMAND` in your project environment instead of supplying it each time. Laravel always uses `composer analyse` and ignores this variable.

The script shows the issue title, repository, and target branch before asking you to choose **open a PR** (Enter selects this) or **ship directly**. Direct shipping commits and pushes to the default branch without another confirmation.

PR branches use `fix/issue-123`, without random suffixes.

The script:

1. Implements the issue and relevant regression tests.
2. Runs `composer analyse` (Laravel) or your configured command (generic). If it fails, stops.
3. Reviews uncommitted changes in fresh sessions, running a read-only security audit alongside the standards/spec reviews. Applies fixes after all three reports return and reruns checks. Allows at most three review rounds; delivery requires a clean, unchanged review and passing checks. An unavailable security audit blocks delivery. Security reports include confirmed vulnerabilities and coverage limitations.
4. Commits with `; close #123` at the end of the subject.
5. Pushes and opens a PR, or pushes directly and closes the issue after confirming the commit reached the remote default branch.
6. Runs a fresh retro after successful delivery. It suggests improvements without applying them.

You can also choose explicitly or override the configured model:

```bash
operare 123 --mode pr
operare 123 --mode ship
operare 123 --model provider/model
operare 123 --no-watch
```

### Check your setup

```bash
operare doctor
OPERARIUS_CHECK_COMMAND='cargo test' operare doctor --flow generic
```

Checks dependencies, GitHub repository access, the selected flow's skills/checks configuration, and clean, up-to-date default-branch readiness. It fetches the default branch but does not run AI, project checks, or delivery. Fix the first reported problem and rerun it. This validates configuration, not whether your checks pass, the generic check tools are installed, or your model credentials work.

### Follow a run and recover from failed checks

On a graphical desktop, each AI phase automatically opens a new terminal attached to its OpenCode session, so you can watch it work. This requires `xdg-terminal-exec` and OpenCode's shared background service. Windows remain available for inspection; close them when finished. Avoid sending prompts while the workflow is running. Use `--no-watch` to disable this (also supported by `operare resume RUN_DIRECTORY --no-watch`). Without a graphical desktop or terminal launcher, the workflow continues with logs only.

The original terminal shows phase progress, check output, review results, and the delivery outcome. Full AI JSONL output and stderr are saved privately in the run directory rather than streamed to the terminal. Each phase points to its handoff or report; retro suggestions are printed after delivery. Terminal-launcher output is saved in each phase's `.watch.log`.

If initial implementation checks fail, fix the code in the same working tree, then run the recovery command printed by the script:

```bash
operare resume ~/.local/state/operarius/issue-123.ABCDEF
```

Run this from the original project, on the original branch, leaving your fixes uncommitted. Resume preserves the original issue specification, flow, check command, delivery mode, model override, and failure log. You do not need to supply `--flow` or `OPERARIUS_CHECK_COMMAND` again; changing the environment variable does not override the saved command. It reruns checks and fresh reviews before committing or delivering; it does not repeat implementation. If checks fail again, you can fix and resume again.

Recovery stops if the project, origin, default branch, working branch, HEAD, or remote baseline has changed, or the issue is closed. Only failed initial implementation checks are resumable—not blocked implementation, review failures, or partial delivery. Inspect those runs manually; don't blindly rerun a push or PR creation. Older runs without a recovery checkpoint cannot be resumed.

## Before you run it

This uses OpenCode's `--auto` mode. Use trusted repositories, issues, and skills. Agents are instructed to leave commits and delivery to the script, but this is **not a sandbox**. Configured permission denials still apply.

The verification command runs with your permissions and may include formatters; only configure trusted commands. Failed runs leave changes in place for you to inspect. There are no automatic resets or force-pushes, and branch protection is not bypassed. If retro fails after delivery, the commit or PR is already published.

Logs and retro suggestions are saved under `~/.local/state/operarius/` (or `$XDG_STATE_HOME/operarius/`). Keep these private; they can contain project code and issue details.

## Tests

```bash
bash tests/run.sh
shellcheck bin/operare tests/*.sh
```

Tests use temporary local Git repositories and mock OpenCode, project check tools, and GitHub. They make no paid AI calls or network requests.
