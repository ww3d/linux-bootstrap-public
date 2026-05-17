" ~/.vimrc

" ----------------------------------------------------------------------------
" Core
" ----------------------------------------------------------------------------
set nocompatible            " be modern (vim, not vi)
syntax enable
filetype plugin indent on

" ----------------------------------------------------------------------------
" Truecolor
" ----------------------------------------------------------------------------
" Vim 7.4.1799+ supports 24-bit color in terminals via 'termguicolors'.
" This replaces the old `set t_Co=256` approach.
if has('termguicolors')
    " Tmux compatibility: tell vim how to set true colors
    let &t_8f = "\<Esc>[38;2;%lu;%lu;%lum"
    let &t_8b = "\<Esc>[48;2;%lu;%lu;%lum"
    set termguicolors
endif

" ----------------------------------------------------------------------------
" Colorscheme — Catppuccin (Mocha for dark terminals, Latte for GUI)
" ----------------------------------------------------------------------------
autocmd ColorScheme catppuccin_mocha highlight Normal guibg=NONE ctermbg=NONE
autocmd ColorScheme catppuccin_mocha highlight NonText guibg=NONE ctermbg=NONE
autocmd ColorScheme catppuccin_mocha highlight LineNr guibg=NONE ctermbg=NONE
autocmd ColorScheme catppuccin_mocha highlight SignColumn guibg=NONE ctermbg=NONE

if has('gui_running')
    colorscheme catppuccin_latte
else
    colorscheme catppuccin_mocha
endif

" Toggle between dark/light Catppuccin flavors with <F5>
function! ToggleCatppuccinBg() abort
    if get(g:, 'colors_name', '') ==# 'catppuccin_mocha'
        colorscheme catppuccin_latte
    else
        colorscheme catppuccin_mocha
    endif
endfunction
nnoremap <silent> <F5> :call ToggleCatppuccinBg()<CR>

" ----------------------------------------------------------------------------
" Sensible defaults
" ----------------------------------------------------------------------------
set number                  " show line numbers
set ruler                   " show cursor position
set showcmd                 " show partial command in status line
set wildmenu                " enhanced command-line completion
set scrolloff=5             " keep 5 lines above/below cursor
set sidescrolloff=5
set hidden                  " allow switching buffers without saving
set backspace=indent,eol,start
set encoding=utf-8
set laststatus=2            " always show status line

" Search
set incsearch               " incremental search
set hlsearch                " highlight matches
set ignorecase
set smartcase               " case-sensitive if pattern has uppercase

" Indentation
set autoindent
set tabstop=4
set shiftwidth=4
set expandtab               " spaces, not tabs

" Mouse (useful in terminal too on modern terminals)
if has('mouse')
    set mouse=a
endif

" Persistent undo across sessions
if has('persistent_undo')
    let s:undodir = expand('~/.vim/undo')
    if !isdirectory(s:undodir)
        call mkdir(s:undodir, 'p', 0700)
    endif
    let &undodir = s:undodir
    set undofile
endif
