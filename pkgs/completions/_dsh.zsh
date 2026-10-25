#compdef dsh
# zsh completion for dsh — mirrors `dsh --help` (commander CLI, dsh 0.2.x).

_dsh_home() { print -r -- "${DSH_HOME:-$HOME/.dsh}"; }

# Real profile dirs (a profile carries a package.json) plus shipped templates.
_dsh_profiles() {
  local home=$(_dsh_home) d
  local -a profiles
  for d in "$home"/profiles/*(N/); do
    [[ -f $d/package.json ]] && profiles+=("${d:t}")
  done
  profiles+=(web acp headless sdk sdk-minimal)
  _describe -t profiles 'profile' profiles
}

_dsh_templates() {
  local -a templates=(web acp headless sdk sdk-minimal)
  _describe -t templates 'shipped template' templates
}

_dsh_plugin() {
  # The value of --profile is a profile name, wherever it appears.
  if [[ ${words[CURRENT-1]} == --profile ]]; then
    _dsh_profiles
    return
  fi
  local i positional=0 skip=0
  # words: dsh plugin ... — count positionals after `plugin`, skipping --profile's value.
  for (( i = 3; i < CURRENT; i++ )); do
    if (( skip )); then skip=0; continue; fi
    case ${words[i]} in
      --profile) skip=1 ;;
      -*) ;;
      *) (( positional++ )) ;;
    esac
  done
  if (( positional == 0 )) && [[ ${words[CURRENT]} != -* ]]; then
    local -a cmds=(add install remove update list why)
    _describe -t pnpm-commands 'pnpm command' cmds
    return
  fi
  _files
}

_dsh() {
  local -a opts
  opts=(
    '(-V --version)'{-V,--version}'[output the version number]'
    '--profile=[the profile under $DSH_HOME/profiles to boot]:profile:_dsh_profiles'
    '--from-default-profile=[replace a custom profile with a shipped template]:template:_dsh_templates'
    '*--patch=[extra patch-list overlay applied after the profile layer]:patch file:_files'
    '--dump-config[print the composed profile tree and exit]'
    '--dump-config-schema[print JSON Schema for profile entries and patches]'
    '--dump-default-config[print the profile tree without its user layer and exit]'
    '(-h --help)'{-h,--help}'[show help]'
  )

  # `dsh plugin …` forwards the trailing arguments to pnpm in the profile dir.
  local i
  for (( i = 2; i < CURRENT; i++ )); do
    [[ ${words[i]} == plugin ]] && { _dsh_plugin; return; }
    [[ ${words[i]} != -* ]] && break
  done

  if (( CURRENT == 2 )) && [[ ${words[2]} != -* ]]; then
    _alternative \
      'profiles:profile:_dsh_profiles' \
      'subcommands:subcommand:(plugin)'
    return
  fi

  _arguments -C "${opts[@]}" '*:app args:_default'
}

_dsh "$@"
