-- Language of a static site root: redirects / to /<lang>/ chosen from
-- Accept-Language by weight, among the languages the served release has
-- (directories with index.html). A release without language directories
-- is served as is.
local _M = {}

-- preferred(header): primary language subtags of Accept-Language, highest
-- weight first; equal weights keep the header order. q=0 and * are dropped.
local function preferred(header)
    local items = {}
    for item in header:gmatch("[^,]+") do
        local tag, params = item:match("^%s*([%a%-]+)%s*(.*)$")
        local lang = tag and tag:match("^(%a%a%a?)%f[^%a]")
        if lang then
            local q = tonumber(params:match(";%s*[qQ]%s*=%s*([%d.]+)")) or 1
            if q > 0 then
                items[#items + 1] = { lang = lang:lower(), q = math.min(q, 1), pos = #items }
            end
        end
    end
    table.sort(items, function(a, b)
        if a.q ~= b.q then
            return a.q > b.q
        end
        return a.pos < b.pos
    end)
    return items
end

local function served(lang)
    local f = io.open(ngx.var.document_root .. "/" .. lang .. "/index.html")
    if f then
        f:close()
        return true
    end
    return false
end

-- redirect(default): sends the client to the best served language, or to
-- default when none of its languages is served. Returns when the release has
-- neither, so the request falls through to the root index.html.
function _M.redirect(default)
    local lang
    for _, item in ipairs(preferred(ngx.var.http_accept_language or "")) do
        if served(item.lang) then
            lang = item.lang
            break
        end
    end
    lang = lang or (served(default) and default)
    if not lang then
        return
    end

    local target = "/" .. lang .. "/"
    if ngx.var.args then
        target = target .. "?" .. ngx.var.args
    end
    ngx.header["Vary"] = "Accept-Language"
    return ngx.redirect(target, ngx.HTTP_MOVED_TEMPORARILY)
end

return _M
