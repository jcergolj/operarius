#!/usr/bin/env bash
# Test doubles: never start AI sessions, contact GitHub, or run Composer.
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
                printf '{"number":123,"title":"Fix behavior","body":"Add regression coverage","url":"https://github.com/test/project/issues/123","state":"%s"}\n' "${TEST_ISSUE_STATE:-OPEN}"
                ;;
            *) exit 70 ;;
        esac
        ;;
    composer)
        # Composer is only checked for availability; the interactive agent runs it.
        exit 71
        ;;
    opencode)
        [[ $# == 4 && $1 == --auto && $2 == --prompt ]]
        [[ $4 == "$TEST_DIR/project" && $PWD == "$TEST_DIR/project" ]]
        run_dir=$(find "$XDG_STATE_HOME/operarius" -mindepth 1 -maxdepth 1 -type d)
        [[ $3 == "$(cat "$run_dir/workflow.prompt.txt")" ]]
        # No implementation or delivery should happen before opening the TUI.
        [[ $(git rev-parse HEAD) == "$TEST_BASELINE" ]]
        [[ -z $(git status --porcelain) ]]
        echo workflow > "$TEST_DIR/session-opened"
        [[ $SCENARIO != launch-fails ]] || exit 72
        ;;
    *) exit 73 ;;
esac
