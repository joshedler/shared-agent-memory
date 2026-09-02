#!/usr/bin/env bats
#
# Tests for adapters/claude-code/hooks/stop.sh. Run with: mise exec -- bats test/

bats_require_minimum_version 1.5.0

setup() {
  script="${BATS_TEST_DIRNAME}/../adapters/claude-code/hooks/stop.sh"
  scratch="$(mktemp -d)"
  export HOME="${scratch}/home"
  mkdir -p "${HOME}"
  export SHARED_AGENT_MEMORY_ROOT="${scratch}/shared-root"
  sessions_dir="${HOME}/.local/state/shared-agent-memory/sessions"
}

teardown() {
  rm -rf "${scratch}"
}

write_hook_input() {
  local session_id="${1}"
  jq -n --arg session_id "${session_id}" '{session_id: $session_id, hook_event_name: "Stop"}' \
    >"${scratch}/hook_input.json"
}

@test "releases the lock and removes the state file when a session resolved a project" {
  mkdir -p "${sessions_dir}"
  echo "test-project" >"${sessions_dir}/session-abc.key"

  lock_dir="${SHARED_AGENT_MEMORY_ROOT}/test-project"
  mkdir -p "${lock_dir}"
  {
    printf 'host=this-host\n'
    printf 'session_id=session-abc\n'
    printf 'acquired_at=%s\n' "$(date +%s)"
  } >"${lock_dir}/.lock"

  write_hook_input "session-abc"

  run --separate-stderr bash -c "'${script}' < '${scratch}/hook_input.json'"

  [ "${status}" -eq 0 ]
  [ ! -f "${lock_dir}/.lock" ]
  [ ! -f "${sessions_dir}/session-abc.key" ]
}

@test "is a safe no-op when the session has no state file" {
  write_hook_input "session-never-resolved"

  run --separate-stderr bash -c "'${script}' < '${scratch}/hook_input.json'"

  [ "${status}" -eq 0 ]
}
