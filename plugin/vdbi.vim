" vdbi.vim
" Last Change: 2012-03-08
" Maintainer:   Yasuhiro Matsumoto <mattn.jp@gmail.com>
" License:      BSD style license

command! -nargs=0 VDBI call vdbi#tables()
command! -nargs=+ VDBIExec call vdbi#execute(<q-args>)
command! -nargs=0 VDBIReset call vdbi#shutdown()
