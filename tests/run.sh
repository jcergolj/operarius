#!/usr/bin/env bash
# Integration tests: real temporary Git remotes; no AI, network, or Composer runs.
set -euo pipefail
tests=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$tests/../bin/operare"
suite=$(mktemp -d "${TMPDIR:-/tmp}/operarius-tests.XXXXXX")
echo "Test evidence: $suite"
mkdir "$suite/bin"
for tool in gh opencode composer; do ln -s "$tests/mock-tool.sh" "$suite/bin/$tool"; done
export PATH="$suite/bin:$PATH"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
unset GH_REPO GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export OPERARIUS_SKILLS_DIR="$suite/skills"
for skill in laravel-full-stack code-review retro; do
    mkdir -p "$OPERARIUS_SKILLS_DIR/$skill"
    echo 'Test fixture; AI calls are mocked.' > "$OPERARIUS_SKILLS_DIR/$skill/SKILL.md"
done

fail() { echo "FAIL: $* (evidence: $TEST_DIR)" >&2; exit 1; }
assert_contains() { grep -q -- "$2" "$1" || fail "Missing '$2' in $1"; }
assert_absent() { if [[ -f $1 ]] && grep -q -- "$2" "$1"; then fail "Unexpected '$2' in $1"; fi; }

setup() {
    export SCENARIO=$1 TEST_DIR="$suite/$1" TEST_DEFAULT=${2:-main}
    export TEST_REMOTE="$TEST_DIR/remote.git" MOCK_LOG="$TEST_DIR/tools.log"
    export XDG_STATE_HOME="$TEST_DIR/state"
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
    bash "$script" 123 --mode "$1" > "$TEST_DIR/output.log" 2>&1 || fail 'Expected success'
    [[ $(git log -1 --format=%s) == 'Fix issue behavior; close #123' ]] || fail 'Commit suffix'
    [[ -z $(git status --porcelain) ]] || fail 'Expected clean working tree'
    assert_contains "$TEST_DIR/phases" '^retro$'
    echo "PASS: $SCENARIO"
}

run_failure() {
    if bash "$script" 123 --mode "$1" > "$TEST_DIR/output.log" 2>&1; then fail 'Expected failure'; fi
    assert_absent "$MOCK_LOG" 'gh issue close'
    assert_absent "$MOCK_LOG" 'gh pr create'
    assert_absent "$TEST_DIR/phases" '^retro$'
    [[ $(git --git-dir="$TEST_REMOTE" rev-parse "refs/heads/$TEST_DEFAULT") == "$baseline" ]] || fail 'Remote changed on failure'
    echo "PASS: $SCENARIO"
}

setup ship master
run_success ship
assert_contains "$MOCK_LOG" 'gh issue close'
assert_absent "$MOCK_LOG" 'gh pr create'

setup pr
run_success pr
assert_contains "$MOCK_LOG" 'gh pr create'
assert_absent "$MOCK_LOG" 'gh issue close'
[[ $(git branch --show-current) == fix/issue-123-* ]] || fail 'PR branch not created'
[[ $(git --git-dir="$TEST_REMOTE" rev-parse refs/heads/main) == "$baseline" ]] || fail 'PR changed default branch'

for scenario in fixed formatter review-check-fails new-only; do
    setup "$scenario"
    run_success ship
    if [[ $scenario == review-check-fails ]]; then assert_contains "$TEST_DIR/phases" '^review-3$'; fi
    if [[ $scenario == fixed || $scenario == formatter ]]; then assert_contains "$TEST_DIR/phases" '^review-2$'; fi
done

for scenario in implementation-blocked initial-check-fails review-blocked always-fixed false-clean missing-result empty-change agent-commits; do
    setup "$scenario"
    run_failure ship
    if [[ $scenario != agent-commits ]]; then
        [[ $(git rev-parse HEAD) == "$baseline" ]] || fail 'Committed after failure'
    fi
    if [[ $scenario == always-fixed || $scenario == false-clean ]]; then
        [[ $(grep -c '^review-' "$TEST_DIR/phases") == 3 ]] || fail 'Review limit'
    fi
    if [[ $scenario == initial-check-fails ]]; then assert_absent "$TEST_DIR/phases" '^review-'; fi
done

setup dirty
echo unrelated > unrelated.txt
run_failure ship
assert_absent "$MOCK_LOG" '^opencode '
[[ -f unrelated.txt ]] || fail 'Discarded existing work'

setup wrong-branch
git switch -qc unrelated
run_failure ship
assert_absent "$MOCK_LOG" '^opencode '

setup stale
echo local >> app.txt
git commit -qam 'Local only'
run_failure ship
assert_absent "$MOCK_LOG" '^opencode '

setup push-rejected
# A bare-repo hook models branch protection without changing real remotes.
printf '#!/bin/sh\nexit 1\n' > "$TEST_REMOTE/hooks/pre-receive"
chmod +x "$TEST_REMOTE/hooks/pre-receive"
run_failure ship
[[ $(git log -1 --format=%s) == 'Fix issue behavior; close #123' ]] || fail 'Local commit should remain'

setup hook-changes-content
mkdir "$TEST_DIR/hooks"
git config core.hooksPath "$TEST_DIR/hooks"
cat > "$TEST_DIR/hooks/pre-commit" <<'EOF'
#!/bin/sh
echo hook-changed >> app.txt
git add app.txt
EOF
chmod +x "$TEST_DIR/hooks/pre-commit"
run_failure ship
assert_contains "$TEST_DIR/output.log" 'Commit hooks changed reviewed content'

setup retro-fails
if bash "$script" 123 --mode ship > "$TEST_DIR/output.log" 2>&1; then fail 'Expected retro failure'; fi
assert_contains "$MOCK_LOG" 'gh issue close'
assert_contains "$TEST_DIR/output.log" 'Delivery succeeded, but retro failed'
[[ $(git --git-dir="$TEST_REMOTE" rev-parse refs/heads/main) == "$(git rev-parse HEAD)" ]] || fail 'Delivery lost'
echo 'PASS: retro failure preserves successful delivery'

setup interactive-pr
printf '1\n' | bash "$script" 123 > "$TEST_DIR/output.log" 2>&1 || fail 'Interactive PR selection'
assert_contains "$MOCK_LOG" 'gh pr create'
assert_absent "$MOCK_LOG" 'gh issue close'
echo 'PASS: interactive PR selection'

setup interactive-ship
printf '2\n' | bash "$script" 123 > "$TEST_DIR/output.log" 2>&1 || fail 'Interactive ship selection'
assert_contains "$MOCK_LOG" 'gh issue close'
assert_absent "$MOCK_LOG" 'gh pr create'
echo 'PASS: interactive ship selection'

echo 'All workflow tests passed.'
