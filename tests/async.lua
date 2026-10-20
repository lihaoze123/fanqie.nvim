-- Exercise real child processes and cancellation without making network requests.
local root=vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1,"S").source:sub(2),":p")))
vim.opt.rtp:prepend(root)
local function run()
  local temp=vim.fn.tempname(); vim.fn.mkdir(temp,"p")
  local API=require("fanqie.api")
  local Store=require("fanqie.storage")
  local config={state_dir=temp.."/state",cache_dir=temp.."/cache",curl="curl",
    request_interval_ms=1,cache_ttl=3600,offline=false}
  API.setup(config)
  local real_worker=API.worker
  local fixture=temp.."/slow-worker.lua"
  vim.fn.writefile({
    'local req=vim.json.decode(io.read("*a"))',
    'vim.wait(200)',
    'io.write(vim.json.encode({ok=true,data={query=req.args.query}}))',
  },fixture)
  API.worker=fixture
  local cancelled=false
  API.request("search",{query="cancelled"},{owner=1},function() cancelled=true end)
  assert(vim.wait(1000,function() return API.active and API.active.job~=nil end,5))
  API.cancel(1)
  local done,data,err=false
  API.request("search",{query="survives"},{owner=2},function(d,e) done=true; data=d; err=e end)
  assert(vim.wait(3000,function() return done end,5))
  assert(not cancelled and not err and data.query=="survives","late cancelled callbacks must not update the next owner")
  assert(#vim.fn.glob(config.cache_dir.."/*.json",false,true)==1,"cancelled result must not be cached")
  config.offline=true
  local cached=false
  API.request("search",{query="survives"},{force=true},function(d,e,meta)
    cached=not e and meta.cached and d.query=="survives"
  end)
  assert(cached and not API.active,"offline force-refresh must not spawn a process")
  config.offline=false; API.worker=real_worker
  done=false
  API.request("directory",{book="not-a-numeric-id"},{owner=2},function(d,e) done=true; data=d; err=e end)
  assert(vim.wait(3000,function() return done end,5))
  assert(not data and err:find("无效书籍 ID",1,true),"invalid metadata IDs must be rejected")
  assert(#vim.fn.glob(config.cache_dir.."/*.json",false,true)==1,"failures must not poison the cache")
  local corrupt=temp.."/corrupt.json"; vim.fn.writefile({"{broken"},corrupt)
  local value,read_err=Store.read(corrupt)
  assert(not value and read_err,"invalid stored JSON must surface an error")
  print("PASS: real worker cancellation, owner isolation, offline cache, errors not cached, corrupt JSON")
end
local ok,err=xpcall(run,debug.traceback)
if not ok then io.stderr:write(err.."\n"); vim.cmd("cquit 1") end
