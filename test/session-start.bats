#!/usr/bin/env bats
#
# Tests for adapters/claude-code/hooks/session-start.sh. Run with: mise exec -- bats test/

bats_require_minimum_version 1.5.0

setup() {
  script="${BATS_TEST_DIRNAME}/../adapters/claude-code/hooks/session-start.sh"
  scratch="$(mktemp -d)"
  export HOME="${scratch}/home"
  mkdir -p "${HOME}"
  export SHARED_AGENT_MEMORY_ROOT="${scratch}/shared-root"
  project_dir="${scratch}/project"
  mkdir -p "${project_dir}"
  git -C "${project_dir}" init -q
  git -C "${project_dir}" remote add origin git@github.com:example-org/example-repo.git
}

teardown() {
  rm -rf "${scratch}"
}

write_hook_input() {
  local cwd="${1}"
  local session_id="${2}"
  jq -n --arg cwd "${cwd}" --arg session_id "${session_id}" \
    '{session_id: $session_id, cwd: $cwd, hook_event_name: "SessionStart"}' \
    >"${scratch}/hook_input.json"
}

@test "links memory and acquires the lock on a clean resolved project" {
  write_hook_input "${project_dir}" "session-abc"

  run --separate-stderr bash -c "'${script}' < '${scratch}/hook_input.json'"

  [ "${status}" -eq 0 ]
  [ -z "${output}" ]

  slug="$("${BATS_TEST_DIRNAME}/../adapters/claude-code/hooks/lib/project-slug.sh" "${project_dir}")"
  memory_path="${HOME}/.claude/projects/${slug}/memory"
  target="${SHARED_AGENT_MEMORY_ROOT}/github.com/example-org/example-repo"

  [ -L "${memory_path}" ]
  [ "$(readlink -f "${memory_path}")" = "$(readlink -f "${target}")" ]

  lock_file="${target}/.lock"
  [ -f "${lock_file}" ]
  grep -qx "session_id=session-abc" "${lock_file}"

  state_file="${HOME}/.local/state/shared-agent-memory/sessions/session-abc.key"
  [ -f "${state_file}" ]
  [ "$(cat "${state_file}")" = "github.com/example-org/example-repo" ]
}

@test "does nothing for an unresolved project (no remote, no marker file)" {
  unresolved_dir="${scratch}/unresolved-project"
  mkdir -p "${unresolved_dir}"
  write_hook_input "${unresolved_dir}" "session-xyz"

  run --separate-stderr bash -c "'${script}' < '${scratch}/hook_input.json'"

  [ "${status}" -eq 0 ]
  [ -z "${output}" ]

  # no side effects at all
  [ ! -d "${SHARED_AGENT_MEMORY_ROOT}" ]
  [ ! -f "${HOME}/.local/state/shared-agent-memory/sessions/session-xyz.key" ]
}

@test "surfaces a lock conflict as additionalContext" {
  target="${SHARED_AGENT_MEMORY_ROOT}/github.com/example-org/example-repo"
  mkdir -p "${target}"
  {
    printf 'host=other-host\n'
    printf 'session_id=other-session\n'
    printf 'acquired_at=%s\n' "$(date +%s)"
  } >"${target}/.lock"

  write_hook_input "${project_dir}" "session-abc"

  run --separate-stderr bash -c "'${script}' < '${scratch}/hook_input.json'"

  [ "${status}" -eq 0 ]
  [ -n "${output}" ]

  context="$(jq -r '.hookSpecificOutput.additionalContext' <<<"${output}")"
  [[ "${context}" == *"other-host"* ]]

  # the lock is still taken over despite the conflict -- advisory, not blocking
  grep -qx "session_id=session-abc" "${target}/.lock"
}

@test "surfaces a stale-reclaimed lock as additionalContext" {
  target="${SHARED_AGENT_MEMORY_ROOT}/github.com/example-org/example-repo"
  mkdir -p "${target}"
  old_acquired_at=$(($(date +%s) - 20000)) # older than the default 14400s TTL
  {
    printf 'host=old-host\n'
    printf 'session_id=old-session\n'
    printf 'acquired_at=%s\n' "${old_acquired_at}"
  } >"${target}/.lock"

  write_hook_input "${project_dir}" "session-abc"

  run --separate-stderr bash -c "'${script}' < '${scratch}/hook_input.json'"

  [ "${status}" -eq 0 ]
  [ -n "${output}" ]

  context="$(jq -r '.hookSpecificOutput.additionalContext' <<<"${output}")"
  [[ "${context}" == *"old-host"* ]]
}

@test "links memory for the _personal key without acquiring a lock" {
  write_hook_input "${HOME}" "session-personal"

  run --separate-stderr bash -c "'${script}' < '${scratch}/hook_input.json'"

  [ "${status}" -eq 0 ]
  [ -z "${output}" ]

  slug="$("${BATS_TEST_DIRNAME}/../adapters/claude-code/hooks/lib/project-slug.sh" "${HOME}")"
  memory_path="${HOME}/.claude/projects/${slug}/memory"
  target="${SHARED_AGENT_MEMORY_ROOT}/_personal"

  [ -L "${memory_path}" ]
  [ "$(readlink -f "${memory_path}")" = "$(readlink -f "${target}")" ]
  [ ! -f "${target}/.lock" ]

  state_file="${HOME}/.local/state/shared-agent-memory/sessions/session-personal.key"
  [ -f "${state_file}" ]
  [ "$(cat "${state_file}")" = "_personal" ]
}

@test "surfaces a link-memory refusal as additionalContext" {
  slug="$("${BATS_TEST_DIRNAME}/../adapters/claude-code/hooks/lib/project-slug.sh" "${project_dir}")"
  memory_path="${HOME}/.claude/projects/${slug}/memory"
  mkdir -p "${memory_path}"
  echo "real memory" >"${memory_path}/some_fact.md"

  write_hook_input "${project_dir}" "session-abc"

  run --separate-stderr bash -c "'${script}' < '${scratch}/hook_input.json'"

  [ "${status}" -eq 0 ]
  [ -n "${output}" ]

  context="$(jq -r '.hookSpecificOutput.additionalContext' <<<"${output}")"
  [[ "${context}" == *"migrate"* ]]

  # nothing was touched
  [ ! -L "${memory_path}" ]
  [ -f "${memory_path}/some_fact.md" ]
}
