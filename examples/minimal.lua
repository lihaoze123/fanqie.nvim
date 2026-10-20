-- An isolated reading session; does not load or modify your normal Neovim config.
-- Reading mappings use <leader>F... (e.g. ,Ft for the chapter directory).
local path=vim.fn.fnamemodify(debug.getinfo(1,"S").source:sub(2),":p")
vim.opt.rtp:prepend(vim.fs.dirname(vim.fs.dirname(path)))
vim.g.mapleader=","
vim.opt.termguicolors=true
vim.opt.number=false
vim.opt.relativenumber=false
vim.opt.swapfile=false
require("fanqie").setup()
vim.api.nvim_create_autocmd("VimEnter",{once=true,callback=function()
  if vim.api.nvim_buf_get_name(0)~="" then require("fanqie").enable() end
end})
