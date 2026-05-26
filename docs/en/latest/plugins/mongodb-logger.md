---
title: mongodb-logger
keywords:
  - Apache APISIX
  - API Gateway
  - Plugin
  - MongoDB Logger
description: This document contains information about the Apache APISIX mongodb-logger Plugin.
---

<!--
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
-->

## Description

The `mongodb-logger` Plugin ships APISIX access logs directly into a [MongoDB](https://www.mongodb.com/) collection using the native MongoDB Wire Protocol (OP_MSG over TCP/TLS). Each access log is stored as a structured BSON document that mirrors the standard APISIX log format produced by all logger plugins.

Key capabilities:

- **Native Wire Protocol** – communicates directly over the MongoDB binary protocol; no HTTP intermediary is required.
- **SCRAM authentication** – supports SCRAM-SHA-1 (default) and SCRAM-SHA-256 (requires `lua-resty-openssl`), including full mutual authentication (server signature verification per RFC 5802).
- **TLS/SSL** – optional encrypted transport with configurable peer verification.
- **Replica Set / Kubernetes** – the `hosts` array allows multiple `host:port` endpoints. The plugin randomly selects an endpoint per batch (with sequential fallback on failure), enabling natural load distribution across replica-set members or Kubernetes headless-service endpoints.
- **Connection pooling** – TCP connections (and TLS sessions) are kept alive across requests via nginx's cosocket keepalive pool, avoiding repeated handshake overhead.
- **Batching** – log entries are accumulated and flushed in configurable batches, minimising round-trips to MongoDB.
- **Ordered = false inserts** – individual document failures do not abort the rest of the batch; per-document errors are surfaced as APISIX warnings.

## Attributes

| Name                | Type    | Required | Default       | Valid values                     | Description |
|---------------------|---------|----------|---------------|----------------------------------|-------------|
| host                | string  | False    | `"127.0.0.1"` |                                  | MongoDB host. Ignored when `hosts` is set. |
| port                | integer | False    | `27017`       | [1, 65535]                       | MongoDB port. Ignored when `hosts` is set. |
| hosts               | array   | False    |               | `["host:port", ...]`             | List of MongoDB endpoints. When provided, the plugin randomly selects one per batch and falls back to the others on failure. Suitable for replica sets and Kubernetes headless services. |
| database            | string  | True     |               |                                  | Target database name (must not be empty). |
| collection          | string  | True     |               |                                  | Target collection name (must not be empty). |
| username            | string  | False    |               |                                  | MongoDB username. Leave empty to skip authentication. |
| password            | string  | False    |               |                                  | MongoDB password. Stored encrypted in etcd (see `encrypt_fields` below). |
| auth_database       | string  | False    | `"admin"`     |                                  | Database that holds the MongoDB user credentials (typically `admin`). |
| auth_mechanism      | string  | False    | `"SCRAM-SHA-1"` | `"SCRAM-SHA-1"`, `"SCRAM-SHA-256"` | SCRAM authentication mechanism. `SCRAM-SHA-256` requires `lua-resty-openssl`. |
| ssl                 | boolean | False    | `false`       |                                  | Enable TLS/SSL. |
| ssl_verify          | boolean | False    | `true`        |                                  | Verify the server certificate when `ssl` is `true`. |
| timeout             | integer | False    | `3000`        | [1, ...]                         | Socket timeout in milliseconds. |
| pool_size           | integer | False    | `5`           | [1, ...]                         | Maximum number of idle TCP connections kept in the cosocket keepalive pool per nginx worker. |
| keepalive_timeout   | integer | False    | `60`          | [1, ...]                         | Idle connection keepalive timeout in seconds. |
| name                | string  | False    | `"mongodb-logger"` |                             | Unique logger name reported in `apisix_batch_process_entries` (Prometheus). |
| log_format          | object  | False    |               |                                  | Log format declared as key-value pairs in JSON. Values support strings and nested objects. Within strings, [APISIX](../apisix-variable.md) or [NGINX](http://nginx.org/en/docs/varindex.html) variables can be referenced by prefixing with `$`. |
| include_req_body    | boolean | False    | `false`       |                                  | When `true`, includes the request body in the log. Bodies too large to buffer in memory will not be logged (nginx limitation). |
| include_req_body_expr  | array | False  |               |                                  | [lua-resty-expr](https://github.com/api7/lua-resty-expr) filter: request body is logged only when this expression evaluates to `true`. Requires `include_req_body = true`. |
| include_resp_body   | boolean | False    | `false`       |                                  | When `true`, includes the response body in the log. |
| include_resp_body_expr | array | False  |               |                                  | [lua-resty-expr](https://github.com/api7/lua-resty-expr) filter for `include_resp_body`. |

NOTE: `encrypt_fields = {"password"}` is defined in the plugin schema, which means that the `password` field is stored encrypted in etcd. See [encrypted storage fields](../plugin-develop.md#encrypted-storage-fields).

This plugin supports using batch processors to aggregate and process entries (logs/data) in a batch. This avoids the need for frequently submitting the data. The batch processor submits data every `5` seconds or when the data in the queue reaches `1000`. See [Batch Processor](../batch-processor.md#configuration) for more information or setting your custom configuration.

### Default log format

Each log entry is a BSON document that follows the standard APISIX unified log format:

```json
{
    "request": {
        "method": "GET",
        "uri": "/hello",
        "url": "http://localhost:9080/hello",
        "size": 87,
        "headers": {
            "host": "localhost",
            "connection": "close"
        },
        "querystring": {}
    },
    "response": {
        "status": 200,
        "size": 118,
        "headers": {
            "content-type": "text/plain",
            "content-length": "12"
        }
    },
    "upstream": "127.0.0.1:1980",
    "upstream_latency": 3,
    "apisix_latency": 8.999,
    "latency": 11.999,
    "start_time": 1704507612177,
    "client_ip": "127.0.0.1",
    "route_id": "1",
    "service_id": "",
    "server": {
        "hostname": "apisix-node",
        "version": "3.9.0"
    }
}
```

## Metadata

You can also set the format of the logs by configuring the Plugin metadata. The following configurations are available:

| Name       | Type    | Required | Default | Description |
|------------|---------|----------|---------|-------------|
| log_format | object  | False    |         | Log format declared as key-value pairs in JSON. Values support strings and nested objects. Within strings, [APISIX](../apisix-variable.md) or [NGINX](http://nginx.org/en/docs/varindex.html) variables can be referenced by prefixing with `$`. |
| max_pending_entries | integer | False | | Maximum number of pending entries buffered in the batch processor before it starts dropping them. |

:::info IMPORTANT

Configuring the Plugin metadata is global in scope. This means that it will take effect on all Routes and Services which use the `mongodb-logger` Plugin.

:::

```shell
curl http://127.0.0.1:9180/apisix/admin/plugin_metadata/mongodb-logger \
  -H "X-API-KEY: $admin_key" -X PUT -d '
{
    "log_format": {
        "host": "$host",
        "@timestamp": "$time_iso8601",
        "client_ip": "$remote_addr"
    }
}'
```

## Enable Plugin

:::note
You can fetch the `admin_key` from `config.yaml` and save to an environment variable with the following command:

```bash
admin_key=$(yq '.deployment.admin.admin_key[0].key' conf/config.yaml | sed 's/"//g')
```

:::

### Basic configuration (no authentication)

```shell
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: $admin_key" -X PUT -d '
{
    "uri": "/hello",
    "plugins": {
        "mongodb-logger": {
            "host": "127.0.0.1",
            "port": 27017,
            "database": "apisix_logs",
            "collection": "access_logs"
        }
    },
    "upstream": {
        "type": "roundrobin",
        "nodes": { "127.0.0.1:1980": 1 }
    }
}'
```

### With SCRAM-SHA-1 authentication

```shell
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: $admin_key" -X PUT -d '
{
    "uri": "/hello",
    "plugins": {
        "mongodb-logger": {
            "host": "mongo.internal",
            "port": 27017,
            "database": "apisix_logs",
            "collection": "access_logs",
            "username": "apisix",
            "password": "s3cr3t",
            "auth_database": "admin",
            "auth_mechanism": "SCRAM-SHA-1"
        }
    },
    "upstream": {
        "type": "roundrobin",
        "nodes": { "127.0.0.1:1980": 1 }
    }
}'
```

### TLS with SCRAM-SHA-256

```shell
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: $admin_key" -X PUT -d '
{
    "uri": "/hello",
    "plugins": {
        "mongodb-logger": {
            "host": "mongo.example.com",
            "port": 27017,
            "database": "apisix_logs",
            "collection": "access_logs",
            "username": "apisix",
            "password": "s3cr3t",
            "auth_mechanism": "SCRAM-SHA-256",
            "ssl": true,
            "ssl_verify": true
        }
    },
    "upstream": {
        "type": "roundrobin",
        "nodes": { "127.0.0.1:1980": 1 }
    }
}'
```

### Replica Set / Kubernetes headless service

Provide all replica-set members (or all headless-service pod IPs) in the `hosts` array. The plugin randomly selects one endpoint per batch. If a selected endpoint is unreachable, the remaining endpoints are tried in order before the batch is abandoned. This enables zero-configuration load balancing across replica-set members and survives rolling restarts of MongoDB pods.

```shell
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: $admin_key" -X PUT -d '
{
    "uri": "/hello",
    "plugins": {
        "mongodb-logger": {
            "hosts": [
                "mongo-0.mongo.default.svc.cluster.local:27017",
                "mongo-1.mongo.default.svc.cluster.local:27017",
                "mongo-2.mongo.default.svc.cluster.local:27017"
            ],
            "database": "apisix_logs",
            "collection": "access_logs",
            "username": "apisix",
            "password": "${{MONGODB_PASSWORD}}"
        }
    },
    "upstream": {
        "type": "roundrobin",
        "nodes": { "127.0.0.1:1980": 1 }
    }
}'
```

When deploying in Kubernetes, sensitive values (username, password) can be injected from Kubernetes Secret objects using the APISIX `${{ENV_VAR}}` syntax. Store the secret as an environment variable in the APISIX pod and reference it in the plugin configuration.

## Example usage

After enabling the plugin, send a test request:

```shell
curl -i http://127.0.0.1:9080/hello
```

Verify that the log entry was written to MongoDB:

```shell
mongosh "mongodb://apisix:s3cr3t@127.0.0.1:27017/apisix_logs" \
  --eval 'db.access_logs.findOne({}, {_id:0})'
```

Expected output (truncated):

```json
{
  "request": { "method": "GET", "uri": "/hello", ... },
  "response": { "status": 200, ... },
  "client_ip": "127.0.0.1",
  "latency": 12.5,
  "start_time": 1704507612177
}
```

## Design notes

### Wire Protocol

The plugin communicates directly over the [MongoDB Wire Protocol](https://www.mongodb.com/docs/manual/reference/mongodb-wire-protocol/) using `OP_MSG` (opCode 2013). The insert command is sent as a kind-0 section (command BSON document) plus a kind-1 Document Sequence for the log entries. Using a Document Sequence avoids embedding entries as a BSON array, which removes the single-document 16 MB BSON size ceiling for large batches.

### BSON encoding

BSON is encoded from scratch using LuaJIT FFI for type-safe little-endian integer and IEEE-754 double serialisation. Whole numbers in the range `[-2³¹, 2³¹-1]` are encoded as BSON Int32 (type `0x10`) rather than Double, matching the representation MongoDB uses natively. Circular references and excessively deep nested tables are detected and truncated to prevent encoder panics.

### SCRAM authentication

SCRAM authentication follows [RFC 5802](https://datatracker.ietf.org/doc/html/rfc5802) and includes **mutual authentication**: the server's final message signature (`v=` field) is verified against the client's computed `ServerSignature`, preventing MITM attacks. PBKDF2 derivations (≈10 000 iterations per MongoDB default) are cached in an LRU cache keyed by `(mechanism, password-digest, salt, iterations)` to amortise the cost across batches.

### Connection pooling

On a successful insert, the TCP connection is returned to nginx's cosocket keepalive pool via `setkeepalive`. Subsequent batches from the same nginx worker reuse the existing connection, avoiding repeated TCP handshake, TLS negotiation, and SCRAM authentication overhead. Connections are only closed (not pooled) on error paths.

## Delete Plugin

To remove the `mongodb-logger` Plugin, delete the corresponding configuration from the Plugin configuration. APISIX will automatically reload and you do not have to restart for this to take effect.

```shell
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: $admin_key" -X PUT -d '
{
    "uri": "/hello",
    "plugins": {},
    "upstream": {
        "type": "roundrobin",
        "nodes": { "127.0.0.1:1980": 1 }
    }
}'
```
