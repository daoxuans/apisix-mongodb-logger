--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--

-- mongodb-logger: ships access log entries into a MongoDB collection.
--
-- Transport: MongoDB Wire Protocol (OP_MSG, opCode=2013) over TCP/TLS.
-- Requires MongoDB 3.6+.
-- Auth:       SCRAM-SHA-1 (optional – set username + password to enable).
-- Batching:   driven by the shared batch-processor-manager, same as every
--             other APISIX logger plugin.

local bp_manager_mod = require("apisix.utils.batch-processor-manager")
local log_util       = require("apisix.utils.log-util")
local plugin         = require("apisix.plugin")
local core           = require("apisix.core")
local bit            = require("bit")
local ffi            = require("ffi")

local ngx            = ngx
local tcp            = ngx.socket.tcp
local math_random    = math.random
local math_floor     = math.floor
local str_format     = string.format
local str_byte       = string.byte
local str_char       = string.char
local str_sub        = string.sub
local str_find       = string.find
local str_match      = string.match
local tbl_concat     = table.concat
local tbl_insert     = table.insert
local type           = type
local pairs          = pairs
local ipairs         = ipairs
local tostring       = tostring
local setmetatable   = setmetatable
local getmetatable   = getmetatable

local plugin_name = "mongodb-logger"
local batch_processor_manager = bp_manager_mod.new(plugin_name)

-- SCRAM-SHA-256 support via lua-resty-openssl (available in APISIX by default).
-- Falls back gracefully: SHA-1 still works even if openssl modules are absent.
local _has_sha256
local _resty_hmac, _resty_digest
do
    local ok1, m1 = pcall(require, "resty.openssl.hmac")
    local ok2, m2 = pcall(require, "resty.openssl.digest")
    if ok1 and ok2 then
        _has_sha256   = true
        _resty_hmac   = m1
        _resty_digest = m2
    end
end


-- ============================================================
-- Schema
-- ============================================================

local schema = {
    type = "object",
    properties = {
        -- hosts supports multiple entries for replica set / K8s headless service discovery.
        -- Each entry is "host:port". If only one server is needed, use hosts = ["host:port"].
        hosts = {
            type = "array",
            minItems = 1,
            items = {
                type = "string",
                pattern = "^[^:]+:[0-9]+$",
            },
            description = "List of MongoDB hosts as 'host:port'. "
                          .. "One is chosen randomly per batch, enabling round-robin "
                          .. "across replica set members or K8s pod endpoints.",
        },
        -- Kept for backward compat / single-host simplicity.
        host = {type = "string", default = "127.0.0.1"},
        port = {type = "integer", minimum = 1, maximum = 65535, default = 27017},
        database   = {type = "string", minLength = 1},
        collection = {type = "string", minLength = 1},
        -- database used for authentication (defaults to "admin")
        auth_database = {type = "string", default = "admin"},
        username  = {type = "string"},
        password  = {type = "string"},
        -- SCRAM auth mechanism; SCRAM-SHA-256 requires lua-resty-openssl.
        auth_mechanism = {
            type    = "string",
            enum    = {"SCRAM-SHA-1", "SCRAM-SHA-256"},
            default = "SCRAM-SHA-1",
        },
        ssl       = {type = "boolean", default = false},
        ssl_verify = {type = "boolean", default = true},
        -- connection + read timeout in milliseconds
        timeout   = {type = "integer", minimum = 1, default = 3000},
        -- TCP connection pool size per nginx worker (setkeepalive)
        pool_size          = {type = "integer", minimum = 1, default = 5},
        -- idle keepalive timeout in seconds
        keepalive_timeout  = {type = "integer", minimum = 1, default = 60},
        log_format = {type = "object"},
        include_req_body = {type = "boolean", default = false},
        include_req_body_expr = {
            type = "array", minItems = 1,
            items = {type = "array"},
        },
        include_resp_body = {type = "boolean", default = false},
        include_resp_body_expr = {
            type = "array", minItems = 1,
            items = {type = "array"},
        },
    },
    required = {"database", "collection"},
    encrypt_fields = {"password"},
}

local metadata_schema = {
    type = "object",
    properties = {
        log_format = {type = "object"},
        max_pending_entries = {
            type = "integer",
            description = "maximum number of pending entries in the batch processor",
            minimum = 1,
        },
    },
}

local _M = {
    version  = 0.1,
    priority = 397,
    name     = plugin_name,
    schema   = batch_processor_manager:wrap_schema(schema),
    metadata_schema = metadata_schema,
}


function _M.check_schema(conf, schema_type)
    if schema_type == core.schema.TYPE_METADATA then
        return core.schema.check(metadata_schema, conf)
    end

    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return nil, err
    end

    local has_user = conf.username and conf.username ~= ""
    local has_pass = conf.password ~= nil and conf.password ~= ""
    if has_user ~= has_pass then
        return nil, "username and password must both be set or both be absent"
    end

    if conf.auth_mechanism == "SCRAM-SHA-256" and not _has_sha256 then
        return nil, "auth_mechanism 'SCRAM-SHA-256' requires lua-resty-openssl " ..
                    "(resty.openssl.hmac and resty.openssl.digest must be available)"
    end

    return log_util.check_log_schema(conf)
end


-- ============================================================
-- BSON encoding
--
-- BSON spec: http://bsonspec.org/spec.html
-- Only the subset needed for log documents is implemented.
-- ============================================================

-- Protected against "already defined" errors on module reload (worker restart
-- without process restart reloads Lua modules into the same LuaJIT state).
do
    local ok, err = pcall(ffi.cdef, [[
        typedef union { double  d; uint8_t b[8]; } bson_dbl_t;
        typedef union { int32_t i; uint8_t b[4]; } bson_i32_t;
    ]])
    if not ok and not str_find(err or "", "already defined", 1, true) then
        error("[" .. plugin_name .. "] ffi.cdef failed: " .. tostring(err))
    end
end

local function le_int32(n)
    local u = ffi.new("bson_i32_t")
    u.i = n
    return ffi.string(u.b, 4)
end

local function le_double(n)
    local u = ffi.new("bson_dbl_t")
    u.d = n
    return ffi.string(u.b, 8)
end

-- Sentinel: emit type 0x05 (Binary, subtype 0).
local _binary_mt = {}
local function bson_binary(data)
    return setmetatable({_data = data}, _binary_mt)
end

-- Sentinel: force a Lua number to be emitted as BSON Int32 (type 0x10).
-- Used for protocol fields like conversationId that MongoDB requires as Int32.
local _int32_mt = {}
local function bson_int32(n)
    return setmetatable({_val = n}, _int32_mt)
end

local encode_bson_doc  -- forward declaration

local MAX_BSON_DEPTH = 10

local function is_lua_array(t)
    if next(t) == nil then
        return false  -- empty table → treat as object (BSON document)
    end
    local i = 0
    for _ in pairs(t) do
        i = i + 1
        if t[i] == nil then
            return false
        end
    end
    return true
end

local function encode_bson_element(key, value, seen, depth)
    local kc = key .. "\0"  -- null-terminated key
    local vt = type(value)

    if value == nil then
        return "\x0A" .. kc                                         -- Null

    elseif vt == "boolean" then
        return "\x08" .. kc .. (value and "\x01" or "\x00")         -- Boolean

    elseif vt == "number" then
        -- Emit as Int32 when the value is a whole number within the 32-bit signed
        -- range (status codes, counts, latency ms, etc.).  Everything else is Double.
        if value == math_floor(value)
           and value >= -2147483648
           and value <=  2147483647
        then
            return "\x10" .. kc .. le_int32(math_floor(value))      -- Int32
        end
        return "\x01" .. kc .. le_double(value)                     -- Double

    elseif vt == "string" then
        local s = value .. "\0"
        return "\x02" .. kc .. le_int32(#s) .. s                    -- UTF-8 string

    elseif vt == "table" then
        if getmetatable(value) == _binary_mt then
            local d = value._data
            -- type 0x05: int32 size + uint8 subtype(0) + bytes
            return "\x05" .. kc .. le_int32(#d) .. "\x00" .. d      -- Binary

        elseif getmetatable(value) == _int32_mt then
            return "\x10" .. kc .. le_int32(value._val)              -- Int32 (explicit)

        elseif depth >= MAX_BSON_DEPTH then
            -- Truncate deeply nested or circular structures to a string
            local s = "(truncated)" .. "\0"
            return "\x02" .. kc .. le_int32(#s) .. s

        elseif seen[value] then
            -- Circular reference: emit a null to avoid infinite recursion
            return "\x0A" .. kc

        elseif is_lua_array(value) then
            seen[value] = true
            local elems = {}
            for i, v in ipairs(value) do
                elems[#elems + 1] = encode_bson_element(tostring(i - 1), v, seen, depth + 1)
            end
            seen[value] = nil
            local body = tbl_concat(elems, "")
            return "\x04" .. kc .. le_int32(#body + 5) .. body .. "\x00"  -- Array

        else
            seen[value] = true
            local doc = encode_bson_doc(value, seen, depth + 1)
            seen[value] = nil
            return "\x03" .. kc .. doc                              -- Document
        end

    else
        -- Fallback: encode anything else (e.g. userdata) as a string
        local s = tostring(value) .. "\0"
        return "\x02" .. kc .. le_int32(#s) .. s
    end
end

encode_bson_doc = function(tbl, seen, depth)
    seen  = seen  or {}
    depth = depth or 1
    local elems = {}
    for k, v in pairs(tbl) do
        if v ~= nil then
            elems[#elems + 1] = encode_bson_element(tostring(k), v, seen, depth)
        end
    end
    local body = tbl_concat(elems, "")
    -- document = int32(total bytes) + elements + 0x00 terminator
    return le_int32(#body + 5) .. body .. "\x00"
end


-- ============================================================
-- Minimal BSON document parser
--
-- Only decodes the top-level fields needed for:
--   - checking `ok` (double or int32) in command responses
--   - reading `conversationId` (int32) and `payload` (binary) in SCRAM
-- ============================================================

local function bson_read_le_int32(data, pos)
    return str_byte(data, pos)
        + str_byte(data, pos + 1) * 256
        + str_byte(data, pos + 2) * 65536
        + str_byte(data, pos + 3) * 16777216
end

local function bson_parse_doc(data, depth)
    depth = depth or 0
    local result = {}
    if #data < 5 then
        return result
    end

    local doc_size = bson_read_le_int32(data, 1)
    local pos = 5

    while pos < doc_size do
        local btype = str_byte(data, pos)
        if btype == 0 then break end  -- document terminator
        pos = pos + 1

        local key_end = str_find(data, "\0", pos, true)
        if not key_end then break end
        local key = str_sub(data, pos, key_end - 1)
        pos = key_end + 1

        if btype == 0x01 then           -- Double (8 bytes, little-endian IEEE 754)
            local u = ffi.new("bson_dbl_t")
            for i = 0, 7 do
                u.b[i] = str_byte(data, pos + i)
            end
            result[key] = u.d
            pos = pos + 8

        elseif btype == 0x02 then       -- UTF-8 string
            local slen = bson_read_le_int32(data, pos)
            pos = pos + 4
            result[key] = str_sub(data, pos, pos + slen - 2)  -- strip null terminator
            pos = pos + slen

        elseif btype == 0x03 then       -- Embedded document
            local sub_size = bson_read_le_int32(data, pos)
            if depth < 2 then
                result[key] = bson_parse_doc(str_sub(data, pos, pos + sub_size - 1), depth + 1)
            end
            pos = pos + sub_size

        elseif btype == 0x04 then       -- Array
            local sub_size = bson_read_le_int32(data, pos)
            if depth < 2 then
                -- Parse as document then convert "0","1",... keys to Lua array indices
                local arr_doc = bson_parse_doc(str_sub(data, pos, pos + sub_size - 1), depth + 1)
                local arr = {}
                for k, v in pairs(arr_doc) do
                    local idx = tonumber(k)
                    if idx then arr[idx + 1] = v end
                end
                result[key] = arr
            end
            pos = pos + sub_size

        elseif btype == 0x05 then       -- Binary
            local bin_size = bson_read_le_int32(data, pos)
            pos = pos + 4
            pos = pos + 1               -- skip subtype byte
            result[key] = str_sub(data, pos, pos + bin_size - 1)
            pos = pos + bin_size

        elseif btype == 0x08 then       -- Boolean
            result[key] = str_byte(data, pos) == 1
            pos = pos + 1

        elseif btype == 0x09 or btype == 0x11 or btype == 0x12 then  -- datetime/timestamp/int64
            pos = pos + 8

        elseif btype == 0x0A then       -- Null
            result[key] = nil

        elseif btype == 0x10 then       -- Int32
            result[key] = bson_read_le_int32(data, pos)
            pos = pos + 4

        else
            -- Unknown element type – cannot determine its length, stop parsing
            core.log.warn(plugin_name, ": unknown BSON type 0x",
                          str_format("%02X", btype), " while parsing response")
            break
        end
    end

    return result
end


-- ============================================================
-- MongoDB Wire Protocol helpers (OP_MSG, opCode = 2013)
--
-- Spec: https://www.mongodb.com/docs/manual/reference/mongodb-wire-protocol/
-- ============================================================

local OP_MSG_CODE = "\xDD\x07\x00\x00"  -- 2013 in little-endian int32

-- Build a complete OP_MSG frame.
--   section0_doc     – BSON-encoded command document  (kind = 0)
--   seq_identifier   – identifier string for the document sequence (kind = 1), or nil
--   seq_docs         – array of BSON-encoded documents for kind=1, or nil
local function make_op_msg(section0_doc, seq_identifier, seq_docs)
    -- Section 0 (Body): kind byte + command document
    local sec0 = "\x00" .. section0_doc

    -- Section 1 (Document Sequence): avoids wrapping documents in a BSON array
    local sec1 = ""
    if seq_identifier and seq_docs then
        local docs_bytes = tbl_concat(seq_docs, "")
        local id_cstr    = seq_identifier .. "\0"
        local seq_size   = 4 + #id_cstr + #docs_bytes  -- includes the size field itself
        sec1 = "\x01" .. le_int32(seq_size) .. id_cstr .. docs_bytes
    end

    local flag_bits = "\x00\x00\x00\x00"
    local sections  = sec0 .. sec1
    -- Total length = MsgHeader(16) + flagBits(4) + sections
    local msg_len   = 20 + #sections

    return le_int32(msg_len)
        .. le_int32(math_random(1, 2147483647))  -- requestID (arbitrary)
        .. "\x00\x00\x00\x00"                    -- responseTo
        .. OP_MSG_CODE
        .. flag_bits
        .. sections
end

-- Read one OP_MSG response from sock; returns the BSON body bytes or nil, err.
local function read_op_msg_response(sock)
    local header, err = sock:receive(16)
    if not header then
        return nil, "failed to read response header: " .. (err or "unknown")
    end

    local msg_len  = bson_read_le_int32(header, 1)
    local body_len = msg_len - 16
    if body_len < 5 then
        return nil, "response body too short (" .. msg_len .. " bytes total)"
    end

    local body, err = sock:receive(body_len)
    if not body then
        return nil, "failed to read response body: " .. (err or "unknown")
    end

    -- body layout: flagBits(4) + [kind(1) + BSON doc] + ...
    -- We only parse the first (kind=0) section.
    if str_byte(body, 5) ~= 0 then
        return nil, "unexpected first section kind: " .. str_byte(body, 5)
    end

    return str_sub(body, 6)  -- BSON document starts at byte 6 of body
end


-- ============================================================
-- SCRAM authentication
--
-- Implements RFC 5802 for both SCRAM-SHA-1 and SCRAM-SHA-256.
-- SCRAM-SHA-256 requires lua-resty-openssl (checked at config time).
-- ============================================================

local function xor_bytes(a, b)
    local t = {}
    for i = 1, #a do
        t[i] = str_char(bit.bxor(str_byte(a, i), str_byte(b, i)))
    end
    return tbl_concat(t, "")
end

-- Generic single-block PBKDF2; hmac_fn(key, data) returns raw bytes.
local function pbkdf2(password, salt, iterations, hmac_fn)
    local u = hmac_fn(password, salt .. "\x00\x00\x00\x01")
    local result = u
    for _ = 2, iterations do
        u = hmac_fn(password, u)
        result = xor_bytes(result, u)
    end
    return result
end

-- HMAC-SHA256 via lua-resty-openssl.
local function hmac_sha256(key, data)
    local h, err = _resty_hmac.new(key, "sha256")
    if not h then error("hmac_sha256: " .. tostring(err)) end
    local ok, uerr = h:update(data)
    if not ok then error("hmac_sha256 update: " .. tostring(uerr)) end
    return h:final()
end

-- SHA-256 digest via lua-resty-openssl.
local function sha256_bin(data)
    local d, err = _resty_digest.new("sha256")
    if not d then error("sha256_bin: " .. tostring(err)) end
    local ok, uerr = d:update(data)
    if not ok then error("sha256_bin update: " .. tostring(uerr)) end
    return d:final()
end

-- Cache PBKDF2 derivation per (mechanism, password, salt, iterations).
-- PBKDF2 at 10 000 iterations (~40 ms) is expensive; the salt is stable
-- per user, so we can safely reuse the derived key for hours.
local _scram_pwd_cache = core.lrucache.new({ttl = 3600, count = 64})

local function get_salted_pwd(pwd_digest, salt_b64, iterations, hmac_fn, mechanism)
    local cache_key = mechanism .. ":" .. pwd_digest .. ":"
                      .. salt_b64 .. ":" .. iterations
    return _scram_pwd_cache(cache_key, nil, function()
        return pbkdf2(pwd_digest, ngx.decode_base64(salt_b64), iterations, hmac_fn)
    end)
end

local function generate_nonce(len)
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    local t = {}
    for i = 1, len do
        local idx = math_random(1, #chars)
        t[i] = str_sub(chars, idx, idx)
    end
    return tbl_concat(t, "")
end

-- Perform a SCRAM handshake over an already-connected socket.
-- mechanism: "SCRAM-SHA-1" (default) | "SCRAM-SHA-256"
-- Returns true on success, false + error string on failure.
local function scram_auth(sock, database, username, password, mechanism)
    mechanism = mechanism or "SCRAM-SHA-1"

    local pwd_digest, hmac_fn, hash_fn
    if mechanism == "SCRAM-SHA-1" then
        -- MongoDB SCRAM-SHA-1 pre-hashes the password with MD5
        pwd_digest = ngx.md5(username .. ":mongo:" .. password)
        hmac_fn    = ngx.hmac_sha1
        hash_fn    = ngx.sha1_bin
    elseif mechanism == "SCRAM-SHA-256" then
        -- SCRAM-SHA-256 uses the raw password (SASLprep normalisation omitted)
        pwd_digest = password
        hmac_fn    = hmac_sha256
        hash_fn    = sha256_bin
    else
        return false, "unsupported auth mechanism: " .. mechanism
    end

    local client_nonce      = generate_nonce(24)
    local client_first_bare = "n=" .. username .. ",r=" .. client_nonce
    local client_first      = "n,," .. client_first_bare

    -- ── Round 1: saslStart ───────────────────────────────────────────
    local cmd1 = encode_bson_doc({
        saslStart = 1,
        mechanism = mechanism,
        payload   = bson_binary(client_first),
        ["$db"]   = database,
    })
    local ok, err = sock:send(make_op_msg(cmd1))
    if not ok then return false, "saslStart send: " .. err end

    local resp1
    resp1, err = read_op_msg_response(sock)
    if not resp1 then return false, "saslStart recv: " .. err end

    local r1 = bson_parse_doc(resp1)
    if not r1.ok or r1.ok ~= 1 then
        return false, "saslStart failed (ok=" .. tostring(r1.ok) .. ")"
    end

    local conv_id     = r1.conversationId
    local server_first = r1.payload

    if not server_first then
        return false, "saslStart: missing payload"
    end

    local full_nonce = str_match(server_first, "r=([^,]+)")
    local salt_b64   = str_match(server_first, "s=([^,]+)")
    local iterations = tonumber(str_match(server_first, "i=([^,]+)"))

    if not full_nonce or not salt_b64 or not iterations then
        return false, "invalid server-first-message: " .. server_first
    end
    if str_sub(full_nonce, 1, #client_nonce) ~= client_nonce then
        return false, "server nonce prefix mismatch"
    end

    -- ── Client proof ─────────────────────────────────────────────────
    local salted_pwd            = get_salted_pwd(pwd_digest, salt_b64, iterations,
                                                  hmac_fn, mechanism)
    local client_key            = hmac_fn(salted_pwd, "Client Key")
    local stored_key            = hash_fn(client_key)
    local client_final_no_proof = "c=biws,r=" .. full_nonce
    local auth_message          = client_first_bare .. "," .. server_first
                                  .. "," .. client_final_no_proof
    local client_sig            = hmac_fn(stored_key, auth_message)
    local client_proof          = xor_bytes(client_key, client_sig)
    local client_final          = client_final_no_proof
                                  .. ",p=" .. ngx.encode_base64(client_proof)

    -- ── Round 2: saslContinue ─────────────────────────────────────────
    -- conversationId MUST be BSON Int32 (not Double) per the MongoDB wire protocol.
    local cmd2 = encode_bson_doc({
        saslContinue   = 1,
        conversationId = bson_int32(conv_id),
        payload        = bson_binary(client_final),
        ["$db"]        = database,
    })
    ok, err = sock:send(make_op_msg(cmd2))
    if not ok then return false, "saslContinue send: " .. err end

    local resp2
    resp2, err = read_op_msg_response(sock)
    if not resp2 then return false, "saslContinue recv: " .. err end

    local r2 = bson_parse_doc(resp2)
    if not r2.ok or r2.ok ~= 1 then
        return false, "saslContinue failed"
    end

    -- ── Verify server signature (mutual auth per RFC 5802 §3) ────────
    -- This detects a rogue server / MITM that does not know the real password.
    local server_final = r2.payload or ""
    local actual_v     = str_match(server_final, "v=([^,]+)")
    if actual_v then
        local server_key = hmac_fn(salted_pwd, "Server Key")
        local server_sig = hmac_fn(server_key, auth_message)
        if actual_v ~= ngx.encode_base64(server_sig) then
            return false, "SCRAM server signature mismatch — possible MITM attack"
        end
    end

    if r2.done then
        return true
    end

    -- ── Round 3: final empty continuation (required by some MongoDB versions) ──
    local cmd3 = encode_bson_doc({
        saslContinue   = 1,
        conversationId = bson_int32(conv_id),
        payload        = bson_binary(""),
        ["$db"]        = database,
    })
    ok, err = sock:send(make_op_msg(cmd3))
    if not ok then return false, "saslContinue-3 send: " .. err end

    local resp3
    resp3, err = read_op_msg_response(sock)
    if not resp3 then return false, "saslContinue-3 recv: " .. err end

    local r3 = bson_parse_doc(resp3)
    if not r3.ok or r3.ok ~= 1 then
        return false, "saslContinue-3 failed"
    end

    return true
end


-- ============================================================
-- Core send function
-- ============================================================

-- Send pre-encoded BSON documents to a single MongoDB host.
-- Returns true, or false + error string.
local function send_to_one_host(conf, host, port, cmd_doc, docs_bson)
    local sock, err = tcp()
    if not sock then
        return false, "failed to create socket: " .. (err or "unknown")
    end
    sock:settimeout(conf.timeout)

    local ok
    ok, err = sock:connect(host, port)
    if not ok then
        return false, str_format("connect [%s:%d]: %s", host, port, err)
    end

    if conf.ssl then
        ok, err = sock:sslhandshake(true, host, conf.ssl_verify)
        if not ok then
            sock:close()
            return false, str_format("TLS [%s:%d]: %s", host, port, err)
        end
    end

    if conf.username and conf.username ~= "" then
        local auth_db   = conf.auth_database or "admin"
        local mechanism = conf.auth_mechanism or "SCRAM-SHA-1"
        ok, err = scram_auth(sock, auth_db, conf.username, conf.password or "", mechanism)
        if not ok then
            sock:close()
            return false, "SCRAM auth: " .. (err or "unknown")
        end
    end

    ok, err = sock:send(make_op_msg(cmd_doc, "documents", docs_bson))
    if not ok then
        sock:close()
        return false, "send insert: " .. err
    end

    local resp
    resp, err = read_op_msg_response(sock)
    if not resp then
        sock:close()
        return false, "read response: " .. err
    end

    local r = bson_parse_doc(resp)
    if not r.ok or r.ok ~= 1 then
        sock:close()
        return false, str_format("insert command failed (ok=%s)", tostring(r.ok))
    end

    -- Return the connection to the pool for reuse (avoids repeated TCP+TLS+SCRAM setup).
    sock:setkeepalive((conf.keepalive_timeout or 60) * 1000, conf.pool_size or 5)

    -- Log per-document failures (non-fatal when ordered=false).
    if r.writeErrors and type(r.writeErrors) == "table" and #r.writeErrors > 0 then
        core.log.warn(plugin_name, ": ", #r.writeErrors, " document(s) failed to insert into ",
                      conf.database, ".", conf.collection)
    end
    if r.writeConcernError and type(r.writeConcernError) == "table" then
        core.log.warn(plugin_name, ": writeConcernError: ",
                      tostring(r.writeConcernError.errmsg))
    end

    return true
end

local function send_to_mongodb(conf, entries)
    -- Encode all log documents first; pcall catches any encoder panic so a
    -- malformed log entry cannot break the entire batch or the worker.
    local ok_enc, docs_bson = pcall(function()
        local t = {}
        for _, entry in ipairs(entries) do
            tbl_insert(t, encode_bson_doc(entry))
        end
        return t
    end)
    if not ok_enc then
        return false, "BSON encoding failed: " .. tostring(docs_bson)
    end

    local cmd_doc = encode_bson_doc({
        insert  = conf.collection,
        ordered = false,        -- continue past partial write errors
        ["$db"] = conf.database,
    })

    -- Build a shuffled list of hosts so that on retry we contact a different
    -- member of the replica set / K8s endpoint group.
    local host_list = {}
    if conf.hosts and #conf.hosts > 0 then
        local indices = {}
        for i = 1, #conf.hosts do indices[i] = i end
        for i = #indices, 2, -1 do          -- Fisher-Yates shuffle
            local j = math_random(1, i)
            indices[i], indices[j] = indices[j], indices[i]
        end
        for _, idx in ipairs(indices) do
            local h, p = str_match(conf.hosts[idx], "^(.+):(%d+)$")
            tbl_insert(host_list, {h, tonumber(p)})
        end
    else
        tbl_insert(host_list, {conf.host or "127.0.0.1", conf.port or 27017})
    end

    local last_err
    for _, hp in ipairs(host_list) do
        local ok, err = send_to_one_host(conf, hp[1], hp[2], cmd_doc, docs_bson)
        if ok then return true end
        last_err = err
        core.log.warn(plugin_name, ": [", hp[1], ":", hp[2], "] ", err,
                      " — trying next host")
    end
    return false, last_err
end


-- ============================================================
-- Plugin hooks
-- ============================================================

function _M.body_filter(conf, ctx)
    log_util.collect_body(conf, ctx)
end


function _M.log(conf, ctx)
    local metadata = plugin.plugin_metadata(plugin_name)
    local max_pending_entries = metadata and metadata.value
                                and metadata.value.max_pending_entries or nil

    local entry = log_util.get_log_entry(plugin_name, conf, ctx)
    if not entry.route_id then
        entry.route_id = "no-matched"
    end

    if batch_processor_manager:add_entry(conf, entry, max_pending_entries) then
        return
    end

    local func = function(entries)
        return send_to_mongodb(conf, entries)
    end

    batch_processor_manager:add_entry_to_new_processor(conf, entry, ctx,
                                                        func, max_pending_entries)
end


return _M
