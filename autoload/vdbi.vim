" vdbi.vim
" Last Change: 2012-03-08
" Maintainer:   Yasuhiro Matsumoto <mattn.jp@gmail.com>
" License:      BSD style license

let s:save_cpo = &cpo
set cpo&vim

let s:uri = 'http://localhost:9876/'
let s:vdbi = webapi#jsonrpc#wrap([
\ {'uri': s:uri, 'name': 'connect',          'argnames': ['data_source', 'username', 'auth']},
\ {'uri': s:uri, 'name': 'do',               'argnames': ['sql', 'params']},
\ {'uri': s:uri, 'name': 'select_all',       'argnames': ['sql', 'params']},
\ {'uri': s:uri, 'name': 'prepare',          'argnames': ['sql']},
\ {'uri': s:uri, 'name': 'execute',          'argnames': ['params']},
\ {'uri': s:uri, 'name': 'fetch',            'argnames': ['num']},
\ {'uri': s:uri, 'name': 'disconnect',       'argnames': []},
\ {'uri': s:uri, 'name': 'type_info_all',    'argnames': []},
\ {'uri': s:uri, 'name': 'status',           'argnames': []},
\ {'uri': s:uri, 'name': 'fetch_columns',    'argnames': []},
\ {'uri': s:uri, 'name': 'table_info',       'argnames': ['catalog', 'schema', 'table', 'type']},
\ {'uri': s:uri, 'name': 'column_info',      'argnames': ['catalog', 'schema', 'table', 'column']},
\ {'uri': s:uri, 'name': 'primary_key_info', 'argnames': ['catalog', 'schema', 'table']},
\ {'uri': s:uri, 'name': 'foreign_key_info', 'argnames': ['pkcatalog', 'pkschema', 'pktable', 'fkcatalog', 'fkschema', 'fktable']},
\])

let s:hist_file = expand('~/.vdbi_history')
let s:perl_file = expand('<sfile>:h') . '/app.psgi'

let s:history = get(s:, 'history', {"datasource":[], "sql":[]})
let s:datasource = get(s:, 'datasource', '')
let s:start_server = get(s:, 'start_server', 0)

let s:null = function('webapi#json#null')
let s:driver_param = {
\  'sqlite' : {
\    'data_sql' : 'select * from %table% limit %limit%',
\    'table_info_args' : [s:null, s:null, s:null, s:null],
\    'column_info_args' : [s:null, s:null, s:null, s:null],
\  },
\  'mysql' : {
\    'data_sql' : 'select * from %table% limit %limit%',
\    'table_info_args' : [s:null, s:null, s:null, s:null],
\    'column_info_args' : [s:null, s:null, s:null, '%'],
\  },
\  'pg' : {
\    'data_sql' : 'select * from %table% limit %limit%',
\    'table_info_args' : [s:null, s:null, s:null, s:null],
\    'column_info_args' : [s:null, s:null, s:null, s:null],
\  },
\  'oracle' : {
\    'data_sql' : 'select * from %table% where rownum <= %limit%',
\    'table_info_args' : [s:null, s:null, s:null, s:null],
\    'column_info_args' : [s:null, s:null, s:null, '%'],
\  },
\}

if empty(s:history.datasource) && filereadable(s:hist_file)
  let s:history = eval(join(readfile(s:hist_file), ''))
endif

function! s:get_field_value(name)
  let title = getline(3)
  let pos1 = stridx(title, ' '.a:name.' ')
  if pos1 == -1 | return '' | endif
  let pos2 = stridx(title, '|', pos1)
  if pos2 == -1 | return '' | endif
  let data = strpart(getline('.'), pos1 + 1, pos2 - pos1 - 2)
  return matchstr(data, '\v^\s*\zs.{-}\ze\s*$')
endfunction

function! s:do_tab(dir)
  if line('.') > 4 && getline('.') =~ '^|'
    let title = getline(3)
    let pos = getpos('.')
    if a:dir > 0
      let next = stridx(title, '|', col('.')-1)
      if next == -1 | return | endif
      if next + 1 >= len(title)
        let pos[1] += 1
        let pos[2] = 2
      else
        let pos[2] = next + 2
      endif
    else
      let prev = strridx(title, '|', col('.')-1)
      let prev = strridx(title, '|', prev-1)
      if prev == -1
        if pos[1] > 5
          let pos[1] -= 1
        endif
        let pos[2] = strridx(title, '|', len(title) - 2) + 2
      else
        let pos[2] = prev + 2
      endif
    endif
    call setpos('.', pos)
  endif
endfunction

function! s:do_yank()
  if line('.') > 4 && getline('.') =~ '^|'
    let title = getline(3)
    let pos0 = col('.')-1
    let pos1 = strridx(title, '|', pos0)
    if pos1 == -1 || pos1 == pos0 | return | endif
    let pos2 = stridx(title, '|', pos1 + 1)
    if pos2 == -1 | return | endif
    let data = strpart(getline('.'), pos1 + 2, pos2 - pos1 - 3)
    let data = matchstr(data, '\v^\s*\zs.{-}\ze\s*$')
    if exists('g:vdbi_clip_command')
      call system(g:vdbi_clip_command, data)
    elseif has('unix') && !has('xterm_clipboard')
      let @" = data
    else
      let @+ = data
    endif
    call s:message('Yanked')
  endif
endfunction

function! s:do_select()
  if b:type == 'tables' && line('.') > 4 && getline('.') =~ '^|'
    let title = getline(3)
    let schem = s:get_field_value('TABLE_SCHEM')
    let table = s:get_field_value('TABLE_NAME')
    let sql = s:get_driver_params('data_sql')
    let sql = substitute(sql, '%table%', schem.'.'.table, 'g')
    let sql = substitute(sql, '%limit%', get(g:, 'vdbi_data_count', 50), 'g')
    call vdbi#execute(sql)
  endif
endfunction

function! s:do_action()
  if b:type == 'tables' && line('.') > 4 && getline('.') =~ '^|'
    let title = getline(3)
    let schem = s:get_field_value('TABLE_SCHEM')
    let table = s:get_field_value('TABLE_NAME')
    call vdbi#columns(schem, table)
  endif
endfunction

function! s:do_hide()
  if b:type == 'columns'
    call vdbi#tables()
  elseif b:type == 'query'
    "call vdbi#tables()
    hide
  else
    hide
  endif
endfunction

function! s:do_history()
  let sql = input('History: ', '', 'customlist,vdbi#sql_history')
  if len(sql) > 0
    silent %d _
    silent put! =sql
  endif
endfunction

function! s:do_query()
  let sql = join(getline(1, line('$')))
  if vdbi#execute(sql) == 0
    if index(s:history.sql, sql) == -1
      call add(s:history.sql, sql)
      if len(s:history.sql) >= 10
        let s:history.sql = s:history.sql[-10:]
      endif
      call writefile([string(s:history)], s:hist_file)
    endif
    bw!
  endif
endfunction

function! s:do_sql()
  if !bufexists('[VDBI:Query]')
    silent botright 5split
    silent edit `='[VDBI:Query]'`
    setlocal bufhidden=wipe buftype=nofile noswapfile nobuflisted
    setlocal filetype=sql conceallevel=3 concealcursor=nvic
    nnoremap <buffer> <silent> q :bw!<cr>
    inoremap <buffer> <silent> <c-e> <esc>:call <SID>do_query()<cr>
    nnoremap <buffer> <silent> <leader>e <esc>:call <SID>do_query()<cr>
    nnoremap <buffer> <silent> <leader>r <esc>:call <SID>do_history()<cr>
  else
    execute bufwinnr('VDBI:Query').'wincmd w'
  endif
  startinsert
endfunction

function! s:cursor_moved()
  let l = line('.')
  if l > 4
    setlocal cursorline
  else
    setlocal nocursorline
  endif
endfunction

function! vdbi#clear_view()
  if bufexists('[VDBI:View]')
    silent! execute bufwinnr('VDBI:View').'wincmd w'
    if &ft != 'vdbi'
      silent 10split
    endif
    silent edit `='[VDBI:View]'`
    setlocal modifiable nocursorline
    silent %d _
    setlocal nomodifiable
  endif
endfunction

function! vdbi#open_view(typ, label, rows)
  if !bufexists('[VDBI:View]')
    silent 10split
    silent edit `='[VDBI:View]'`
    setlocal bufhidden=hide buftype=nofile noswapfile nobuflisted
    setlocal filetype=vdbi conceallevel=3 concealcursor=nvic
    setlocal nowrap nonumber nolist
    auto CursorMoved <buffer> call s:cursor_moved()
    auto BufWipeout <buffer> call vdbi#shutdown()
    hi def link VdbiDataSetSep Ignore
    hi link VdbiDataSet SpecialKey
    hi link VdbiHeader Title
    hi link VdbiStatement Statement
    hi link VdbiLabel Type
    nnoremap <buffer> <silent> q :call <SID>do_hide()<cr>
    nnoremap <buffer> <silent> <cr> :call <SID>do_action()<cr>
    nnoremap <buffer> <silent> <leader>s :call <SID>do_sql()<cr>
    nnoremap <buffer> <silent> <leader>d :call <SID>do_select()<cr>
    nnoremap <buffer> <silent> <leader>y :call <SID>do_yank()<cr>
    nnoremap <buffer> <silent> <tab> :call <SID>do_tab(1)<cr>
    nnoremap <buffer> <silent> <s-tab> :call <SID>do_tab(-1)<cr>
  else
    silent execute bufwinnr('VDBI:View').'wincmd w'
    if &ft != 'vdbi'
      silent 10split
    endif
    silent edit `='[VDBI:View]'`
  endif
  let b:type = a:typ
  setlocal modifiable
  silent %d _
  syntax clear

  let lines = s:datasource . "\n"
  let lines .= "> " . a:label . "\n"
  let rows = a:rows
  if type(rows) == 3 && len(rows) > 1000
    let ans = confirm(printf('%d records exists.', len(rows)), join([
    \ "&1 Keep it up.",
    \ "&2 Truncate to 1000 records.",
    \ "&3 Discard results."], "\n"), 1)
    if ans == 2
      let rows = rows[0:999]
      call s:message('Tuncated to 1000 records.')
    elseif ans == 3
      unlet rows
      let rows = 'Canceled.'
    endif
  endif
  if type(rows) == 3
    let rows = s:fill_columns(rows)
    for c in rows[0]
      exe printf('syntax match VdbiDataSet "\%%>%dc|" contains=VdbiDataSetSep', len(c))
    endfor
    syntax match VdbiDataSet "^|" contains=VdbiDataSetSep
    syntax match VdbiDataSet "|$" contains=VdbiDataSetSep
    syntax match VdbiDataSet "^|[-+]\+|$" contains=VdbiDataSetSep
    syntax match VdbiHeader "^\w.*"
    syntax match VdbiLabel /^>\ze/
    syntax match VdbiStatement /^> \(.\+\)/hs=s+2 contains=VdbiLabel
    let lines .= "|" . join(rows[0], "|") . "|\n"
    let lines .= "|" . join(map(copy(rows[0]), 'repeat("-", len(v:val))'), '+') . "|\n"
    for row in rows[1:]
      let lines .= "|" . join(row, "|") . "|\n"
    endfor
  else
    syntax match VdbiHeader "^\w.*"
    syntax match VdbiLabel /^>\ze/
    syntax match VdbiStatement /^> \(.\+\)/hs=s+2 contains=VdbiLabel
    let lines .= rows
  endif
  silent put! =lines
  normal! Gddgg
  setlocal nomodifiable
  redraw! | echo
endfunction

function! s:error(msg)
  redraw | echohl ErrorMsg | echo a:msg | echohl None
endfunction

function! s:message(msg)
  redraw | echohl Title | echo a:msg | echohl None
endfunction

function! vdbi#show_error()
  try
    let err = s:vdbi.status()
  catch
    let err = ''
  endtry
  if type(err) == 3
    if type(err[1]) == 1 && err[1] != ''
      call s:error(err[1])
    else
      " TODO: MySQL don't raise error.
      call s:message('Something wrong: ' . string(err))
    endif
  else
    call s:error('Someting wrong: ' . string(err))
  endif
endfunction

function! vdbi#shutdown()
  if s:start_server == 1
    if get(g:, 'vdbi_use_external_server', 0) == 0
      try
        call webapi#http#get(s:uri . 'shutdown')
      catch
      endtry
    endif
  endif
  let s:datasource = ''
endfunction

function! vdbi#sql_history(...)
  return filter(reverse(deepcopy(s:history.sql)), 'len(v:val)>0')
endfunction

function! vdbi#datasource_history(...)
  return map(reverse(deepcopy(s:history.datasource)), 'v:val[0]')
endfunction

function! vdbi#show_datasources()
  if len(s:datasource) > 0
    call vdbi#shutdown()
  endif

  if !bufexists('[VDBI:Datasources]')
    silent botright 5split
    silent edit `='[VDBI:Datasources]'`
    setlocal bufhidden=wipe buftype=nofile noswapfile nobuflisted
    setlocal filetype=vdbi conceallevel=3 concealcursor=nvic
    setlocal nowrap
    nnoremap <buffer> <silent> q :bw!<cr>
    nnoremap <buffer> <silent> <cr> :call <SID>startup_vdbi_from_history()<cr>
    hi link VdbiHeader Title
    syntax match VdbiHeader "^\w.*"
    let datasources = vdbi#datasource_history()
    for datasource in datasources
      silent! execute 'normal! O' . datasource
    endfor
    silent! execute 'normal! Gddgg'
    setlocal nomodifiable
  else
    call vdbi#tables()
  endif
endfunction

function! s:startup_vdbi_from_history()
  let datasource = getline('.')
  hide
  if !s:startup_vdbi(datasource) | return | endif
  call s:tables()
endfunction

function! s:startup_vdbi(...)
  if len(s:datasource) == 0
    let history_datasource = ''
    if a:0 > 0
      let history_datasource = a:1
    endif

    if history_datasource == ''
      if s:datasource == '' | let s:datasource = input('DataSource: ', '', 'customlist,vdbi#datasource_history') | endif
      if len(s:datasource) == 0 | return 0 | endif
      let i = index(map(deepcopy(s:history.datasource), 'v:val[0]'), s:datasource)
      if i != -1
        let username = s:history.datasource[i][1]
        let password = s:history.datasource[i][2]
      else
        let [username, password] = ['', '']
      endif
      let username = input('Username: ', username)
      let password = inputsecret('Password: ', password)
    else
      let s:datasource = history_datasource
      let i = index(map(deepcopy(s:history.datasource), 'v:val[0]'), s:datasource)
      let username = s:history.datasource[i][1]
      let password = s:history.datasource[i][2]
    endif

    try
      augroup VDBI
        au!
        auto VimLeavePre * call vdbi#shutdown()
      augroup END
      call s:message('Connecting to server...')
      if get(g:, 'vdbi_use_external_server', 0) == 0
        let s:start_server = 1
        let port = str2nr(matchlist(s:uri, '^https\?://\%([^:]\+:\(\d\+\)\|.*\)')[1])
        let port = port ? port : 80
        if has('win32') || has('win64')
          silent exe '!start /b plackup --port '.port.' '.shellescape(s:perl_file)
        else
          silent exe '!plackup --port '.port.' '.shellescape(s:perl_file).' > /dev/null 2>&1 > /dev/null &'
        endif
        exe "sleep" get(g:, 'vdbi_server_wait', 2)
      endif
      call s:vdbi.connect(s:datasource, username, password)
      if index(map(deepcopy(s:history.datasource), 'v:val[0]'), s:datasource) == -1
        if get(g:, 'vdbi_store_password_in_history', 1) == 0
          let password = ''
        endif
        call add(s:history.datasource, [s:datasource, username, password])
        if len(s:history.datasource) >= 10
          let s:history.datasource = s:history.datasource[-10:]
        endif
        call writefile([string(s:history)], s:hist_file)
      endif
    catch
      let s:datasource = ''
      call s:error(v:exception)
      return 0
    endtry
  endif
  return 1
endfunction

function! s:fill_columns(rows)
  let rows = a:rows
  if type(rows) != 3 || type(rows[0]) != 3
    call s:error('Failed to execute query')
    return [[]]
  endif
  let cols = len(rows[0])
  for c in range(cols)
    let m = 0
    let w = range(len(rows))
    for r in range(len(w))
      if type(rows[r][c]) == 2
        let s = string(rows[r][c])
        if s == "function('webapi#json#null')"
          let rows[r][c] = 'NULL'
        elseif s == "function('webapi#json#true')"
          let rows[r][c] = 'true'
        elseif s == "function('webapi#json#false')"
          let rows[r][c] = 'false'
        endif
      endif
      let w[r] = strdisplaywidth(rows[r][c])
      let m = max([m, w[r]])
    endfor
    for r in range(len(w))
      let rows[r][c] = ' ' . rows[r][c] . repeat(' ', m - w[r]) . ' '
    endfor
  endfor
  return rows
endfunction

function! s:get_driver_params(cat)
  let token = split(s:datasource, ':')
  if len(token) > 2
    let driver = tolower(token[1])
    if has_key(s:driver_param, driver) && has_key(s:driver_param[driver], a:cat)
      return s:driver_param[driver][a:cat]
    endif
  endif
  throw "Unknown driver"
endfunction

function! vdbi#columns(scheme, table)
  if !s:startup_vdbi() | return | endif

  call vdbi#clear_view()
  call s:message('Listing column infomations...')

  let old_allow_null = get(g:, 'webapi#json#allow_null', 0)
  try
    let g:webapi#json#allow_null = 1
    let param = s:get_driver_params('column_info_args')
    let param[1] = a:scheme
    let param[2] = a:table
    let rows = call(s:vdbi['column_info'], param, s:vdbi)
    let rows = extend([rows[0]], rows[1])
  catch
    let rows = 0
  finally
    let g:webapi#json#allow_null = old_allow_null
  endtry

  if type(rows) != 3
    call vdbi#show_error()
  else
    call vdbi#open_view('columns', 'columns', rows)
  endif
endfunction

function! vdbi#tables()
  if !s:startup_vdbi() | return | endif
  call s:tables()
endfunction

function! s:tables()
  call vdbi#clear_view()
  call s:message('Listing table infomations...')

  let old_allow_null = get(g:, 'webapi#json#allow_null', 0)
  try
    let g:webapi#json#allow_null = 1
    let param = s:get_driver_params('table_info_args')
    let rows = call(s:vdbi['table_info'], param, s:vdbi)
    let rows = extend([rows[0]], rows[1])
  catch
    let rows = 0
  finally
    let g:webapi#json#allow_null = old_allow_null
  endtry

  if type(rows) != 3
    call vdbi#show_error()
  else
    call vdbi#open_view('tables', 'tables', rows)
  endif
endfunction

function! vdbi#execute(query)
  if !s:startup_vdbi() | return 0 | endif

  call vdbi#clear_view()
  call s:message('Executing query...')

  let old_allow_null = get(g:, 'webapi#json#allow_null', 0)
  try
    let g:webapi#json#allow_null = 1
    call s:vdbi.prepare(a:query)
    let res = s:vdbi.execute([])
    let cols = s:vdbi.fetch_columns()
    let rows = s:vdbi.fetch(-1)
    if len(cols)
      let rows = extend([cols], rows)
    endif
  catch
    if exists('l:rows') | unlet rows | endif
    let rows = 0
  finally
    let g:webapi#json#allow_null = old_allow_null
  endtry

  if type(rows) != 3
    call vdbi#show_error()
  elseif len(rows) > 0
    call vdbi#open_view('query', a:query, rows)
  else
    call vdbi#open_view('query', a:query, printf("%d rows affected.", res))
  endif
  return 1
endfunction

" vim:set et:
