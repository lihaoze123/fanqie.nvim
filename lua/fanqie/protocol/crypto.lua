-- Protocol request primitives only; no chapter fetching, content keys or content decryption.
-- Adapted from the supplied fanqie.koplugin; see NOTICE.md.
local Aes = require("fanqie.protocol.aes")
local Text = require("fanqie.protocol.text")
local Crypto = {}
local AID = 1967
function Crypto.urandom(n)
    local f = io.open("/dev/urandom", "rb")
    if f then
        local d = f:read(n)
        f:close()
        if d and #d == n then return d end
    end
    local t = {}
    for i = 1, n do t[i] = string.char(math.random(0, 255)) end
    return table.concat(t)
end

function Crypto.build_common_query(device, ts_ms)
    if type(ts_ms) ~= "number" then
        ts_ms = os.time() * 1000
    end
    return {
        iid = tostring(device.install_id),
        device_id = tostring(device.device_id),
        ac = "wifi",
        channel = device.channel or "43536163a",
        aid = tostring(AID),
        app_name = "novelapp",
        version_code = tostring(device.version_code or "73733"),
        version_name = tostring(device.version_name or "7.3.7.33"),
        device_platform = "android",
        os = "android",
        ssmix = "a",
        device_type = device.device_type or "P30",
        device_brand = device.device_brand or "Huawei",
        language = device.language or "zh",
        os_api = tostring(device.os_api or "30"),
        os_version = tostring(device.os_version or "12"),
        manifest_version_code = tostring(device.version_code or "73733"),
        resolution = device.resolution or "1280*720",
        dpi = tostring(device.dpi or "240"),
        update_version_code = tostring(device.version_code or "73733"),
        _rticket = tostring(ts_ms),
        host_abi = device.host_abi or "armeabi-v7a",
        cdid = device.cdid or "",
        openudid = device.openudid or "",
    }
end

function Crypto.encode_query(params)
    local order = {
        "iid", "device_id", "ac", "channel", "aid", "app_name", "version_code",
        "version_name", "device_platform", "os", "ssmix", "device_type", "device_brand",
        "language", "os_api", "os_version", "manifest_version_code", "resolution",
        "dpi", "update_version_code", "_rticket", "host_abi", "cdid", "openudid",
        "item_ids", "key_register_ts", "book_id", "req_type",
    }
    local seen = {}
    local parts = {}
    local function add(k, v)
        if v == nil or seen[k] then return end
        seen[k] = true
        local vs = tostring(v)
        local ek = Text.urlEncode(tostring(k))
        local ev
        if k == "item_ids" then
            ev = (Text.urlEncode(vs):gsub("%%2C", ","))
        else
            ev = Text.urlEncode(vs)
            ev = ev:gsub("%%2A", "*"):gsub("%%2B", "+")
        end
        parts[#parts + 1] = ek .. "=" .. ev
    end
    for _, k in ipairs(order) do
        if params[k] ~= nil then add(k, params[k]) end
    end
    for k, v in pairs(params) do
        add(k, v)
    end
    return table.concat(parts, "&")
end

---@param device table
---@param ts_ms number|nil
---@return table
function Crypto.build_unsigned_headers(device, ts_ms)
    ts_ms = ts_ms or (os.time() * 1000)
    local vc = device.version_code or "73733"
    local rom = tostring(device.rom_version or "S643.217451.03386707"):match("^[^%+]+") or ""
    local ua = string.format(
        "com.dragon.read.oversea.gp/%s (Linux; U; Android %s; zh_CN; %s; Build/%s;tt-ok/3.12.13.4-tiktok)",
        vc, device.os_version or "12", device.device_type or "P30", rom)
    local rnd = ""
    do
        local f = io.open("/dev/urandom", "rb")
        if f then
            local d = f:read(4)
            f:close()
            if d then rnd = Aes.to_hex(d) end
        end
        if rnd == "" then rnd = string.format("%08x", math.random(0, 0xffffffff)) end
    end
    return {
        ["User-Agent"] = ua,
        ["Accept"] = "application/json; charset=utf-8,application/x-protobuf",
        ["Accept-Encoding"] = "identity",
        ["sdk-version"] = "2",
        ["passport-sdk-version"] = "50564",
        ["lc"] = "101",
        ["x-tt-store-region"] = "cn-zj",
        ["x-tt-store-region-src"] = "did",
        ["x-vc-bdturing-sdk-version"] = "3.7.2.cn",
        ["x-xs-from-web"] = "0",
        ["X-Ss-Req-Ticket"] = tostring(ts_ms),
        ["x-reading-request"] = tostring(ts_ms) .. "-" .. rnd,
        ["Cookie"] = "store-region=cn-zj; store-region-src=did; install_id="
            .. tostring(device.install_id),
    }
end

Crypto.HOST = "api5-normal-sinfonlinec.fqnovel.com"
return Crypto
