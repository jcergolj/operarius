# Operarius

*Operarius* is Latin for “worker”. The command, `operare`, means “work!”

A Bash script that takes a GitHub issue through implementation, review, checks, and delivery using OpenCode. Built for Laravel projects.

Each AI phase starts a fresh session. A small handoff carries the essentials between phases instead of dragging the whole conversation along.

## Requirements

- Linux, Bash 4+, Git, `jq`, `sha256sum`, and Composer.
- OpenCode V2, configured with a working model.
- GitHub CLI (`gh`), signed in with access to your repository.
- A Laravel project with an `origin` remote and a `composer analyse` script that runs your checks and tests.
- Your own `laravel-full-stack`, `code-review`, and `retro` skills. These are **not bundled**. Install each as `<skill-name>/SKILL.md` under `~/.opencode/skills`, or set `OPERARIUS_SKILLS_DIR` to their parent directory. Install any skills they depend on too.

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

From your Laravel project, start on its clean, up-to-date default branch:

```bash
operare 123
```

Choose **open a PR** or **ship directly**. Direct shipping commits and pushes to the default branch without another confirmation.

The script:

1. Implements the issue and relevant regression tests.
2. Runs `composer analyse`. If it fails, stops.
3. Reviews uncommitted changes in fresh sessions, applies fixes, and reruns checks. Allows at most three review rounds; delivery requires a clean, unchanged review and passing checks.
4. Commits with `; close #123` at the end of the subject.
5. Pushes and opens a PR, or pushes directly and closes the issue after confirming the commit reached the remote default branch.
6. Runs a fresh retro after successful delivery. It suggests improvements without applying them.

You can also choose explicitly or override the configured model:

```bash
operare 123 --mode pr
operare 123 --mode ship
operare 123 --model provider/model
```

## Before you run it

This uses OpenCode's `--auto` mode. Use trusted repositories, issues, and skills. Agents are instructed to leave commits and delivery to the script, but this is **not a sandbox**. Configured permission denials still apply.

`composer analyse` runs whatever your project defines, including formatters. Failed runs leave changes in place for you to inspect. There are no automatic resets or force-pushes, and branch protection is not bypassed. If retro fails after delivery, the commit or PR is already published.

Logs and retro suggestions are saved under `~/.local/state/operarius/` (or `$XDG_STATE_HOME/operarius/`). Keep these private; they can contain project code and issue details.

## Tests

```bash
bash tests/run.sh
shellcheck bin/operare tests/*.sh
```

Tests use temporary local Git repositories and mock OpenCode, Composer, and GitHub. They make no paid AI calls or network requests.
