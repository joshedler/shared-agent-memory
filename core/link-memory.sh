#!/usr/bin/env bash
# This file:
#
#  - Ensures a Claude Code project's memory path is a symlink into its
#    shared-agent-memory subfolder. Never touches real (non-symlink) data
#    at the memory path, and never relinks over a stale symlink target
#    that still has content -- both are refused with guidance to run the
#    'shared-agent-memory-migrate' skill instead, so memory is never
#    silently lost.
#
# Usage:
#
#  ./link-memory.sh <memory_path> <shared_root> <project_key>
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
# `[arg]`-taking options, which this script never needs (its arguments
# are plain positionals).

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
  echo "  Usage: ${__file} <memory_path> <shared_root> <project_key>" 1>&2
  echo "" 1>&2
  echo "  -v --verbose     Enable verbose output (between info and debug)" 1>&2
  echo "  -d --debug       Enables debug mode. Repeat (-dd) to also enable upstream's old raw-source echoing." 1>&2
  echo "  -h --help        This page" 1>&2
  echo "  -n --no-color    Disable color output" 1>&2
  echo "" 1>&2
  echo "  Ensures <memory_path> is a symlink into <shared_root>/<project_key>," 1>&2
  echo "  creating the target directory if it's new. Prints one of: created," 1>&2
  echo "  already-linked, relinked. Refuses (nonzero exit, message on stderr)" 1>&2
  echo "  if real data would be orphaned or overwritten -- run the" 1>&2
  echo "  'shared-agent-memory-migrate' skill in that case instead of" 1>&2
  echo "  forcing it." 1>&2
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

### Global flags, then positional args
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

### Runtime
##############################################################################

memory_path="${1:?$(help "memory_path, shared_root, and project_key are required")}"
shared_root="${2:?$(help "memory_path, shared_root, and project_key are required")}"
project_key="${3:?$(help "memory_path, shared_root, and project_key are required")}"

target_dir="${shared_root}/${project_key}"

if [[ ! -e "${memory_path}" && ! -L "${memory_path}" ]]; then
  mkdir -p "${target_dir}"
  mkdir -p "$(dirname "${memory_path}")"
  ln -s "${target_dir}" "${memory_path}"
  info "Created ${memory_path} -> ${target_dir}"
  printf 'created\n'
  exit 0
fi

if [[ -L "${memory_path}" ]]; then
  current_target="$(readlink -f "${memory_path}")"
  resolved_target_dir="$(mkdir -p "${target_dir}" && readlink -f "${target_dir}")"

  if [[ "${current_target}" = "${resolved_target_dir}" ]]; then
    debug "${memory_path} already links to ${target_dir}"
    printf 'already-linked\n'
    exit 0
  fi

  if [[ ! -e "${current_target}" ]] || { [[ -d "${current_target}" ]] && [[ -z "$(ls -A "${current_target}" 2>/dev/null)" ]]; }; then
    rm -f "${memory_path}"
    ln -s "${resolved_target_dir}" "${memory_path}"
    info "Relinked ${memory_path} -> ${resolved_target_dir} (old target ${current_target} was empty or missing, nothing lost)"
    printf 'relinked\n'
    exit 0
  fi

  fatal "${memory_path} currently links to ${current_target}, which still has content -- not relinking to ${resolved_target_dir} automatically, that would orphan it. Run the 'shared-agent-memory-migrate' skill to reconcile it first."
fi

fatal "${memory_path} already exists and is not a symlink -- refusing to touch it. Run the 'shared-agent-memory-migrate' skill to bring its content into shared-agent-memory first."
