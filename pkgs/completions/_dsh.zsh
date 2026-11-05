#compdef dsh
# zsh completion for dsh — mirrors `dsh --help` (commander CLI, dsh 0.2.x).
#
# `dsh plugin …` hands its arguments to pnpm, so pnpm's own completion server
# supplies the candidates. A copied-in verb table drifts from the pnpm that dsh
# actually ships, and the one it replaced had invented several verbs.

_dsh_home() { print -r -- "${DSH_HOME:-$HOME/.dsh}"; }

# Real profile dirs (a profile carries a package.json) plus shipped templates.
_dsh_profile_names() {
  local home=$(_dsh_home) d
  local -a profiles
  for d in "$home"/profiles/*(N/); do
    [[ -f $d/package.json ]] && profiles+=("${d:t}")
  done
  profiles+=(web acp headless sdk sdk-minimal)
  print -l -- $profiles
}

_dsh_profiles() {
  local -a profiles
  profiles=(${(f)"$(_dsh_profile_names)"})
  _describe -t profiles 'profile' profiles
}

_dsh_templates() {
  local -a templates=(web acp headless sdk sdk-minimal)
  _describe -t templates 'shipped template' templates
}

# Ask pnpm about a line rebuilt from the forwarded argv. pnpm parses COMP_LINE
# only, so COMP_CWORD just has to look like a real cursor. The timeout keeps a
# wedged server from stalling completion, and the guards keep a pnpm-less PATH
# silent instead of noisy.
_dsh_pnpm_candidates() {
  local partial=$1
  shift
  (( $+commands[pnpm] )) || return 0
  (( $+commands[timeout] )) || return 0
  local line=pnpm word
  for word in "$@"; do line+=" $word"; done
  line+=" $partial"
  COMP_CWORD=$(( $# + 1 )) COMP_LINE=$line COMP_POINT=${#line} SHELL=zsh \
    timeout 5 pnpm completion-server -- pnpm "$@" "$partial" 2>/dev/null
}

# Complete the argument list after `dsh plugin`. dsh owns --profile and the
# three version-exemption verbs; every other position is pnpm's.
_dsh_plugin() {
  local partial=${words[CURRENT]}
  local -a candidates
  local i

  # The value of --profile is a profile name, wherever it appears.
  if [[ ${words[CURRENT-1]} == --profile ]]; then
    _dsh_profiles
    return
  fi
  if [[ $partial == --profile=* ]]; then
    local -a values
    local value
    # The full candidate is tested against the partial, not the other way
    # round: `--profile=w` has to match `--profile=web`, and the bare
    # `[[ $partial == --profile=$value* ]]` would ask whether `--profile=w`
    # starts with `--profile=web`, which it does not.
    for value in ${(f)"$(_dsh_profile_names)"}; do
      [[ --profile=$value == $partial* ]] && values+=("--profile=$value")
    done
    _describe -t profiles 'profile' values
    return
  fi

  local plugin_index=0
  for (( i = 2; i < CURRENT; i++ )); do
    case ${words[i]} in
      plugin) plugin_index=$i; break ;;
      -*) ;;
      *) break ;;
    esac
  done

  # Drop dsh's own --profile (both spellings) so pnpm sees the argv dsh would
  # forward, not the dsh command line it never receives.
  local -a forwarded
  local skip=0
  for (( i = plugin_index + 1; i < CURRENT; i++ )); do
    if (( skip )); then skip=0; continue; fi
    case ${words[i]} in
      --profile) skip=1 ;;
      --profile=*) ;;
      *) forwarded+=("${words[i]}") ;;
    esac
  done

  local is_command=1 word
  for word in "${forwarded[@]}"; do
    [[ $word == -* ]] || is_command=0
  done
  if (( is_command )); then
    candidates+=(allow-version revoke-version version-exemptions --profile -h --help)
  fi

  # pnpm already prefix-filters for bash, but its zsh output is the whole
  # option list; filter here so all three shells offer the same words.
  local out candidate
  out=$(_dsh_pnpm_candidates "$partial" "${forwarded[@]}")
  for candidate in ${(f)out}; do
    [[ -n $candidate && $candidate == $partial* ]] && candidates+=("$candidate")
  done

  (( ${#candidates} )) && _describe -t pnpm 'pnpm' candidates
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
