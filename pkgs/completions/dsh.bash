# bash completion for dsh
# Flags mirror `dsh --help` (commander CLI, dsh 0.2.x). Profile names come from
# $DSH_HOME/profiles at completion time, merged with the shipped templates.

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
    case "$prev" in
      --profile) COMPREPLY=($(compgen -W "$(_dsh_profiles)" -- "$cur")); return ;;
    esac
    if [[ $cur == -* ]]; then
      COMPREPLY=($(compgen -W '--profile --help -h' -- "$cur")); return
    fi
    # Count positionals after `plugin`, skipping the --profile value.
    local positional=0 skip=0
    for (( i = 2; i < COMP_CWORD; i++ )); do
      if (( skip )); then skip=0; continue; fi
      case "${COMP_WORDS[i]}" in
        --profile) skip=1 ;;
        -*) ;;
        *) positional=$(( positional + 1 )) ;;
      esac
    done
    if (( positional == 0 )); then
      COMPREPLY=($(compgen -W 'add install remove update list why' -- "$cur"))
    fi
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
