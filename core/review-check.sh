#!/usr/bin/env bash
# This file:
#
#  - Runs the mechanical (no-LLM) checks of a shared-agent-memory review
#    over the whole shared root and prints the findings as one JSON
#    document on stdout. It never changes anything.
#
# Usage:
#
#  ./review-check.sh [-r <shared_root>]
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

# Set magic variables for current file, directory, os, etc. Resolves
# through symlinks -- upstream's own plain `dirname "${BASH_SOURCE[0]}"`
# doesn't -- since a script built on this template is meant to still find
# files bundled alongside it (config, data, other scripts) when symlinked
# onto PATH from elsewhere, not just when run from its own checkout. Fork
# addition, not upstream b3bp.
__source="${BASH_SOURCE[${__b3bp_tmp_source_idx:-0}]}"
while [[ -h "${__source}" ]]; do
  __dir="$(cd -P "$(dirname "${__source}")" && pwd)"
  __source="$(readlink "${__source}")"
  [[ "${__source}" != /* ]] && __source="${__dir}/${__source}"
done
__dir="$(cd -P "$(dirname "${__source}")" && pwd)"
__file="${__dir}/$(basename "${__source}")"
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
  -r --root  [arg] Shared memory root. Default is computed at runtime ($SHARED_AGENT_MEMORY_ROOT, else ~/.claude-shared-memory).
  -v --verbose     Enable verbose output (between info and debug)
  -d --debug       Enables debug mode. Repeat (-dd) to also enable upstream's old raw-source echoing (was -v/set -o verbose).
  -h --help        This page
  -n --no-color    Disable color output
EOF

# shellcheck disable=SC2015
[[ "${__helptext+x}" ]] || read -r -d '' __helptext <<-'EOF' || true # exits non-zero when EOF encountered
 Prints {"root", "generated_at", "findings": [...]} on stdout. Each finding
 has a stable "id" (the same on every run and host), "check", "severity"
 (info or warn), "bucket" and "file" (paths relative to the root, or null)
 and a "message". Logging goes to stderr, so stdout is safe to capture.
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
command -v jq >/dev/null 2>&1 || fatal "jq is required but wasn't found on PATH"

root="${arg_r:-${SHARED_AGENT_MEMORY_ROOT:-${HOME}/.claude-shared-memory}}"
[[ -d "${root}" ]] || fatal "Shared root not found: ${root}"
root="$(cd "${root}" && pwd)"

### Runtime
##############################################################################

findings=()

# Appends one finding. bucket and file are paths relative to the root, or ""
# for none. The id is check:path, so the same problem gets the same id on
# every run and every host (decisions are recorded against it).
function add_finding() {
  local check="${1}" severity="${2}" bucket="${3}" file="${4}" message="${5}"

  findings+=("$(jq -cn \
    --arg check "${check}" --arg severity "${severity}" \
    --arg bucket "${bucket}" --arg file "${file}" --arg message "${message}" \
    '{
      id: ($check + ":" + (if $file != "" then $file else $bucket end)),
      check: $check,
      severity: $severity,
      bucket: (if $bucket == "" then null else $bucket end),
      file: (if $file == "" then null else $file end),
      message: $message
    }')")
}

## Layout: empty buckets and stray directories

# _archive, _rules and _reviews have their own checks (or none) and are never
# scanned as buckets. _unresolved holds buckets but isn't one itself. Dot
# folders (Syncthing's .stfolder, .stversions) are skipped everywhere.
mapfile -t dirs < <(
  cd "${root}" \
    && find . -mindepth 1 \
      \( -name '.*' -o -path ./_archive -o -path ./_rules -o -path ./_reviews \) -prune \
      -o -type d -print \
    | sed 's|^\./||' | LC_ALL=C sort
)

# A bucket is any directory directly holding a .md file or a .lock.
declare -A is_bucket=()
for dir in "${dirs[@]}"; do
  if [[ -n "$(find "${root}/${dir}" -mindepth 1 -maxdepth 1 -type f \( -name '*.md' -o -name .lock \) -print -quit)" ]]; then
    is_bucket["${dir}"]=1
  fi
done

# Every directory that is a bucket or has one somewhere below it.
declare -A leads_to_bucket=()
for bucket in "${!is_bucket[@]}"; do
  path="${bucket}"
  while [[ -n "${path}" ]]; do
    leads_to_bucket["${path}"]=1
    [[ "${path}" == */* ]] || break
    path="${path%/*}" # up one level
  done
done

for dir in "${dirs[@]}"; do
  if [[ -n "${is_bucket[${dir}]:-}" ]]; then
    # Same rule as link-memory.sh: a leftover .lock doesn't count as content.
    if [[ -z "$(find "${root}/${dir}" -mindepth 1 -maxdepth 1 ! -name .lock -print -quit)" ]]; then
      add_finding empty-bucket warn "${dir}" "" \
        "Bucket holds nothing but a .lock, usually left behind by a link that moved or a key that was computed wrongly. Candidate for deletion once no host links to it."
    fi
    continue
  fi

  [[ "${dir}" = "_unresolved" ]] && continue
  [[ -n "${leads_to_bucket[${dir}]:-}" ]] && continue

  # Report a stray only at its top: skip it if its parent is a stray too.
  parent=""
  [[ "${dir}" == */* ]] && parent="${dir%/*}"
  if [[ -n "${parent}" ]] && [[ "${parent}" != "_unresolved" ]] && [[ -z "${leads_to_bucket[${parent}]:-}" ]]; then
    continue
  fi

  add_finding stray-dir warn "" "${dir}" \
    "Directory is neither a bucket nor on the path to one (no memory files or .lock anywhere below it). Candidate for deletion."
done

## Syncthing conflict copies, anywhere in the root

while IFS= read -r file; do
  add_finding sync-conflict warn "$(dirname "${file}")" "${file}" \
    "Syncthing conflict copy: two hosts changed this file before syncing. Compare it with the original, merge, then delete it."
done < <(
  cd "${root}" \
    && find . -mindepth 1 -name '.*' -prune -o -type f -name '*.sync-conflict-*' -print \
    | sed 's|^\./||' | LC_ALL=C sort
)

## Output

generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if ((${#findings[@]})); then
  printf '%s\n' "${findings[@]}"
fi | jq -s --arg root "${root}" --arg generated_at "${generated_at}" \
  '{root: $root, generated_at: $generated_at, findings: .}'
