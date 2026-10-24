#compdef dsh
# zsh completion for dsh — flags mirror dsh --help (commander CLI, dsh 0.2.x).

_dsh_profiles() {
  local home="${DSH_HOME:-$HOME/.dsh}"
  local -a profiles
  profiles=("$home"/profiles/*(N:t) web acp headless sdk sdk-minimal)
  _describe -t profiles 'profile' profiles
}

_dsh_templates() {
  local -a templates=(web acp headless sdk sdk-minimal)
  _describe -t templates 'shipped template' templates
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
    '1:profile:_dsh_profiles'
    '*:app args:_default'
  )

  if (( CURRENT == 2 )) && [[ ${words[2]} != -* ]]; then
    _alternative \
      'subcommands:subcommand:(plugin)' \
      'profiles:profile:_dsh_profiles'
  elif [[ ${words[2]} == plugin ]]; then
    _arguments -C \
      '--profile=[profile whose plugins pnpm manages]:profile:_dsh_profiles' \
      '1:pnpm command:(add install remove update list)' \
      '*::pnpm args:_default'
  else
    _arguments -C "${opts[@]}"
  fi
}

_dsh "$@"
