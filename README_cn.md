# apisix-mongodb-logger

Apache APISIX 的日志插件，通过原生 MongoDB Wire 协议（TCP/TLS 上的 OP_MSG）将访问日志直接写入 [MongoDB](https://www.mongodb.com/) 集合。

## 特性

- **原生 Wire 协议** — 直接通过 MongoDB 二进制协议通信，无需 HTTP 中间层。
- **SCRAM 身份认证** — 支持 SCRAM-SHA-1（默认）和 SCRAM-SHA-256（需要 `lua-resty-openssl`），完整实现双向认证（按 RFC 5802 验证服务端签名，防御中间人攻击）。
- **TLS/SSL** — 可选加密传输，支持配置服务端证书验证。
- **副本集 / Kubernetes** — `hosts` 数组支持多个端点，每批次随机选取一个，失败时依次尝试其余端点，天然适配副本集成员和 Kubernetes Headless Service。
- **连接池** — 通过 nginx cosocket keepalive 池在请求间复用 TCP 连接及 TLS 会话，避免重复握手开销。
- **异步批量写入** — 日志条目在内存中积累后异步刷写，对请求处理延迟零影响。
- **无序插入（`ordered=false`）** — 单条文档写入失败不中止整批，各文档级错误以 APISIX 警告日志上报。

## 环境要求

- Apache APISIX 3.6+
- MongoDB 3.6+（需支持 OP_MSG）
- `lua-resty-openssl`（仅 SCRAM-SHA-256 时需要）

## 安装

1. 将插件文件复制到 APISIX 插件目录：

   ```bash
   cp apisix/plugins/mongodb-logger.lua /path/to/apisix/apisix/plugins/
   ```

2. 在 `config.yaml` 中注册插件：

   ```yaml
   plugins:
     - mongodb-logger
   ```

3. 重新加载 APISIX：

   ```bash
   apisix reload
   ```

## 快速开始

在路由上启用插件（无认证）：

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

发送测试请求，并验证日志已写入 MongoDB：

```shell
curl -i http://127.0.0.1:9080/hello

mongosh "mongodb://127.0.0.1:27017/apisix_logs" \
  --eval 'db.access_logs.findOne({}, {_id:0})'
```

## Kubernetes 示例

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

密码等敏感信息可通过 APISIX 的 `${{ENV_VAR}}` 语法从 Kubernetes Secret 注入，无需明文写入配置。

## 配置参数

| 参数名                | 类型    | 默认值            | 说明 |
|-----------------------|---------|-------------------|------|
| host                  | string  | `"127.0.0.1"`     | MongoDB 主机地址，设置 `hosts` 后忽略。 |
| port                  | integer | `27017`           | MongoDB 端口，设置 `hosts` 后忽略。 |
| hosts                 | array   | —                 | MongoDB 端点列表，格式 `["host:port", ...]`，适用于副本集和 K8s。 |
| database              | string  | **必填**          | 目标数据库名称。 |
| collection            | string  | **必填**          | 目标集合名称。 |
| username              | string  | —                 | MongoDB 用户名，留空则跳过认证。 |
| password              | string  | —                 | MongoDB 密码，在 etcd 中加密存储。 |
| auth_database         | string  | `"admin"`         | 存放用户凭据的认证数据库。 |
| auth_mechanism        | string  | `"SCRAM-SHA-1"`   | 认证机制：`SCRAM-SHA-1` 或 `SCRAM-SHA-256`。 |
| ssl                   | boolean | `false`           | 启用 TLS/SSL。 |
| ssl_verify            | boolean | `true`            | 启用 TLS 时是否验证服务端证书。 |
| timeout               | integer | `3000`            | Socket 超时时间（毫秒）。 |
| pool_size             | integer | `5`               | 每个 nginx worker 的 keepalive 连接池大小。 |
| keepalive_timeout     | integer | `60`              | 空闲连接 keepalive 超时时间（秒）。 |
| log_format            | object  | —                 | 自定义日志格式，支持 APISIX/NGINX 变量（以 `$` 前缀引用）。 |
| include_req_body      | boolean | `false`           | 是否在日志中记录请求体。 |
| include_resp_body     | boolean | `false`           | 是否在日志中记录响应体。 |

批处理参数（`batch_max_size`、`inactive_timeout`、`buffer_duration`、`max_retry_count` 等）同样支持，详见 [APISIX 批处理器文档](https://apisix.apache.org/docs/apisix/batch-processor/)。

## 文档

- [English](docs/en/latest/plugins/mongodb-logger.md)
- [中文文档（含性能设计与鲁棒性设计）](docs/zh/latest/plugins/mongodb-logger.md)

## 许可证

[Apache License 2.0](LICENSE)
