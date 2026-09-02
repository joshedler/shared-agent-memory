#!/usr/bin/env bats
#
# Tests for core/resolve-key.sh. Run with: mise exec -- bats test/

bats_require_minimum_version 1.5.0

setup() {
  script="${BATS_TEST_DIRNAME}/../core/resolve-key.sh"
  scratch="$(mktemp -d)"
}

teardown() {
  rm -rf "${scratch}"
}

@test "resolves via ssh-form git remote" {
  git -C "${scratch}" init -q
  git -C "${scratch}" remote add origin git@github.com:example-org/example-repo.git

  run --separate-stderr "${script}" "${scratch}"

  [ "${status}" -eq 0 ]
  [ "${output}" = "github.com/example-org/example-repo" ]
}

@test "resolves via https-form git remote to the same key as ssh" {
  git -C "${scratch}" init -q
  git -C "${scratch}" remote add origin https://github.com/example-org/example-repo.git

  run --separate-stderr "${script}" "${scratch}"

  [ "${status}" -eq 0 ]
  [ "${output}" = "github.com/example-org/example-repo" ]
}

@test "falls back to marker file when there's no git remote" {
  echo "my-manual-key" >"${scratch}/.claude-project-id"

  run --separate-stderr "${script}" "${scratch}"

  [ "${status}" -eq 0 ]
  [ "${output}" = "my-manual-key" ]
}

@test "marker file resolution walks up to the git root, not just the cwd" {
  git -C "${scratch}" init -q
  echo "root-key" >"${scratch}/.claude-project-id"
  mkdir -p "${scratch}/nested/subdir"

  run --separate-stderr "${script}" "${scratch}/nested/subdir"

  [ "${status}" -eq 0 ]
  [ "${output}" = "root-key" ]
}

@test "an empty marker file is ignored, not treated as a valid key" {
  touch "${scratch}/.claude-project-id"

  run --separate-stderr "${script}" "${scratch}"

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}

@test "no remote and no marker file fails with no stdout" {
  run --separate-stderr "${script}" "${scratch}"

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}

@test "a git repo with no remote and no marker still fails" {
  git -C "${scratch}" init -q

  run --separate-stderr "${script}" "${scratch}"

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}

@test "resolves the exact HOME directory to the reserved _personal key" {
  export HOME="${scratch}/home-dir"
  mkdir -p "${HOME}"

  run --separate-stderr "${script}" "${HOME}"

  [ "${status}" -eq 0 ]
  [ "${output}" = "_personal" ]
}

@test "a git remote inside HOME still takes priority over _personal" {
  export HOME="${scratch}/home-dir"
  mkdir -p "${HOME}"
  git -C "${HOME}" init -q
  git -C "${HOME}" remote add origin git@github.com:example-org/example-repo.git

  run --separate-stderr "${script}" "${HOME}"

  [ "${status}" -eq 0 ]
  [ "${output}" = "github.com/example-org/example-repo" ]
}

@test "a marker file inside HOME still takes priority over _personal" {
  export HOME="${scratch}/home-dir"
  mkdir -p "${HOME}"
  echo "my-manual-key" >"${HOME}/.claude-project-id"

  run --separate-stderr "${script}" "${HOME}"

  [ "${status}" -eq 0 ]
  [ "${output}" = "my-manual-key" ]
}

@test "a non-HOME directory with no remote and no marker still fails, not _personal" {
  export HOME="${scratch}/home-dir"
  mkdir -p "${HOME}"
  other_dir="${scratch}/not-home"
  mkdir -p "${other_dir}"

  run --separate-stderr "${script}" "${other_dir}"

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}

@test "defaults to the current directory when none is given" {
  git -C "${scratch}" init -q
  git -C "${scratch}" remote add origin git@github.com:example-org/example-repo.git

  cd "${scratch}"
  run --separate-stderr "${script}"

  [ "${status}" -eq 0 ]
  [ "${output}" = "github.com/example-org/example-repo" ]
}

@test "errors clearly when the given path isn't a directory" {
  run --separate-stderr "${script}" "${scratch}/does-not-exist"

  [ "${status}" -eq 1 ]
}
