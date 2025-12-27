# Fish completions for just with module support
#
# This file provides smart completions for just commands with module awareness.
# When you type 'just nix <TAB>', it will show only nix module recipes.
#
# Installation:
#   Run: just install-fish-completions
#   Then: exec fish (or source ~/.config/fish/completions/just.fish)
#
# Maintained in: scripts/completions/just.fish

# Helper to extract module names
function __fish_just_modules
    just --summary 2>/dev/null | string split ' ' | string match -r '^[^:]+::' | string replace '::' '' | sort -u
end

# Check if token before cursor is a known module
function __fish_just_after_module
    set -l tokens (commandline -opc 2>/dev/null)
    if test (count $tokens) -ge 2
        set -l last_token $tokens[-1]
        contains -- $last_token (__fish_just_modules)
        return $status
    end
    return 1
end

# Get the module name from command line
function __fish_just_current_module
    set -l tokens (commandline -opc 2>/dev/null)
    if test (count $tokens) -ge 2
        for token in $tokens[2..-1]
            if contains -- $token (__fish_just_modules)
                echo $token
                return 0
            end
        end
    end
    return 1
end

# Completions for recipes in a module
complete -c just -f -n __fish_just_after_module -a '(
    set -l mod (__fish_just_current_module)
    if test -n "$mod"
        just --summary 2>/dev/null | string split " " | string match "$mod::*" | string replace "$mod::" ""
    end
)'

# Completions for top-level (modules and top-level recipes)
complete -c just -f -n 'not __fish_just_after_module' -a '(
    set -l all (just --summary 2>/dev/null | string split " ")
    # Top-level recipes (no ::)
    string match -v "*::*" -- $all
    # Module names
    __fish_just_modules
)'

# Standard flags
complete -c just -l help -s h -d 'Print help'
complete -c just -l version -s V -d 'Print version'
complete -c just -l list -s l -d 'List available recipes'
complete -c just -l show -s s -d 'Show recipe' -r
complete -c just -l dry-run -s n -d 'Print what just would do'
complete -c just -l verbose -s v -d 'Use verbose output'
complete -c just -l quiet -s q -d 'Suppress all output'
complete -c just -l justfile -s f -d 'Use <JUSTFILE> as justfile' -r -F
complete -c just -l working-directory -s d -d 'Use <WORKING-DIRECTORY> as working directory' -r -F
complete -c just -l set -d 'Override <VARIABLE> with <VALUE>' -r
complete -c just -l dotenv-path -s E -d 'Load <DOTENV-PATH> as environment file' -r -F
complete -c just -l color -d 'Print colorful output' -r -f -a "always auto never"
