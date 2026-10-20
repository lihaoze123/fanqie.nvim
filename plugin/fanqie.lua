if vim.g.loaded_fanqie then return end
vim.g.loaded_fanqie=true
-- Lazy setup: loading the plugin does not touch TXT buffers or start network requests.
vim.api.nvim_create_user_command("Fanqie",function(cmd)
  require("fanqie").setup()
  require("fanqie").command(cmd.args)
end,{nargs="*",desc="本地 TXT 阅读与番茄段评",complete=function(lead)
  local items={"enable","disable","bind","chapter","comments","hover","unmatched","calibrate","uncalibrate",
    "toc","next","prev","bookmark","bookmarks","unbookmark","refresh","offline","online","status"}
  return vim.tbl_filter(function(item) return item:sub(1,#lead)==lead end,items)
end})
