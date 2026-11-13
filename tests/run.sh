#!/usr/bin/env bash
# Launcher integration tests: real local Git repos; no AI or network calls.
set -euo pipefail
tests=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$tests/../bin/operare"
suite=$(mktemp -d "${TMPDIR:-/tmp/opencode}/operarius-tests.XXXXXX")
echo "Test evidence: $suite"
mkdir "$suite/bin"
for tool in gh opencode composer; do ln -s "$tests/mock-tool.sh" "$suite/bin/$tool"; done
export PATH="$suite/bin:$PATH"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
unset GH_REPO GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export OPERARIUS_SKILLS_DIR="$suite/skills"
# Retro is optional, not a delivery dependency.
for skill in laravel-full-stack tdd code-review; do
    mkdir -p "$OPERARIUS_SKILLS_DIR/$skill"
    echo 'Test fixture; AI calls are mocked.' > "$OPERARIUS_SKILLS_DIR/$skill/SKILL.md"
done

fail() { echo "FAIL: $* (evidence: ${TEST_DIR:-$suite})" >&2; exit 1; }
assert_contains() { grep -q -- "$2" "$1" || fail "Missing '$2' in $1"; }
assert_absent() { if [[ -f $1 ]] && grep -q -- "$2" "$1"; then fail "Unexpected '$2' in $1"; fi; }

setup() {
    unset TEST_ISSUE_STATE OPERARIUS_CHECK_COMMAND
    export SCENARIO=$1 TEST_DIR="$suite/$1" TEST_DEFAULT=${2:-main}
    export TEST_REMOTE="$TEST_DIR/remote.git" MOCK_LOG="$TEST_DIR/tools.log"
    export XDG_STATE_HOME="$TEST_DIR/state"
    export OPERARIUS_SKILLS_DIR="$suite/skills"
    mkdir -p "$TEST_DIR"
    git init --bare -q --initial-branch="$TEST_DEFAULT" "$TEST_REMOTE"
    git init -q --initial-branch="$TEST_DEFAULT" "$TEST_DIR/project"
    cd "$TEST_DIR/project"
    git config user.name 'Workflow Test'
    git config user.email 'workflow@example.test'
    git config commit.gpgsign false
    git config core.hooksPath /dev/null
    echo '{"require":{"laravel/framework":"*"},"scripts":{"analyse":"test"}}' > composer.json
    echo original > app.txt
    git add --all
    git commit -qm Initial
    git remote add origin "$TEST_REMOTE"
    git push -q -u origin "$TEST_DEFAULT"
    export TEST_BASELINE
    TEST_BASELINE=$(git rev-parse HEAD)
}

run_success() {
    bash "$script" 123 "$@" > "$TEST_DIR/output.log" 2>&1 || fail 'Expected success'
    assert_contains "$TEST_DIR/session-opened" '^workflow$'
    [[ $(grep -c '^opencode ' "$MOCK_LOG") == 1 ]] || fail 'Expected exactly one session'
    [[ $(grep '^opencode ' "$MOCK_LOG" | head -n 1) == 'opencode --auto --prompt '* ]] \
        || fail 'Expected a fresh interactive auto session before implementation'
    [[ $(git rev-parse HEAD) == "$TEST_BASELINE" ]] || fail 'Launcher committed'
    [[ $(git --git-dir="$TEST_REMOTE" rev-parse "refs/heads/$TEST_DEFAULT") == "$TEST_BASELINE" ]] || fail 'Launcher pushed'
    assert_absent "$MOCK_LOG" '^composer '
    assert_absent "$MOCK_LOG" 'gh pr create'
    assert_absent "$MOCK_LOG" 'gh issue close'
    handoff=$(find "$XDG_STATE_HOME/operarius" -mindepth 1 -maxdepth 1 -type d)
    prompt="$handoff/workflow.prompt.txt"
    assert_contains "$prompt" 'Continue autonomously until delivery succeeds'
    assert_contains "$prompt" 'at most three rounds'
    assert_contains "$prompt" 'separate fresh read-only child sessions'
    assert_contains "$prompt" 'security-auditor subagent alongside them'
    assert_contains "$prompt" 'Wait for all three reports before applying'
    assert_contains "$prompt" 'unchanged fingerprint'
    assert_contains "$prompt" 'If this initial verification fails, stop'
    assert_contains "$prompt" 'its tree equals the recorded reviewed tree'
    assert_contains "$prompt" 'Further changes, commits, and pushes require my explicit approval'
    assert_contains "$prompt" 'retrospective only if I explicitly ask'
    assert_contains "$prompt" 'close #123'
    echo "PASS: $SCENARIO"
}

run_failure() {
    if bash "$script" 123 "$@" > "$TEST_DIR/output.log" 2>&1; then fail 'Expected failure'; fi
    assert_absent "$MOCK_LOG" 'gh issue close'
    assert_absent "$MOCK_LOG" 'gh pr create'
    [[ $(git --git-dir="$TEST_REMOTE" rev-parse "refs/heads/$TEST_DEFAULT") == "$TEST_BASELINE" ]] || fail 'Remote changed'
    echo "PASS: $SCENARIO"
}

bash "$script" --help > "$suite/help.log"
assert_contains "$suite/help.log" 'Usage: operare ISSUE \[--generic\] \[--ship\]'

setup pr
run_success
[[ $(git branch --show-current) == fix/issue-123 ]] || fail 'Unexpected PR branch'
assert_contains "$prompt" 'Open a PR in test/project with base main and head fix/issue-123'
assert_contains "$prompt" 'Do not merge the PR or close the issue'
assert_contains "$prompt" '/laravel-full-stack/SKILL.md'
assert_contains "$handoff/run.md" 'Verification: composer analyse'
# The saved launcher opens the same fresh session from another working directory.
cd "$TEST_DIR"
bash "$handoff/workflow.sh" || fail 'Saved workflow launcher failed'

setup 'paths with spaces'
run_success
cd "$TEST_DIR"
bash "$handoff/workflow.sh" || fail 'Saved launcher failed with spaces in paths'

setup ship master
run_success --ship
[[ $(git branch --show-current) == master ]] || fail 'Ship changed branch'
assert_contains "$prompt" 'Direct delivery is explicitly authorized by --ship'
assert_contains "$prompt" 'Only then close issue #123'
assert_absent "$prompt" 'Open a PR in'

setup generic
git rm -q composer.json
git commit -qm 'Non-Laravel project'
git push -q origin main
TEST_BASELINE=$(git rev-parse HEAD)
export OPERARIUS_CHECK_COMMAND='cargo test && cargo clippy'
run_success --generic
assert_contains "$handoff/run.md" 'Verification: cargo test && cargo clippy'
assert_contains "$prompt" '/tdd/SKILL.md'
assert_absent "$prompt" 'laravel\|composer'

setup generic-ship
export OPERARIUS_CHECK_COMMAND='pytest'
run_success --generic --ship
assert_contains "$prompt" '/tdd/SKILL.md'
assert_contains "$prompt" 'Direct delivery is explicitly authorized by --ship'

setup launch-fails
run_failure
assert_contains "$TEST_DIR/output.log" 'Saved workflow launcher'
[[ -f $TEST_DIR/session-opened ]] || fail 'Did not attempt interactive launch'

setup dirty
echo unrelated > unrelated.txt
run_failure
assert_absent "$MOCK_LOG" '^opencode '
[[ -f unrelated.txt ]] || fail 'Discarded existing work'

setup wrong-branch
git switch -qc unrelated
run_failure
assert_absent "$MOCK_LOG" '^opencode '

setup stale
echo local >> app.txt
git commit -qam 'Local only'
run_failure
assert_absent "$MOCK_LOG" '^opencode '

setup closed-issue
export TEST_ISSUE_STATE=CLOSED
run_failure
assert_absent "$MOCK_LOG" '^opencode '

setup missing-skill
export OPERARIUS_SKILLS_DIR="$TEST_DIR/missing-skills"
run_failure
assert_contains "$TEST_DIR/output.log" 'Missing skill:'
assert_absent "$MOCK_LOG" '^opencode '

setup generic-missing-checks
run_failure --generic
assert_contains "$TEST_DIR/output.log" 'Set OPERARIUS_CHECK_COMMAND'
assert_absent "$MOCK_LOG" '^opencode '

setup invalid-options
for option in --flow --mode --model --no-watch --unknown; do
    run_failure "$option"
    assert_contains "$TEST_DIR/output.log" 'Unexpected arguments'
done
for command in doctor resume; do
    if bash "$script" "$command" > "$TEST_DIR/output.log" 2>&1; then fail 'Accepted invalid issue'; fi
    assert_contains "$TEST_DIR/output.log" 'positive GitHub issue number'
done
assert_absent "$MOCK_LOG" '^opencode '

echo 'All launcher tests passed. Agent workflow execution is not simulated.'
