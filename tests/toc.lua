-- Paginated directory interaction; no network access.
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1,"S").source:sub(2),":p")))
vim.opt.rtp:prepend(root)
local function run()
  local temp = vim.fn.tempname()
  vim.fn.mkdir(temp, "p")
  local lines = {}
  for i = 1, 73 do
    vim.list_extend(lines, {("第%d章 章节%d"):format(i,i), "正文" .. i, ""})
  end
  local file = temp .. "/目录测试.txt"
  vim.fn.writefile(lines, file)
  local F = require("fanqie")
  F.setup({offline=true, state_dir=temp.."/state", cache_dir=temp.."/cache", restore_position=false})
  vim.cmd.edit(file)
  vim.api.nvim_win_set_cursor(0, {(37-1)*3+1, 0})
  local s = F.enable()
  local original_select = vim.ui.select
  vim.ui.select = function() error("TOC must not use an external picker") end
  local function press(key)
    local mapping = vim.fn.maparg(key, "n", false, true)
    assert(type(mapping.callback)=="function", "Missing key: " .. key)
    mapping.callback()
  end
  F.command("toc")
  assert(s.toc and s.toc.selected==37, "Opening must select the current chapter")
  local view = s.toc
  local page = view.page
  local selected = view.selected
  press("n")
  assert(view.page==page+1 and view.selected>selected, "Next page must advance")
  press("p")
  assert(view.page==page and view.selected==selected, "Previous page must preserve row")
  press("G")
  assert(view.selected==73 and view.page==view.pages)
  press("n")
  assert(view.selected==73, "Paging past the end must stay at the end")
  press("gg")
  assert(view.selected==1 and view.page==1)
  press("p")
  assert(view.selected==1, "Paging before the first page must stay at the start")
  press("j"); assert(view.selected==2)
  press("k"); assert(view.selected==1)
  press("g"); assert(view.selected==37)
  local original_input = vim.ui.input
  vim.ui.input = function(_,cb) cb("73") end
  press("/")
  assert(#view.items==1 and view.items[1].number==73, "Search must include chapters on other pages")
  press("<CR>")
  assert(not s.toc and s.current.number==73)
  assert(vim.api.nvim_get_current_buf()==s.buf and vim.api.nvim_win_get_cursor(s.win)[1]==217,
    "Enter must focus the TXT at the selected chapter")
  F.command("toc")
  view=s.toc
  vim.ui.input = function(_,cb) cb("没有这样的章节") end
  press("/")
  assert(#view.items==0)
  press("<CR>"); assert(s.toc==view, "Empty results must not jump")
  press("c"); assert(#view.items==73 and view.selected==73)
  local old_size=view.page_size
  vim.o.lines=15
  vim.api.nvim_exec_autocmds("VimResized",{})
  assert(view.page_size<old_size and view.selected==73, "Resize must keep the selected chapter")
  press("q")
  assert(not s.toc and s.current.number==73)
  F.command("prev")
  assert(s.current.number==72, "Previous chapter must work after closing the directory")
  F.command("next")
  assert(s.current.number==73)
  F.command("toc")
  F.command("disable")
  assert(not s.toc and not F.sessions[s.buf], "Disabling from the TOC must close it")
  assert(vim.deep_equal(vim.fn.readfile(file),lines), "Directory navigation must not modify TXT")
  vim.ui.select=original_select; vim.ui.input=original_input
  print("PASS: TOC current chapter, page boundaries, movement, search, Enter jump, resize, close, next/prev, cleanup, TXT unchanged")
end
local ok,err=xpcall(run,debug.traceback)
if not ok then io.stderr:write(err.."\n"); vim.cmd("cquit 1") end
