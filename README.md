# Operarius

*Operarius* is Latin for “worker”. The command, `operare`, means “work!”

A Bash script that takes a GitHub issue through implementation, review, checks, and delivery using OpenCode. One script, with Laravel and language-independent flows.

Each AI phase starts a fresh session: implementation, every review round, and the final human-led PR review. Within a review round, standards, spec, and security reviewers run as separate subagents, each with fresh context. A small handoff carries the essentials between phases instead of dragging the whole conversation along.

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
3. Starts a fresh review session. The `code-review` skill delegates standards/spec reviews to separate subagents, while `security-auditor` runs alongside them in its own child session. All reviewers are instructed to remain read-only and review the same unchanged code. The parent applies relevant fixes only after all three reports return, then the script reruns checks. Allows at most three rounds; delivery requires all reviews completed, no unresolved findings, an unchanged clean round, and passing checks. An unavailable required reviewer blocks delivery. Security reports include confirmed vulnerabilities and coverage limitations.
4. Commits with `; close #123` at the end of the subject.
5. Pushes and opens a PR, or pushes directly and closes the issue after confirming the commit reached the remote default branch.
6. After opening a PR, hands control to a fresh interactive OpenCode session for your review instructions. Retro runs only when you ask. Direct shipping still runs a fresh, suggestion-only retro automatically.

You can also choose explicitly or override the configured model:

```bash
operare 123 --mode pr
operare 123 --mode ship
operare 123 --model provider/model
operare 123 --no-watch
```

### Command reference

| Command | Purpose |
| --- | --- |
| `operare --help` | Show usage and requirements. |
| `operare ISSUE` | Start a new run for a positive issue number in the current repository. Prompts for PR/direct shipping; defaults to Laravel. |
| `operare ISSUE --flow laravel` | Use `laravel-full-stack` and `composer analyse`. |
| `operare ISSUE --flow generic` | Use `tdd` and the required `OPERARIUS_CHECK_COMMAND`. |
| `operare ISSUE --mode pr` | Open a PR, then hand off to human-led review. No delivery-mode prompt. |
| `operare ISSUE --mode ship` | Push directly to the default branch, close the issue, then run retro automatically. No further confirmation. |
| `operare ISSUE --model PROVIDER/MODEL` | Override the model for automated sessions. |
| `operare ISSUE --no-watch` | Disable automated watcher windows; keep the final PR handoff in the current terminal or a saved launcher. |
| `operare doctor` | Validate the default Laravel setup without AI calls or running checks. |
| `operare doctor --flow laravel` | Explicitly validate the Laravel setup. |
| `operare doctor --flow generic` | Validate generic setup; requires `OPERARIUS_CHECK_COMMAND`. |
| `operare resume RUN_DIRECTORY` | Retry failed initial checks, then security/review and delivery using saved settings. |
| `operare resume RUN_DIRECTORY --no-watch` | Resume without automated watcher windows. |
| `bash RUN_DIRECTORY/pr-review.sh` | Open a fresh human-led PR review session using the saved handoff. Does not rerun delivery. |

Options can be combined after the issue number, for example `operare 123 --flow generic --mode pr --no-watch`. Issue URLs are not accepted. Resume restores the original flow, model and delivery mode; `--flow` may only repeat the saved flow. Use `--no-watch` to change watcher behavior when resuming.

| Environment variable | Purpose |
| --- | --- |
| `OPERARIUS_CHECK_COMMAND` | Required generic-flow verification command. Saved for resume; ignored by Laravel. |
| `OPERARIUS_SKILLS_DIR` | Skill parent directory; defaults to `~/.opencode/skills`. |
| `XDG_STATE_HOME` | State parent directory; logs/handoffs go under `operarius/`. Defaults to `~/.local/state`. |

Inside the final OpenCode session, give normal-language review instructions and ask for `/retro` when ready. `/retro` is an OpenCode skill invocation, not an `operare` subcommand.

### Workflow

```text
Issue → Preflight → Choose Laravel/generic + PR/ship
                         │
                         ▼
                Implementation session
                         │
                         ▼
                    Project checks ──fail──→ Manual fix → resume
                         │ pass
                         ▼
                 Fresh review session
                  ├─ Standards subagent
                  ├─ Spec subagent
                  └─ Security subagent
                         │ all reports returned
                         ▼
                  Parent applies fixes
                         │
                         ▼
                    Project checks
                         │
              Changes/findings? → Repeat security/review (max 3 rounds)
                         │ clean + unchanged + checks pass
                         ▼
                    Commit + Push
                   ┌─────┴──────┐
                  PR           Ship
                   │             │
          Open pull request   Confirm delivery
                   │          Close issue
                   ▼             │
          Fresh interactive      ▼
          human-led session   Automatic retro
                   ↕
          Your requested changes
          Approve commits/pushes
          Ask for /retro
          You merge when ready
```

### Human-led PR review

After the PR opens, the script stops making code or delivery decisions and opens a new interactive OpenCode session with the PR URL, original issue, implementation handoff, and review reports. It acknowledges the handoff and waits for your instructions before changing code. Ask for follow-up changes, then explicitly approve any commits or pushes. The session is told not to merge or close the issue.

When you're ready, ask it to run `/retro`. It reviews both the automated run and your follow-up session, suggests improvements without applying them, and writes `retro.md` in the run directory. Nothing runs retro automatically in PR mode.

The handoff opens in a new terminal on a graphical desktop. With `--no-watch` or without a desktop launcher, it uses the current terminal if interactive. Otherwise it prints a saved launcher you can run later:

```bash
bash ~/.local/state/operarius/issue-123.ABCDEF/pr-review.sh
```

The handoff starts a fresh TUI session without `--auto`, using your normal OpenCode agent/model settings; `--model` applies to the automated phases. Its prompt is saved in `pr-review.prompt.txt`. If the handoff cannot open, the PR is already delivered: use the saved launcher rather than rerunning delivery.

### Check your setup

```bash
operare doctor
OPERARIUS_CHECK_COMMAND='cargo test' operare doctor --flow generic
```

Checks dependencies, GitHub repository access, the selected flow's skills/checks configuration, and clean, up-to-date default-branch readiness. It fetches the default branch but does not run AI, project checks, or delivery. Fix the first reported problem and rerun it. This validates configuration, not whether your checks pass, the generic check tools are installed, or your model credentials work.

### Follow a run and recover from failed checks

On a graphical desktop, each automated AI phase opens a new terminal attached to its OpenCode session, so you can watch it work. This requires `xdg-terminal-exec` and OpenCode's shared background service. Windows remain available for inspection; close them when finished. Avoid sending prompts to automated sessions while the workflow is running; use the final PR review session for your instructions. Use `--no-watch` to disable watcher windows (also supported by `operare resume RUN_DIRECTORY --no-watch`); it does not disable the final interactive handoff. Without a graphical desktop or terminal launcher, automated phases continue with logs only.

The original terminal shows phase progress, check output, review results, and the delivery outcome. Full automated AI JSONL output and stderr are saved privately in the run directory rather than streamed to the terminal. Each phase points to its handoff or report; direct-shipping retro suggestions are printed after delivery. Watcher output is saved in each phase's `.watch.log`; final PR terminal-launcher output is saved in `pr-review.launch.log`.

If initial implementation checks fail, fix the code in the same working tree, then run the recovery command printed by the script:

```bash
operare resume ~/.local/state/operarius/issue-123.ABCDEF
```

Run this from the original project, on the original branch, leaving your fixes uncommitted. Resume preserves the original issue specification, flow, check command, delivery mode, model override, and failure log. You do not need to supply `--flow` or `OPERARIUS_CHECK_COMMAND` again; changing the environment variable does not override the saved command. It reruns checks and fresh reviews before committing or delivering; it does not repeat implementation. If checks fail again, you can fix and resume again.

Recovery stops if the project, origin, default branch, working branch, HEAD, or remote baseline has changed, or the issue is closed. Only failed initial implementation checks are resumable—not blocked implementation, review failures, or partial delivery. Inspect those runs manually; don't blindly rerun a push or PR creation. Older runs without a recovery checkpoint cannot be resumed.

## Before you run it

Automated phases use OpenCode's `--auto` mode. Use trusted repositories, issues, and skills. Automated agents are instructed to leave commits and delivery to the script, but this is **not a sandbox**. Configured permission denials still apply. The final human-led PR review session does not use `--auto` and requires your explicit approval for commits or pushes.

The verification command runs with your permissions and may include formatters; only configure trusted commands. Failed runs leave changes in place for you to inspect. There are no automatic resets or force-pushes, and branch protection is not bypassed. A failed PR handoff or direct-shipping retro does not undo delivery.

Logs and retro suggestions are saved under `~/.local/state/operarius/` (or `$XDG_STATE_HOME/operarius/`). Keep these private; they can contain project code and issue details.

## Tests

```bash
bash tests/run.sh
shellcheck bin/operare tests/*.sh
```

Tests use temporary local Git repositories and mock OpenCode, project check tools, and GitHub. They make no paid AI calls or network requests.
