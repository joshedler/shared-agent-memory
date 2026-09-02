#!/usr/bin/env bats
#
# Tests for core/link-memory.sh. Run with: mise exec -- bats test/

bats_require_minimum_version 1.5.0

setup() {
  script="${BATS_TEST_DIRNAME}/../core/link-memory.sh"
  scratch="$(mktemp -d)"
  memory_path="${scratch}/claude-projects/some-slug/memory"
  shared_root="${scratch}/shared-root"
}

teardown() {
  rm -rf "${scratch}"
}

@test "creates the target dir and symlink when nothing exists yet" {
  run --separate-stderr "${script}" "${memory_path}" "${shared_root}" "test-project"

  [ "${status}" -eq 0 ]
  [ "${output}" = "created" ]
  [ -L "${memory_path}" ]
  [ "$(readlink -f "${memory_path}")" = "$(readlink -f "${shared_root}/test-project")" ]
}

@test "relinks when the symlink points at a target that no longer exists" {
  mkdir -p "$(dirname "${memory_path}")"
  ln -s "${scratch}/nowhere" "${memory_path}"

  run --separate-stderr "${script}" "${memory_path}" "${shared_root}" "test-project"

  [ "${status}" -eq 0 ]
  [ "${output}" = "relinked" ]
  [ "$(readlink -f "${memory_path}")" = "$(readlink -f "${shared_root}/test-project")" ]
}

@test "relinks when the symlink points at an empty directory" {
  mkdir -p "$(dirname "${memory_path}")"
  mkdir -p "${scratch}/old-empty-target"
  ln -s "${scratch}/old-empty-target" "${memory_path}"

  run --separate-stderr "${script}" "${memory_path}" "${shared_root}" "test-project"

  [ "${status}" -eq 0 ]
  [ "${output}" = "relinked" ]
  [ "$(readlink -f "${memory_path}")" = "$(readlink -f "${shared_root}/test-project")" ]
}

@test "refuses to relink when the old target still has real content" {
  mkdir -p "$(dirname "${memory_path}")"
  mkdir -p "${scratch}/old-target-with-content"
  echo "real memory" >"${scratch}/old-target-with-content/some_fact.md"
  ln -s "${scratch}/old-target-with-content" "${memory_path}"

  run --separate-stderr "${script}" "${memory_path}" "${shared_root}" "test-project"

  [ "${status}" -ne 0 ]
  [[ "${stderr}" == *"${scratch}/old-target-with-content"* ]]
  [[ "${stderr}" == *"migrate"* ]]
  # nothing was touched
  [ "$(readlink -f "${memory_path}")" = "$(readlink -f "${scratch}/old-target-with-content")" ]
}

@test "refuses to touch a real directory already at memory_path" {
  mkdir -p "${memory_path}"
  echo "real memory" >"${memory_path}/some_fact.md"

  run --separate-stderr "${script}" "${memory_path}" "${shared_root}" "test-project"

  [ "${status}" -ne 0 ]
  [[ "${stderr}" == *"migrate"* ]]
  # nothing was touched
  [ ! -L "${memory_path}" ]
  [ -f "${memory_path}/some_fact.md" ]
}

@test "no-ops when already the correct symlink" {
  "${script}" "${memory_path}" "${shared_root}" "test-project"

  run --separate-stderr "${script}" "${memory_path}" "${shared_root}" "test-project"

  [ "${status}" -eq 0 ]
  [ "${output}" = "already-linked" ]
  [ "$(readlink -f "${memory_path}")" = "$(readlink -f "${shared_root}/test-project")" ]
}
