-- Copyright (C) Huo Mao (@)
-- 访问php 数据保存到redis和ngxcache 
-- php timeout 10s 
-- 如果超时访问托底数据，1分钟后再请求php 
 

local redis = require "resty.redis_iresty" 
local resty_lock = require "resty.lock"
local http = require "resty.http"
local shared = ngx.shared
local red = redis:new({host='127.0.0.1',auth=nil})
local setmetatable = setmetatable
local lockName = "ngxLock"
local key = ngx.md5(ngx.var.escaped_key)

local _M = { _VERSION = '0.02' }
local mt = { __index = _M }

local ERR = ngx.ERR
local NOTICE = ngx.NOTICE
local log = ngx.log

local function request(fullurl, method, headers, body, cache_skip_fetch)
    
    headers[cache_skip_fetch] = "TRUE"
    local httpc = http.new()
    local res, err = httpc:request_uri(fullurl, {method = method, body = body, headers = headers})
    ngx.log(NOTICE, "[LUA], success to update new cache, url: ", fullurl, ", method: ", method)
    if err then
        ngx.log(ERR, "  ",err)
    end
    return res
end


function _M.new()
    
    local self = {
        cache_skip_fetch = "X-Skip-Fetch",
        cache_methods = "GET",
        method = ngx.var.request_method,
        ngxCache = ngx.shared["ngxCache"],
        stale = 10,
        LOCK_EXPTIME = 10,
        LOCK_TIMEOUT = 5,
    }
    return setmetatable(self, mt)
end


-- redis 获取 ttl
function _M.rttl(self, key)

    local val, err = red:ttl(key)
    if not val then
        return nil, key, " not data"
    end

    return val
end


function _M.getTtl(self)

    local ngxKey = "TTL_" .. key
    local cache = self.ngxCache

    --获取 ngx 缓存
    local val, err = cache:get(ngxKey)
    if val then
        return val
    end

    if err then
        ngx.log(NOTICE, "failed to get key from shm: ", err)
        return
    end

    --创建锁
    local lock, err = resty_lock:new(lockName,{exptime=self.LOCK_EXPTIME,timeout=self.LOCK_TIMEOUT})
    if not lock then
        ngx.log(NOTICE, "failed to create lock: ", err)
        return
    end

    local elapsed, err = lock:lock(ngxKey)
    if not elapsed then
        ngx.log(NOTICE, "failed to acquire the lock: ", err)
        return
    end

    -- 成功得到锁!

    -- 有请求可能已经把值放到缓存中了
    -- 所以我们在查询一遍
    val, err = cache:get(ngxKey)
    if val then
        local ok, err = lock:unlock()
        if not ok then
            ngx.log(NOTICE, "failed to unlock: ", err)
            return
        end

        return val
    end


    -- 从 redis 获取数据
    local val = self.rttl(self, key)
    if not val then
        local ok, err = lock:unlock()
        if not ok then
            ngx.log(NOTICE, "failed to unlock: ", err)
            return
        end

        -- FIXME: we should handle the backend miss more carefully
        -- here, like inserting a stub value into the cache.
        return
    end

    -- 用新获取的值更新ngx 缓存
    local ok, err = cache:set(ngxKey, val, 1)
    if not ok then
        local ok, err = lock:unlock()
        if not ok then
            ngx.log(NOTICE, "failed to unlock: ", err)
            return
        end

        ngx.log(NOTICE, "failed to update shm cache: ", err)
        return
    end

    --解锁
    local ok, err = lock:unlock()
    if not ok then
        ngx.log(NOTICE, "failed to unlock: ", err)
        return
    end

    return val
end


function _M.run(self)

    local skip = ngx.var["http_" .. self.cache_skip_fetch:lower():gsub("-", "_")]
    -- 如果 X-Skip-Fetch 有值或者请求不是 get方式 return
    if skip or not self.cache_methods:find(self.method) then return end

    local ttl = self.getTtl(self)

    if not ttl or ttl == nil then
        ttl = 0
    end

    local fullurl = ngx.var.scheme .. "://" .. ngx.var.host .. ":" .. ngx.var.server_port .. ngx.var.request_uri
    if ttl < self.stale then
        if ttl == -2 then
            self.lock(self, fullurl)
        else
            if ttl > 0 then
                self.lock(self, fullurl)
            end
        end
    end

    return
end


function _M.lock(self, fullurl)

    local cache = self.ngxCache
    local key = "lock_" .. key
    
    local lock, err = resty_lock:new(lockName,{exptime=self.LOCK_EXPTIME,timeout=self.LOCK_TIMEOUT})
    if not lock then
        return
    end

    local elapsed, err = lock:lock(key)
    if not elapsed then
        return
    end

    if elapsed == 0 then
        local val = request(fullurl, self.method, ngx.req.get_headers(), ngx.req.get_body_data(), self.cache_skip_fetch) 
    end

    lock:unlock()
end

_M:new():run()
return _M
