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

# --- rules link and install version ------------------------------------------

@test "links ~/.claude/rules to the shared root's _rules bucket, creating it" {
  run --separate-stderr "${script}"

  [ "${status}" -eq 0 ]
  [ -d "${scratch_home}/.claude-shared-memory/_rules" ]
  [ -L "${scratch_home}/.claude/rules" ]
  [ "$(readlink -f "${scratch_home}/.claude/rules")" = "$(readlink -f "${scratch_home}/.claude-shared-memory/_rules")" ]
}

@test "leaves existing _rules content alone" {
  mkdir -p "${scratch_home}/.claude-shared-memory/_rules"
  echo "# A rule" >"${scratch_home}/.claude-shared-memory/_rules/a_rule.md"

  run --separate-stderr "${script}"

  [ "${status}" -eq 0 ]
  [ "$(cat "${scratch_home}/.claude/rules/a_rule.md")" = "# A rule" ]
}

@test "--root points the rules link into the custom root" {
  custom_root="${scratch_home}/somewhere-else"
  run --separate-stderr "${script}" --root "${custom_root}"

  [ "${status}" -eq 0 ]
  [ "$(readlink -f "${scratch_home}/.claude/rules")" = "$(readlink -f "${custom_root}/_rules")" ]
}

@test "reports the rules link as already linked on a second run" {
  run --separate-stderr "${script}"
  run --separate-stderr "${script}"

  [ "${status}" -eq 0 ]
  [[ "${stderr}" == *"Rules already linked"* ]]
}

@test "doesn't clobber an existing real ~/.claude/rules, and doesn't record the install version" {
  mkdir -p "${scratch_home}/.claude/rules"
  echo "mine" >"${scratch_home}/.claude/rules/mine.md"

  run --separate-stderr "${script}"

  [ "${status}" -eq 0 ]
  [ ! -L "${scratch_home}/.claude/rules" ]
  [ -f "${scratch_home}/.claude/rules/mine.md" ]
  [[ "${stderr}" == *"Skipping rules link"* ]]
  [ ! -e "${scratch_home}/.local/state/shared-agent-memory/installed-version" ]
}

@test "treats a dangling ~/.claude/rules symlink as in the way" {
  mkdir -p "${scratch_home}/.claude"
  ln -s "${scratch_home}/nowhere" "${scratch_home}/.claude/rules"

  run --separate-stderr "${script}"

  [ "${status}" -eq 0 ]
  [ "$(readlink "${scratch_home}/.claude/rules")" = "${scratch_home}/nowhere" ]
  [[ "${stderr}" == *"Skipping rules link"* ]]
}

@test "records the repo's install version on a clean run" {
  run --separate-stderr "${script}"

  [ "${status}" -eq 0 ]
  expected="$(tr -d '[:space:]' <"${BATS_TEST_DIRNAME}/../install-version")"
  [ "$(cat "${scratch_home}/.local/state/shared-agent-memory/installed-version")" = "${expected}" ]
}

@test "doesn't record the install version when a skill was skipped" {
  mkdir -p "${scratch_home}/.claude/skills/shared-agent-memory-setup"
  echo "pre-existing" >"${scratch_home}/.claude/skills/shared-agent-memory-setup/mine.md"

  run --separate-stderr "${script}"

  [ "${status}" -eq 0 ]
  [ ! -e "${scratch_home}/.local/state/shared-agent-memory/installed-version" ]
  [[ "${stderr}" == *"wasn't recorded"* ]]
}

@test "--skip-skills still records the install version" {
  run --separate-stderr "${script}" --skip-skills

  [ "${status}" -eq 0 ]
  [ -f "${scratch_home}/.local/state/shared-agent-memory/installed-version" ]
}
