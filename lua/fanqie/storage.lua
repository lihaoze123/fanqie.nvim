local M = {}
function M.read(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local data = file:read("*a"); file:close()
  local ok, value = pcall(vim.json.decode, data, {luanil={object=true,array=true}})
  if ok and type(value) == "table" then return value end
  return nil, "JSON 文件损坏：" .. path
end
function M.write(path, value)
  vim.fn.mkdir(vim.fs.dirname(path), "p", 448)
  local temp = path .. "." .. vim.uv.os_getpid() .. ".tmp"
  local fd, err = vim.uv.fs_open(temp, "w", 384)
  if not fd then error(err) end
  local encoded = vim.json.encode(value)
  local wrote, werr = vim.uv.fs_write(fd, encoded, 0)
  vim.uv.fs_close(fd)
  if wrote ~= #encoded then vim.uv.fs_unlink(temp); error(werr or "写入不完整") end
  local ok, rerr = vim.uv.fs_rename(temp, path)
  if not ok then vim.uv.fs_unlink(temp); error(rerr) end
end
function M.canonical(value)
  if type(value) ~= "table" then return vim.json.encode(value) end
  local keys = vim.tbl_keys(value)
  table.sort(keys, function(a,b) return tostring(a)<tostring(b) end)
  local out = {}
  for _, k in ipairs(keys) do out[#out+1]=vim.json.encode(k)..":"..M.canonical(value[k]) end
  return "{"..table.concat(out,",").."}"
end
return M
