local M = {}
local ns=vim.api.nvim_create_namespace("fanqie.panel")
local function clean(text)
  return (tostring(text or ""):gsub("%c",function(c) return c=="\n" and c or " " end))
end
function M.close(s,quiet)
  local panel=s.panel
  s.panel=nil
  if panel and vim.api.nvim_win_is_valid(panel.win) then vim.api.nvim_win_close(panel.win,true) end
  if panel and not quiet and panel.ctl.closed then panel.ctl.closed(s) end
end
function M.show(s,ctl,opts)
  opts=opts or {}
  local kind=opts.kind or (s.panel and s.panel.kind) or "split"
  if s.panel and s.panel.kind~=kind then M.close(s,true) end
  if s.panel and vim.api.nvim_win_is_valid(s.panel.win) then
    M.render(s)
    if opts.focus~=false then vim.api.nvim_set_current_win(s.panel.win) end
    return
  end
  local origin=vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(s.win) then vim.api.nvim_set_current_win(s.win) end
  local source_win=vim.api.nvim_get_current_win()
  local buf=vim.api.nvim_create_buf(false,true)
  local config
  if kind=="hover" then
    config={relative="cursor",row=1,col=0,style="minimal",border="rounded",title=" 段评 · K 进入 · q 关闭 ",
      width=math.max(1,math.min(s.config.hover_width,vim.o.columns-4)),
      height=math.max(1,math.min(s.config.hover_height,vim.o.lines-vim.o.cmdheight-4))}
  else config={split="right",win=source_win,width=s.config.panel_width} end
  local win=vim.api.nvim_open_win(buf,opts.focus~=false,config)
  s.win=source_win
  vim.api.nvim_buf_set_name(buf,"fanqie://comments/"..s.buf.."/"..buf)
  vim.bo[buf].buftype="nofile"; vim.bo[buf].bufhidden="wipe"; vim.bo[buf].swapfile=false
  vim.bo[buf].filetype="fanqie"
  vim.wo[win].wrap=true; vim.wo[win].linebreak=true; vim.wo[win].number=false
  vim.wo[win].relativenumber=false; vim.wo[win].signcolumn="no"; vim.wo[win].conceallevel=0
  local panel={buf=buf,win=win,rows={},kind=kind,ctl=ctl}
  s.panel=panel
  vim.api.nvim_create_autocmd("BufWipeout",{buffer=buf,once=true,callback=function()
    if s.panel==panel then
      s.panel=nil
      if ctl.closed then ctl.closed(s) end
    end
  end})
  local function map(key,fn,desc) vim.keymap.set("n",key,fn,{buffer=buf,silent=true,desc=desc}) end
  map("q",function() M.close(s) end,"关闭段评")
  if kind=="hover" then map("<Esc>",function() M.close(s) end,"关闭段评悬浮窗") end
  map("<CR>",function()
    local row=s.panel and s.panel.rows[vim.api.nvim_win_get_cursor(win)[1]]
    if row then ctl.action(s,row) end
  end,"查看段评 / 展开回复")
  map("a",function() ctl.calibrate(s) end,"绑定到正文光标段落")
  map("u",function() ctl.unknown(s) end,"查看未对齐段评")
  map("r",function() ctl.reload(s) end,"刷新当前段评")
  map("n",function() ctl.page(s,1) end,"下一页")
  map("p",function() ctl.page(s,-1) end,"上一页")
  map("s",function() ctl.sort(s) end,"热门 / 最新")
  map("o",function()
    local row=s.panel and s.panel.rows[vim.api.nvim_win_get_cursor(win)[1]]
    if row and row.url then
      if row.url:match("^https?://") then vim.ui.open(row.url) end
    end
  end,"打开图片链接")
  M.render(s)
  if opts.focus==false and vim.api.nvim_win_is_valid(origin) then vim.api.nvim_set_current_win(origin) end
end
function M.render(s)
  if not s.panel or not vim.api.nvim_buf_is_valid(s.panel.buf) then return end
  local lines,rows,highlights={},{},{}
  local function add(text,row,hl)
    for _,line in ipairs(vim.split(clean(text),"\n",{plain=true})) do
      lines[#lines+1]=line
      if row then rows[#lines]=row end
      if hl then highlights[#highlights+1]={#lines-1,hl} end
    end
  end
  add("番茄段评 · "..(s.book.binding and s.book.binding.title or "未绑定书籍"),nil,"Title")
  add(s.current and s.current.title or "未进入章节",nil,"Title")
  add("q 关闭 · u 未对齐 · a 校准 · r 刷新",nil,"Comment")
  add("n/p 翻页 · s 排序 · Enter 回复 · o 图片",nil,"Comment")
  if s.status then add(s.status,nil,"DiagnosticInfo") end
  if s.error then add("请求失败："..s.error,nil,"DiagnosticError") end
  add("")
  local view=s.view or {mode="unknown"}
  if view.mode=="message" then
    add(view.text or "将光标移到正文段落查看段评。",nil,"DiagnosticInfo")
  elseif view.mode=="unknown" then
    add("未对齐段评（Enter 查看，a 绑定到正文光标段落）",nil,"Title")
    local count=0
    for _,id in ipairs(s.stats_order or {}) do
      if not s.resolved[id] then
        count=count+1
        local info=s.stats[id]
        add(("  段号 %s · %d 条"):format(id,tonumber(info.count) or 0),{kind="paragraph",id=id})
      end
    end
    if count==0 then
      add(s.stats_ready and "没有未对齐的段评。" or "尚未取得本章段评统计；可继续阅读本地正文。")
    end
  else
    local map=s.mappings and s.mappings[view.para]
    add(("段号 %s · %s · %s"):format(view.para,map and (map.method=="manual" and "手动校准" or "原文核验") or "位置未确认",
      s.sort==1 and "最新" or "热门"),nil,"Title")
    local pages=s.pages[view.para] or {}
    local page=pages[view.page or 1]
    if s.loading then add("加载中…",nil,"DiagnosticInfo") end
    if page then
      add(("第 %d 页 · 共 %d 条%s"):format(view.page or 1,page.total or 0,page.cached and " · 缓存" or ""),nil,"Comment")
      if #page.comments==0 then add("本页没有评论。") end
      local function comment(c,depth,parent)
        local prefix=string.rep("  ",math.min(depth,6))
        local id=tostring(c.comment_id or c.reply_id or "")
        local state=s.replies[id]
        local row=parent or {kind="comment",comment=c}
        local titles=table.concat(c.titles or {}," · ")
        add(prefix..(c.is_author and "[作者] " or "")..(c.user_name or "读者")
          ..(titles~="" and " ["..titles.."]" or "")
          ..(" · 赞 %d · 回复 %d %s"):format(c.digg_count or 0,c.reply_count or 0,state and state.expanded and "▾" or "▸"),row,"Identifier")
        if c.reply_to_user_name then add(prefix.."回复 "..c.reply_to_user_name,row,"Comment") end
        add(prefix..(c.text or ""),row)
        for i,im in ipairs(c.images or {}) do
          add(prefix..("[图片 %d] "):format(i)..(im.url or ""),{kind="image",url=im.url},"Underlined")
        end
        if state and state.expanded then
          if state.loading then add(prefix.."  回复加载中…",nil,"Comment") end
          if state.error then add(prefix.."  "..state.error,nil,"DiagnosticError") end
          local tree=require("fanqie.protocol.comments").build_reply_tree(state.items or {})
          local function walk(nodes,d)
            for _,node in ipairs(nodes) do
              comment(node,d,row)
              if d<12 then walk(node.children or {},d+1) end
            end
          end
          walk(tree,depth+1)
          if state.has_more then add(prefix.."  [加载更多回复]",{kind="reply_more",comment=c},"Underlined") end
        end
        add("")
      end
      for _,c in ipairs(page.comments) do comment(c,0) end
      add(page.has_more and "n 下一页 · p 上一页" or "已到本段最后一页 · p 上一页",nil,"Comment")
    elseif not s.loading then add("没有取得本页数据；r 重试。") end
  end
  local buf=s.panel.buf
  local context=table.concat({s.current and s.current.line or 0,view.mode or "",view.para or "",view.page or 1},":")
  local cursor=s.panel.context==context and vim.api.nvim_win_is_valid(s.panel.win)
    and vim.api.nvim_win_get_cursor(s.panel.win) or {1,0}
  s.panel.context=context
  vim.bo[buf].modifiable=true
  vim.api.nvim_buf_set_lines(buf,0,-1,false,lines)
  vim.bo[buf].modifiable=false
  vim.api.nvim_buf_clear_namespace(buf,ns,0,-1)
  for _,item in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(buf,ns,item[1],0,{line_hl_group=item[2]})
  end
  s.panel.rows=rows
  if vim.api.nvim_win_is_valid(s.panel.win) then
    vim.api.nvim_win_set_cursor(s.panel.win,{math.min(cursor[1],#lines),0})
  end
end
return M
