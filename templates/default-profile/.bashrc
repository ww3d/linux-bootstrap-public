# ~/.bashrc: executed by bash(1) for non-login shells.
# see /usr/share/doc/bash/examples/startup-files (in the bash-doc package)
# for examples.

# ----------------------------------------------------------------------------
# Interactive shell guard
# ----------------------------------------------------------------------------
# .bashrc is sometimes sourced for non-interactive sessions (scp, certain
# ssh "host cmd" invocations, BASH_ENV scripts). Producing any output there
# breaks scp ("received corrupted data") and similar protocols.
case $- in
    *i*) ;;
      *) return;;
esac

# ----------------------------------------------------------------------------
# Chroot identifier (used in prompt)
# ----------------------------------------------------------------------------
if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi

# ----------------------------------------------------------------------------
# History
# ----------------------------------------------------------------------------
HISTCONTROL=ignoreboth:erasedups   # ignore dups + leading-space lines, erase older dups
HISTSIZE=10000                     # in-memory entries
HISTFILESIZE=20000                 # entries persisted to ~/.bash_history
HISTTIMEFORMAT='%F %T '            # timestamps when running `history`
shopt -s histappend                # append on exit instead of overwriting (critical for parallel sessions)

# ----------------------------------------------------------------------------
# Shell options
# ----------------------------------------------------------------------------
shopt -s checkwinsize              # update LINES/COLUMNS after each command
shopt -s globstar                  # ** matches files recursively
shopt -s cdspell                   # autocorrect minor typos in `cd`
shopt -s dirspell 2>/dev/null      # autocorrect dir names during completion (bash 4+)

# ----------------------------------------------------------------------------
# less / lesspipe — show .gz, .tar, .deb, ... directly in less
# ----------------------------------------------------------------------------
[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

# ----------------------------------------------------------------------------
# Prompt
# ----------------------------------------------------------------------------
# Determine if the terminal supports color. Modern terminals (alacritty, kitty,
# wezterm, foot, ghostty, ...) often don't have a "-256color" suffix, so we
# match them explicitly too.
case "$TERM" in
    xterm-color|*-256color|alacritty|*kitty*|wezterm|foot|ghostty|tmux*|screen*)
        color_prompt=yes
        ;;
esac

# Force color even if heuristic above failed (most setups support it nowadays)
force_color_prompt=yes

if [ -n "$force_color_prompt" ]; then
    if [ -x /usr/bin/tput ] && tput setaf 1 >&/dev/null; then
        color_prompt=yes
    else
        color_prompt=
    fi
fi

if [ "$color_prompt" = yes ]; then
    PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
else
    PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w\$ '
fi
unset color_prompt force_color_prompt

# Set window title to user@host:dir for terminals that support OSC 0
case "$TERM" in
    xterm*|rxvt*|alacritty|*kitty*|wezterm|foot|ghostty|tmux*|screen*)
        PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]$PS1"
        ;;
esac

# ----------------------------------------------------------------------------
# Colors (ls, grep, ...) — uses system-default dircolors (kept fresh by coreutils)
# ----------------------------------------------------------------------------
if [ -x /usr/bin/dircolors ]; then
    eval "$(dircolors -b)"
fi

export LS_OPTIONS='--color=auto'

# ----------------------------------------------------------------------------
# Aliases
# ----------------------------------------------------------------------------
# ls family
alias ls='ls $LS_OPTIONS -lisah'
alias ll='ls $LS_OPTIONS -l'
alias l='ls $LS_OPTIONS -lA'

# Coloured tooling
alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias fgrep='fgrep --color=auto'
alias diff='diff --color=auto'     # GNU diff 3.4+ supports --color
alias ip='ip -c'                   # colored ip output

# Human-readable by default
alias df='df -h'
alias du='du -h'
alias free='free -h'

# Personal
alias pwsh='pwsh-preview'

# Safety nets — uncomment if desired
# alias rm='rm -i'
# alias cp='cp -i'
# alias mv='mv -i'

# Personal aliases can go into a separate file
if [ -f ~/.bash_aliases ]; then
    . ~/.bash_aliases
fi

# ----------------------------------------------------------------------------
# Bash completion
# ----------------------------------------------------------------------------
if ! shopt -oq posix; then
    if [ -f /usr/share/bash-completion/bash_completion ]; then
        . /usr/share/bash-completion/bash_completion
    elif [ -f /etc/bash_completion ]; then
        . /etc/bash_completion
    fi
fi
