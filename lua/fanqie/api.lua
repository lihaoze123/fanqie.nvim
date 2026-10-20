local Store=require("fanqie.storage")
local M={queue={},active=nil,last=0}
function M.setup(config)
  M.config=config
  M.worker=vim.fn.fnamemodify(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1,"S").source:sub(2)),"worker.lua"),":p")
end
local function pump()
  if M.active or #M.queue==0 then return end
  local task=table.remove(M.queue,1)
  M.active=task
  local delay=math.max(0,M.config.request_interval_ms-(vim.uv.now()-M.last))
  vim.defer_fn(function()
    if M.active~=task then return end
    local req={action=task.action,args=task.args,curl=M.config.curl,
      device_path=vim.fs.joinpath(M.config.state_dir,"device.json")}
    task.job=vim.system({vim.v.progpath,"--headless","-u","NONE","-i","NONE","-n","-l",M.worker},
      {stdin=vim.json.encode(req),text=true,timeout=50000},function(result)
        vim.schedule(function()
          if M.active~=task then return end
          M.active=nil; M.last=vim.uv.now()
          local ok,decoded=pcall(vim.json.decode,result.stdout or "",{luanil={object=true,array=true}})
          local err,data
          if result.code~=0 then err="段评工作进程失败（退出码 "..result.code.."）"
          elseif not ok or type(decoded)~="table" then err="工作进程响应无效"
          elseif not decoded.ok then err=decoded.error
          else data=decoded.data end
          if data then
            local wrote,werr=pcall(Store.write,task.path,{schema=1,time=os.time(),data=data})
            if not wrote then err="取得数据，但缓存写入失败："..tostring(werr) end
          end
          local called,cb_err=pcall(task.callback,data,err,{cached=false})
          if not called then vim.notify(tostring(cb_err),vim.log.levels.ERROR,{title="fanqie.nvim"}) end
          pump()
        end)
      end)
  end,delay)
end
function M.request(action,args,opts,callback)
  opts=opts or {}
  local key=vim.fn.sha256(Store.canonical({action=action,args=args,schema=1}))
  local path=vim.fs.joinpath(M.config.cache_dir,key..".json")
  local cache=Store.read(path)
  if cache and cache.schema==1 and (M.config.offline or (not opts.force and (opts.stale or os.time()-cache.time<M.config.cache_ttl))) then
    callback(cache.data,nil,{cached=true,time=cache.time}); return
  end
  if M.config.offline then
    callback(nil,"离线模式下没有这份缓存",{}); return
  end
  M.queue[#M.queue+1]={action=action,args=args,owner=opts.owner,path=path,callback=callback}
  pump()
end
function M.cancel(owner)
  for i=#M.queue,1,-1 do if M.queue[i].owner==owner then table.remove(M.queue,i) end end
  if M.active and M.active.owner==owner then
    local task=M.active; M.active=nil
    if task.job then task.job:kill(15) end
    pump()
  end
end
return M
