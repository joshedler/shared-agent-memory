#!/usr/bin/env bash
# This file:
#
#  - Bootstraps shared-agent-memory on this host: creates the shared
#    memory root and symlinks this repo's skills into ~/.claude/skills so
#    they're available from any session, not just ones launched here.
#    Also symlinks ~/.claude/rules to the shared root's _rules/ bucket,
#    so Claude Code loads the shared working rules in every session.
#    When nothing was skipped, records this repo's install-version for
#    the host, which the SessionStart hook compares against to tell the
#    user when a pull needs install.sh re-run.
#
# Usage:
#
#  ./install.sh
#  ./install.sh --root /path/to/shared-root
#
# Based on a template by BASH3 Boilerplate v2.8.0
# https://bash3boilerplate.sh/#authors
#
# The MIT License (MIT)
# Copyright (c) 2013 Kevin van Zonneveld and contributors
# You are not obligated to bundle the LICENSE file with your b3bp projects as long
# as you leave these references intact in the header comments of your source files.

# Exit on error. Append "|| true" if you expect an error.
set -o errexit
# Exit on error inside any functions or subshells.
set -o errtrace
# Do not allow use of undefined vars. Use ${VAR:-} to use an undefined VAR
set -o nounset
# Catch the error in a pipe e.g. `mysqldump |gzip` returns mysqldump's exit code, not gzip's
set -o pipefail
# Turn on traces, useful while debugging but commented out by default
# set -o xtrace

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  __i_am_main_script="0" # false

  if [[ "${__usage+x}" ]]; then
    if [[ "${BASH_SOURCE[1]}" = "${0}" ]]; then
      __i_am_main_script="1" # true
    fi

    __b3bp_external_usage="true"
    __b3bp_tmp_source_idx=1
  fi
else
  __i_am_main_script="1" # true
  [[ "${__usage+x}" ]] && unset -v __usage
  [[ "${__helptext+x}" ]] && unset -v __helptext
fi

# Set magic variables for current file, directory, os, etc.
__dir="$(cd "$(dirname "${BASH_SOURCE[${__b3bp_tmp_source_idx:-0}]}")" && pwd)"
__file="${__dir}/$(basename "${BASH_SOURCE[${__b3bp_tmp_source_idx:-0}]}")"
__base="$(basename "${__file}" .sh)"
# shellcheck disable=SC2034,SC2015
__invocation="$(printf %q "${__file}")$( (($#)) && printf ' %q' "$@" || true)"

# Define the environment variables (and their defaults) that this script depends on
LOG_LEVEL="${LOG_LEVEL:-6}" # 8 = debug -> 0 = fatal
NO_COLOR="${NO_COLOR:-}"    # true = disable color. otherwise autodetected

### Functions
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
      # Don't use colors on pipes or non-recognized terminals
      color=""
      color_reset=""
    fi
  fi

  # all remaining arguments are to be printed
  local log_line=""

  while IFS=$'\n' read -r log_line; do
    echo -e "$(date -u +"%Y-%m-%d %H:%M:%S UTC") ${color}$(printf "[%8s]" "${log_level}")${color_reset} ${log_line}" 1>&2
  done <<<"${@:-}"
}

# The `; true` ensures the function exits 0 even when the log level check
# short-circuits the && chain, preventing failures under `set -o errexit`.
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
  echo "  ${__usage:-No usage available}" 1>&2
  echo "" 1>&2

  if [[ "${__helptext:-}" ]]; then
    echo " ${__helptext}" 1>&2
    echo "" 1>&2
  fi

  exit 1
}

function __b3bp_set_opt_display_suffix() {
  local __b3bp_tmp_short_opt="${1}"
  local __b3bp_tmp_out_varname="${2}"
  local __b3bp_tmp_varname="__b3bp_tmp_opt_short2long_${__b3bp_tmp_short_opt}"
  local __b3bp_tmp_opt_long=""

  printf -v "__b3bp_tmp_opt_long" '%s' "${!__b3bp_tmp_varname:-}"

  if [[ "${__b3bp_tmp_opt_long:-}" ]]; then
    printf -v "${__b3bp_tmp_out_varname}" ' (--%s)' "${__b3bp_tmp_opt_long//_/-}"
  else
    printf -v "${__b3bp_tmp_out_varname}" '%s' ""
  fi
}

### Parse commandline options
##############################################################################

# Commandline options. This defines the usage page, and is used to parse cli
# opts & defaults from. The parsing is unforgiving so be precise in your syntax
# - A short option must be preset for every long option; but every short option
#   need not have a long option
# - `--` is respected as the separator between options and arguments
# - We do not bash-expand defaults, so setting '~/app' as a default will not resolve to ${HOME}.
#   you can use bash variables to work around this (so use ${HOME} instead)

# shellcheck disable=SC2015
[[ "${__usage+x}" ]] || read -r -d '' __usage <<-'EOF' || true # exits non-zero when EOF encountered
  -r --root  [arg] Shared memory root directory. Default is computed at runtime (~/.claude-shared-memory).
  -s --skip-skills  Skip symlinking this repo's skills into ~/.claude/skills
  -v --verbose     Enable verbose output (between info and debug)
  -d --debug       Enables debug mode. Repeat (-dd) to also enable upstream's old raw-source echoing (was -v/set -o verbose).
  -h --help        This page
  -n --no-color    Disable color output
EOF

# shellcheck disable=SC2015
[[ "${__helptext+x}" ]] || read -r -d '' __helptext <<-'EOF' || true # exits non-zero when EOF encountered
 Creates the shared-agent-memory root directory if it doesn't exist yet,
 and symlinks this repo's .claude/skills/* into ~/.claude/skills/ so
 they're discoverable from any session, not just ones launched inside
 this repo. Symlinks ~/.claude/rules to the shared root's _rules/
 bucket, so Claude Code loads the shared working rules in every session.
 When nothing was skipped, records this repo's install-version under
 ~/.local/state/shared-agent-memory/, so the SessionStart hook can tell
 you when a later pull needs this re-run. Safe to re-run any time.
 Does not touch ~/.claude/settings.json — hook registration
 is handled by the 'shared-agent-memory-setup' skill (run it in Claude Code after this).
EOF

# Translate usage string -> getopts arguments, and set $arg_<flag> defaults
while read -r __b3bp_tmp_line; do
  if [[ "${__b3bp_tmp_line}" =~ ^- ]]; then
    # fetch single character version of option string
    __b3bp_tmp_opt="${__b3bp_tmp_line%% *}"
    __b3bp_tmp_opt="${__b3bp_tmp_opt:1}"

    # fetch long version if present
    __b3bp_tmp_long_opt=""

    if [[ "${__b3bp_tmp_line}" = *"--"* ]]; then
      __b3bp_tmp_long_opt="${__b3bp_tmp_line#*--}"
      __b3bp_tmp_long_opt="${__b3bp_tmp_long_opt%% *}"
    fi

    # map opt long name to+from opt short name
    printf -v "__b3bp_tmp_opt_long2short_${__b3bp_tmp_long_opt//-/_}" '%s' "${__b3bp_tmp_opt}"
    printf -v "__b3bp_tmp_opt_short2long_${__b3bp_tmp_opt}" '%s' "${__b3bp_tmp_long_opt//-/_}"

    # check if option takes an argument
    if [[ "${__b3bp_tmp_line}" =~ \[.*\] ]]; then
      __b3bp_tmp_opt="${__b3bp_tmp_opt}:" # add : if opt has arg
      __b3bp_tmp_init=""                  # it has an arg. init with ""
      printf -v "__b3bp_tmp_has_arg_${__b3bp_tmp_opt:0:1}" '%s' "1"
    elif [[ "${__b3bp_tmp_line}" =~ \{.*\} ]]; then
      __b3bp_tmp_opt="${__b3bp_tmp_opt}:" # add : if opt has arg
      __b3bp_tmp_init=""                  # it has an arg. init with ""
      # remember that this option requires an argument
      printf -v "__b3bp_tmp_has_arg_${__b3bp_tmp_opt:0:1}" '%s' "2"
    else
      __b3bp_tmp_init="0" # it's a flag. init with 0
      printf -v "__b3bp_tmp_has_arg_${__b3bp_tmp_opt:0:1}" '%s' "0"
    fi
    __b3bp_tmp_opts="${__b3bp_tmp_opts:-}${__b3bp_tmp_opt}"

    if [[ "${__b3bp_tmp_line}" =~ ^Can\ be\ repeated\. ]] || [[ "${__b3bp_tmp_line}" =~ \.\ *Can\ be\ repeated\. ]]; then
      # remember that this option can be repeated
      printf -v "__b3bp_tmp_is_array_${__b3bp_tmp_opt:0:1}" '%s' "1"
    else
      printf -v "__b3bp_tmp_is_array_${__b3bp_tmp_opt:0:1}" '%s' "0"
    fi
  fi

  [[ "${__b3bp_tmp_opt:-}" ]] || continue

  if [[ "${__b3bp_tmp_line}" =~ ^Default= ]] || [[ "${__b3bp_tmp_line}" =~ \.\ *Default= ]]; then
    # ignore default value if option does not have an argument
    __b3bp_tmp_varname="__b3bp_tmp_has_arg_${__b3bp_tmp_opt:0:1}"
    if [[ "${!__b3bp_tmp_varname}" != "0" ]]; then
      # take default
      __b3bp_tmp_init="${__b3bp_tmp_line##*Default=}"
      # strip double quotes from default argument
      __b3bp_tmp_re='^"(.*)"$'
      if [[ "${__b3bp_tmp_init}" =~ ${__b3bp_tmp_re} ]]; then
        __b3bp_tmp_init="${BASH_REMATCH[1]}"
      else
        # strip single quotes from default argument
        __b3bp_tmp_re="^'(.*)'$"
        if [[ "${__b3bp_tmp_init}" =~ ${__b3bp_tmp_re} ]]; then
          __b3bp_tmp_init="${BASH_REMATCH[1]}"
        fi
      fi
    fi
  fi

  if [[ "${__b3bp_tmp_line}" =~ ^Required\. ]] || [[ "${__b3bp_tmp_line}" =~ \.\ *Required\. ]]; then
    # remember that this option requires an argument
    printf -v "__b3bp_tmp_has_arg_${__b3bp_tmp_opt:0:1}" '%s' "2"
  fi

  # Init var with value unless it is an array / a repeatable
  __b3bp_tmp_varname="__b3bp_tmp_is_array_${__b3bp_tmp_opt:0:1}"
  [[ "${!__b3bp_tmp_varname}" = "0" ]] && printf -v "arg_${__b3bp_tmp_opt:0:1}" '%s' "${__b3bp_tmp_init}"
done <<<"${__usage:-}"

# run getopts only if options were specified in __usage
if [[ "${__b3bp_tmp_opts:-}" ]]; then
  # Allow long options like --this
  __b3bp_tmp_opts="${__b3bp_tmp_opts}-:"
  __b3bp_tmp_opt_long_suffix=""

  # Reset in case getopts has been used previously in the shell.
  OPTIND=1

  # start parsing command line
  set +o nounset # getopts may reference unbound OPTARG / positional params
  # Overwrite $arg_<flag> defaults with the actual CLI options
  while getopts "${__b3bp_tmp_opts}" __b3bp_tmp_opt; do
    [[ "${__b3bp_tmp_opt}" = "?" ]] && help "Invalid use of script: ${*} "

    if [[ "${__b3bp_tmp_opt}" = "-" ]]; then
      __b3bp_tmp_optarg_has_explicit=0
      __b3bp_tmp_optarg_value=""

      # OPTARG is long-option-name or long-option=value
      if [[ "${OPTARG}" =~ .*=.* ]]; then
        # --key=value format
        __b3bp_tmp_long_opt="${OPTARG%%=*}"
        __b3bp_tmp_optarg_value="${OPTARG#*=}"
        __b3bp_tmp_optarg_has_explicit=1
      else
        # --key value format
        __b3bp_tmp_long_opt="${OPTARG}"
      fi

      if [[ ! "${__b3bp_tmp_long_opt}" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
        help "Invalid use of script: --${__b3bp_tmp_long_opt}"
      fi

      # Set opt to the short option corresponding to the long option
      __b3bp_tmp_varname="__b3bp_tmp_opt_long2short_${__b3bp_tmp_long_opt//-/_}"
      if [[ -z "${!__b3bp_tmp_varname:-}" ]]; then
        help "Invalid use of script: --${__b3bp_tmp_long_opt}"
      fi
      printf -v "__b3bp_tmp_opt" '%s' "${!__b3bp_tmp_varname}"

      # Decide whether this long option may/must receive an argument.
      __b3bp_tmp_varname="__b3bp_tmp_has_arg_${__b3bp_tmp_opt}"
      __b3bp_tmp_varvalue="${!__b3bp_tmp_varname:-0}"

      if [[ "${__b3bp_tmp_varvalue}" = "0" ]]; then
        # Flags are not allowed to receive a value in --flag=value syntax.
        if [[ "${__b3bp_tmp_optarg_has_explicit}" = "1" ]]; then
          __b3bp_set_opt_display_suffix "${__b3bp_tmp_opt}" "__b3bp_tmp_opt_long_suffix"
          help "Option -${__b3bp_tmp_opt}${__b3bp_tmp_opt_long_suffix} does not take an argument"
        fi
        OPTARG=""
      else
        if [[ "${__b3bp_tmp_optarg_has_explicit}" = "1" ]]; then
          OPTARG="${__b3bp_tmp_optarg_value}"
        else
          # --key value format: consume next token as-is, including empty or hyphen-prefixed values.
          if [[ "${!OPTIND+x}" != "x" ]]; then
            __b3bp_set_opt_display_suffix "${__b3bp_tmp_opt}" "__b3bp_tmp_opt_long_suffix"
            help "Option -${__b3bp_tmp_opt}${__b3bp_tmp_opt_long_suffix} requires an argument"
          fi
          printf -v "__b3bp_tmp_optarg_value" '%s' "${!OPTIND-}"
          OPTARG="${__b3bp_tmp_optarg_value}"
          ((OPTIND += 1))
        fi
      fi
      # we have set opt/OPTARG to the short value and the argument as OPTARG if it exists
    fi

    __b3bp_tmp_value="${OPTARG}"
    __b3bp_tmp_varname="__b3bp_tmp_has_arg_${__b3bp_tmp_opt:0:1}"
    __b3bp_tmp_opt_has_arg="${!__b3bp_tmp_varname:-0}"

    __b3bp_tmp_varname="__b3bp_tmp_is_array_${__b3bp_tmp_opt:0:1}"
    if [[ "${!__b3bp_tmp_varname}" != "0" ]]; then
      # repeatables
      # shellcheck disable=SC2016
      if [[ "${__b3bp_tmp_opt_has_arg}" = "0" ]]; then
        # repeatable flags, they increment
        __b3bp_tmp_varname="arg_${__b3bp_tmp_opt:0:1}"
        debug "cli arg ${__b3bp_tmp_varname} = (${__b3bp_tmp_default}) -> ${!__b3bp_tmp_varname}"
        # shellcheck disable=SC2004
        __b3bp_tmp_value=$((${!__b3bp_tmp_varname} + 1))
        printf -v "${__b3bp_tmp_varname}" '%s' "${__b3bp_tmp_value}"
      else
        # repeatable args, they get appended to an array
        __b3bp_tmp_varname="arg_${__b3bp_tmp_opt:0:1}[@]"
        debug "cli arg ${__b3bp_tmp_varname} append ${__b3bp_tmp_value}"
        declare -a "${__b3bp_tmp_varname}"='("${!__b3bp_tmp_varname}" "${__b3bp_tmp_value}")'
      fi
    else
      # non-repeatables
      __b3bp_tmp_varname="arg_${__b3bp_tmp_opt:0:1}"
      __b3bp_tmp_default="${!__b3bp_tmp_varname}"

      if [[ "${__b3bp_tmp_opt_has_arg}" = "0" ]]; then
        __b3bp_tmp_value=$((__b3bp_tmp_default + 1))
      fi

      printf -v "${__b3bp_tmp_varname}" '%s' "${__b3bp_tmp_value}"

      debug "cli arg ${__b3bp_tmp_varname} = (${__b3bp_tmp_default}) -> ${!__b3bp_tmp_varname}"
    fi
  done
  set -o nounset # no more unbound variable references expected

  shift $((OPTIND - 1))

  if [[ "${1:-}" = "--" ]]; then
    shift
  fi
fi

# -h short-circuits here, before required-argument validation below --
# upstream's own ordering only checks it in "Command-line argument
# switches" further down, which runs after that validation. That means
# `-h` alone (no other args) shows "Option -f requires an argument"
# instead of the help page, since a Required. flag fails validation
# first. Skipped when sourced with a caller-supplied __usage (see
# __b3bp_external_usage above) -- that path returns before ever reaching
# the switches section anyway, so this only matters for direct execution.
# The original check further down is left in place too, harmlessly
# redundant for the direct-execution path by the time it's reached.
if [[ "${__b3bp_external_usage:-}" != "true" ]] && [[ "${arg_h:?}" = "1" ]]; then
  help "Help using ${0}"
fi

### Automatic validation of required option arguments
##############################################################################

for __b3bp_tmp_varname in ${!__b3bp_tmp_has_arg_*}; do
  # validate only options which required an argument
  [[ "${!__b3bp_tmp_varname}" = "2" ]] || continue

  __b3bp_tmp_opt_short="${__b3bp_tmp_varname##*_}"
  __b3bp_tmp_varname="arg_${__b3bp_tmp_opt_short}"
  [[ "${!__b3bp_tmp_varname}" ]] && continue

  __b3bp_set_opt_display_suffix "${__b3bp_tmp_opt_short}" "__b3bp_tmp_opt_long_suffix"
  help "Option -${__b3bp_tmp_opt_short}${__b3bp_tmp_opt_long_suffix} requires an argument"
done

### Cleanup Environment variables
##############################################################################

for __tmp_varname in ${!__b3bp_tmp_*}; do
  unset -v "${__tmp_varname}"
done

unset -v __tmp_varname

### Externally supplied __usage. Nothing else to do here
##############################################################################

if [[ "${__b3bp_external_usage:-}" = "true" ]]; then
  unset -v __b3bp_external_usage
  return
fi

### Signal trapping and backtracing
##############################################################################

function __b3bp_cleanup_before_exit() {
  verbose "Cleaning up. Done"
}
trap __b3bp_cleanup_before_exit EXIT

# requires `set -o errtrace`
function __b3bp_err_report() {
  local error_code="${?}"
  error "Error in ${__file} in function ${1} on line ${2}"
  exit "${error_code}"
}
# Uncomment the following line for always providing an error backtrace
# trap '__b3bp_err_report "${FUNCNAME:-.}" ${LINENO}' ERR

### Command-line argument switches (like -d for debugmode, -h for showing helppage)
##############################################################################

# verbose mode -- just a LOG_LEVEL bump, unlike debug mode below (which
# also enables xtrace and error backtracing). debug mode overrides this
# with a higher level if both are passed, since it runs second.
if [[ "${arg_v:?}" = "1" ]]; then
  LOG_LEVEL="7"
fi

# debug mode -- repeat (-dd) to also enable upstream's old raw-source
# echoing ("set -o verbose": unevaluated source lines, not the expanded
# commands xtrace shows). Folded in as a second debug tier instead of its
# own flag, since it's a deeper flavor of the same "show me exactly what's
# happening" need, not a distinct feature.
if [[ "${arg_d:?}" -ge 1 ]]; then
  set -o xtrace
  PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
  LOG_LEVEL="8"
  # Enable error backtracing
  trap '__b3bp_err_report "${FUNCNAME:-.}" ${LINENO}' ERR
fi

if [[ "${arg_d:?}" -ge 2 ]]; then
  set -o verbose
fi

# no color mode
if [[ "${arg_n:?}" = "1" ]]; then
  NO_COLOR="true"
fi

# help mode
if [[ "${arg_h:?}" = "1" ]]; then
  # Help exists with code 1
  help "Help using ${0}"
fi

### Validation. Error out if the things required for your script are not present
##############################################################################

[[ "${LOG_LEVEL:-}" ]] || fatal "Cannot continue without LOG_LEVEL. "

### Runtime
##############################################################################

shared_root="${arg_r:-${HOME}/.claude-shared-memory}"
state_dir="${HOME}/.local/state/shared-agent-memory"

install_version_file="${__dir}/install-version"
[[ -f "${install_version_file}" ]] || fatal "Missing ${install_version_file}"
install_version="$(tr -d '[:space:]' <"${install_version_file}")"
[[ "${install_version}" =~ ^[0-9]+$ ]] || fatal "${install_version_file} must hold a whole number, got '${install_version}'"

# Set when anything is skipped, so the install version isn't recorded and
# the SessionStart hook keeps saying this host needs a re-run.
incomplete=0

info "Shared memory root: ${shared_root}"

if [[ -e "${shared_root}" ]]; then
  info "Shared root already exists, leaving it as-is"
else
  mkdir -p "${shared_root}"
  notice "Created shared memory root at ${shared_root}"
fi

if [[ "${arg_s:-0}" = "1" ]]; then
  notice "Skipping skill symlinking (--skip-skills)"
else
  skills_src="${__dir}/.claude/skills"
  skills_dest="${HOME}/.claude/skills"
  mkdir -p "${skills_dest}"

  for skill_dir in "${skills_src}"/*/; do
    [[ -d "${skill_dir}" ]] || continue
    skill_name="$(basename "${skill_dir}")"
    dest="${skills_dest}/${skill_name}"

    if [[ -L "${dest}" ]] && [[ "$(readlink -f "${dest}")" = "$(readlink -f "${skill_dir}")" ]]; then
      info "Skill '${skill_name}' already linked"
      continue
    fi

    if [[ -e "${dest}" ]]; then
      warning "Skipping '${skill_name}': ${dest} already exists and isn't a link to this repo"
      incomplete=1
      continue
    fi

    ln -s "${skill_dir%/}" "${dest}"
    notice "Linked skill '${skill_name}' -> ${dest}"
  done
fi

rules_src="${shared_root}/_rules"
rules_dest="${HOME}/.claude/rules"

if [[ ! -d "${rules_src}" ]]; then
  mkdir -p "${rules_src}"
  notice "Created shared rules bucket at ${rules_src}"
fi
mkdir -p "$(dirname "${rules_dest}")"

if [[ -L "${rules_dest}" ]] && [[ "$(readlink -f "${rules_dest}")" = "$(readlink -f "${rules_src}")" ]]; then
  info "Rules already linked"
elif [[ -e "${rules_dest}" ]] || [[ -L "${rules_dest}" ]]; then
  warning "Skipping rules link: ${rules_dest} already exists and isn't a link to ${rules_src}. Move any rule files you want to keep into ${rules_src}, remove ${rules_dest}, and re-run."
  incomplete=1
else
  ln -s "${rules_src}" "${rules_dest}"
  notice "Linked rules ${rules_dest} -> ${rules_src}"
fi

if ((incomplete)); then
  warning "Something above was skipped, so this host's install version wasn't recorded. Sessions will keep reporting that install.sh needs a re-run until it completes cleanly."
else
  mkdir -p "${state_dir}"
  printf '%s\n' "${install_version}" >"${state_dir}/installed-version"
  info "Recorded install version ${install_version}"
  notice "Install complete."
fi

notice "Next: open Claude Code anywhere and ask it to run the 'shared-agent-memory-setup' skill to finish (registers hooks, confirms the shared root, offers to migrate existing memory)."
