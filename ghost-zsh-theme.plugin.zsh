# from https://github.com/agkozak/agkozak-zsh-theme 

# Set $GHOST_THEME_DEBUG to 1 to see debugging information
typeset -g GHOST_THEME_DEBUG=${GHOST_THEME_DEBUG:-0}

(( GHOST_THEME_DEBUG )) && setopt WARN_CREATE_GLOBAL


setopt PROMPT_SUBST NO_PROMPT_BANG

TRAPWINCH() {
    zle && zle -R
}

_ghost_has_colors() {
    (( $(tput colors) >= 8 ))
}


_ghost_is_ssh() {
    [[ -n "${SSH_CONNECTION-}${SSH_CLIENT-}${SSH_TTY-}" ]]
}

_ghost_branch_status() {
    local ref branch
    ref="$(git symbolic-ref --quiet HEAD 2> /dev/null)"
    case $? in        # See what the exit code is.
        0) ;;           # $ref contains the name of a checked-out branch.
        128) return ;;  # No Git repository here.
        # Otherwise, see if HEAD is in detached state.
        *) ref="$(git rev-parse --short HEAD 2> /dev/null)" || return ;;
    esac
    branch="${ref#refs/heads/}"
    printf ' (%s%s)' "$branch" "$(_ghost_branch_changes)"
}

_ghost_branch_changes() {
    local git_status symbols k

    git_status="$(LC_ALL=C command git status 2>&1)"

    declare -A messages

    messages=(
        'renamed:'                '>'
        'Your branch is ahead of' '*'
        'new file:'               '+'
        'Untracked files'         '?'
        'deleted'                 'x'
        'modified:'               '!'
    )

    for k in ${(@k)messages}; do
        case $git_status in
            *${k}*) symbols="${messages[$k]}${symbols}" ;;
        esac
    done

    [[ -n $symbols ]] && printf ' %s' "$symbols"
}

_ghost_has_usr1() {
    if whence -w TRAPUSR1 &> /dev/null; then
        (( GHOST_THEME_DEBUG )) && echo 'TRAPUSR1() already defined'
        false
    else
        case $signals in    # Array containing names of available signals
            *USR1*) true ;;
            *)
                (( GHOST_THEME_DEBUG )) && echo 'SIGUSR1 not available'
                false
                ;;
        esac
    fi
}

_ghost_load_async_lib() {
    if ! whence -w async_init &> /dev/null; then      # Don't load zsh-async twice
        echo "zsh_async is not installed"
    fi
}


_ghost_async_init() {
    typeset -g GHOST_ASYNC_METHOD RPS1

    case $GHOST_FORCE_ASYNC_METHOD in
        zsh-async)
            _ghost_load_async_lib
            GHOST_ASYNC_METHOD=$GHOST_FORCE_ASYNC_METHOD
            ;;
        usr1|none)
            GHOST_ASYNC_METHOD=$GHOST_FORCE_ASYNC_METHOD
            ;;
        *)
            # Avoid trying to load zsh-async on systems where it is known not to work
            #
            # Msys2) it doesn't load successfully
            # Cygwin) it loads but doesn't work (see
            #   https://github.com/sindresorhus/pure/issues/141)
            # TODO: WSL seems to work perfectly now with zsh-async, but it may not
            #   have in the past
            local sysinfo="$(uname -a)"

            case $sysinfo in
                # On Msys2, zsh-async won't load; on Cygwin, it loads but does not work.
                *Msys|*Cygwin) GHOST_ASYNC_METHOD='usr1' ;;
                *)
                    # Avoid loading zsh-async on zsh v5.0.2
                    # See https://github.com/mafredri/zsh-async/issues/12
                    # The theme appears to work properly now with zsh-async and zsh v5.0.8
                    case $ZSH_VERSION in
                        '5.0.2')
                            if _ghost_has_usr1; then
                                GHOST_ASYNC_METHOD='usr1';
                            else
                                GHOST_ASYNC_METHOD='none'
                            fi
                            ;;
                        *)

                            # Having exhausted known problematic systems, try to load
                            # zsh-async; in case that doesn't work, try the SIGUSR1 method if
                            # SIGUSR1 is available and TRAPUSR1() hasn't been defined; failing
                            # that, switch off asynchronous mode
                            if _ghost_load_async_lib; then
                                GHOST_ASYNC_METHOD='zsh-async'
                            else
                                if _ghost_has_usr1; then
                                    case $sysinfo in
                                        *Microsoft*Linux)
                                            unsetopt BG_NICE                # nice doesn't work on WSL
                                            GHOST_ASYNC_METHOD='usr1'
                                            ;;
                                        # TODO: the SIGUSR1 method doesn't work on Solaris 11 yet
                                        # but it does work on OpenIndiana
                                        # SIGUSR2 works on Solaris 11
                                        *solaris*) GHOST_ASYNC_METHOD='none' ;;
                                        *) GHOST_ASYNC_METHOD='usr1' ;;
                                    esac
                                else
                                    GHOST_ASYNC_METHOD='none'
                                fi
                            fi
                            ;;
                    esac
                    ;;
            esac
            ;;
    esac

    case $GHOST_ASYNC_METHOD in
        zsh-async)

            ########################################################
            # Create zsh-async worker
            ########################################################
            _ghost_zsh_async() {
                async_start_worker ghost_git_status_worker -n
                async_register_callback ghost_git_status_worker _ghost_zsh_async_callback
                async_job ghost_git_status_worker :
            }

            ########################################################
            # Set RPROPT and stop worker
            ########################################################
            _ghost_zsh_async_callback() {
                psvar[3]="$(_ghost_branch_status)"
                zle && zle reset-prompt
                async_stop_worker ghost_git_status_worker -n
            }
            ;;

        usr1)

            ########################################################
            # precmd uses this function to launch async workers to
            # calculate the Git status. It can tell if anything has
            # redefined the TRAPUSR1() function that actually
            # displays the status; if so, it will drop the theme
            # down into non-asynchronous mode.
            ########################################################
            _ghost_usr1_async() {
                if [[ "$(builtin which TRAPUSR1)" = $GHOST_TRAPUSR1_FUNCTION ]]; then
                    # Kill running child process if necessary
                    if (( GHOST_USR1_ASYNC_WORKER )); then
                        kill -s HUP $GHOST_USR1_ASYNC_WORKER &> /dev/null || :
                    fi

                    # Start background computation of Git status
                    _ghost_usr1_async_worker &!
                    GHOST_USR1_ASYNC_WORKER=$!
                else
                    echo 'ghost-zsh-theme warning: TRAPUSR1() has been redefined. Disabling asynchronous mode.'
                    GHOST_ASYNC_METHOD='none'
                fi
            }

            ########################################################
            # Asynchronous Git branch status using SIGUSR1
            ########################################################
            _ghost_usr1_async_worker() {
                # Save Git branch status to temporary file
                _ghost_branch_status > "/tmp/ghost_zsh_theme_$$"

                # Signal parent process
                if (( GHOST_THEME_DEBUG )); then
                    kill -s USR1 $$
                else
                    kill -s USR1 $$ &> /dev/null
                fi
            }

            ########################################################
            # On SIGUSR1, redraw prompt
            ########################################################
            TRAPUSR1() {
                # read from temp file
                psvar[3]="$(cat /tmp/ghost_zsh_theme_$$)"

                # Reset asynchronous process number
                GHOST_USR1_ASYNC_WORKER=0

                # Redraw the prompt
                zle && zle reset-prompt
            }

            typeset -g GHOST_TRAPUSR1_FUNCTION
            GHOST_TRAPUSR1_FUNCTION="$(builtin which TRAPUSR1)"
            ;;
    esac
}


_ghost_collapsed_wd() {
    echo $(pwd | perl -pe '
   BEGIN {
      binmode STDIN,  ":encoding(UTF-8)";
      binmode STDOUT, ":encoding(UTF-8)";
   }; s|^$ENV{HOME}|~|g; s|/([^/.])[^/]*(?=/)|/$1|g; s|/\.([^/])[^/]*(?=/)|/.$1|g
')
}

_ghost_precmd() {
    psvar[2]="$(_ghost_collapsed_wd)"
    psvar[3]=''

    case $GHOST_ASYNC_METHOD in
        'zsh-async') _ghost_zsh_async ;;
        'usr1') _ghost_usr1_async ;;
        *) psvar[3]="$(_ghost_branch_status)" ;;
    esac

}

ghost_zsh_theme() {
    _ghost_async_init

    case $GHOST_ASYNC_METHOD in
        'zsh-async')
            async_init
            ;;
        'usr1')
            typeset -g GHOST_USR1_ASYNC_WORKER
            GHOST_USR1_ASYNC_WORKER=0
            ;;
    esac

    autoload -Uz add-zsh-hook
    add-zsh-hook precmd _ghost_precmd

    # Only display the $HOSTNAME for an ssh connection or for a superuser
    if _ghost_is_ssh || [[ $EUID -eq 0 ]]; then
        psvar[1]="$(print -Pn "%n@%m")"
    else
        psvar[1]="$(print -Pn "%n" | head -c1)"
    fi

    # When the user is a superuser, the username and hostname are
    # displayed in reverse video
    if _ghost_has_colors; then
        PS1='%(?..%B%F{red}(%?%)%f%b )%(!.%S%B.%B%F{blue})%1v%(!.%b%s.%f%b) %B%F{green}%2v%f%b $ '
        RPS1='%F{yellow}%3v%f'
    else
        PS1='%(?..(%?%) )%(!.%S.)%1v%(!.%s.) %2v $ '
        RPS1='%3v'
    fi
}

ghost_zsh_theme
