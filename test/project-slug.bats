#!/usr/bin/env bats
#
# Tests for adapters/claude-code/hooks/lib/project-slug.sh. Run with: mise exec -- bats test/

bats_require_minimum_version 1.5.0

setup() {
  script="${BATS_TEST_DIRNAME}/../adapters/claude-code/hooks/lib/project-slug.sh"
}

@test "replaces path separators with dashes" {
  run --separate-stderr "${script}" "/home/alice"

  [ "${status}" -eq 0 ]
  [ "${output}" = "-home-alice" ]
}

@test "replaces underscores with dashes too, not just slashes" {
  run --separate-stderr "${script}" "/home/alice/dev/my_project"

  [ "${status}" -eq 0 ]
  [ "${output}" = "-home-alice-dev-my-project" ]
}

@test "preserves case, does not lowercase" {
  run --separate-stderr "${script}" "/home/alice/Work"

  [ "${status}" -eq 0 ]
  [ "${output}" = "-home-alice-Work" ]
}

@test "refuses paths that would produce a slug over 200 characters" {
  long_path="/home/alice/$(printf 'a%.0s' {1..250})"

  run --separate-stderr "${script}" "${long_path}"

  [ "${status}" -ne 0 ]
}
