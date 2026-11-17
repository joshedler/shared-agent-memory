#!/usr/bin/env bats
#
# Tests for core/resolve-key.sh. Run with: mise exec -- bats test/

bats_require_minimum_version 1.5.0

setup() {
  script="${BATS_TEST_DIRNAME}/../core/resolve-key.sh"
  scratch="$(mktemp -d)"

  # A fake `ssh` first on PATH, so no test ever reads the real ssh config.
  # It answers `ssh -G <host>` the way real ssh does: one config line per
  # key, with `hostname` mapped from the alias below and every other host
  # passed through unchanged. Each call is logged so tests can assert
  # whether ssh was consulted at all.
  fake_bin="${scratch}/fake-bin"
  mkdir -p "${fake_bin}"
  cat >"${fake_bin}/ssh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_SSH_LOG}"
[[ "${FAKE_SSH_FAIL:-}" = "1" ]] && exit 255
[[ "${1:-}" = "-G" ]] || exit 255
case "${2:-}" in
  github.com-example-alias) real="github.com" ;;
  *) real="${2:-}" ;;
esac
printf 'user git\nhostname %s\ncanonicalizehostname false\nport 22\n' "${real}"
EOF
  chmod +x "${fake_bin}/ssh"
  export PATH="${fake_bin}:${PATH}"
  export FAKE_SSH_LOG="${scratch}/ssh.log"
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

@test "an ssh host alias in an scp-style remote resolves to the real host" {
  git -C "${scratch}" init -q
  git -C "${scratch}" remote add origin git@github.com-example-alias:example-org/example-repo.git

  run --separate-stderr "${script}" "${scratch}"

  [ "${status}" -eq 0 ]
  [ "${output}" = "github.com/example-org/example-repo" ]
}

@test "an ssh host alias in an ssh:// remote resolves to the real host" {
  git -C "${scratch}" init -q
  git -C "${scratch}" remote add origin ssh://git@github.com-example-alias/example-org/example-repo.git

  run --separate-stderr "${script}" "${scratch}"

  [ "${status}" -eq 0 ]
  [ "${output}" = "github.com/example-org/example-repo" ]
}

@test "a port in an ssh:// remote is dropped from the key" {
  git -C "${scratch}" init -q
  git -C "${scratch}" remote add origin ssh://git@github.com:2222/example-org/example-repo.git

  run --separate-stderr "${script}" "${scratch}"

  [ "${status}" -eq 0 ]
  [ "${output}" = "github.com/example-org/example-repo" ]
}

@test "an ssh:// remote with both an alias and a port resolves to the real host, no port" {
  git -C "${scratch}" init -q
  git -C "${scratch}" remote add origin ssh://git@github.com-example-alias:2222/example-org/example-repo.git

  run --separate-stderr "${script}" "${scratch}"

  [ "${status}" -eq 0 ]
  [ "${output}" = "github.com/example-org/example-repo" ]
}

@test "an https remote never consults ssh" {
  git -C "${scratch}" init -q
  git -C "${scratch}" remote add origin https://github.com/example-org/example-repo.git

  run --separate-stderr "${script}" "${scratch}"

  [ "${status}" -eq 0 ]
  [ "${output}" = "github.com/example-org/example-repo" ]
  [ ! -e "${FAKE_SSH_LOG}" ]
}

@test "if ssh fails, an ssh remote keeps its literal host" {
  git -C "${scratch}" init -q
  git -C "${scratch}" remote add origin git@github.com-example-alias:example-org/example-repo.git
  export FAKE_SSH_FAIL=1

  run --separate-stderr "${script}" "${scratch}"

  [ "${status}" -eq 0 ]
  [ "${output}" = "github.com-example-alias/example-org/example-repo" ]
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
