-- Signed comment requests only. No reader/batch_full or registerkey operations.
local Crypto = require("fanqie.protocol.crypto")
local Sign = require("fanqie.protocol.sign")
local M = {}
function M.signed_call(client, name, device, path, build_query, build_body)
  local sec, usec = vim.uv.gettimeofday()
  local ts = sec * 1000 + math.floor(usec / 1000)
  local query = Crypto.encode_query(build_query(device, ts))
  local body = build_body and build_body(client, device)
  local headers = Crypto.build_unsigned_headers(device, ts)
  if body then headers["Content-Type"] = "application/json" end
  for k,v in pairs(Sign.sign_headers(query, device.device_id, {
    khronos = math.floor(ts/1000), version_name = device.version_name,
    device_type = device.device_type, os_version = device.os_version,
  })) do headers[k] = v end
  local text, code = client:request({url="https://"..Crypto.HOST..path.."?"..query,
    method=body and "POST" or "GET", headers=headers, body=body, timeout=20})
  if not code then return nil, name.." 网络请求失败" end
  if code < 200 or code >= 300 then return nil, name.." HTTP "..code end
  if not text or text == "" then return nil, name.." 空响应（未取得评论数据）" end
  local ok, data = pcall(client.json_decode, client, text)
  if not ok or type(data) ~= "table" then return nil, name.." 响应不是有效 JSON" end
  if tonumber(data.code) ~= 0 or type(data.data) ~= "table" then
    return nil, name.." 失败："..tostring(data.message or data.msg or data.code)
  end
  return data
end
return M
