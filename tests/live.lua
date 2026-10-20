-- Explicit opt-in live integration test. No novel body requests.
-- FANQIE_TEST_TXT=/absolute/path/book.txt nvim --headless -u NONE -i NONE -l tests/live.lua
local root=vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1,"S").source:sub(2),":p")))
vim.opt.rtp:prepend(root)
local function run()
  local file=assert(vim.env.FANQIE_TEST_TXT,"Set FANQIE_TEST_TXT to the local 铁血残明.txt")
  file=assert(vim.uv.fs_realpath(file),"TXT file missing")
  local dir=vim.env.FANQIE_TEST_DIR or vim.fn.tempname()
  local Store=require("fanqie.storage")
  local F=require("fanqie")
  F.setup({state_dir=dir,cache_dir=dir.."/cache",restore_position=false})
  local API=require("fanqie.api")
  local function request(action,args)
    local done,data,err=false
    API.request(action,args,{},function(d,e) data=d; err=e; done=true end)
    assert(vim.wait(55000,function() return done end,20),"live request timed out")
    assert(data,err)
    return data
  end
  local search=request("search",{query="铁血残明",offset=0})
  local binding
  for _,book in ipairs(search.books) do if book.title=="铁血残明" and book.author=="柯山梦" then binding=book end end
  assert(binding,"Expected title/author not returned")
  local directory=request("directory",{book=binding.id})
  Store.write(dir.."/books/"..vim.fn.sha256(file)..".json",{
    schema=1,file=file,binding=binding,directory=directory,bookmarks={},
  })
  vim.cmd.edit(file); vim.api.nvim_win_set_cursor(0,{20,0})
  local s=F.enable()
  assert(vim.wait(120000,function() return s.stats_ready and not API.active and #API.queue==0 end,20),"stats/probes timed out")
  assert(not s.error,s.error)
  assert(s.remote.title=="第一章 恶隶",s.remote.title)
  assert(vim.tbl_count(s.resolved)>0,"No comment quotes matched local paragraphs")
  local target
  for _,p in ipairs(s.paragraphs) do if p.line==21 then target={id="1",p=p}; break end end
  assert(target,"Expected local paragraph is missing")
  vim.api.nvim_win_set_cursor(s.win,{target.p.line,0}); F.command("comments")
  assert(vim.wait(55000,function() return not s.loading and not s.locating end,20))
  assert(not s.error,s.error)
  assert(s.view.para==target.id and s.resolved[target.id].line==21,"candidate quote must map to local line 21")
  local page=s.pages[target.id][1]
  assert(page and #page.comments>0)
  local second
  if page.has_more then
    local key=vim.fn.maparg("n","n",false,true).callback; key()
    assert(vim.wait(55000,function() return not s.loading end,20)); assert(not s.error,s.error)
    second=s.pages[target.id][2]; assert(second and #second.comments>0)
  end
  local reply_count=0
  for row,item in pairs(s.panel.rows) do
    if item.kind=="comment" and (item.comment.reply_count or 0)>0 then
      vim.api.nvim_win_set_cursor(s.panel.win,{row,0})
      vim.fn.maparg("<CR>","n",false,true).callback()
      local state=s.replies[tostring(item.comment.comment_id)]
      assert(vim.wait(55000,function() return not state.loading end,20))
      assert(not state.error,state.error)
      reply_count=#state.items
      break
    end
  end
  local old_notify=vim.notify; vim.notify=function() end
  F.command("offline"); vim.notify=old_notify
  vim.fn.maparg("r","n",false,true).callback()
  assert(not s.loading and not s.error,"offline cache re-read failed")
  assert(s.pages[target.id][1].cached,"offline response must be marked as cached")
  F.disable(s.buf)
  print(vim.json.encode({ok=true,local_chapters=#s.chapters,remote_chapters=#directory,
    paragraphs_with_comments=#s.stats_order,verified=vim.tbl_count(s.resolved),
    first_page=#page.comments,second_page=second and #second.comments or 0,replies=reply_count,offline=true,
    matched_line=target.p.line,state_dir=dir}))
end
local ok,err=xpcall(run,debug.traceback)
if not ok then io.stderr:write(err.."\n"); vim.cmd("cquit 1") end
