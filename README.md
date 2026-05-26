# apisix-mongodb-logger

An [Apache APISIX](https://apisix.apache.org/) logger plugin that ships access logs directly into a [MongoDB](https://www.mongodb.com/) collection using the native MongoDB Wire Protocol (OP_MSG over TCP/TLS).

## Features

- **Native Wire Protocol** – communicates directly over the MongoDB binary protocol; no HTTP intermediary required.
- **SCRAM authentication** – supports SCRAM-SHA-1 (default) and SCRAM-SHA-256 (requires `lua-resty-openssl`), with full mutual authentication (server signature verification per RFC 5802).
- **TLS/SSL** – optional encrypted transport with configurable peer verification.
- **Replica Set / Kubernetes** – the `hosts` array supports multiple endpoints; the plugin randomly selects one per batch with sequential fallback, enabling load distribution across replica-set members or Kubernetes headless-service pod endpoints.
- **Connection pooling** – TCP connections (and TLS sessions) are kept alive across requests via nginx cosocket keepalive pool.
- **Async batching** – log entries are accumulated in memory and flushed asynchronously, with zero impact on request latency.
- **Ordered = false inserts** – individual document failures do not abort the rest of the batch.

## Requirements

- Apache APISIX 3.6+
- MongoDB 3.6+ (OP_MSG support)
- `lua-resty-openssl` (only required for SCRAM-SHA-256)

## Installation

1. Copy the plugin file into your APISIX plugins directory:

   ```bash
   cp apisix/plugins/mongodb-logger.lua /path/to/apisix/apisix/plugins/
   ```

2. Register the plugin in your `config.yaml`:

   ```yaml
   plugins:
     - mongodb-logger
   ```

3. Reload APISIX:

   ```bash
   apisix reload
   ```

## Quick Start

Enable the plugin on a route (no authentication):

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

Send a test request and verify the log entry was stored:

```shell
curl -i http://127.0.0.1:9080/hello

mongosh "mongodb://127.0.0.1:27017/apisix_logs" \
  --eval 'db.access_logs.findOne({}, {_id:0})'
```

## Kubernetes Example

```json
{
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
}
```

## Documentation

- [English](docs/en/latest/plugins/mongodb-logger.md)
- [中文](docs/zh/latest/plugins/mongodb-logger.md)

## Configuration Reference

| Parameter           | Type    | Default         | Description |
|---------------------|---------|-----------------|-------------|
| host                | string  | `"127.0.0.1"`   | MongoDB host (ignored when `hosts` is set). |
| port                | integer | `27017`         | MongoDB port (ignored when `hosts` is set). |
| hosts               | array   | —               | List of `host:port` endpoints for replica sets or K8s. |
| database            | string  | **required**    | Target database name. |
| collection          | string  | **required**    | Target collection name. |
| username            | string  | —               | MongoDB username. |
| password            | string  | —               | MongoDB password (stored encrypted in etcd). |
| auth_database       | string  | `"admin"`       | Authentication database. |
| auth_mechanism      | string  | `"SCRAM-SHA-1"` | `SCRAM-SHA-1` or `SCRAM-SHA-256`. |
| ssl                 | boolean | `false`         | Enable TLS. |
| ssl_verify          | boolean | `true`          | Verify server certificate. |
| timeout             | integer | `3000`          | Socket timeout in milliseconds. |
| pool_size           | integer | `5`             | Keepalive pool size per nginx worker. |
| keepalive_timeout   | integer | `60`            | Idle connection timeout in seconds. |
| log_format          | object  | —               | Custom log format with APISIX/NGINX variable support. |
| include_req_body    | boolean | `false`         | Include request body in log. |
| include_resp_body   | boolean | `false`         | Include response body in log. |

Batch processor parameters (`batch_max_size`, `inactive_timeout`, `buffer_duration`, `max_retry_count`, etc.) are also supported. See [APISIX Batch Processor](https://apisix.apache.org/docs/apisix/batch-processor/).

## License

[Apache License 2.0](LICENSE)
