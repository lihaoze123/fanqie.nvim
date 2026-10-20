-- Cursor follow and hover interactions with deliberately out-of-order responses.
local root=vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1,"S").source:sub(2),":p")))
vim.opt.rtp:prepend(root)
local function run()
  local requests,cancelled={},{}
  local held_stats,hold_stats=nil,false
  local API={setup=function() end,cancel=function(owner) cancelled[#cancelled+1]=owner end}
  function API.request(action,args,opts,callback)
    if action=="stats" then
      if hold_stats then held_stats=callback
      else callback({["0"]={count=2},["1"]={count=2},["2"]={count=2}},nil,{cached=false}) end
    elseif action=="comments" then
      requests[#requests+1]={args=args,callback=callback,owner=opts.owner}
    else error("Unexpected action: "..action) end
  end
  package.loaded["fanqie.api"]=API
  local dir=vim.fn.tempname(); vim.fn.mkdir(dir,"p")
  local lines={"第1章 开始","甲段正文。","乙段正文。","丙段正文。","","第2章 后续","丁段正文。"}
  local file=dir.."/sample.txt"; vim.fn.writefile(lines,file)
  local F=require("fanqie")
  F.setup({state_dir=dir.."/state",cache_dir=dir.."/cache",restore_position=false,probe_limit=0,follow_delay_ms=30})
  vim.keymap.set("n","K",function() end,{desc="Global hover"})
  vim.cmd.edit(file)
  local s=F.enable()
  local source=s.win
  assert(vim.fn.maparg("K","n",false,true).buffer==1)
  s.book.binding={id="123",title="样本",author="作者"}
  s.book.directory={{id="10",title="第一章 开始"},{id="20",title="第二章 后续"}}
  F.command("next"); F.command("prev")
  local function move(line)
    vim.api.nvim_set_current_win(source)
    vim.api.nvim_win_set_cursor(source,{line,0})
    vim.api.nvim_exec_autocmds("CursorMoved",{buffer=s.buf})
  end
  local function finish(request,text,comment)
    request.callback({comments={{comment_id="c"..request.args.para,user_name="读者",text=comment or "评论："..text,
      para_index=request.args.para,para_src_content=text,reply_count=0,images={}}},
      total=2,cursor="next",has_more=request.args.cursor==""},nil,{cached=false})
  end
  local function contents()
    return table.concat(vim.api.nvim_buf_get_lines(s.panel.buf,0,-1,false),"\n")
  end
  local function key(k) vim.fn.maparg(k,"n",false,true).callback() end
  move(2); key("K")
  assert(s.panel.kind=="hover" and vim.api.nvim_get_current_win()==source,"K must preview without stealing focus")
  assert(#requests==1 and s.locating)
  key("K")
  assert(vim.api.nvim_get_current_win()==s.panel.win and #requests==1,"Second K must enter without duplicating a request")
  finish(requests[1],lines[2])
  assert(contents():find("评论：甲段正文。",1,true) and not s.loading)
  key("n"); assert(#requests==2)
  finish(requests[2],lines[2],"第二页评论")
  assert(s.view.page==2 and contents():find("第二页评论",1,true))
  key("q"); assert(not s.panel)
  F.command("comments")
  assert(s.panel.kind=="split")
  move(3)
  assert(s.view.mode=="message","Old comments must disappear immediately on a new paragraph")
  assert(vim.wait(1000,function() return #requests==3 end,5),"Following did not request paragraph B")
  assert(vim.api.nvim_get_current_win()==source,"Background follow must preserve source focus")
  move(4)
  assert(vim.wait(1000,function() return #requests==4 end,5))
  finish(requests[4],lines[4])
  finish(requests[3],lines[3],"过期乙段评论")
  assert(s.view.para=="2" and not contents():find("过期乙段评论",1,true),"A late response must not replace the focused paragraph")
  assert(not s.pages["1"],"Cancelled paragraph data must not enter the current view cache")
  move(2)
  assert(vim.wait(1000,function() return s.view.para=="0" end,5))
  local before=#requests
  vim.api.nvim_win_set_cursor(source,{2,3})
  vim.api.nvim_exec_autocmds("CursorMoved",{buffer=s.buf})
  vim.wait(80)
  assert(#requests==before and s.view.para=="0","Movement inside a paragraph must not request it again")
  move(3); move(4); move(3)
  assert(vim.wait(1000,function() return #requests==before+1 end,5))
  vim.wait(80)
  assert(#requests==before+1,"Rapid movement must debounce into one request")
  require("fanqie.ui").close(s)
  finish(requests[#requests],lines[3])
  move(4); vim.wait(80)
  assert(not s.panel and #requests==before+1,"Closed panels must not reopen on late callbacks or movement")
  move(3); key("K")
  local stale=requests[#requests]
  move(4)
  assert(not s.panel,"Hover must close when leaving its paragraph")
  finish(stale,lines[3])
  assert(not s.panel)
  hold_stats=true
  F.command("next"); move(7); key("K"); key("K")
  assert(s.awaiting_cursor and held_stats and vim.api.nvim_get_current_win()==s.panel.win)
  held_stats(nil,"统计请求失败（测试）",{cached=false})
  assert(s.error and contents():find("按 r 重试",1,true),"Statistics errors must be visible")
  hold_stats=false; key("r")
  finish(requests[#requests],lines[7])
  assert(s.view.para=="0" and contents():find("评论：丁段正文。",1,true),"Hover must resume after chapter statistics arrive")
  key("q"); move(7); F.command("uncalibrate"); key("K")
  finish(requests[#requests],"另一版本的正文。","不属于当前段落的评论")
  assert(s.view.mode=="message" and not contents():find("不属于当前段落的评论",1,true),"Unverified comments must not appear as a hover match")
  F.disable(s.buf)
  assert(not s.panel and not s.cursor_timer and not F.sessions[s.buf])
  assert(vim.fn.maparg("K","n",false,true).desc=="Global hover","Disable must reveal the existing global K")
  assert(vim.tbl_contains(cancelled,s.view_owner),"View requests must have a separate cancellable owner")
  F.setup({state_dir=dir.."/state",cache_dir=dir.."/cache",restore_position=false,probe_limit=0,
    follow_cursor=false,follow_delay_ms=10})
  vim.keymap.set("n","K",function() end,{buffer=s.buf,desc="User buffer K"})
  s=F.enable()
  assert(vim.fn.maparg("K","n",false,true).desc=="User buffer K","Existing buffer K must be preserved")
  source=s.win; move(7); F.command("comments")
  finish(requests[#requests],lines[7])
  local panel=s.panel
  move(6); vim.wait(80)
  assert(s.panel==panel and s.view.mode=="comments","follow_cursor=false must keep the selected paragraph")
  F.disable(s.buf)
  assert(vim.fn.maparg("K","n",false,true).desc=="User buffer K")
  assert(vim.deep_equal(vim.fn.readfile(file),lines),"TXT must remain unchanged")
  print("PASS: K hover/focus/paging, cursor follow, debounce, stale responses, closing, delayed stats/retry, strict alignment, K preservation, opt-out, cleanup")
end
local ok,err=xpcall(run,debug.traceback)
if not ok then io.stderr:write(err.."\n"); vim.cmd("cquit 1") end
