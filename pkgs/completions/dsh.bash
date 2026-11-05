# bash completion for dsh
# Flags mirror `dsh --help` (commander CLI, dsh 0.2.x). Profile names come from
# $DSH_HOME/profiles at completion time, merged with the shipped templates.
#
# `dsh plugin …` forwards its arguments to pnpm, so pnpm owns the candidates:
# asking pnpm's own completion server keeps the list in step with whichever
# pnpm dsh actually ships, instead of a hand-copied and slowly drifting table.

_dsh_home() { printf '%s' "${DSH_HOME:-$HOME/.dsh}"; }

# Real profile dirs (a valid profile has package.json) plus shipped templates.
_dsh_profiles() {
  local home d
  home=$(_dsh_home)
  {
    for d in "$home"/profiles/*/; do
      [ -f "$d/package.json" ] && printf '%s\n' "${d%/}"
    done | xargs -r -n1 basename
    printf '%s\n' web acp headless sdk sdk-minimal
  } 2>/dev/null | sort -u
}

_dsh_templates() { printf '%s\n' web acp headless sdk sdk-minimal; }

# Ask pnpm's completion server about a line rebuilt from the forwarded argv.
# pnpm parses only COMP_LINE, so COMP_CWORD merely has to look like a real
# cursor. The timeout keeps a wedged server from blocking the TAB key, and
# the missing-tool early returns keep a pnpm-less PATH quiet instead of noisy.
_dsh_pnpm_candidates() {
  local partial=$1 line=pnpm word
  shift
  command -v pnpm >/dev/null 2>&1 || return 0
  command -v timeout >/dev/null 2>&1 || return 0
  for word in "$@"; do line+=" $word"; done
  line+=" $partial"
  COMP_CWORD=$(( $# + 1 )) COMP_LINE=$line COMP_POINT=${#line} SHELL=bash \
    timeout 5 pnpm completion-server -- pnpm "$@" "$partial" 2>/dev/null
}

# Complete the argument list after `dsh plugin`. dsh owns --profile and the
# three version-exemption verbs; every other position is pnpm's.
_dsh_plugin() {
  local cur=$1 prev=$2
  local i
  case "$prev" in
    --profile) COMPREPLY=($(compgen -W "$(_dsh_profiles)" -- "$cur")); return ;;
  esac
  if [[ $cur == --profile=* ]]; then
    local prefix=${cur%%=*}=
    COMPREPLY=($(compgen -W "$(_dsh_profiles)" -- "${cur#*=}"))
    for (( i = 0; i < ${#COMPREPLY[@]}; i++ )); do
      COMPREPLY[i]=$prefix${COMPREPLY[i]}
    done
    return
  fi

  # Drop dsh's own --profile (both spellings) so the line handed to pnpm is
  # the argv dsh would actually forward, not the dsh command line.
  local -a forwarded=() skipwords=()
  local skip=0
  for (( i = 2; i < COMP_CWORD; i++ )); do
    if (( skip )); then skip=0; continue; fi
    case ${COMP_WORDS[i]} in
      --profile) skip=1 ;;
      --profile=*) ;;
      *) forwarded+=("${COMP_WORDS[i]}") ;;
    esac
  done

  local -a candidates=()
  local word is_command=1
  for word in "${forwarded[@]}"; do
    [[ $word == -* ]] || is_command=0
  done
  if (( is_command )); then
    candidates+=($(compgen -W 'allow-version revoke-version version-exemptions --profile -h --help' -- "$cur"))
  fi

  local line
  while IFS= read -r line; do
    [ -n "$line" ] && candidates+=("$line")
  done < <(_dsh_pnpm_candidates "$cur" "${forwarded[@]}")

  COMPREPLY=("${candidates[@]}")
}

_dsh() {
  local cur prev words cword
  _init_completion -n = || return
  prev=${COMP_WORDS[COMP_CWORD-1]}

  # `dsh plugin …` forwards everything to pnpm inside the profile dir.
  local i sub=
  for (( i = 1; i < COMP_CWORD; i++ )); do
    case "${COMP_WORDS[i]}" in
      plugin) sub=plugin; break ;;
      -*) ;;
      *) break ;;
    esac
  done

  if [ "$sub" = plugin ]; then
    _dsh_plugin "$cur" "$prev"
    return
  fi

  case "$prev" in
    --profile)              COMPREPLY=($(compgen -W "$(_dsh_profiles)" -- "$cur")); return ;;
    --from-default-profile) COMPREPLY=($(compgen -W "$(_dsh_templates)" -- "$cur")); return ;;
    --patch)                COMPREPLY=($(compgen -f -- "$cur")); return ;;
  esac

  if [[ $cur == -* ]]; then
    COMPREPLY=($(compgen -W '--profile --from-default-profile --patch
      --dump-config --dump-config-schema --dump-default-config
      --version --help' -- "$cur"))
    return
  fi

  if (( COMP_CWORD == 1 )); then
    COMPREPLY=($(compgen -W "plugin $(_dsh_profiles)" -- "$cur"))
  fi
}

complete -F _dsh dsh
