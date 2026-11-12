#!/usr/bin/env bash
# Test doubles for paid AI calls, Composer and GitHub. Git itself remains real.
set -euo pipefail
tool=$(basename "$0")
echo "$tool $*" >> "$MOCK_LOG"
case "$tool" in
    gh)
        case "$1 $2" in
            'repo view')
                printf '{"nameWithOwner":"test/project","defaultBranchRef":{"name":"%s"}}\n' "$TEST_DEFAULT"
                ;;
            'issue view')
                if [[ $* == *'--jq'* ]]; then
                    echo "${TEST_ISSUE_STATE:-OPEN}"
                else
                    printf '{"number":123,"title":"Fix behavior","body":"Add regression coverage","url":"https://github.com/test/project/issues/123","state":"%s"}\n' "${TEST_ISSUE_STATE:-OPEN}"
                fi
                ;;
            'issue close')
                # Closing is authorized only after the commit exists remotely.
                git merge-base --is-ancestor HEAD "$(git --git-dir="$TEST_REMOTE" rev-parse "refs/heads/$TEST_DEFAULT")"
                ;;
            'pr create')
                [[ $* == *"--base $TEST_DEFAULT"* ]]
                [[ $(git --git-dir="$TEST_REMOTE" rev-parse "refs/heads/$(git branch --show-current)") == "$(git rev-parse HEAD)" ]]
                body_file=${*: -1}
                grep -q '^Closes #123$' "$body_file"
                echo 'https://github.com/test/project/pull/42'
                ;;
            *) exit 70 ;;
        esac
        ;;
    composer|pytest|cargo|ctest)
        case "$tool" in
            composer) [[ $1 == analyse ]] ;;
            cargo) [[ $1 == test ]] ;;
        esac
        [[ $PWD == "$TEST_DIR/project" ]]
        count_file="$TEST_DIR/check-count"
        count=$(cat "$count_file" 2>/dev/null || echo 0)
        count=$((count + 1))
        echo "$count" > "$count_file"
        if [[ ${TEST_CHECK_FAIL:-0} == 1 ]]; then exit 1; fi
        if [[ $SCENARIO == initial-check-fails && $count == 1 ]]; then exit 1; fi
        if [[ $SCENARIO == review-check-fails && $count == 2 ]]; then exit 1; fi
        if [[ $SCENARIO == formatter && $count == 2 ]]; then echo formatted >> app.txt; fi
        echo 'Checks passed'
        ;;
    opencode)
        if [[ $1 == --prompt ]]; then
            [[ $3 == "$TEST_DIR/project" && $PWD == "$TEST_DIR/project" ]]
            [[ $2 == *'human-led PR review'* && $2 == *'Do not commit or push without my explicit approval'* ]]
            echo pr-review > "$TEST_DIR/handoff-opened"
            exit 0
        fi
        [[ $1 == run ]]
        [[ $* != *'--model'* && $* != *'--format'* ]]
        [[ $* != *'--continue'* && $* != *'--session'* && $* != *'--fork'* ]]
        phase=''
        while [[ $# -gt 0 ]]; do
            if [[ $1 == --title ]]; then phase=${2##*: }; break; fi
            shift
        done
        run_dir=$(find "$XDG_STATE_HOME/operarius" -mindepth 1 -maxdepth 1 -type d)
        echo "$phase" >> "$TEST_DIR/phases"
        if [[ $SCENARIO == agent-fails ]]; then
            echo '{"type":"error","message":"Provider unavailable"}'
            echo 'Provider unavailable' >&2
            exit 1
        fi
        case "$phase" in
            implementation)
                if grep -q '^Flow: generic$' "$run_dir/run.md"; then
                    grep -q '/tdd/SKILL.md' "$run_dir/implementation.prompt.txt"
                    if grep -q 'laravel\|composer' "$run_dir/implementation.prompt.txt"; then exit 73; fi
                else
                    grep -q '/laravel-full-stack/SKILL.md' "$run_dir/implementation.prompt.txt"
                fi
                if [[ $SCENARIO == implementation-blocked ]]; then
                    echo '{"status":"blocked"}' > "$run_dir/implementation.result.json"
                    exit 0
                fi
                if [[ $SCENARIO != empty-change ]]; then
                    if [[ $SCENARIO != new-only ]]; then echo implemented >> app.txt; fi
                    echo regression > regression.txt
                fi
                echo 'Implemented issue and regression test.' > "$run_dir/implementation.md"
                echo 'Fix issue behavior' > "$run_dir/subject.txt"
                echo 'Fix the reported behavior and add regression coverage.' > "$run_dir/pr-body.md"
                if [[ $SCENARIO != missing-result ]]; then
                    echo '{"status":"ready"}' > "$run_dir/implementation.result.json"
                fi
                if [[ $SCENARIO == agent-commits ]]; then git add --all; git commit -qm 'Unauthorized commit'; fi
                ;;
            review-*)
                if grep -q '^Flow: generic$' "$run_dir/run.md"; then
                    if grep -q 'laravel\|composer' "$run_dir/$phase.prompt.txt"; then exit 73; fi
                fi
                grep -q 'delegating Standards and Spec reviews to separate subagents' "$run_dir/$phase.prompt.txt"
                grep -q 'Run the security-auditor subagent alongside those review subagents' "$run_dir/$phase.prompt.txt"
                grep -q 'own fresh child session and remain read-only' "$run_dir/$phase.prompt.txt"
                grep -q 'only after all three reports return' "$run_dir/$phase.prompt.txt"
                grep -q 'blocked (unresolved findings or any required review unavailable)' "$run_dir/$phase.prompt.txt"
                result=clean
                if [[ $SCENARIO == review-blocked || $SCENARIO == security-blocked || $SCENARIO == security-unresolved ]]; then result=blocked; fi
                if [[ $SCENARIO == always-fixed || ( $SCENARIO == fixed && $phase == review-1 ) || ( $SCENARIO == security-findings && $phase == review-1 ) || ( $SCENARIO == review-check-fails && $phase == review-2 ) ]]; then
                    echo "$phase fix" >> app.txt
                    result=fixed
                fi
                # A clean claim cannot bypass the fingerprint gate.
                if [[ $SCENARIO == false-clean ]]; then echo unexpected >> regression.txt; fi
                echo 'Standards: reviewed. Spec: reviewed. Security: reviewed.' > "$run_dir/$phase.md"
                printf '{"status":"%s"}\n' "$result" > "$run_dir/$phase.result.json"
                ;;
            *) exit 71 ;;
        esac
        printf '%s: Done\n' "$phase"
        ;;
    *) exit 72 ;;
esac
