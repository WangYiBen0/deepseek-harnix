# fish completion for dsh — mirrors `dsh --help` (commander CLI, dsh 0.2.x).
#
# `dsh plugin …` forwards its arguments to pnpm, so pnpm's own completion
# server supplies those candidates. A copied-in verb table drifts from the pnpm
# dsh actually ships; the one this replaced had invented verbs pnpm rejects.

function __dsh_home
    if set -q DSH_HOME
        echo $DSH_HOME
    else
        echo $HOME/.dsh
    end
end

# Real profile directories (a profile carries a package.json) plus the shipped
# templates. node_modules is dependency lookup space, not a profile.
function __dsh_profiles
    set -l home (__dsh_home)
    for d in $home/profiles/*/
        if test -f $d/package.json
            basename $d
        end
    end
    printf '%s\n' web acp headless sdk sdk-minimal
end

function __dsh_templates
    printf '%s\n' web acp headless sdk sdk-minimal
end

# Ask pnpm about a line rebuilt from the forwarded arguments. pnpm parses only
# COMP_LINE, so COMP_CWORD merely has to look like a real cursor. The timeout
# keeps a wedged server from stalling completion, and the guards keep a
# pnpm-less PATH silent instead of noisy.
function __dsh_pnpm_candidates
    set -l partial $argv[1]
    set -e argv[1]
    command -q pnpm; or return 0
    command -q timeout; or return 0
    set -l line pnpm
    for word in $argv
        set line "$line $word"
    end
    set line "$line $partial"
    set -l cword (math (count $argv) + 1)
    COMP_CWORD=$cword COMP_LINE="$line" COMP_POINT=(string length -- "$line") SHELL=fish \
        timeout 5 pnpm completion-server -- pnpm $argv $partial 2>/dev/null
end

# The argument list after `dsh plugin`. dsh owns --profile and the three
# version-exemption verbs; every other position belongs to pnpm.
function __dsh_plugin_candidates
    set -l partial (commandline -ct)
    set -l tokens (commandline -opc)
    set -l plugin_index 0
    for i in (seq 2 (count $tokens))
        switch $tokens[$i]
            case plugin
                set plugin_index $i
                break
            case '-*'
            case '*'
                break
        end
    end
    test $plugin_index -gt 0; or return 0

    set -l previous $tokens[-1]
    if test "$previous" = --profile
        __dsh_profiles
        return 0
    end
    if string match -q -- '--profile=*' $partial
        __dsh_profiles | string replace -r '^' '--profile='
        return 0
    end

    # Drop dsh's own --profile (both spellings) so pnpm sees the argv dsh would
    # forward, not the dsh command line it never receives.
    set -l forwarded
    set -l skip 0
    for i in (seq (math $plugin_index + 1) (count $tokens))
        set -l word $tokens[$i]
        if test $skip -eq 1
            set skip 0
            continue
        end
        switch $word
            case --profile
                set skip 1
            case '--profile=*'
            case '*'
                set forwarded $forwarded $word
        end
    end

    set -l is_command 1
    for word in $forwarded
        string match -q -- '-*' $word; or set is_command 0
    end
    if test $is_command -eq 1
        printf '%s\n' allow-version revoke-version version-exemptions --profile -h --help
    end

    __dsh_pnpm_candidates $partial $forwarded
end

complete -c dsh -f

# First argument: a profile name or the plugin subcommand.
complete -c dsh -n '__fish_is_first_arg' -a '(__dsh_profiles)' -d Profile
complete -c dsh -n '__fish_is_first_arg' -a plugin -d "Manage a profile's plugins by forwarding the arguments to pnpm"

# Launcher flags.
complete -c dsh -s V -l version -d 'Output the version number'
complete -c dsh -f -l profile -r -d 'The profile under $DSH_HOME/profiles to boot' -a '(__dsh_profiles)'
complete -c dsh -f -l from-default-profile -r -d 'Replace a custom profile with a fresh copy of a shipped template' -a '(__dsh_templates)'
complete -c dsh -l patch -r -d 'Extra patch-list overlay applied after the profile layer (repeatable)' -F
complete -c dsh -l dump-config -d 'Print the composed profile tree and exit'
complete -c dsh -l dump-config-schema -d 'Print JSON Schema for profile entries and patches without mounting'
complete -c dsh -l dump-default-config -d 'Print the profile tree without its user layer or --patch overlays and exit'
complete -c dsh -s h -l help -d 'Show help'

# `dsh plugin …` forwards the rest to pnpm in the profile directory.
complete -c dsh -f -n '__fish_seen_subcommand_from plugin' -l profile -r -d 'Profile whose plugins pnpm manages' -a '(__dsh_profiles)'
complete -c dsh -n '__fish_seen_subcommand_from plugin' -s h -l help -d 'Show help'
complete -c dsh -f -n '__fish_seen_subcommand_from plugin' -a '(__dsh_plugin_candidates)' -d 'pnpm'
