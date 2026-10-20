local P = require("fanqie.parser")
local M = {}
-- Match full normalized text, or a long, unique quote covering >=80% of a paragraph.
function M.find(paragraphs, source)
  local needle=P.normalize(source)
  if needle=="" then return nil end
  local matches={}
  for _, p in ipairs(paragraphs) do
    local text=p.normalized
    if text==needle or (#needle>=60 and #needle>=#text*0.8 and text:find(needle,1,true)) then
      matches[#matches+1]=p
    end
  end
  return #matches==1 and matches[1] or nil
end
function M.resolve(paragraphs, mapping)
  if not mapping then return nil end
  local matches={}
  for _, p in ipairs(paragraphs) do if p.hash==mapping.hash then matches[#matches+1]=p end end
  -- Identical repeated lines are ambiguous; a stored line number is not proof.
  return #matches==1 and matches[1] or nil
end
function M.record(paragraphs, source)
  local p=M.find(paragraphs,source)
  if p then return {hash=p.hash,method="verified"} end
end
return M
