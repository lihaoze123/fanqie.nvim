local M = {}
local digits = { ["零"]=0,["〇"]=0,["一"]=1,["二"]=2,["两"]=2,["三"]=3,
  ["四"]=4,["五"]=5,["六"]=6,["七"]=7,["八"]=8,["九"]=9 }
local units = {["十"]=10,["百"]=100,["千"]=1000,["万"]=10000}
function M.trim(text)
  return vim.trim((text:gsub("　", " "):gsub("\239\187\191", "")))
end
function M.number(text)
  if text:match("^%d+$") then return tonumber(text) end
  local total, section, digit, found = 0,0,0,false
  for _, c in ipairs(vim.fn.split(text, "\\zs")) do
    if digits[c] ~= nil then digit=digits[c]; found=true
    elseif units[c] then
      found=true
      if units[c] == 10000 then total=total+(section+digit)*10000; section=0
      else section=section+(digit==0 and 1 or digit)*units[c] end
      digit=0
    else return nil end
  end
  return found and total+section+digit or nil
end
function M.title(text, pattern)
  text = M.trim(text)
  if pattern then
    local parts = vim.fn.matchlist(text, pattern)
    if #parts > 0 then return {number=M.number(parts[2] or ""),name=M.trim(parts[3] or text),title=text} end
  end
  local n, name = text:match("^(.-)章%s*(.*)$")
  if n then
    n = n:gsub("^第", "")
    local num = M.number(n)
    if num then return {number=num,name=M.trim(name),title=text} end
  end
  if vim.tbl_contains({"引子","序章","楔子","序言","前言","后记","尾声"},text) then
    return {name=text,title=text}
  end
end
function M.normalize(text)
  if type(text) ~= "string" then return "" end
  text = text:gsub("<[^>]->", "")
  local entities = {amp="&",lt="<",gt=">",quot='"',apos="'",nbsp=" "}
  text = text:gsub("&([%w#]+);", function(e)
    if entities[e] then return entities[e] end
    local n = e:match("^#(%d+)$") or e:match("^#x(%x+)$")
    if n then
      n = tonumber(n,e:match("^#x") and 16 or 10)
      if n and n > 0 and n <= 0x10ffff then return vim.fn.nr2char(n) end
    end
    return "&"..e..";"
  end)
  return (text:gsub("　", ""):gsub("\194\160", ""):gsub("%s+", ""))
end
function M.parse(lines, options)
  options = options or {}
  local chapters = {}
  for line, text in ipairs(lines) do
    local title = M.title(text, options.chapter_pattern)
    if title then title.line=line; title.index=#chapters+1; chapters[#chapters+1]=title end
  end
  if #chapters == 0 then chapters={{line=1,index=1,title="全文",name="全文",no_heading=true}} end
  for i, ch in ipairs(chapters) do
    ch.last=(chapters[i+1] and chapters[i+1].line-1) or #lines
  end
  return chapters
end
function M.at(chapters, line)
  local lo, hi = 1, #chapters
  while lo <= hi do
    local mid=math.floor((lo+hi)/2)
    if chapters[mid].line <= line then lo=mid+1 else hi=mid-1 end
  end
  return chapters[math.max(1,hi)]
end
function M.paragraphs(lines, chapter, mode)
  local result, pending = {}, nil
  local function flush()
    if pending then
      pending.normalized=M.normalize(pending.text)
      pending.hash=vim.fn.sha256(pending.normalized)
      result[#result+1]=pending; pending=nil
    end
  end
  local first=chapter.no_heading and chapter.line or chapter.line+1
  for i=first,chapter.last do
    local text=M.trim(lines[i] or "")
    if text == "" then flush()
    elseif mode == "blank" then
      if pending then pending.text=pending.text..text; pending.last=i
      else pending={line=i,last=i,text=text} end
    else
      flush(); pending={line=i,last=i,text=text}; flush()
    end
  end
  flush()
  return result
end
-- Match both the chapter number and subtitle. Never fall back to array position.
function M.match_chapter(local_chapter, directory)
  local exact, names = {}, {}
  for _, entry in ipairs(directory or {}) do
    local remote=M.title(entry.title or "")
    local name=remote and remote.name or M.trim(entry.title or "")
    if M.normalize(name)==M.normalize(local_chapter.name) then
      names[#names+1]=entry
      if remote and remote.number==local_chapter.number then exact[#exact+1]=entry end
    end
  end
  if #exact==1 then return exact[1] end
  if #names==1 then return names[1] end
end
return M
