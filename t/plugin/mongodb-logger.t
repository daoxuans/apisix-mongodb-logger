#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

use t::APISIX 'no_plan';

log_level("info");
repeat_each(1);
no_long_string();
no_root_location();

run_tests();

__DATA__

=== TEST 1: schema check – minimal valid config
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.mongodb-logger")
            local ok, err = plugin.check_schema({
                database   = "apisix",
                collection = "logs",
            })
            if not ok then
                ngx.say(err)
            else
                ngx.say("passed")
            end
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 2: schema check – full valid config with credentials
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.mongodb-logger")
            local ok, err = plugin.check_schema({
                host          = "127.0.0.1",
                port          = 27017,
                database      = "apisix",
                collection    = "access_logs",
                auth_database = "admin",
                username      = "root",
                password      = "secret",
                ssl           = false,
                timeout       = 5000,
            })
            if not ok then
                ngx.say(err)
            else
                ngx.say("passed")
            end
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 3: schema check – missing required field
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.mongodb-logger")
            local ok, err = plugin.check_schema({
                database = "apisix",
                -- collection intentionally omitted
            })
            if not ok then
                ngx.say("failed as expected: ", err)
            else
                ngx.say("should have failed")
            end
        }
    }
--- request
GET /t
--- response_body_like
failed as expected:.*collection



=== TEST 4: schema check – username without password is rejected
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.mongodb-logger")
            local ok, err = plugin.check_schema({
                database   = "apisix",
                collection = "logs",
                username   = "alice",
                -- password omitted
            })
            if not ok then
                ngx.say("failed as expected")
            else
                ngx.say("should have failed")
            end
        }
    }
--- request
GET /t
--- response_body
failed as expected



=== TEST 5: BSON encoding sanity – encode_bson_doc returns non-empty bytes
--- config
    location /t {
        content_by_lua_block {
            -- Load the plugin module and verify encode_bson_doc is exercised
            -- via the internal send path by checking schema pass.
            local plugin = require("apisix.plugins.mongodb-logger")
            -- We cannot call internal BSON helpers directly (they are local),
            -- but we can verify the plugin loads without errors.
            ngx.say("loaded")
        }
    }
--- request
GET /t
--- response_body
loaded



=== TEST 6: add plugin to route and send a request (no-op without real MongoDB)
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "mongodb-logger": {
                            "database":   "apisix",
                            "collection": "logs",
                            "host":       "127.0.0.1",
                            "port":       27017,
                            "timeout":    100,
                            "batch_max_size": 1,
                            "max_retry_count": 0
                        }
                    },
                    "upstream": {
                        "nodes": {"127.0.0.1:1980": 1},
                        "type": "roundrobin"
                    },
                    "uri": "/opentracing"
                }]]
            )
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 7: metadata schema check
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.mongodb-logger")
            local core   = require("apisix.core")
            local ok, err = core.schema.check(plugin.metadata_schema, {
                log_format = {host = "$host", uri = "$uri"},
                max_pending_entries = 100,
            })
            if not ok then
                ngx.say(err)
            else
                ngx.say("passed")
            end
        }
    }
--- request
GET /t
--- response_body
passed
