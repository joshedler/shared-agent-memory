#!/usr/bin/env bash
# This file:
#
#  - The Claude Code SessionStart hook command. Reads the hook's JSON on
#    stdin, resolves the current directory's shared-agent-memory project
#    key, links Claude Code's native memory path into the shared root, and
#    acquires the advisory lock. Silent (no stdout) when everything is
#    clean; only emits additionalContext JSON when there's something worth
#    telling the user about.
#
# Usage:
#
#  ./session-start.sh < hook-input.json
#
# Based on a template by BASH3 Boilerplate v2.8.0
# https://bash3boilerplate.sh/#authors
#
# The MIT License (MIT)
# Copyright (c) 2013 Kevin van Zonneveld and contributors
# You are not obligated to bundle the LICENSE file with your b3bp projects as long
# as you leave these references intact in the header comments of your source files.
#
# ---
#
# This script keeps b3bp's logging conventions and signal-trapping
# pattern, but replaces its getopts option-parsing engine with a lighter
# hand-rolled flag loop: that engine's value is declaring custom
# `[arg]`-taking options, which this script never needs (all its input
# comes from stdin JSON).

set -o errexit
set -o errtrace
set -o nounset
set -o pipefail
# set -o xtrace

__dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__file="${__dir}/$(basename "${BASH_SOURCE[0]}")"

LOG_LEVEL="${LOG_LEVEL:-6}"
NO_COLOR="${NO_COLOR:-}"

### Logging (from bash3boilerplate)
##############################################################################

function __b3bp_log() {
  local log_level="${1}"
  shift

  # shellcheck disable=SC2034
  local color_debug="\\x1b[35m" color_verbose="\\x1b[30m" color_info="\\x1b[32m" color_notice="\\x1b[1;34m" \
    color_warning="\\x1b[33m" color_alert="\\x1b[31m" color_error="\\x1b[1;31m" \
    color_critical="\\x1b[1;37;41m" color_fatal="\\x1b[1;4;1;37;41m"

  local colorvar="color_${log_level}"
  local color="${!colorvar:-${color_error}}"
  local color_reset="\\x1b[0m"

  if [[ "${NO_COLOR:-}" = "true" ]] \
    || { [[ "${TERM:-}" != "xterm"* ]] && [[ "${TERM:-}" != "screen"* ]]; } \
    || [[ ! -t 2 ]]; then
    if [[ "${NO_COLOR:-}" != "false" ]]; then
      color=""
      color_reset=""
    fi
  fi

  local log_line=""
  while IFS=$'\n' read -r log_line; do
    echo -e "$(date -u +"%Y-%m-%d %H:%M:%S UTC") ${color}$(printf "[%8s]" "${log_level}")${color_reset} ${log_line}" 1>&2
  done <<<"${@:-}"
}

function fatal() {
  __b3bp_log fatal "${@}"
  exit 1
}
function critical() {
  [[ "${LOG_LEVEL:-0}" -ge 1 ]] && __b3bp_log critical "${@}"
  true
}
function error() {
  [[ "${LOG_LEVEL:-0}" -ge 2 ]] && __b3bp_log error "${@}"
  true
}
function alert() {
  [[ "${LOG_LEVEL:-0}" -ge 3 ]] && __b3bp_log alert "${@}"
  true
}
function warning() {
  [[ "${LOG_LEVEL:-0}" -ge 4 ]] && __b3bp_log warning "${@}"
  true
}
function notice() {
  [[ "${LOG_LEVEL:-0}" -ge 5 ]] && __b3bp_log notice "${@}"
  true
}
function info() {
  [[ "${LOG_LEVEL:-0}" -ge 6 ]] && __b3bp_log info "${@}"
  true
}
function verbose() {
  [[ "${LOG_LEVEL:-0}" -ge 7 ]] && __b3bp_log verbose "${@}"
  true
}
function debug() {
  [[ "${LOG_LEVEL:-0}" -ge 8 ]] && __b3bp_log debug "${@}"
  true
}

function help() {
  echo "" 1>&2
  echo " ${*}" 1>&2
  echo "" 1>&2
  echo "  Usage: ${__file} < hook-input.json" 1>&2
  echo "" 1>&2
  echo "  -v --verbose     Enable verbose output (between info and debug)" 1>&2
  echo "  -d --debug       Enables debug mode. Repeat (-dd) to also enable upstream's old raw-source echoing." 1>&2
  echo "  -h --help        This page" 1>&2
  echo "  -n --no-color    Disable color output" 1>&2
  echo "" 1>&2
  echo "  Claude Code SessionStart hook. Reads hook JSON from stdin, links" 1>&2
  echo "  memory and acquires the advisory lock for the resolved project." 1>&2
  echo "  Silent on success; emits additionalContext JSON only when there's" 1>&2
  echo "  a refusal or lock conflict to relay." 1>&2
  echo "" 1>&2
  exit 1
}

### Signal trapping and backtracing
##############################################################################

function __b3bp_cleanup_before_exit() {
  verbose "Cleaning up. Done"
}
trap __b3bp_cleanup_before_exit EXIT

function __b3bp_err_report() {
  local error_code="${?}"
  error "Error in ${__file} in function ${1} on line ${2}"
  exit "${error_code}"
}
# trap '__b3bp_err_report "${FUNCNAME:-.}" ${LINENO}' ERR

### Global flags
##############################################################################

args=()
arg_v=0
arg_d=0
arg_n=0
arg_h=0

while [[ $# -gt 0 ]]; do
  case "${1}" in
  -v | --verbose)
    arg_v=1
    shift
    ;;
  -d | --debug)
    arg_d=$((arg_d + 1))
    shift
    ;;
  -n | --no-color)
    arg_n=1
    shift
    ;;
  -h | --help)
    arg_h=1
    shift
    ;;
  *)
    args+=("${1}")
    shift
    ;;
  esac
done
set -- "${args[@]}"

if [[ "${arg_v}" = "1" ]]; then
  LOG_LEVEL="7"
fi

if [[ "${arg_d}" -ge 1 ]]; then
  set -o xtrace
  PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
  LOG_LEVEL="8"
  trap '__b3bp_err_report "${FUNCNAME:-.}" ${LINENO}' ERR
fi

if [[ "${arg_d}" -ge 2 ]]; then
  set -o verbose
fi

if [[ "${arg_n}" = "1" ]]; then
  NO_COLOR="true"
fi

if [[ "${arg_h}" = "1" ]]; then
  help "Help using ${__file}"
fi

### Validation
##############################################################################

[[ "${LOG_LEVEL:-}" ]] || fatal "Cannot continue without LOG_LEVEL. "
command -v jq >/dev/null || fatal "jq is required but not found on PATH."

### Runtime
##############################################################################

core_dir="$(cd "${__dir}/../../../core" && pwd)"
shared_root="${SHARED_AGENT_MEMORY_ROOT:-${HOME}/.claude-shared-memory}"
sessions_dir="${HOME}/.local/state/shared-agent-memory/sessions"

hook_json="$(cat)"
cwd="$(jq -r '.cwd' <<<"${hook_json}")"
session_id="$(jq -r '.session_id' <<<"${hook_json}")"

debug "SessionStart: cwd=${cwd} session_id=${session_id}"

slug="$("${__dir}/lib/project-slug.sh" "${cwd}")"
memory_path="${HOME}/.claude/projects/${slug}/memory"

if ! project_key="$("${core_dir}/resolve-key.sh" "${cwd}" 2>/dev/null)"; then
  debug "No resolvable project key for ${cwd} yet, nothing to do"
  exit 0
fi

debug "Resolved project key: ${project_key}"

link_err_file="$(mktemp)"
link_status=0
"${core_dir}/link-memory.sh" "${memory_path}" "${shared_root}" "${project_key}" \
  >/dev/null 2>"${link_err_file}" || link_status=$?

if ((link_status != 0)); then
  link_error="$(<"${link_err_file}")"
  rm -f "${link_err_file}"
  jq -n --arg ctx "shared-agent-memory: couldn't link this project's memory: ${link_error}" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
  exit 0
fi
rm -f "${link_err_file}"

if [[ "${project_key}" = "_personal" ]]; then
  mkdir -p "${sessions_dir}"
  printf '%s\n' "${project_key}" >"${sessions_dir}/${session_id}.key"
  info "SessionStart complete for _personal (session ${session_id}, always-synced -- no lock)"
  exit 0
fi

lock_status="$("${core_dir}/lock.sh" acquire "${shared_root}" "${project_key}" "${session_id}")"
debug "Lock status: ${lock_status}"

mkdir -p "${sessions_dir}"
printf '%s\n' "${project_key}" >"${sessions_dir}/${session_id}.key"

context=""

if [[ "${lock_status}" != "clean" ]]; then
  read -r lock_kind lock_host lock_acquired_at <<<"${lock_status}"
  lock_time="$(date -d "@${lock_acquired_at}" '+%Y-%m-%d %H:%M:%S %Z')"

  case "${lock_kind}" in
  conflict)
    context="shared-agent-memory: this project has an active session on host '${lock_host}' as of ${lock_time}. Not blocked, just worth mentioning in case it wasn't expected."
    ;;
  stale-reclaimed)
    context="shared-agent-memory: reclaimed this project's lock, last held by host '${lock_host}' as of ${lock_time} (past the staleness window, likely an uncleanly-ended session)."
    ;;
  esac
fi

if [[ -n "${context}" ]]; then
  jq -n --arg ctx "${context}" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
fi

info "SessionStart complete for ${project_key} (session ${session_id})"
