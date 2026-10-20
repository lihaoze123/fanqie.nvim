-- Runs in an isolated headless Neovim. stdin/stdout are JSON, stderr is diagnostic only.
local source=debug.getinfo(1,"S").source:sub(2)
local root=vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
vim.opt.rtp:prepend(root)
local Store=require("fanqie.storage")
local function run(req)
  local Text=require("fanqie.protocol.text")
  local client={}
  function client:json_encode(data) return vim.json.encode(data) end
  function client:json_decode(text) return vim.json.decode(text,{luanil={object=true,array=true}}) end
  function client:request(opts)
    local host=opts.url:match("^https://([^/]+)/")
    if not vim.tbl_contains({"log.snssdk.com","novel.snssdk.com","fanqienovel.com",
      "api5-normal-sinfonlinec.fqnovel.com"},host) then error("不允许的接口域名") end
    local cmd={req.curl or "curl","--silent","--show-error","--proto","=https",
      "--max-time",tostring(opts.timeout or 20),"--connect-timeout","8",
      "--request",opts.method or "GET","--write-out","\n%{http_code}"}
    for k,v in pairs(opts.headers or {}) do
      cmd[#cmd+1]="--header"; cmd[#cmd+1]=k..": "..v
    end
    if opts.body then cmd[#cmd+1]="--data-binary"; cmd[#cmd+1]="@-" end
    cmd[#cmd+1]=opts.url
    local r=vim.system(cmd,{text=true,stdin=opts.body}):wait()
    if r.code~=0 then error("curl 请求失败（退出码 "..r.code.."）："..vim.trim(r.stderr or "")) end
    local body,code=(r.stdout or ""):match("^([%s%S]*)\n(%d%d%d)$")
    return body,tonumber(code)
  end
  local function json_get(url,ua)
    local text,code=client:request({url=url,headers={["User-Agent"]=ua or "Mozilla/5.0",
      ["Accept"]="application/json",["Referer"]="https://fanqienovel.com/"}})
    if code~=200 then error("元数据 HTTP "..tostring(code)) end
    if not text or text=="" then error("元数据接口返回空响应") end
    local data=client:json_decode(text)
    if type(data)~="table" or tonumber(data.code)~=0 then error("元数据接口失败："..tostring(data and (data.message or data.code))) end
    return data.data
  end
  local a=req.args or {}
  if req.action=="search" then
    local data=json_get("https://novel.snssdk.com/api/novel/channel/homepage/search/search/v1/?aid=1967&offset="
      ..tostring(tonumber(a.offset) or 0).."&q="..Text.urlEncode(a.query),"com.dragon.read/6.5.3.32")
    if type(data)~="table" or type(data.ret_data)~="table" then error("搜索结果结构无效") end
    local books={}
    for _,b in ipairs(data.ret_data) do
      if type(b.book_id)=="string" and b.book_id:match("^%d+$") then
        books[#books+1]={id=b.book_id,title=tostring(b.title or ""),author=tostring(b.author or "")}
      end
    end
    return {books=books,has_more=data.has_more==true,offset=data.offset}
  elseif req.action=="directory" then
    assert(tostring(a.book):match("^%d+$"),"无效书籍 ID")
    local data=json_get("https://fanqienovel.com/api/reader/directory/detail?bookId="..a.book)
    local out={}
    for _,volume in ipairs(data.chapterListWithVolume or {}) do
      for _,ch in ipairs(volume) do
        if type(ch.itemId)~="string" then error("目录章节 ID 不是字符串，拒绝使用可能丢失精度的 ID") end
        out[#out+1]={id=ch.itemId,title=ch.title}
      end
    end
    if #out==0 then error("目录接口没有返回可识别章节") end
    return out
  end
  assert(req.action=="stats" or req.action=="comments" or req.action=="replies","不支持的操作")
  assert(tostring(a.chapter or a.comment):match("^%d+$"),"无效章节/评论 ID")
  local saved,read_err=Store.read(req.device_path)
  if read_err then error(read_err) end
  local settings={values=saved or {}}
  function settings:get(k,default) if self.values[k]==nil then return default end return self.values[k] end
  function settings:set(k,v) self.values[k]=v end
  function settings:flush() Store.write(req.device_path,self.values) end
  local C=require("fanqie.protocol.comments")
  if req.action=="stats" then
    local data,err=C.stats(client,settings,a.chapter)
    if not data then error(err) end
    -- JSON object keys must remain strings, including sparse paragraph indices.
    local out=vim.empty_dict()
    for k,v in pairs(data) do out[tostring(k)]=v end
    return out
  end
  local rows,info,err
  local opts={count=20,cursor=a.cursor or "",sort=a.sort or 0,item_version=a.version}
  if req.action=="comments" then
    assert(tostring(a.book):match("^%d+$") and tonumber(a.para) and tonumber(a.para)>=0,"无效段落")
    rows,info,err=C.list(client,settings,a.chapter,a.book,a.para,opts)
  else rows,info,err=C.replies(client,settings,a.comment,opts) end
  if not rows then error(err) end
  local out={}
  for _,row in ipairs(rows) do
    local flat=req.action=="comments" and C.flatten_comment(row) or C.flatten_reply(row)
    flat.images=C.normalize_images(flat.images)
    out[#out+1]=flat
  end
  return {comments=out,cursor=tostring(info.cursor or ""),has_more=info.has_more==true,total=tonumber(info.total) or 0}
end
local ok,result=xpcall(function()
  return run(vim.json.decode(io.read("*a"),{luanil={object=true,array=true}}))
end,function(err) return (tostring(err):gsub("^.-:%d+:%s*", "")) end)
io.write(vim.json.encode(ok and {ok=true,data=result} or {ok=false,error=result}))
io.flush()
