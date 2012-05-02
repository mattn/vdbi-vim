" vdbi.vim
" Last Change: 2012-03-10
" Maintainer:  Yasuhiro Matsumoto <mattn.jp@gmail.com>
" License:     BSD style license
" Version:     0.01

command! -nargs=0 VDBI call vdbi#tables()
command! -nargs=+ VDBIExec call vdbi#execute(<q-args>)
command! -nargs=0 VDBIReset call vdbi#shutdown()
command! -nargs=0 VDBIDatasources call vdbi#show_datasources()
