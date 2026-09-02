#!/usr/bin/env bash
# This file:
#
#  - Advisory cross-host lock for a shared-agent-memory project. Not
#    distributed consensus -- acquire always succeeds, it only reports
#    what the prior state was so a caller can decide whether to relay
#    that to the user.
#
# Usage:
#
#  ./lock.sh acquire <shared_root> <project_key> <session_id> [--host <name>] [--ttl <seconds>]
#  ./lock.sh release <shared_root> <project_key> <session_id>
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
# pattern, but replaces its getopts option-parsing engine with a
# hand-rolled global-flag pre-pass + subcommand dispatch: that engine
# assumes one fixed flat option set for the whole script, which doesn't
# fit a git-style CLI where `acquire` and `release` each take different
# positional args and flags.

set -o errexit
set -o errtrace
set -o nounset
set -o pipefail
# set -o xtrace

__dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__file="${__dir}/$(basename "${BASH_SOURCE[0]}")"
__base="$(basename "${__file}" .sh)"
# shellcheck disable=SC2034
__invocation="$(printf %q "${__file}")$( (($#)) && printf ' %q' "$@" || true)"

LOG_LEVEL="${LOG_LEVEL:-6}" # 8 = debug -> 0 = fatal
NO_COLOR="${NO_COLOR:-}"    # true = disable color. otherwise autodetected

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
  echo "  Usage:" 1>&2
  echo "    ${__file} acquire <shared_root> <project_key> <session_id> [--host <name>] [--ttl <seconds>]" 1>&2
  echo "    ${__file} release <shared_root> <project_key> <session_id>" 1>&2
  echo "" 1>&2
  echo "  -v --verbose     Enable verbose output (between info and debug)" 1>&2
  echo "  -d --debug       Enables debug mode. Repeat (-dd) to also enable upstream's old raw-source echoing." 1>&2
  echo "  -h --help        This page" 1>&2
  echo "  -n --no-color    Disable color output" 1>&2
  echo "" 1>&2
  exit 1
}

function usage() {
  help "Usage error"
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
# Uncomment for always-on error backtracing
# trap '__b3bp_err_report "${FUNCNAME:-.}" ${LINENO}' ERR

### Global flags (recognized anywhere), then subcommand dispatch
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

subcommand="${1:-}"
[[ -n "${subcommand}" ]] || usage
shift

case "${subcommand}" in
acquire)
  shared_root="${1:?$(usage)}"
  project_key="${2:?$(usage)}"
  session_id="${3:?$(usage)}"
  shift 3

  host="$(hostname)"
  ttl=14400

  while [[ $# -gt 0 ]]; do
    case "${1}" in
    --host)
      host="${2:?--host requires an argument}"
      shift 2
      ;;
    --ttl)
      ttl="${2:?--ttl requires an argument}"
      shift 2
      ;;
    *)
      fatal "Unknown argument: ${1}"
      ;;
    esac
  done

  lock_dir="${shared_root}/${project_key}"
  lock_file="${lock_dir}/.lock"

  mkdir -p "${lock_dir}"

  status_line="clean"

  if [[ -f "${lock_file}" ]]; then
    prev_host="$(sed -n 's/^host=//p' "${lock_file}")"
    prev_acquired_at="$(sed -n 's/^acquired_at=//p' "${lock_file}")"

    if [[ "${prev_host}" != "${host}" ]]; then
      age=$(($(date +%s) - prev_acquired_at))

      if ((age < ttl)); then
        status_line="conflict ${prev_host} ${prev_acquired_at}"
      else
        status_line="stale-reclaimed ${prev_host} ${prev_acquired_at}"
      fi
    fi
  fi

  {
    printf 'host=%s\n' "${host}"
    printf 'session_id=%s\n' "${session_id}"
    printf 'acquired_at=%s\n' "$(date +%s)"
  } >"${lock_file}"

  info "Wrote lock at ${lock_file} (host=${host}, session=${session_id})"
  printf '%s\n' "${status_line}"
  ;;
release)
  shared_root="${1:?$(usage)}"
  project_key="${2:?$(usage)}"
  session_id="${3:?$(usage)}"

  lock_file="${shared_root}/${project_key}/.lock"

  if [[ -f "${lock_file}" ]]; then
    held_by="$(sed -n 's/^session_id=//p' "${lock_file}")"

    if [[ "${held_by}" = "${session_id}" ]]; then
      rm -f "${lock_file}"
      info "Released lock at ${lock_file}"
      exit 0
    fi
  fi

  warning "Lock at ${lock_file} is not held by session ${session_id}, leaving it alone"
  exit 1
  ;;
*)
  usage
  ;;
esac
