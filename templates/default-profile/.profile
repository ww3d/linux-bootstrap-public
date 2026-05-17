# ~/.profile: executed by Bourne-compatible login shells.

# Source ~/.bashrc when running bash (interactive shells get the same env)
if [ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi

# User-local binaries (XDG standard + legacy ~/bin)
[ -d "$HOME/.local/bin" ] && PATH="$HOME/.local/bin:$PATH"
[ -d "$HOME/bin" ]        && PATH="$HOME/bin:$PATH"
export PATH

# Default editor
export EDITOR=vim
export VISUAL="$EDITOR"
