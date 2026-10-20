local M={sessions={}}
local P=require("fanqie.parser")
local Align=require("fanqie.align")
local Store=require("fanqie.storage")
local API=require("fanqie.api")
local UI=require("fanqie.ui")
local TOC=require("fanqie.toc")
local ns=vim.api.nvim_create_namespace("fanqie.paragraphs")
local defaults={
  state_dir=vim.fn.stdpath("state").."/fanqie",
  cache_dir=vim.fn.stdpath("cache").."/fanqie",
  curl="curl",panel_width=52,paragraph_mode="line",chapter_pattern=nil,
  request_interval_ms=650,cache_ttl=3600,probe_limit=3,offline=false,
  keymaps=true,restore_position=true,
  follow_cursor=true,follow_delay_ms=350,hover_key="K",hover_width=64,hover_height=18,
}
local ctl={}
local enter_chapter,render_marks,load_comments,probe,show_at_cursor,schedule_cursor
local function notify(text,level) vim.notify(text,level or vim.log.levels.INFO,{title="fanqie.nvim"}) end
local function alive(s) return M.sessions[s.buf]==s and vim.api.nvim_buf_is_valid(s.buf) end
local function cancel_view(s)
  s.view_token=(s.view_token or 0)+1
  API.cancel(s.view_owner)
  s.loading=false; s.locating=false
  for _,state in pairs(s.replies or {}) do state.loading=false end
end
local function stop_cursor_timer(s)
  s.cursor_ticket=(s.cursor_ticket or 0)+1
  if s.cursor_timer then
    if not s.cursor_timer:is_closing() then s.cursor_timer:stop(); s.cursor_timer:close() end
    s.cursor_timer=nil
  end
end
local function configure_window(s,win)
  if not s.windows[win] then
    s.windows[win]={wrap=vim.wo[win].wrap,linebreak=vim.wo[win].linebreak}
  end
  if not s.windows[win].active then
    vim.wo[win].wrap=true; vim.wo[win].linebreak=true
    s.windows[win].active=true
  end
end
local function restore_window(s,win)
  local options=s.windows[win]
  if options and options.active and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].wrap=options.wrap; vim.wo[win].linebreak=options.linebreak
    options.active=false
  end
end
local function save(s)
  local ok,err=pcall(Store.write,s.path,s.book)
  if not ok then notify("阅读状态保存失败："..tostring(err),vim.log.levels.ERROR) end
end
local function chapter_key(ch) return vim.fn.sha256(ch.title) end
local function paragraph(s,line)
  for _,p in ipairs(s.paragraphs or {}) do if line>=p.line and line<=p.last then return p end end
end
local function source_line(s)
  if vim.api.nvim_win_is_valid(s.win) and vim.api.nvim_win_get_buf(s.win)==s.buf then
    return vim.api.nvim_win_get_cursor(s.win)[1]
  end
  return s.cursor or 1
end
local function ready(s)
  if not s.book.binding then notify("先用 :Fanqie bind 绑定书籍"); return false end
  if not s.remote then notify("当前章节尚未绑定，用 :Fanqie chapter 手动选择"); return false end
  return true
end
local function ordered(stats)
  local ids=vim.tbl_keys(stats)
  table.sort(ids,function(a,b) return (tonumber(a) or 0)<(tonumber(b) or 0) end)
  return ids
end
local function label(s)
  if not alive(s) then return end
  local mapped=vim.tbl_count(s.resolved or {})
  local all=#(s.stats_order or {})
  vim.b[s.buf].fanqie_status=(s.current and s.current.title or "")..(" · 段评 %d/%d"):format(mapped,all)
end
render_marks=function(s)
  if not alive(s) then return end
  vim.api.nvim_buf_clear_namespace(s.buf,ns,0,-1)
  s.resolved={}
  local by_line={}
  for id,mapping in pairs(s.mappings or {}) do
    local p=Align.resolve(s.paragraphs,mapping)
    if p and s.stats[id] then
      if not by_line[p.line] then by_line[p.line]={} end
      by_line[p.line][#by_line[p.line]+1]={id=id,p=p,mapping=mapping}
    end
  end
  for _,candidates in pairs(by_line) do
    -- Two remote paragraph IDs on one local paragraph require further calibration.
    if #candidates==1 then
      local c=candidates[1]; s.resolved[c.id]=c.p
      local count=tonumber(s.stats[c.id].count) or 0
      vim.api.nvim_buf_set_extmark(s.buf,ns,c.p.last-1,0,{
        virt_text={{(" 💬 %d%s"):format(count,c.mapping.method=="manual" and " [手动]" or ""),"DiagnosticInfo"}},
        virt_text_pos="eol",hl_mode="combine",right_gravity=false,
      })
    end
  end
  label(s); UI.render(s)
end
local function chapter_maps(s)
  if not s.remote then return {} end
  s.book.alignments=s.book.alignments or {}
  s.book.alignments[s.remote.id]=s.book.alignments[s.remote.id] or {}
  return s.book.alignments[s.remote.id]
end
local function accept_sources(s,id,page)
  local candidates={}
  for _,c in ipairs(page.comments or {}) do
    if tostring(c.para_index)==tostring(id) then
      local mapping=Align.record(s.paragraphs,c.para_src_content)
      if mapping then candidates[mapping.hash]=mapping end
    end
  end
  if vim.tbl_count(candidates)==1 then
    local _,mapping=next(candidates)
    -- A human correction wins over an automated quote match.
    if not s.mappings[id] or s.mappings[id].method~="manual" then
      s.mappings[id]=mapping; save(s); render_marks(s)
    end
  end
end
local function args_for(s,id,cursor)
  return {book=s.book.binding.id,chapter=s.remote.id,para=tonumber(id),cursor=cursor or "",sort=s.sort or 0}
end
probe=function(s,generation)
  if not alive(s) or generation~=s.generation or not s.remote then return end
  if s.loading or s.locating then return end
  s.probed=s.probed or {}
  local id
  -- Verify candidates with the most comments first; at most probe_limit per entry.
  local candidates=vim.deepcopy(s.stats_order or {})
  table.sort(candidates,function(a,b)
    local ca,cb=tonumber(s.stats[a].count) or 0,tonumber(s.stats[b].count) or 0
    if ca==cb then return tonumber(a)<tonumber(b) end
    return ca>cb
  end)
  if s.probe_count>=s.config.probe_limit then return end
  for _,candidate in ipairs(candidates) do
    if not s.probed[candidate] and not s.resolved[candidate] then id=candidate; break end
  end
  if not id then return end
  s.probed[id]=true; s.probe_count=s.probe_count+1
  local sort=s.sort
  API.request("comments",args_for(s,id),{owner=s.buf},function(data,err,meta)
    if not alive(s) or generation~=s.generation then return end
    if data then
      if s.sort==sort then
        data.cached=meta.cached; s.pages[id]=s.pages[id] or {}; s.pages[id][1]=data
      end
      accept_sources(s,id,data)
    end
    if err then s.error=err; UI.render(s); return end
    probe(s,generation)
  end)
end
local function refresh(s,force)
  if not ready(s) then return end
  local gen=s.generation
  s.error=nil; s.stats_error=nil; s.status="正在获取本章段评统计…"; UI.render(s)
  local function received(data,err,meta)
    if not alive(s) or gen~=s.generation then return end
    if err then
      s.error=err; s.stats_error=err; s.status="本地正文可正常阅读"
      if s.view and s.view.mode=="message" then s.view.text="段评统计获取失败，按 r 重试。" end
      UI.render(s); return
    end
    s.stats=data; s.stats_order=ordered(data); s.stats_ready=true
    s.status=meta.cached and "已载入段评统计缓存" or "已刷新本章段评统计"
    render_marks(s)
    if s.awaiting_cursor and show_at_cursor and (vim.api.nvim_get_current_buf()==s.buf
      or (s.panel and vim.api.nvim_get_current_buf()==s.panel.buf)) then
      local opts=s.awaiting_cursor; s.awaiting_cursor=nil
      show_at_cursor(s,opts)
    end
    if meta.cached and not s.config.offline and not force then
      API.request("stats",{chapter=s.remote.id},{owner=s.buf,force=true},received)
    else probe(s,gen) end
  end
  API.request("stats",{chapter=s.remote.id},{owner=s.buf,force=force,stale=true},received)
end
enter_chapter=function(s,ch,force)
  if s.current==ch and not force then return end
  API.cancel(s.buf)
  cancel_view(s)
  s.generation=s.generation+1
  s.current=ch; s.paragraphs=P.paragraphs(s.lines,ch,s.config.paragraph_mode)
  s.remote=nil; s.stats={}; s.stats_order={}; s.stats_ready=false
  s.resolved={}; s.mappings={}; s.pages={}; s.replies={}; s.sort=0
  s.view={mode="unknown"}; s.loading=false; s.status=nil; s.error=nil
  s.locating=false; s.stats_error=nil
  s.awaiting_cursor=nil; s.focus_key=nil
  s.probed={}; s.probe_count=0
  local saved=s.book.chapter_bindings and s.book.chapter_bindings[chapter_key(ch)]
  if saved then s.remote=saved
  elseif s.book.directory then s.remote=P.match_chapter(ch,s.book.directory) end
  s.mappings=chapter_maps(s)
  render_marks(s)
  if s.book.binding then
    if s.remote then refresh(s,false)
    else s.status="章节未匹配：用 :Fanqie chapter 手动绑定"; UI.render(s) end
  end
end
load_comments=function(s,id,page_no,force,opts)
  opts=opts or {}
  if not ready(s) then return end
  if s.loading then notify("请等待当前评论页加载完成"); return end
  id=tostring(id); page_no=page_no or 1
  s.view={mode="comments",para=id,page=page_no}
  s.pages[id]=s.pages[id] or {}
  local pages=s.pages[id]
  if pages[page_no] and not force then s.error=nil; UI.show(s,ctl,opts); return end
  local previous=pages[page_no-1]
  if page_no>1 and not previous then return end
  if page_no>1 and (not previous.has_more or previous.cursor=="") then notify("已到最后一页"); return end
  local gen,token=s.generation,s.view_token
  s.loading=true; s.error=nil; UI.show(s,ctl,opts)
  API.request("comments",args_for(s,id,previous and previous.cursor),{owner=s.view_owner,force=force},function(data,err,meta)
    if not alive(s) or gen~=s.generation or token~=s.view_token then return end
    s.loading=false
    if err then s.error=err
    elseif data then
      -- A cursor that does not advance must not create an infinite paging loop.
      if previous and data.cursor==previous.cursor then data.has_more=false end
      data.cached=meta.cached; pages[page_no]=data
      accept_sources(s,id,data)
    end
    UI.render(s)
    probe(s,gen)
  end)
end
function ctl.closed(s) cancel_view(s); s.awaiting_cursor=nil; stop_cursor_timer(s) end
function ctl.unknown(s,opts) s.view={mode="unknown"}; UI.show(s,ctl,opts) end
function ctl.reload(s)
  if s.view and s.view.mode=="comments" then
    local id=s.view.para; s.pages[id]={}; load_comments(s,id,1,true)
  else
    if s.view and s.view.mode=="message" and s.panel then
      s.awaiting_cursor={kind=s.panel.kind,focus=false,follow=s.panel.kind=="split"}
    end
    refresh(s,true)
  end
end
function ctl.page(s,delta)
  if s.view and s.view.mode=="comments" then
    load_comments(s,s.view.para,math.max(1,(s.view.page or 1)+delta))
  end
end
function ctl.sort(s)
  if not s.view or s.view.mode~="comments" then return end
  if s.loading then notify("请等待当前请求完成"); return end
  s.sort=s.sort==1 and 0 or 1; s.pages={}; s.replies={}
  load_comments(s,s.view.para,1)
end
local function replies(s,c,more)
  local id=tostring(c.comment_id)
  local state=s.replies[id]
  if state and not more then state.expanded=not state.expanded; UI.render(s); return end
  if not state then state={expanded=true,items={}}; s.replies[id]=state end
  if state.loading then return end
  state.loading=true; state.error=nil; UI.render(s)
  local gen,token=s.generation,s.view_token
  API.request("replies",{comment=id,cursor=state.cursor or ""},{owner=s.view_owner},function(data,err)
    if not alive(s) or gen~=s.generation or token~=s.view_token then return end
    state.loading=false
    if err then state.error=err
    elseif #data.comments==0 and (tonumber(c.reply_count) or 0)>0 and #state.items==0 then
      state.error="接口返回空回复，与评论回复数不符；Enter 收起，再 Enter 重试"
    else
      local seen={}
      for _,r in ipairs(state.items) do seen[tostring(r.reply_id)]=true end
      for _,r in ipairs(data.comments) do
        if not seen[tostring(r.reply_id)] then state.items[#state.items+1]=r; seen[tostring(r.reply_id)]=true end
      end
      state.has_more=data.has_more and data.cursor~=state.cursor
      state.cursor=data.cursor
    end
    UI.render(s)
  end)
end
function ctl.action(s,row)
  if row.kind=="paragraph" then load_comments(s,row.id,1)
  elseif row.kind=="comment" and (row.comment.reply_count or 0)>0 then
    local state=s.replies[tostring(row.comment.comment_id)]
    if state and state.error and not state.expanded then s.replies[tostring(row.comment.comment_id)]=nil end
    replies(s,row.comment,false)
  elseif row.kind=="reply_more" then replies(s,row.comment,true) end
end
function ctl.calibrate(s,explicit_id)
  if not ready(s) then return end
  local p=paragraph(s,source_line(s))
  if not p then notify("先把正文光标放到要绑定的段落"); return end
  local id=explicit_id or (s.view and s.view.mode=="comments" and s.view.para)
  if not id and s.panel and vim.api.nvim_get_current_win()==s.panel.win then
    local row=s.panel.rows[vim.api.nvim_win_get_cursor(s.panel.win)[1]]
    id=row and row.kind=="paragraph" and row.id or nil
  end
  if not id then
    vim.ui.select(s.stats_order,{prompt="绑定到当前正文段落的远端段号"},function(choice)
      if choice and alive(s) then ctl.calibrate(s,choice) end
    end)
    return
  end
  id=tostring(id)
  if not s.stats[id] then notify("当前统计中没有这个段号"); return end
  if not Align.resolve(s.paragraphs,{hash=p.hash}) then notify("这段文字在本章重复，暂不能唯一定位"); return end
  local gen=s.generation
  vim.ui.select({"确认绑定","取消"},{prompt=("段号 %s → 第 %d 行：%s"):format(id,p.line,vim.fn.strcharpart(p.text,0,45))},function(choice)
    if choice=="确认绑定" and alive(s) and gen==s.generation then
      for other,mapping in pairs(s.mappings) do if other~=id and mapping.hash==p.hash then s.mappings[other]=nil end end
      s.mappings[id]={hash=p.hash,method="manual"}; save(s); render_marks(s)
    end
  end)
end
local function current()
  local s=M.sessions[vim.api.nvim_get_current_buf()]
  if not s then
    for _,candidate in pairs(M.sessions) do
      if (candidate.panel and candidate.panel.buf==vim.api.nvim_get_current_buf())
        or (candidate.toc and candidate.toc.buf==vim.api.nvim_get_current_buf()) then s=candidate; break end
    end
  end
  if not s then notify("先在本地 TXT 中执行 :Fanqie enable") end
  return s
end
local function lookup_at_cursor(s,p,opts)
  opts=opts or {}
  if not p or not s.stats_ready or s.locating then ctl.unknown(s,opts); return end
  local index,positions
  positions={}
  for i,local_p in ipairs(s.paragraphs) do positions[local_p.line]=i; if local_p.line==p.line then index=i end end
  if not index then ctl.unknown(s,opts); return end
  -- Offsets generate a candidate request only. A returned quote must verify it.
  local candidate,distance=tostring(index-1),math.huge
  for id,anchor in pairs(s.resolved) do
    local anchor_index=positions[anchor.line]
    if anchor_index then
      local delta=index-anchor_index
      if math.abs(delta)<distance then candidate=tostring(tonumber(id)+delta); distance=math.abs(delta) end
    end
  end
  if not s.stats[candidate] then
    if opts.follow or opts.kind=="hover" then
      s.view={mode="message",text="当前段落尚未对齐；按 u 查看未对齐段评，或按 a 手动校准。"}
      UI.show(s,ctl,opts)
    else ctl.unknown(s,opts) end
    return
  end
  local gen,sort,token=s.generation,s.sort,s.view_token
  s.locating=true; s.status="正在核验当前段落的候选段评…"; s.error=nil
  s.view={mode="message",text="正在通过评论原文核验当前段落…"}; UI.show(s,ctl,opts)
  API.request("comments",args_for(s,candidate),{owner=s.view_owner},function(data,err,meta)
    if not alive(s) or gen~=s.generation or token~=s.view_token then return end
    s.locating=false
    if err then
      s.error=err; s.view={mode="message",text="段评获取失败，按 r 重试。"}; UI.render(s); return
    end
    if sort==s.sort then
      data.cached=meta.cached; s.pages[candidate]=s.pages[candidate] or {}; s.pages[candidate][1]=data
    end
    accept_sources(s,candidate,data)
    local resolved=s.resolved[candidate]
    if resolved and resolved.hash==p.hash then
      s.status="当前段落已通过原文核验"
      if paragraph(s,source_line(s))==p then load_comments(s,candidate,1,false,opts) else UI.render(s) end
    else
      s.status="候选段评与当前段落未能对齐，可从列表查看或手动校准"
      if opts.follow or opts.kind=="hover" then
        s.view={mode="message",text=s.status}; UI.render(s)
      else ctl.unknown(s,opts) end
    end
    probe(s,gen)
  end)
end
local function cursor_key(s)
  local line=source_line(s)
  local ch=P.at(s.chapters,line)
  local p=ch==s.current and paragraph(s,line) or nil
  return table.concat({ch.line,p and p.line or line,p and p.hash or ""},":")
end
show_at_cursor=function(s,opts)
  opts=opts or {kind="split",focus=true}
  stop_cursor_timer(s)
  local ch=P.at(s.chapters,source_line(s))
  if ch~=s.current then enter_chapter(s,ch) end
  local key=cursor_key(s)
  if opts.enter_existing and opts.kind=="hover" and s.panel and s.panel.kind=="hover" and s.focus_key==key
    and vim.api.nvim_win_is_valid(s.panel.win) then
    UI.show(s,ctl,{kind="hover",focus=true})
    return
  end
  cancel_view(s)
  s.focus_key=key; s.cursor_key=key; s.awaiting_cursor=nil; s.error=nil; s.status=nil
  local p=paragraph(s,source_line(s))
  local message
  if not s.book.binding then message="先执行 :Fanqie bind 绑定本地文件对应的书籍。"
  elseif not s.remote then message="当前章节尚未匹配；执行 :Fanqie chapter 手动绑定。"
  elseif not p then message="将光标移到正文段落查看段评。"
  elseif not s.stats_ready then
    message=s.stats_error and ("段评统计获取失败："..s.stats_error.."；按 r 重试。") or "正在获取本章段评统计…"
    if not s.stats_error then s.awaiting_cursor=vim.tbl_extend("force",opts,{enter_existing=false}) end
  end
  if message then
    s.view={mode="message",text=message}; UI.show(s,ctl,opts); return
  end
  local id
  for pid,local_p in pairs(s.resolved) do if local_p.line==p.line then id=pid; break end end
  if id then load_comments(s,id,1,false,opts) else lookup_at_cursor(s,p,opts) end
end
schedule_cursor=function(s)
  stop_cursor_timer(s)
  local key=cursor_key(s)
  if s.cursor_key~=key then
    s.cursor_key=key
    if s.panel and s.panel.kind=="hover" then UI.close(s) end
    if s.panel and s.panel.kind=="split" and s.config.follow_cursor then
      cancel_view(s); s.awaiting_cursor=nil; s.status=nil; s.error=nil
      s.view={mode="message",text="光标停留后加载当前段落的段评…"}; UI.render(s)
    end
  end
  local ticket=s.cursor_ticket
  local delay=s.panel and s.panel.kind=="split" and s.config.follow_cursor and s.config.follow_delay_ms or 200
  s.cursor_timer=vim.defer_fn(function()
    if not alive(s) or ticket~=s.cursor_ticket then return end
    s.cursor_timer=nil
    if vim.api.nvim_get_current_buf()~=s.buf then return end
    local ch=P.at(s.chapters,source_line(s))
    if ch~=s.current then enter_chapter(s,ch) end
    if s.panel and s.panel.kind=="split" and s.config.follow_cursor
      and (s.focus_key~=cursor_key(s) or s.view.mode=="message") then
      show_at_cursor(s,{kind="split",focus=false,follow=true})
    end
  end,delay)
end
function M.bind(s,query)
  s=s or current(); if not s then return end
  if not query or query=="" then
    vim.ui.input({prompt="搜索书名：",default=s.title},function(q) if q and q~="" and alive(s) then M.bind(s,q) end end)
    return
  end
  if s.config.offline then notify("书籍搜索需要联网；已有绑定可离线使用"); return end
  s.status="搜索书籍中…"; UI.render(s)
  local function search(offset)
    API.request("search",{query=query,offset=offset or 0},{owner=s.buf},function(data,err)
      if not alive(s) then return end
      if err then s.error=err; notify(err,vim.log.levels.ERROR); UI.render(s); return end
      local choices=vim.deepcopy(data.books)
      if data.has_more and data.offset then choices[#choices+1]={more=true,title="[下一页搜索结果]"} end
      vim.ui.select(choices,{prompt="确认本地 TXT 对应的书籍和作者",format_item=function(b)
        return b.more and b.title or (b.title.." / "..(b.author or "未知作者").." / "..b.id)
      end},function(book)
        if not book or not alive(s) then return end
        if book.more then search(data.offset); return end
        API.request("directory",{book=book.id},{owner=s.buf},function(directory,derr)
          if not alive(s) then return end
          if derr then s.error=derr; notify(derr,vim.log.levels.ERROR); UI.render(s); return end
          s.book.binding=book; s.book.directory=directory
          s.book.chapter_bindings={}; s.book.alignments={}
          save(s); enter_chapter(s,s.current,true)
          notify("已绑定："..book.title.." / "..book.author)
        end)
      end)
    end)
  end
  search(0)
end
local function bind_chapter(s)
  if not s.book.directory then notify("请先绑定书籍"); return end
  local gen=s.generation
  vim.ui.select(s.book.directory,{prompt="为「"..s.current.title.."」选择平台章节",format_item=function(ch) return ch.title end},function(ch)
    if ch and alive(s) and gen==s.generation then
      s.book.chapter_bindings=s.book.chapter_bindings or {}
      s.book.chapter_bindings[chapter_key(s.current)]=ch
      save(s); enter_chapter(s,s.current,true)
    end
  end)
end
local function jump(s,line)
  local win=vim.api.nvim_win_is_valid(s.win) and s.win or vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(win); vim.api.nvim_win_set_buf(win,s.buf); s.win=win
  vim.api.nvim_win_set_cursor(win,{math.min(line,vim.api.nvim_buf_line_count(s.buf)),0})
  vim.cmd("normal! zt")
  s.cursor=line; enter_chapter(s,P.at(s.chapters,line))
end
local function position(s)
  if not alive(s) then return end
  local line=source_line(s)
  local p=paragraph(s,line)
  s.book.position={line=line,chapter=s.current.title,paragraph_hash=p and p.hash,
    text=vim.fn.sha256(P.normalize(s.lines[line] or ""))}
  save(s)
end
function M.enable(buf)
  if not M.config then M.setup() end
  buf=buf or vim.api.nvim_get_current_buf()
  if M.sessions[buf] then return M.sessions[buf] end
  local name=vim.api.nvim_buf_get_name(buf)
  if name=="" or vim.bo[buf].buftype~="" then notify("请在已命名的本地 TXT buffer 中启用"); return end
  local lines=vim.api.nvim_buf_get_lines(buf,0,-1,false)
  local canonical=vim.uv.fs_realpath(name) or name
  local path=vim.fs.joinpath(M.config.state_dir,"books",vim.fn.sha256(canonical)..".json")
  local book,err=Store.read(path)
  if err then notify(err,vim.log.levels.ERROR); return end
  book=book or {schema=1,file=canonical,bookmarks={}}
  local s={buf=buf,win=vim.api.nvim_get_current_win(),lines=lines,path=path,book=book,config=M.config,
    chapters=P.parse(lines,M.config),title=vim.fn.fnamemodify(name,":t:r"),generation=0,cursor=1,windows={},
    view_owner="fanqie:view:"..buf,view_token=0}
  M.sessions[buf]=s
  vim.b[buf].fanqie_enabled=true
  configure_window(s,s.win)
  local line=vim.api.nvim_win_get_cursor(s.win)[1]
  if M.config.restore_position and book.position then
    local pos=book.position
    if pos.line<=#lines and vim.fn.sha256(P.normalize(lines[pos.line] or ""))==pos.text then line=pos.line
    else
      local matches={}
      for i,text in ipairs(lines) do if vim.fn.sha256(P.normalize(text))==pos.text then matches[#matches+1]=i end end
      if #matches==1 then line=matches[1] end
    end
    vim.api.nvim_win_set_cursor(s.win,{line,0})
  end
  s.cursor=line; enter_chapter(s,P.at(s.chapters,line))
  local group=vim.api.nvim_create_augroup("FanqieBuffer"..buf,{clear=true}); s.group=group
  vim.api.nvim_create_autocmd("CursorMoved",{group=group,buffer=buf,callback=function()
    if not alive(s) then return end
    s.win=vim.api.nvim_get_current_win(); configure_window(s,s.win)
    s.cursor=vim.api.nvim_win_get_cursor(s.win)[1]
    schedule_cursor(s)
  end})
  vim.api.nvim_create_autocmd("BufLeave",{group=group,buffer=buf,callback=function()
    position(s); stop_cursor_timer(s)
    local panel=s.panel
    vim.schedule(function()
      if alive(s) and s.panel==panel and panel and panel.kind=="hover"
        and vim.api.nvim_get_current_buf()~=s.buf and vim.api.nvim_get_current_buf()~=panel.buf then UI.close(s) end
    end)
  end})
  vim.api.nvim_create_autocmd("BufEnter",{group=group,buffer=buf,callback=function()
    if alive(s) then s.win=vim.api.nvim_get_current_win(); schedule_cursor(s) end
  end})
  vim.api.nvim_create_autocmd("BufWinLeave",{group=group,buffer=buf,callback=function()
    position(s); restore_window(s,vim.api.nvim_get_current_win())
  end})
  vim.api.nvim_create_autocmd("BufWinEnter",{group=group,buffer=buf,callback=function()
    if alive(s) then s.win=vim.api.nvim_get_current_win(); configure_window(s,s.win) end
  end})
  vim.api.nvim_create_autocmd({"BufWipeout","BufDelete"},{group=group,buffer=buf,callback=function() M.disable(buf) end})
  vim.api.nvim_create_autocmd({"TextChanged","TextChangedI","BufWritePost"},{group=group,buffer=buf,callback=function()
    if not alive(s) then return end
    s.lines=vim.api.nvim_buf_get_lines(buf,0,-1,false); s.chapters=P.parse(s.lines,s.config)
    if s.panel and s.panel.kind=="hover" then UI.close(s) end
    enter_chapter(s,P.at(s.chapters,source_line(s)),true)
    schedule_cursor(s)
  end})
  if M.config.keymaps then
    local keys={
      {"<leader>Fc","comments","查看段评"},{"<leader>Fu","unmatched","未对齐段评"},
      {"<leader>Ft","toc","章节目录"},{"<leader>Fn","next","下一章"},
      {"<leader>Fp","prev","上一章"},{"<leader>Fm","bookmark","添加书签"},
      {"<leader>Fb","bookmarks","书签列表"},
      {"<leader>Fh","hover","段评悬浮预览"},
    }
    s.keys={}
    for _,item in ipairs(keys) do
      if vim.fn.maparg(item[1],"n")=="" then
        vim.keymap.set("n",item[1],function() M.command(item[2]) end,{buffer=buf,desc="番茄："..item[3]})
        s.keys[#s.keys+1]=item[1]
      end
    end
    if s.config.hover_key then
      local existing=vim.fn.maparg(s.config.hover_key,"n",false,true)
      if existing.buffer~=1 then
        vim.keymap.set("n",s.config.hover_key,function() M.command("hover") end,
          {buffer=buf,desc="番茄：段评悬浮预览"})
        s.keys[#s.keys+1]=s.config.hover_key
      end
    end
  end
  notify("本地阅读已启用 · "..#s.chapters.." 个章节 · :Fanqie bind 绑定段评")
  return s
end
function M.disable(buf)
  local s=M.sessions[buf or vim.api.nvim_get_current_buf()]; if not s then return end
  position(s); stop_cursor_timer(s); cancel_view(s); API.cancel(s.buf); TOC.close(s,false); UI.close(s,true)
  if s.group then pcall(vim.api.nvim_del_augroup_by_id,s.group) end
  if vim.api.nvim_buf_is_valid(s.buf) then
    vim.api.nvim_buf_clear_namespace(s.buf,ns,0,-1)
    vim.b[s.buf].fanqie_enabled=nil; vim.b[s.buf].fanqie_status=nil
    for _,key in ipairs(s.keys or {}) do pcall(vim.keymap.del,"n",key,{buffer=s.buf}) end
  end
  for win in pairs(s.windows) do restore_window(s,win) end
  M.sessions[s.buf]=nil
end
local commands={"enable","disable","bind","chapter","comments","hover","unmatched","calibrate","uncalibrate",
  "toc","next","prev","bookmark","bookmarks","unbookmark","refresh","offline","online","status"}
function M.command(command)
  local args=vim.split(command or "", "%s+",{trimempty=true}); local action=args[1] or "enable"
  if action=="enable" then M.enable(); return end
  local s=current(); if not s then return end
  if action=="disable" then M.disable(s.buf)
  elseif action=="bind" then M.bind(s,table.concat(args," ",2))
  elseif action=="chapter" then bind_chapter(s)
  elseif action=="comments" then
    show_at_cursor(s,{kind="split",focus=true})
  elseif action=="hover" then show_at_cursor(s,{kind="hover",focus=false,enter_existing=true})
  elseif action=="unmatched" then ctl.unknown(s)
  elseif action=="calibrate" then ctl.calibrate(s,args[2])
  elseif action=="uncalibrate" then
    local p=paragraph(s,source_line(s))
    for id,mapping in pairs(s.mappings) do if p and mapping.hash==p.hash then s.mappings[id]=nil end end
    save(s); render_marks(s)
  elseif action=="refresh" then refresh(s,true)
  elseif action=="toc" then
    TOC.open(s,function(ch) if alive(s) then jump(s,ch.line) end end)
  elseif action=="next" or action=="prev" then
    local index=s.current.index+(action=="next" and 1 or -1)
    if s.chapters[index] then jump(s,s.chapters[index].line) else notify("已到本地文件的章节边界") end
  elseif action=="bookmark" then
    local line=source_line(s)
    vim.ui.input({prompt="书签名称：",default=s.current.title},function(name)
      if not name or not alive(s) then return end
      s.book.bookmarks=s.book.bookmarks or {}
      s.book.bookmarks[#s.book.bookmarks+1]={name=name,line=line,text=P.normalize(s.lines[line] or ""),chapter=s.current.title}
      save(s); notify("书签已保存")
    end)
  elseif action=="bookmarks" or action=="unbookmark" then
    vim.ui.select(s.book.bookmarks or {},{prompt=action=="bookmarks" and "跳转书签" or "删除书签",format_item=function(b)
      return b.name.." · "..b.chapter.." · 第 "..b.line.." 行"
    end},function(b,index)
      if not b or not alive(s) then return end
      if action=="unbookmark" then table.remove(s.book.bookmarks,index); save(s); return end
      if P.normalize(s.lines[b.line] or "")==b.text then jump(s,b.line); return end
      local matches={}
      for i,text in ipairs(s.lines) do if P.normalize(text)==b.text then matches[#matches+1]=i end end
      if #matches==1 then jump(s,matches[1]) else notify("文件已变化，无法唯一定位此书签",vim.log.levels.WARN) end
    end)
  elseif action=="offline" or action=="online" then
    M.config.offline=action=="offline"
    for _,session in pairs(M.sessions) do
      API.cancel(session.buf); cancel_view(session); session.generation=session.generation+1
      session.awaiting_cursor=nil
      for _,state in pairs(session.replies) do state.loading=false end
      session.status=M.config.offline and "离线模式" or "在线模式"; UI.render(session)
    end
    notify(M.config.offline and "已切换到离线模式" or "已切换到在线模式；:Fanqie refresh 刷新")
  elseif action=="status" then
    notify((s.book.binding and (s.book.binding.title.." / "..s.book.binding.author) or "书籍未绑定")
      .."\n"..s.current.title.."\n已对齐 "..vim.tbl_count(s.resolved).." / "..#s.stats_order.." 个有评论段落"
      .."\n"..(M.config.offline and "离线" or "在线")..(s.error and "\n"..s.error or ""))
  else notify("未知子命令："..action,vim.log.levels.WARN) end
end
function M.setup(opts)
  if next(M.sessions) then error("请先 :Fanqie disable，再更改 setup 配置") end
  M.config=vim.tbl_deep_extend("force",vim.deepcopy(defaults),opts or {})
  vim.g.loaded_fanqie=true
  assert(M.config.paragraph_mode=="line" or M.config.paragraph_mode=="blank","paragraph_mode 必须为 line 或 blank")
  assert(type(M.config.request_interval_ms)=="number" and M.config.request_interval_ms>=0,"无效请求间隔")
  assert(type(M.config.follow_delay_ms)=="number" and M.config.follow_delay_ms>=0,"无效光标跟随延迟")
  assert(M.config.hover_key==false or (type(M.config.hover_key)=="string" and M.config.hover_key~=""),"hover_key 必须为按键字符串或 false")
  assert(type(M.config.hover_width)=="number" and M.config.hover_width>=1
    and type(M.config.hover_height)=="number" and M.config.hover_height>=1,"无效悬浮窗尺寸")
  API.setup(M.config)
  vim.api.nvim_create_user_command("Fanqie",function(cmd) M.command(cmd.args) end,{nargs="*",complete=function(lead)
    return vim.tbl_filter(function(c) return c:sub(1,#lead)==lead end,commands)
  end,desc="本地 TXT 阅读与番茄段评"})
  local group=vim.api.nvim_create_augroup("FanqieLifecycle",{clear=true})
  vim.api.nvim_create_autocmd("VimLeavePre",{group=group,callback=function()
    for _,s in pairs(M.sessions) do position(s); stop_cursor_timer(s); cancel_view(s); API.cancel(s.buf) end
  end})
  vim.api.nvim_create_autocmd("FocusLost",{group=group,callback=function()
    for _,s in pairs(M.sessions) do position(s) end
  end})
end
return M
