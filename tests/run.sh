#!/usr/bin/env bash
# Integration tests: real temporary Git remotes; no AI, network, or Composer runs.
set -euo pipefail
tests=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$tests/../bin/operare"
suite=$(mktemp -d "${TMPDIR:-/tmp/opencode}/operarius-tests.XXXXXX")
echo "Test evidence: $suite"
mkdir "$suite/bin"
for tool in gh opencode composer pytest cargo ctest; do ln -s "$tests/mock-tool.sh" "$suite/bin/$tool"; done
export PATH="$suite/bin:$PATH"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
unset GH_REPO GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export OPERARIUS_SKILLS_DIR="$suite/skills"
# Retro is intentionally absent: it is optional, not a delivery dependency.
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
    baseline=$(git rev-parse HEAD)
}

run_success() {
    bash "$script" 123 "$@" > "$TEST_DIR/output.log" 2>&1 || fail 'Expected success'
    [[ $(git log -1 --format=%s) == 'Fix issue behavior; close #123' ]] || fail 'Commit suffix'
    [[ -z $(git status --porcelain) ]] || fail 'Expected clean working tree'
    assert_contains "$TEST_DIR/output.log" '\[1/5\] Implementing'
    assert_contains "$TEST_DIR/output.log" 'implementation: Done'
    assert_absent "$TEST_DIR/phases" '^retro$'
    assert_absent "$MOCK_LOG" '^xdg-terminal-exec '
    echo "PASS: $SCENARIO"
}

run_failure() {
    if bash "$script" 123 "$@" > "$TEST_DIR/output.log" 2>&1; then fail 'Expected failure'; fi
    assert_absent "$MOCK_LOG" 'gh issue close'
    assert_absent "$MOCK_LOG" 'gh pr create'
    assert_absent "$TEST_DIR/phases" '^retro$'
    [[ $(git --git-dir="$TEST_REMOTE" rev-parse "refs/heads/$TEST_DEFAULT") == "$baseline" ]] || fail 'Remote changed on failure'
    echo "PASS: $SCENARIO"
}

bash "$script" --help > "$suite/help.log"
assert_contains "$suite/help.log" 'Usage: operare ISSUE \[--generic\] \[--ship\]'

setup ship master
run_success --ship
assert_contains "$MOCK_LOG" 'gh issue close'
assert_absent "$MOCK_LOG" 'gh pr create'
assert_contains "$TEST_DIR/output.log" '\[5/5\] Done'
[[ $(git branch --show-current) == master ]] || fail 'Ship changed branch'

setup pr
run_success
assert_contains "$MOCK_LOG" 'gh pr create'
assert_absent "$MOCK_LOG" 'gh issue close'
[[ $(git branch --show-current) == fix/issue-123 ]] || fail 'Unexpected PR branch'
[[ $(git --git-dir="$TEST_REMOTE" rev-parse refs/heads/main) == "$baseline" ]] || fail 'PR changed default branch'
handoff=$(find "$XDG_STATE_HOME/operarius" -mindepth 1 -maxdepth 1 -type d)
assert_contains "$handoff/pr-review.prompt.txt" 'https://github.com/test/project/pull/42'
assert_contains "$handoff/pr-review.prompt.txt" 'wait for my instructions'
assert_contains "$handoff/pr-review.prompt.txt" 'Do not commit or push without my explicit approval'
assert_contains "$handoff/pr-review.prompt.txt" 'only when I explicitly ask'
assert_contains "$handoff/pr-review.prompt.txt" 'both the automated run and this follow-up session'
assert_contains "$TEST_DIR/output.log" 'No interactive terminal available'
[[ ! -f $handoff/retro.md && ! -f $handoff/resume.json ]] || fail 'Unexpected retro or recovery checkpoint'
# Saved launcher works from another directory and starts a fresh interactive session.
cd "$TEST_DIR"
bash "$handoff/pr-review.sh" || fail 'Saved PR review launcher failed'
assert_contains "$TEST_DIR/handoff-opened" '^pr-review$'

for scenario in fixed formatter review-check-fails new-only security-findings; do
    setup "$scenario"
    run_success --ship
    if [[ $scenario == review-check-fails ]]; then assert_contains "$TEST_DIR/phases" '^review-3$'; fi
    if [[ $scenario == fixed || $scenario == formatter || $scenario == security-findings ]]; then
        assert_contains "$TEST_DIR/phases" '^review-2$'
    fi
done

for scenario in agent-fails implementation-blocked initial-check-fails review-blocked always-fixed false-clean missing-result empty-change agent-commits security-blocked security-unresolved; do
    setup "$scenario"
    run_failure --ship
    if [[ $scenario != agent-commits ]]; then
        [[ $(git rev-parse HEAD) == "$baseline" ]] || fail 'Committed after failure'
    fi
    if [[ $scenario == always-fixed || $scenario == false-clean ]]; then
        [[ $(grep -c '^review-' "$TEST_DIR/phases") == 3 ]] || fail 'Review limit'
    fi
    if [[ $scenario == initial-check-fails ]]; then
        assert_absent "$TEST_DIR/phases" '^review-'
        assert_contains "$TEST_DIR/output.log" 'continuing manually'
        assert_absent "$TEST_DIR/output.log" 'operare resume'
        [[ -f regression.txt ]] || fail 'Lost implementation after check failure'
    fi
    if [[ $scenario == agent-fails ]]; then
        assert_contains "$TEST_DIR/output.log" 'Agent failed. Log:'
        evidence=$(find "$XDG_STATE_HOME/operarius" -mindepth 1 -maxdepth 1 -type d)
        assert_contains "$evidence/implementation.log" 'Provider unavailable'
    fi
done

setup dirty
echo unrelated > unrelated.txt
run_failure --ship
assert_absent "$MOCK_LOG" '^opencode '
[[ -f unrelated.txt ]] || fail 'Discarded existing work'

setup wrong-branch
git switch -qc unrelated
run_failure --ship
assert_absent "$MOCK_LOG" '^opencode '

setup stale
echo local >> app.txt
git commit -qam 'Local only'
run_failure --ship
assert_absent "$MOCK_LOG" '^opencode '

setup closed-issue
export TEST_ISSUE_STATE=CLOSED
run_failure --ship
assert_absent "$MOCK_LOG" '^opencode '

setup missing-skill
export OPERARIUS_SKILLS_DIR="$TEST_DIR/missing-skills"
run_failure
assert_contains "$TEST_DIR/output.log" 'Missing skill:'
assert_absent "$MOCK_LOG" '^opencode '

setup push-rejected
# A bare-repo hook models branch protection without changing real remotes.
printf '#!/bin/sh\nexit 1\n' > "$TEST_REMOTE/hooks/pre-receive"
chmod +x "$TEST_REMOTE/hooks/pre-receive"
run_failure --ship
[[ $(git log -1 --format=%s) == 'Fix issue behavior; close #123' ]] || fail 'Local commit should remain'
assert_contains "$TEST_DIR/output.log" 'Push attempted; inspect the remote'

setup hook-changes-content
mkdir "$TEST_DIR/hooks"
git config core.hooksPath "$TEST_DIR/hooks"
cat > "$TEST_DIR/hooks/pre-commit" <<'EOF'
#!/bin/sh
echo hook-changed >> app.txt
git add app.txt
EOF
chmod +x "$TEST_DIR/hooks/pre-commit"
run_failure --ship
assert_contains "$TEST_DIR/output.log" 'Commit hooks changed reviewed content'

setup removed-options
for option in --flow --mode --model --no-watch --unknown; do
    run_failure "$option"
    assert_contains "$TEST_DIR/output.log" 'Unexpected arguments'
done
for command in doctor resume; do
    if bash "$script" "$command" > "$TEST_DIR/output.log" 2>&1; then fail 'Accepted removed command'; fi
    assert_contains "$TEST_DIR/output.log" 'positive GitHub issue number'
done
assert_absent "$MOCK_LOG" '^opencode '

setup_generic() {
    setup "$1"
    git rm -q composer.json
    git commit -qm 'Non-Laravel project'
    git push -q origin "$TEST_DEFAULT"
    baseline=$(git rev-parse HEAD)
    export OPERARIUS_SKILLS_DIR="$suite/generic-skills"
    for skill in tdd code-review; do
        mkdir -p "$OPERARIUS_SKILLS_DIR/$skill"
        echo 'Test fixture; AI calls are mocked.' > "$OPERARIUS_SKILLS_DIR/$skill/SKILL.md"
    done
}

for language in python rust cpp; do
    setup_generic "generic-$language"
    case "$language" in
        python) export OPERARIUS_CHECK_COMMAND='pytest && pytest' ;;
        rust) export OPERARIUS_CHECK_COMMAND='cargo test' ;;
        cpp) export OPERARIUS_CHECK_COMMAND='ctest --test-dir build' ;;
    esac
    run_success --generic
    assert_contains "$MOCK_LOG" 'gh pr create'
    assert_absent "$MOCK_LOG" '^composer '
done

setup_generic generic-ship
export OPERARIUS_CHECK_COMMAND='cargo test'
run_success --generic --ship
assert_contains "$MOCK_LOG" 'gh issue close'
assert_absent "$MOCK_LOG" 'gh pr create'
assert_absent "$MOCK_LOG" '^composer '

setup_generic generic-missing-checks
run_failure --generic
assert_contains "$TEST_DIR/output.log" 'Set OPERARIUS_CHECK_COMMAND'
assert_absent "$MOCK_LOG" '^opencode '

setup_generic generic-missing-tdd
export OPERARIUS_CHECK_COMMAND='cargo test'
export OPERARIUS_SKILLS_DIR="$TEST_DIR/skills-without-tdd"
mkdir -p "$OPERARIUS_SKILLS_DIR"
run_failure --generic
assert_contains "$TEST_DIR/output.log" 'Missing skill: .*/tdd/SKILL.md'

setup_generic generic-pipeline-fails
export OPERARIUS_CHECK_COMMAND='false | cat'
run_failure --ship --generic
assert_absent "$TEST_DIR/phases" '^review-'
[[ $(git rev-parse HEAD) == "$baseline" ]] || fail 'Committed after generic check failure'

setup laravel-ignores-generic-checks
export OPERARIUS_CHECK_COMMAND=false
run_success --ship
assert_contains "$MOCK_LOG" '^composer analyse'

echo 'All workflow tests passed.'
