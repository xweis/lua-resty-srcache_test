-- Copyright (C) Huo Mao (@)
-- 访问php 数据保存到redis和ngxcache 
-- php timeout 10s 
-- 如果超时访问托底数据，1分钟后再请求php 
 

local redis = require "resty.redis_iresty" 
local resty_lock = require "resty.lock"
local cjson = require "cjson"
local ngx_re = require "ngx.re"
-- local red = redis:new({host='10.0.0.17',auth='HCeNPa109XzzfqpC'})
local red = redis:new({host='127.0.0.1'})
local setmetatable = setmetatable
local lockName = "ngxLock"
local method = ngx.req.get_method()
local key = ngx.md5(ngx.var.arg_key)

local _M = { _VERSION = '0.02' }
local mt = { __index = _M }

local ERR = ngx.ERR
local NOTICE = ngx.NOTICE
local log = ngx.log

function _M.new()
    
    local ngxCache = ngx.shared.ngxCache
    if not ngxCache then
        return nil, "dictionary not found"
    end

    local ngx_exptime = ngx.var.ngx_exptime or 1
    local redis_exptime = ngx.var.redis_exptime or 100

    local self = {
        ngxCache = ngxCache,
        ngx_exptime = ngx_exptime,
        redis_exptime = redis_exptime,
    }

    return setmetatable(self, mt)
end


-- ngx内部缓存 get
function _M.shmGet(self, key)
    
    local ngxCache = self.ngxCache
    local val, err = ngxCache:get(key)
    if val then
        return val
    end
    
    if err then return nil, "failed to get key from ngxCache : " .. err end

    return nil, "'" .. key .. "' cache Key not exist"

end


-- ngx内部缓存 set
function _M.shmSet(self, key, value, exptime)
    
    if not exptime then
        exptime = self.ngx_exptime
    end
    local ngxCache = self.ngxCache
    local val, err = ngxCache:set(key, value, exptime)
    if val then
        return val
    end
    
    if err then return nil, "failed to get key from ngxCache : " .. err end

    return nil, "'" .. key .. "' cache Key not exist"

end



-- redis 缓存 get
function _M.rget(self, key)

    local val, err = red:get(key)
    if not val then
        return nil, "not data"
    end

    return val
end

-- redis 缓存 set
function _M.rset(self, value)

    local ok, err = red:set(key, value)
    if not ok then
        return nil, "failed Redis set" .. err
    end

    red:expire(key, self.redis_exptime)
    return ok
end


function _M.get(self)

    -- 获取ngxcache数据
    local val, err  = self.shmGet(self, key)
    if val then
        return val
    end

    -- 创建锁 
    local lock, err = resty_lock:new(lockName)
    if not lock then
        return nil, "failed to create lock: " .. err
    end

    local elapsed, err = lock:lock(key)
    -- 没有获取锁
    if not elapsed then
        local val, err = self.rget(self, key)
        if not val then
            return nil, err 
        end
        return val
    end


    -- 成功得到锁!

    -- 有请求可能已经把值放到缓存中了 
    -- 所以我们在查询一遍
    val, err  = self.shmGet(self, key)
    if val then
        local ok, err = lock:unlock()
        if not ok then
            return nil, "failed to unlock: " .. err
        end

        return val
    end


    -- Redis data
    val, err = self.rget(self, key)
    if not val then
        local ok, err = lock:unlock()
        if not ok then
            return nil, "failed to unlock: " .. err
        end

        return nil, "rget data is nil"
    end


    -- 用新获取的值更新ngxcache缓存 
    local ok, err = self.shmSet(self, key, val, self.ngx_exptime)
    if not ok then
        local ok, err = lock:unlock()
        if not ok then
            return nil, "failed to unlock: " .. err
        end

        return nil, "failed to update shm cache: " 
    end

    local ok, err = lock:unlock()
    if not ok then
        return nil, "failed to unlock: " .. err
    end

    return val
end


local cache = _M:new()
if method == 'GET' then
    local value, err = cache:get()
    if not value then
        log(NOTICE, err)
        ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
    end
    ngx.print(value)

elseif method == "PUT" then
    local value = ngx.req.get_body_data()

    local val, err = ngx_re.split(value, "\r\n",nil,nil,2)

    if val and  val[1] then
        local from = ngx.re.find(val[1],"(200)","jo")
        if from then
            local ok, err = cache:rset(value)
            if not ok then
                log(ERR, err)
                log(ERR,key..value)
                ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
            end
            log(NOTICE, 'PUT: ', key)
        else
            ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
        end
    end
else
    ngx.exit(ngx.HTTP_NOT_ALLOWED)
end

-- ngx.print('HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\n\r\n{\"code\":100')
