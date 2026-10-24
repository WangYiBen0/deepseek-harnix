# bash completion for dsh
# Flags mirror dsh --help (commander CLI, dsh 0.2.x); profile names are read
# from $DSH_HOME/profiles at completion time and merged with the shipped
# templates.

_dsh_profiles() {
  local home="${DSH_HOME:-$HOME/.dsh}"
  (command ls "$home/profiles" 2>/dev/null; printf 'web\nacp\nheadless\nsdk\nsdk-minimal\n') | sort -u
}

_dsh_templates() {
  printf 'web\nacp\nheadless\nsdk\nsdk-minimal\n'
}

_dsh() {
  local cur prev words cword
  _init_completion || return

  local prev_cmd=${COMP_WORDS[COMP_CWORD-1]}

  case "$prev_cmd" in
    --profile)
      COMPREPLY=($(compgen -W "$(_dsh_profiles)" -- "$cur"))
      return
      ;;
    --from-default-profile)
      COMPREPLY=($(compgen -W "$(_dsh_templates)" -- "$cur"))
      return
      ;;
    --patch)
      COMPREPLY=($(compgen -f -- "$cur"))
      return
      ;;
  esac

  case "$cur" in
    -*)
      COMPREPLY=($(compgen -W '--profile --from-default-profile --patch
        --dump-config --dump-config-schema --dump-default-config
        --version --help' -- "$cur"))
      return
      ;;
  esac

  if [[ ${COMP_CWORD} -eq 1 ]]; then
    COMPREPLY=($(compgen -W "plugin $(_dsh_profiles)" -- "$cur"))
  fi
}

complete -F _dsh dsh
