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
                    echo '{"number":123,"title":"Fix behavior","body":"Add regression coverage","url":"https://github.com/test/project/issues/123","state":"OPEN"}'
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
    composer)
        [[ $1 == analyse ]]
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
        [[ $1 == run ]]
        if [[ -n ${TEST_EXPECT_MODEL:-} ]]; then [[ $* == *"--model $TEST_EXPECT_MODEL"* ]]; fi
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
                result=clean
                if [[ $SCENARIO == review-blocked ]]; then result=blocked; fi
                if [[ $SCENARIO == always-fixed || ( $SCENARIO == fixed && $phase == review-1 ) || ( $SCENARIO == review-check-fails && $phase == review-2 ) ]]; then
                    echo "$phase fix" >> app.txt
                    result=fixed
                fi
                # A clean claim cannot bypass the fingerprint gate.
                if [[ $SCENARIO == false-clean ]]; then echo unexpected >> regression.txt; fi
                echo 'Standards: reviewed. Spec: reviewed.' > "$run_dir/$phase.md"
                printf '{"status":"%s"}\n' "$result" > "$run_dir/$phase.result.json"
                ;;
            retro)
                echo 'No substantiated improvements.' > "$run_dir/retro.md"
                if [[ $SCENARIO == retro-fails ]]; then exit 1; fi
                ;;
            *) exit 71 ;;
        esac
        printf '{"type":"text","sessionID":"test-%s","text":"Done"}\n' "$phase"
        ;;
    *) exit 72 ;;
esac
