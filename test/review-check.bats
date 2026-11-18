#!/usr/bin/env bats
#
# Tests for core/review-check.sh. Run with: mise exec -- bats test/

bats_require_minimum_version 1.5.0

setup() {
  script="${BATS_TEST_DIRNAME}/../core/review-check.sh"
  scratch="$(mktemp -d)"
  root="${scratch}/shared-root"

  # A small, healthy shared root: one project bucket, _personal, _rules,
  # an _archive and Syncthing's marker folder.
  mkdir -p "${root}/.stfolder" "${root}/_rules" "${root}/_archive/rules" "${root}/_personal" \
    "${root}/github.com/example-org/example-repo"
  printf -- '- [A fact](a_fact.md) — hook\n' >"${root}/github.com/example-org/example-repo/MEMORY.md"
  printf -- '---\nname: a-fact\n---\nbody\n' >"${root}/github.com/example-org/example-repo/a_fact.md"
  printf -- '- [Pref](pref.md) — hook\n' >"${root}/_personal/MEMORY.md"
  printf -- '---\nname: pref\n---\nbody\n' >"${root}/_personal/pref.md"
  printf -- '# A rule\n' >"${root}/_rules/a_rule.md"
  printf -- '# Old rule\n' >"${root}/_archive/rules/old_rule.md"
}

teardown() {
  rm -rf "${scratch}"
}

# Prints the findings array's entries for one check, one compact JSON per line.
findings_for() {
  jq -c --arg check "${1}" '.findings[] | select(.check == $check)' <<<"${output}"
}

@test "a healthy root prints valid JSON with no findings" {
  run --separate-stderr "${script}" -r "${root}"

  [ "${status}" -eq 0 ]
  [ "$(jq -r '.root' <<<"${output}")" = "${root}" ]
  [[ "$(jq -r '.generated_at' <<<"${output}")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
  [ "$(jq '.findings | length' <<<"${output}")" -eq 0 ]
}

@test "fails when the root doesn't exist" {
  run --separate-stderr "${script}" -r "${scratch}/nowhere"

  [ "${status}" -ne 0 ]
  [ -z "${output}" ]
}

@test "falls back to SHARED_AGENT_MEMORY_ROOT when -r isn't given" {
  SHARED_AGENT_MEMORY_ROOT="${root}" run --separate-stderr "${script}"

  [ "${status}" -eq 0 ]
  [ "$(jq -r '.root' <<<"${output}")" = "${root}" ]
}

@test "a bucket holding only a .lock is reported as an empty bucket" {
  mkdir -p "${root}/github.com/example-org/lock-only"
  echo "some-session" >"${root}/github.com/example-org/lock-only/.lock"

  run --separate-stderr "${script}" -r "${root}"

  [ "${status}" -eq 0 ]
  found="$(findings_for empty-bucket)"
  [ "$(wc -l <<<"${found}")" -eq 1 ]
  [ "$(jq -r '.bucket' <<<"${found}")" = "github.com/example-org/lock-only" ]
  [ "$(jq -r '.severity' <<<"${found}")" = "warn" ]
  [ "$(jq -r '.id' <<<"${found}")" = "empty-bucket:github.com/example-org/lock-only" ]
}

@test "an empty directory with no bucket under it is reported once, at its top" {
  mkdir -p "${root}/stray-top/deeper/deepest"
  mkdir -p "${root}/_unresolved/null"

  run --separate-stderr "${script}" -r "${root}"

  [ "${status}" -eq 0 ]
  # _unresolved itself is reserved, so its empty child is reported instead.
  strays="$(findings_for stray-dir | jq -r '.file' | LC_ALL=C sort)"
  [ "${strays}" = "$(printf '%s\n' _unresolved/null stray-top)" ]
}

@test "a directory on the path to a bucket is not a stray" {
  mkdir -p "${root}/_unresolved/null" "${root}/_unresolved/-home-alice-work"
  printf -- '- [X](x.md) — hook\n' >"${root}/_unresolved/-home-alice-work/MEMORY.md"
  printf -- '---\nname: x\n---\n' >"${root}/_unresolved/-home-alice-work/x.md"

  run --separate-stderr "${script}" -r "${root}"

  [ "${status}" -eq 0 ]
  [ "$(findings_for stray-dir | jq -r '.file')" = "_unresolved/null" ]
}

@test "reserved folders and Syncthing folders are never strays" {
  rm -f "${root}/_rules/a_rule.md" "${root}/_archive/rules/old_rule.md"
  mkdir -p "${root}/_reviews/decisions" "${root}/.stversions/old" "${root}/_unresolved"

  run --separate-stderr "${script}" -r "${root}"

  [ "${status}" -eq 0 ]
  [ -z "$(findings_for stray-dir)" ]
}

@test "sync-conflict files are reported anywhere, _archive and _rules included" {
  touch "${root}/github.com/example-org/example-repo/a_fact.sync-conflict-20261116-101010-ABCDEF.md"
  touch "${root}/_rules/a_rule.sync-conflict-20261116-101010-ABCDEF.md"
  touch "${root}/_archive/rules/old_rule.sync-conflict-20261116-101010-ABCDEF.md"

  run --separate-stderr "${script}" -r "${root}"

  [ "${status}" -eq 0 ]
  files="$(findings_for sync-conflict | jq -r '.file' | LC_ALL=C sort)"
  [ "${files}" = "$(printf '%s\n' \
    _archive/rules/old_rule.sync-conflict-20261116-101010-ABCDEF.md \
    _rules/a_rule.sync-conflict-20261116-101010-ABCDEF.md \
    github.com/example-org/example-repo/a_fact.sync-conflict-20261116-101010-ABCDEF.md)" ]
}

@test "finding ids are the same on every run" {
  mkdir -p "${root}/_unresolved/null"
  touch "${root}/_rules/a_rule.sync-conflict-20261116-101010-ABCDEF.md"

  run --separate-stderr "${script}" -r "${root}"
  first="$(jq -r '.findings[].id' <<<"${output}" | sort)"
  run --separate-stderr "${script}" -r "${root}"
  second="$(jq -r '.findings[].id' <<<"${output}" | sort)"

  [ -n "${first}" ]
  [ "${first}" = "${second}" ]
}
