#!/usr/bin/env bash
# This file:
#
#  - The Claude Code Stop hook command. Reads the hook's JSON on stdin,
#    looks up which project this session resolved to (by session_id, not
#    by cwd -- cwd can drift mid-session, session_id can't), releases the
#    advisory lock, and cleans up the session's state file. Always exits 0
#    -- Stop's output isn't consumed the way SessionStart's is, and this
#    is cleanup, not something that should ever block.
#
# Usage:
#
#  ./stop.sh < hook-input.json
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
  echo "  Claude Code Stop hook. Reads hook JSON from stdin, releases the" 1>&2
  echo "  advisory lock for whatever project this session resolved to at" 1>&2
  echo "  SessionStart (found by session_id, not by re-deriving from cwd)," 1>&2
  echo "  and cleans up its state file. Always exits 0." 1>&2
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
session_id="$(jq -r '.session_id' <<<"${hook_json}")"

debug "Stop: session_id=${session_id}"

state_file="${sessions_dir}/${session_id}.key"

if [[ ! -f "${state_file}" ]]; then
  debug "No state file for session ${session_id}, nothing to release"
  exit 0
fi

project_key="$(<"${state_file}")"

"${core_dir}/lock.sh" release "${shared_root}" "${project_key}" "${session_id}" || true
rm -f "${state_file}"

info "Stop complete for ${project_key} (session ${session_id})"
