#!/usr/bin/env bash
# Integration tests: real temporary Git remotes; no AI, network, or Composer runs.
set -euo pipefail
tests=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$tests/../bin/operare"
suite=$(mktemp -d "${TMPDIR:-/tmp}/operarius-tests.XXXXXX")
echo "Test evidence: $suite"
mkdir "$suite/bin"
for tool in gh opencode composer pytest cargo ctest xdg-terminal-exec; do ln -s "$tests/mock-tool.sh" "$suite/bin/$tool"; done
export PATH="$suite/bin:$PATH"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
unset GH_REPO GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export OPERARIUS_SKILLS_DIR="$suite/skills"
for skill in laravel-full-stack tdd code-review retro; do
    mkdir -p "$OPERARIUS_SKILLS_DIR/$skill"
    echo 'Test fixture; AI calls are mocked.' > "$OPERARIUS_SKILLS_DIR/$skill/SKILL.md"
done

fail() { echo "FAIL: $* (evidence: $TEST_DIR)" >&2; exit 1; }
assert_contains() { grep -q -- "$2" "$1" || fail "Missing '$2' in $1"; }
assert_absent() { if [[ -f $1 ]] && grep -q -- "$2" "$1"; then fail "Unexpected '$2' in $1"; fi; }

setup() {
    unset DISPLAY WAYLAND_DISPLAY
    unset TEST_CHECK_FAIL TEST_EXPECT_MODEL TEST_ISSUE_STATE OPERARIUS_CHECK_COMMAND
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
    assert_contains "$TEST_DIR/output.log" '\[1/5\] Implementing'
    assert_contains "$TEST_DIR/output.log" '\[5/5\] Preparing retrospective'
    assert_absent "$TEST_DIR/output.log" '"sessionID"'
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

setup watch
export WAYLAND_DISPLAY=wayland-test
run_success ship
assert_contains "$MOCK_LOG" 'xdg-terminal-exec opencode --session test-implementation '
assert_contains "$MOCK_LOG" 'xdg-terminal-exec opencode --session test-review-1 '
assert_contains "$TEST_DIR/output.log" 'Watching implementation in OpenCode'

setup no-watch
export WAYLAND_DISPLAY=wayland-test
bash "$script" 123 --mode ship --no-watch > "$TEST_DIR/output.log" 2>&1 || fail 'No-watch should succeed'
assert_absent "$MOCK_LOG" '^xdg-terminal-exec '
assert_absent "$TEST_DIR/output.log" 'Watching '
echo 'PASS: --no-watch disables desktop windows'

setup watch-launch-fails
export WAYLAND_DISPLAY=wayland-test
run_success ship
assert_contains "$MOCK_LOG" '^gh issue close'

setup headless
run_success ship
assert_absent "$MOCK_LOG" '^xdg-terminal-exec '
assert_contains "$TEST_DIR/output.log" 'Live watch unavailable'

setup pr
run_success pr
assert_contains "$MOCK_LOG" 'gh pr create'
assert_absent "$MOCK_LOG" 'gh issue close'
[[ $(git branch --show-current) == fix/issue-123 ]] || fail 'PR branch must not have a random suffix'
[[ $(git --git-dir="$TEST_REMOTE" rev-parse refs/heads/main) == "$baseline" ]] || fail 'PR changed default branch'

for scenario in fixed formatter review-check-fails new-only; do
    setup "$scenario"
    run_success ship
    if [[ $scenario == review-check-fails ]]; then assert_contains "$TEST_DIR/phases" '^review-3$'; fi
    if [[ $scenario == fixed || $scenario == formatter ]]; then assert_contains "$TEST_DIR/phases" '^review-2$'; fi
done

for scenario in agent-fails implementation-blocked initial-check-fails review-blocked always-fixed false-clean missing-result empty-change agent-commits; do
    setup "$scenario"
    run_failure ship
    if [[ $scenario != agent-commits ]]; then
        [[ $(git rev-parse HEAD) == "$baseline" ]] || fail 'Committed after failure'
    fi
    if [[ $scenario == always-fixed || $scenario == false-clean ]]; then
        [[ $(grep -c '^review-' "$TEST_DIR/phases") == 3 ]] || fail 'Review limit'
    fi
    if [[ $scenario == initial-check-fails ]]; then assert_absent "$TEST_DIR/phases" '^review-'; fi
    if [[ $scenario == agent-fails ]]; then
        assert_contains "$TEST_DIR/output.log" 'Agent failed. Logs:'
        assert_absent "$TEST_DIR/output.log" 'Provider unavailable'
        evidence=$(find "$XDG_STATE_HOME/operarius" -mindepth 1 -maxdepth 1 -type d)
        assert_contains "$evidence/implementation.jsonl" 'Provider unavailable'
        assert_contains "$evidence/implementation.stderr.log" 'Provider unavailable'
    fi
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
run_failure ship
assert_contains "$TEST_DIR/output.log" 'Commit hooks changed reviewed content'

setup retro-fails
if bash "$script" 123 --mode ship > "$TEST_DIR/output.log" 2>&1; then fail 'Expected retro failure'; fi
assert_contains "$MOCK_LOG" 'gh issue close'
assert_contains "$TEST_DIR/output.log" 'Delivery succeeded, but retro failed'
assert_contains "$TEST_DIR/output.log" 'Stopped during retro. Delivery succeeded.'
assert_absent "$TEST_DIR/output.log" 'Nothing committed or pushed'
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

setup interactive-default
printf '\n' | bash "$script" 123 > "$TEST_DIR/output.log" 2>&1 || fail 'Enter should select PR'
assert_contains "$MOCK_LOG" 'gh pr create'
issue_line=$(grep -n 'test/project #123: Fix behavior' "$TEST_DIR/output.log" | cut -d: -f1)
choice_line=$(grep -n '1) Open a PR' "$TEST_DIR/output.log" | cut -d: -f1)
[[ $issue_line -lt $choice_line ]] || fail 'Issue must appear before delivery choices'
echo 'PASS: default PR and issue preview'

setup doctor
bash "$script" doctor > "$TEST_DIR/output.log" 2>&1 || fail 'Doctor should pass'
assert_contains "$TEST_DIR/output.log" 'Preflight PASS'
assert_absent "$MOCK_LOG" '^opencode '
assert_absent "$MOCK_LOG" '^composer '
assert_absent "$MOCK_LOG" 'gh issue '
[[ $(git rev-parse HEAD) == "$baseline" && -z $(git status --porcelain) ]] || fail 'Doctor changed project'
[[ ! -d $XDG_STATE_HOME/operarius ]] || fail 'Doctor created a workflow run'
echo 'PASS: doctor without AI or workflow side effects'

setup doctor-missing-skill
export OPERARIUS_SKILLS_DIR="$TEST_DIR/missing-skills"
if bash "$script" doctor > "$TEST_DIR/output.log" 2>&1; then fail 'Doctor accepted missing skills'; fi
assert_contains "$TEST_DIR/output.log" 'Missing skill:'
assert_absent "$MOCK_LOG" '^opencode '
export OPERARIUS_SKILLS_DIR="$suite/skills"
echo 'PASS: doctor diagnoses missing skills'

prepare_resume() {
    setup "$1"
    export SCENARIO=initial-check-fails
    if bash "$script" 123 --mode "${2:-ship}" --model test/model > "$TEST_DIR/output.log" 2>&1; then
        fail 'Expected initial check failure'
    fi
    recovery=$(find "$XDG_STATE_HOME/operarius" -mindepth 1 -maxdepth 1 -type d)
    assert_contains "$TEST_DIR/output.log" 'Nothing committed or pushed'
    assert_contains "$TEST_DIR/output.log" 'Check log:'
    assert_contains "$TEST_DIR/output.log" 'operare resume '
    [[ $(cat "$recovery/stage") == implementation-checks ]] || fail 'Missing resumable checkpoint'
}

reject_resume() {
    local checks phases
    checks=$(cat "$TEST_DIR/check-count")
    phases=$(wc -l < "$TEST_DIR/phases")
    if bash "$script" resume "$recovery" > "$TEST_DIR/resume.log" 2>&1; then fail 'Expected resume rejection'; fi
    [[ $(cat "$TEST_DIR/check-count") == "$checks" ]] || fail 'Rejected resume ran checks'
    [[ $(wc -l < "$TEST_DIR/phases") == "$phases" ]] || fail 'Rejected resume called AI'
}

for delivery_mode in ship pr; do
    prepare_resume "resume-$delivery_mode" "$delivery_mode"
    export TEST_EXPECT_MODEL=test/model
    echo 'manual repair' >> app.txt
    bash "$script" resume "$recovery" > "$TEST_DIR/resume.log" 2>&1 || fail 'Expected recovery success'
    [[ $(grep -c '^implementation$' "$TEST_DIR/phases") == 1 ]] || fail 'Resume repeated implementation'
    assert_contains "$TEST_DIR/phases" '^review-1$'
    assert_contains "$TEST_DIR/phases" '^retro$'
    [[ -f $recovery/implementation.check.log ]] || fail 'Original failure log lost'
    [[ $(git log -1 --format=%s) == 'Fix issue behavior; close #123' ]] || fail 'Resume commit subject'
    [[ $(cat "$recovery/stage") == delivered ]] || fail 'Delivery checkpoint missing'
    reject_resume
    echo "PASS: resume $delivery_mode reruns checks/review and preserves model and failure evidence"
done

prepare_resume resume-checks-fail-again
export TEST_CHECK_FAIL=1
if bash "$script" resume "$recovery" > "$TEST_DIR/resume.log" 2>&1; then fail 'Expected repeated check failure'; fi
assert_contains "$TEST_DIR/resume.log" 'operare resume '
assert_absent "$TEST_DIR/phases" '^review-'
[[ $(git rev-parse HEAD) == "$baseline" ]] || fail 'Committed on repeated check failure'
echo 'PASS: failed recovery remains resumable without delivery'

prepare_resume resume-wrong-project
mkdir "$TEST_DIR/other"
git clone -q "$TEST_REMOTE" "$TEST_DIR/other"
cd "$TEST_DIR/other"
reject_resume
assert_contains "$TEST_DIR/resume.log" 'does not match this project'
echo 'PASS: rejects recovery in another project'

prepare_resume resume-wrong-branch
git switch -qc unrelated
reject_resume
assert_contains "$TEST_DIR/resume.log" 'original branch'
echo 'PASS: rejects changed branch'

prepare_resume resume-head-changed
git add --all
git commit -qm 'Manual commit'
reject_resume
assert_contains "$TEST_DIR/resume.log" 'HEAD changed'
echo 'PASS: rejects changed HEAD'

prepare_resume resume-remote-changed
git clone -q "$TEST_REMOTE" "$TEST_DIR/other"
git -C "$TEST_DIR/other" -c user.name=Test -c user.email=test@example.test commit --allow-empty -qm 'Concurrent update'
git -C "$TEST_DIR/other" push -q origin main
reject_resume
assert_contains "$TEST_DIR/resume.log" 'Remote default branch changed'
echo 'PASS: rejects changed remote baseline'

prepare_resume resume-wrong-origin
git init --bare -q --initial-branch=main "$TEST_DIR/other.git"
git remote set-url origin "$TEST_DIR/other.git"
git push -q origin main
reject_resume
assert_contains "$TEST_DIR/resume.log" 'does not match this project'
echo 'PASS: rejects changed origin'

prepare_resume resume-closed-issue
export TEST_ISSUE_STATE=CLOSED
reject_resume
assert_contains "$TEST_DIR/resume.log" 'Issue is no longer open'
echo 'PASS: rejects closed issue'

setup_generic() {
    setup "$1"
    git rm -q composer.json
    git commit -qm 'Non-Laravel project'
    git push -q origin "$TEST_DEFAULT"
    baseline=$(git rev-parse HEAD)
    export OPERARIUS_SKILLS_DIR="$suite/generic-skills"
    for skill in tdd code-review retro; do
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
    bash "$script" doctor --flow generic > "$TEST_DIR/doctor.log" 2>&1 || fail 'Generic doctor should pass'
    assert_contains "$TEST_DIR/doctor.log" 'Flow: generic'
    assert_absent "$MOCK_LOG" '^opencode '
    assert_absent "$MOCK_LOG" '^composer '
    bash "$script" 123 --flow generic --mode pr > "$TEST_DIR/output.log" 2>&1 || fail 'Generic PR should succeed'
    assert_contains "$MOCK_LOG" 'gh pr create'
    assert_contains "$TEST_DIR/phases" '^retro$'
    assert_absent "$MOCK_LOG" '^composer '
    [[ -z $(git status --porcelain) ]] || fail 'Generic delivery left changes'
    echo "PASS: generic $language checks, skills, reviews and PR delivery"
done

setup_generic generic-missing-checks
if bash "$script" doctor --flow generic > "$TEST_DIR/output.log" 2>&1; then fail 'Accepted missing checks'; fi
assert_contains "$TEST_DIR/output.log" 'Set OPERARIUS_CHECK_COMMAND'
assert_absent "$MOCK_LOG" '^opencode '
echo 'PASS: generic flow requires explicit checks'

setup_generic generic-invalid-flow
if bash "$script" 123 --flow other > "$TEST_DIR/output.log" 2>&1; then fail 'Accepted invalid flow'; fi
assert_contains "$TEST_DIR/output.log" '--flow must be laravel or generic'
echo 'PASS: rejects unknown flow'

setup_generic generic-missing-tdd
export OPERARIUS_CHECK_COMMAND='cargo test'
export OPERARIUS_SKILLS_DIR="$TEST_DIR/skills-without-tdd"
mkdir -p "$OPERARIUS_SKILLS_DIR"
if bash "$script" doctor --flow generic > "$TEST_DIR/output.log" 2>&1; then fail 'Accepted missing tdd skill'; fi
assert_contains "$TEST_DIR/output.log" 'Missing skill: .*/tdd/SKILL.md'
echo 'PASS: generic flow requires tdd'

setup_generic generic-resume
export OPERARIUS_CHECK_COMMAND='cargo test'
export SCENARIO=initial-check-fails
if bash "$script" 123 --flow generic --mode ship > "$TEST_DIR/output.log" 2>&1; then fail 'Expected generic check failure'; fi
recovery=$(find "$XDG_STATE_HOME/operarius" -mindepth 1 -maxdepth 1 -type d)
assert_contains "$TEST_DIR/output.log" 'operare resume '
assert_absent "$TEST_DIR/phases" '^review-'
if bash "$script" resume "$recovery" --flow laravel > "$TEST_DIR/wrong-flow.log" 2>&1; then fail 'Accepted changed flow'; fi
assert_contains "$TEST_DIR/wrong-flow.log" 'Resume must use the original flow'
export OPERARIUS_CHECK_COMMAND='false'
echo 'manual repair' >> app.txt
bash "$script" resume "$recovery" > "$TEST_DIR/resume.log" 2>&1 || fail 'Generic recovery should use saved command and flow'
[[ $(grep -c '^implementation$' "$TEST_DIR/phases") == 1 ]] || fail 'Generic resume repeated implementation'
assert_contains "$MOCK_LOG" '^cargo test'
assert_absent "$MOCK_LOG" '^composer '
assert_contains "$MOCK_LOG" 'gh issue close'
echo 'PASS: generic recovery preserves flow and check command'

setup_generic generic-pipeline-fails
export OPERARIUS_CHECK_COMMAND='false | cat'
if bash "$script" 123 --flow generic --mode ship > "$TEST_DIR/output.log" 2>&1; then fail 'Ignored pipeline failure'; fi
assert_absent "$TEST_DIR/phases" '^review-'
assert_absent "$MOCK_LOG" 'gh issue close'
[[ $(git rev-parse HEAD) == "$baseline" ]] || fail 'Committed after generic check failure'
echo 'PASS: generic check pipeline failure prevents delivery'

setup explicit-laravel
export OPERARIUS_SKILLS_DIR="$suite/skills" OPERARIUS_CHECK_COMMAND=false
bash "$script" 123 --flow laravel --mode ship > "$TEST_DIR/output.log" 2>&1 || fail 'Explicit Laravel flow should ignore generic checks'
assert_contains "$MOCK_LOG" '^composer analyse'
assert_contains "$MOCK_LOG" 'gh issue close'
echo 'PASS: explicit Laravel flow preserves Composer verification'

echo 'All workflow tests passed.'
