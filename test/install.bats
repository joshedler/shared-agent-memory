#!/usr/bin/env bats
#
# Tests for install.sh. Run with: mise exec -- bats test/

bats_require_minimum_version 1.5.0

setup() {
  script="${BATS_TEST_DIRNAME}/../install.sh"
  scratch_home="$(mktemp -d)"
  export HOME="${scratch_home}"
}

teardown() {
  rm -rf "${scratch_home}"
}

@test "creates the default shared memory root" {
  run --separate-stderr "${script}"

  [ "${status}" -eq 0 ]
  [ -d "${scratch_home}/.claude-shared-memory" ]
}

@test "symlinks setup, migrate, and uninstall skills into ~/.claude/skills" {
  run --separate-stderr "${script}"

  [ "${status}" -eq 0 ]
  [ -L "${scratch_home}/.claude/skills/shared-agent-memory-setup" ]
  [ -L "${scratch_home}/.claude/skills/shared-agent-memory-migrate" ]
  [ -L "${scratch_home}/.claude/skills/shared-agent-memory-uninstall" ]
  [ -f "${scratch_home}/.claude/skills/shared-agent-memory-setup/SKILL.md" ]
  [ -f "${scratch_home}/.claude/skills/shared-agent-memory-migrate/SKILL.md" ]
  [ -f "${scratch_home}/.claude/skills/shared-agent-memory-uninstall/SKILL.md" ]
}

@test "is idempotent on a second run" {
  run --separate-stderr "${script}"
  [ "${status}" -eq 0 ]

  run --separate-stderr "${script}"
  [ "${status}" -eq 0 ]
  [[ "${stderr}" == *"already exists"* ]]
  [[ "${stderr}" == *"already linked"* ]]
}

@test "--skip-skills skips symlinking without failing" {
  run --separate-stderr "${script}" --skip-skills

  [ "${status}" -eq 0 ]
  [ -d "${scratch_home}/.claude-shared-memory" ]
  [ ! -e "${scratch_home}/.claude/skills/shared-agent-memory-setup" ]
}

@test "--root overrides the default shared memory root location" {
  custom_root="${scratch_home}/somewhere-else"
  run --separate-stderr "${script}" --root "${custom_root}"

  [ "${status}" -eq 0 ]
  [ -d "${custom_root}" ]
  [ ! -e "${scratch_home}/.claude-shared-memory" ]
}

@test "doesn't clobber an existing non-symlink at the skill destination" {
  mkdir -p "${scratch_home}/.claude/skills/shared-agent-memory-setup"
  echo "pre-existing" >"${scratch_home}/.claude/skills/shared-agent-memory-setup/mine.md"

  run --separate-stderr "${script}"

  [ "${status}" -eq 0 ]
  [ ! -L "${scratch_home}/.claude/skills/shared-agent-memory-setup" ]
  [ -f "${scratch_home}/.claude/skills/shared-agent-memory-setup/mine.md" ]
  [[ "${stderr}" == *"Skipping 'shared-agent-memory-setup'"* ]]
}
