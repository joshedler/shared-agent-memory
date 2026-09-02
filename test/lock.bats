#!/usr/bin/env bats
#
# Tests for core/lock.sh. Run with: mise exec -- bats test/

bats_require_minimum_version 1.5.0

setup() {
  script="${BATS_TEST_DIRNAME}/../core/lock.sh"
  scratch="$(mktemp -d)"
}

teardown() {
  rm -rf "${scratch}"
}

@test "acquire with no prior lock creates the lock file and reports clean" {
  run --separate-stderr "${script}" acquire "${scratch}" "test-project" "session-abc" --host "host-a"

  [ "${status}" -eq 0 ]
  [ "${output}" = "clean" ]

  lock_file="${scratch}/test-project/.lock"
  [ -f "${lock_file}" ]
  grep -qx "host=host-a" "${lock_file}"
  grep -qx "session_id=session-abc" "${lock_file}"
  grep -q "^acquired_at=[0-9]\+$" "${lock_file}"
}

@test "acquire when a lock already exists from the same host still reports clean" {
  "${script}" acquire "${scratch}" "test-project" "session-1" --host "host-a"

  run --separate-stderr "${script}" acquire "${scratch}" "test-project" "session-2" --host "host-a"

  [ "${status}" -eq 0 ]
  [ "${output}" = "clean" ]

  lock_file="${scratch}/test-project/.lock"
  grep -qx "session_id=session-2" "${lock_file}"
}

@test "acquire when a live lock exists from a different host reports conflict" {
  "${script}" acquire "${scratch}" "test-project" "session-1" --host "host-b"
  lock_file="${scratch}/test-project/.lock"
  prev_acquired_at="$(grep -oP '(?<=^acquired_at=)\d+' "${lock_file}")"

  run --separate-stderr "${script}" acquire "${scratch}" "test-project" "session-2" --host "host-a"

  [ "${status}" -eq 0 ]
  [ "${output}" = "conflict host-b ${prev_acquired_at}" ]

  # acquire still takes over the lock even on conflict -- advisory, not blocking
  grep -qx "host=host-a" "${lock_file}"
  grep -qx "session_id=session-2" "${lock_file}"
}

@test "acquire when a lock exists from a different host but past the TTL reports stale-reclaimed" {
  lock_file="${scratch}/test-project/.lock"
  mkdir -p "${scratch}/test-project"
  old_acquired_at=$(($(date +%s) - 20000)) # older than the default 14400s TTL
  {
    printf 'host=host-b\n'
    printf 'session_id=session-1\n'
    printf 'acquired_at=%s\n' "${old_acquired_at}"
  } >"${lock_file}"

  run --separate-stderr "${script}" acquire "${scratch}" "test-project" "session-2" --host "host-a"

  [ "${status}" -eq 0 ]
  [ "${output}" = "stale-reclaimed host-b ${old_acquired_at}" ]

  grep -qx "host=host-a" "${lock_file}"
  grep -qx "session_id=session-2" "${lock_file}"
}

@test "--ttl overrides the default staleness window" {
  lock_file="${scratch}/test-project/.lock"
  mkdir -p "${scratch}/test-project"
  recent_acquired_at=$(($(date +%s) - 100)) # within the default TTL, past a 50s one
  {
    printf 'host=host-b\n'
    printf 'session_id=session-1\n'
    printf 'acquired_at=%s\n' "${recent_acquired_at}"
  } >"${lock_file}"

  run --separate-stderr "${script}" acquire "${scratch}" "test-project" "session-2" --host "host-a" --ttl 50

  [ "${status}" -eq 0 ]
  [ "${output}" = "stale-reclaimed host-b ${recent_acquired_at}" ]
}

@test "acquire creates nested directories for a project key containing slashes" {
  run --separate-stderr "${script}" acquire "${scratch}" "github.com/example-org/example-repo" "session-abc" --host "host-a"

  [ "${status}" -eq 0 ]
  [ "${output}" = "clean" ]
  [ -f "${scratch}/github.com/example-org/example-repo/.lock" ]
}

@test "release with a matching session_id clears the lock" {
  "${script}" acquire "${scratch}" "test-project" "session-abc" --host "host-a"
  lock_file="${scratch}/test-project/.lock"
  [ -f "${lock_file}" ]

  run --separate-stderr "${script}" release "${scratch}" "test-project" "session-abc"

  [ "${status}" -eq 0 ]
  [ ! -f "${lock_file}" ]
}

@test "release with a non-matching session_id leaves the lock alone" {
  "${script}" acquire "${scratch}" "test-project" "session-abc" --host "host-a"
  lock_file="${scratch}/test-project/.lock"

  run --separate-stderr "${script}" release "${scratch}" "test-project" "session-xyz"

  [ "${status}" -eq 1 ]
  [ -f "${lock_file}" ]
  grep -qx "session_id=session-abc" "${lock_file}"
}

@test "release when no lock file exists at all is a safe no-op" {
  run --separate-stderr "${script}" release "${scratch}" "test-project" "session-abc"

  [ "${status}" -eq 1 ]
}
