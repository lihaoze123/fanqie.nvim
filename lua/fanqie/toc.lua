local M = {}
local ns = vim.api.nvim_create_namespace("fanqie.toc")

local function valid(view)
  return view and vim.api.nvim_win_is_valid(view.win) and vim.api.nvim_buf_is_valid(view.buf)
end

local function layout()
  local height = math.max(5, math.min(24, vim.o.lines - vim.o.cmdheight - 4))
  local width = math.max(12, math.min(84, vim.o.columns - 4))
  return {
    relative = "editor", style = "minimal", border = "rounded",
    width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - vim.o.cmdheight - height - 2) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    title = " 章节目录 ", title_pos = "center",
  }
end

function M.close(s, restore_focus)
  local view = s.toc
  if not view then return end
  s.toc = nil
  if vim.api.nvim_win_is_valid(view.win) then vim.api.nvim_win_close(view.win, true) end
  if restore_focus and vim.api.nvim_win_is_valid(view.origin) then
    vim.api.nvim_set_current_win(view.origin)
  end
end

local function render(s)
  local view = s.toc
  if not valid(view) then return end
  local size = math.max(1, vim.api.nvim_win_get_height(view.win) - 4)
  view.page_size = size
  view.selected = math.max(1, math.min(view.selected, #view.items))
  view.page = math.floor((view.selected - 1) / size) + 1
  view.pages = math.max(1, math.ceil(#view.items / size))
  local first = (view.page - 1) * size + 1
  local lines = {
    ("第 %d / %d 页 · %d / %d 章%s"):format(view.page, view.pages, #view.items, #s.chapters,
      view.query ~= "" and " · 搜索：" .. view.query or ""),
    "j/k 选择 · n/p 翻页 · Enter 跳转 · / 搜索 · q 返回",
    "",
  }
  view.rows = {}
  for i = first, math.min(first + size - 1, #view.items) do
    local ch = view.items[i]
    lines[#lines + 1] = (ch == s.current and "→ " or "  ") .. ch.title
    view.rows[#lines] = {chapter = ch, index = i}
  end
  if #view.items == 0 then lines[#lines + 1] = "没有匹配的章节，按 / 重新搜索，或 c 清除筛选。" end
  while #lines < size + 3 do lines[#lines + 1] = "" end
  lines[#lines + 1] = "g 当前章节 · gg/G 首尾 · c 清除搜索 · Esc 关闭"
  vim.bo[view.buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
  vim.bo[view.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(view.buf, ns, 0, -1)
  for row, item in pairs(view.rows) do
    if item.chapter == s.current then
      vim.api.nvim_buf_set_extmark(view.buf, ns, row - 1, 0, {line_hl_group = "DiagnosticInfo"})
    end
  end
  vim.api.nvim_buf_set_extmark(view.buf, ns, 0, 0, {line_hl_group = "Title"})
  vim.api.nvim_buf_set_extmark(view.buf, ns, 1, 0, {line_hl_group = "Comment"})
  vim.api.nvim_buf_set_extmark(view.buf, ns, #lines - 1, 0, {line_hl_group = "Comment"})
  vim.api.nvim_win_set_cursor(view.win, {#view.items > 0 and view.selected - first + 4 or 4, 0})
end

local function filter(s, query, current)
  local view = s.toc
  if not valid(view) then return end
  view.query = vim.trim(query)
  view.items = {}
  local needle = view.query:lower()
  local selected = 1
  for _, ch in ipairs(s.chapters) do
    if needle == "" or ch.title:lower():find(needle, 1, true)
      or (ch.number and tostring(ch.number) == needle) then
      view.items[#view.items + 1] = ch
      if ch == current then selected = #view.items end
    end
  end
  view.selected = selected
  render(s)
end

function M.open(s, on_select)
  if valid(s.toc) then
    vim.api.nvim_set_current_win(s.toc.win)
    render(s)
    return
  end
  local origin = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, layout())
  local view = {buf = buf, win = win, origin = origin, selected = 1, query = "", items = {}}
  s.toc = view
  vim.api.nvim_buf_set_name(buf, "fanqie://toc/" .. s.buf .. "/" .. buf)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "fanqie_toc"
  vim.bo[buf].swapfile = false
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].scrolloff = 0
  local function map(keys, callback, desc)
    for _, key in ipairs(type(keys) == "table" and keys or {keys}) do
      vim.keymap.set("n", key, callback, {buffer = buf, silent = true, nowait = key ~= "g", desc = desc})
    end
  end
  local function move(delta)
    if not valid(s.toc) then return end
    view.selected = math.max(1, math.min(#view.items, view.selected + delta))
    render(s)
  end
  local function page(delta)
    if not valid(s.toc) then return end
    local target = math.max(1, math.min(view.pages, view.page + delta))
    local offset = (view.selected - 1) % view.page_size
    view.selected = math.min(#view.items, (target - 1) * view.page_size + offset + 1)
    render(s)
  end
  map({"j", "<Down>"}, function() move(vim.v.count1) end, "下一章目录项")
  map({"k", "<Up>"}, function() move(-vim.v.count1) end, "上一章目录项")
  map({"n", "<PageDown>", "<C-f>", "<Space>"}, function() page(vim.v.count1) end, "下一页目录")
  map({"p", "<PageUp>", "<C-b>"}, function() page(-vim.v.count1) end, "上一页目录")
  map("<C-d>", function() move(math.max(1, math.floor(view.page_size / 2))) end, "向下半页")
  map("<C-u>", function() move(-math.max(1, math.floor(view.page_size / 2))) end, "向上半页")
  map("gg", function() view.selected = 1; render(s) end, "目录第一项")
  map("G", function() view.selected = #view.items; render(s) end, "目录最后一项")
  map("g", function() filter(s, "", s.current) end, "定位当前章节")
  map("c", function() filter(s, "", s.current) end, "清除目录搜索")
  map("/", function()
    vim.ui.input({prompt = "搜索章节（标题或章号）：", default = view.query}, function(query)
      if query and s.toc == view and valid(view) then filter(s, query) end
    end)
  end, "搜索全部章节")
  map({"q", "<Esc>"}, function() M.close(s, true) end, "关闭目录")
  map("<CR>", function()
    local row = view.rows[vim.api.nvim_win_get_cursor(win)[1]]
    if not row then return end
    if not vim.tbl_contains(s.chapters, row.chapter) then filter(s, view.query, s.current); return end
    M.close(s, false)
    on_select(row.chapter)
  end, "跳转到所选章节")
  local group = vim.api.nvim_create_augroup("FanqieToc" .. buf, {clear = true})
  vim.api.nvim_create_autocmd("VimResized", {group = group, callback = function()
    if valid(view) then vim.api.nvim_win_set_config(win, layout()); render(s) end
  end})
  vim.api.nvim_create_autocmd("CursorMoved", {group = group, buffer = buf, callback = function()
    if not valid(view) then return end
    local row = vim.api.nvim_win_get_cursor(win)[1]
    if view.rows[row] then view.selected = view.rows[row].index
    else render(s) end
  end})
  vim.api.nvim_create_autocmd("BufWipeout", {group = group, buffer = buf, once = true, callback = function()
    if s.toc == view then s.toc = nil end
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end})
  filter(s, "", s.current)
end

return M
