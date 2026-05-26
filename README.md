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

## 设计说明

### Wire 协议

本插件直接通过 [MongoDB Wire 协议](https://www.mongodb.com/docs/manual/reference/mongodb-wire-protocol/)使用 `OP_MSG`（opCode 2013）通信。insert 命令以 kind-0 节（命令 BSON 文档）加 kind-1 文档序列（Document Sequence）的形式发送日志条目。使用文档序列可避免将条目嵌入 BSON 数组，从而规避大批次下单文档 16 MB 的 BSON 大小上限。

### BSON 编码

BSON 编码完全由插件自行实现，通过 LuaJIT FFI 完成类型安全的小端整数和 IEEE-754 双精度浮点序列化。范围在 `[-2³¹, 2³¹-1]` 内的整数会编码为 BSON Int32（类型 `0x10`）而非 Double，与 MongoDB 的原生表示保持一致。循环引用和超深嵌套表均会被检测并截断，防止编码器崩溃。

### SCRAM 认证

SCRAM 认证遵循 [RFC 5802](https://datatracker.ietf.org/doc/html/rfc5802)，并实现了**双向认证**：服务端最终消息中的签名字段（`v=`）会与客户端计算的 `ServerSignature` 进行核对，可防御中间人攻击。PBKDF2 密钥派生（MongoDB 默认约 10 000 次迭代）的结果会以 `(机制, 密码摘要, 盐值, 迭代次数)` 为键缓存在 LRU 缓存中，摊销跨批次的计算开销。

### 连接池

每次 insert 成功后，TCP 连接通过 `setkeepalive` 归还至 nginx cosocket keepalive 池。同一 nginx worker 后续批次可直接复用已有连接，避免重复进行 TCP 握手、TLS 协商和 SCRAM 认证。只有在出现错误时才会真正关闭连接。

## 性能设计

### 异步批量写入

插件的 `log` 钩子仅执行两件事：构建日志结构体、将其放入内存队列。整个过程耗时不超过 1 µs，对请求处理延迟零影响。实际的网络写入由 `ngx.timer.at` 异步回调在独立的轻量协程中执行，与请求处理路径完全隔离。

批处理触发条件（满足任一即触发）：

- 队列积累条目数达到 `batch_max_size`（默认 1000）— 数量触发，立即 flush。
- 最后一条日志入队后超过 `inactive_timeout` 秒（默认 5s）仍无新条目 — 空闲超时触发。
- 第一条日志入队后超过 `buffer_duration` 秒（默认 60s）— 最大缓冲时间触发。

每批次仅产生**一次** MongoDB round-trip，批次越大，单条日志的网络开销越低。

### 连接复用降低握手开销

建立一条 MongoDB 连接的全流程代价：

| 阶段 | 典型耗时 |
|------|---------|
| TCP 三次握手 | 0.5–20 ms（取决于网络距离） |
| TLS 握手（启用时）| 5–15 ms |
| SCRAM 三轮握手（启用时）| 1–3 个 RTT |

通过 `setkeepalive` 将连接归还连接池后，后续批次复用同一连接，上述三个阶段全部跳过，仅剩一次 OP_MSG 发送和响应读取。`pool_size`（默认 5）控制每个 nginx worker 保留的最大空闲连接数，高并发场景可适当调大。

### PBKDF2 缓存

SCRAM 认证中的 PBKDF2 密钥派生默认需要约 10 000 次哈希迭代，首次约耗时 40 ms。插件使用 LRU 缓存（容量 64，TTL 3600s）存储派生结果，键为 `(机制:密码摘要:盐值:迭代次数)`。由于 MongoDB 用户的盐值是稳定的，实际上该缓存命中率极高，后续批次的认证开销接近于零。

### BSON 编码效率

- 使用 LuaJIT FFI union 进行数值序列化，避免 Lua 层的位运算。
- 整数优先编码为 BSON Int32（4 字节）而非 Double（8 字节），减少传输体积。
- `ordered=false` 允许 MongoDB 服务端对批内文档并行写入，提升服务端吞吐量。

### 性能调优参考

| 场景 | 建议 |
|------|------|
| 高吞吐、延迟不敏感 | 增大 `batch_max_size`（如 5000），增大 `buffer_duration` |
| 低延迟、实时性要求高 | 减小 `inactive_timeout`（如 1s） |
| 高并发多 worker | 增大 `pool_size`（如 10–20） |
| 同可用区部署 | RTT < 1 ms，连接复用价值最大化 |

## 鲁棒性设计

### BSON 编码隔离

整批日志的 BSON 编码被包裹在 `pcall` 中执行。若某条日志包含无法编码的异常数据（如极端嵌套、非预期 userdata），编码器 panic 只会导致当前批次被丢弃并记录错误日志，**不会造成 nginx worker 崩溃，不会影响后续批次**。

### 深度与循环引用保护

BSON 编码器内置两层防护：

- **循环引用检测**：编码过程中维护 `seen` 哈希表，检测到循环引用时将该字段编码为 BSON Null，而非无限递归。
- **最大深度限制**：嵌套深度超过 `MAX_BSON_DEPTH`（10 层）时，将截断为字符串 `"(truncated)"`。

### 多端点故障转移

`hosts` 数组中的端点在每批次开始前通过 Fisher-Yates 算法随机打乱顺序。插件按顺序尝试各端点，成功则立即返回，失败则记录 warn 日志并尝试下一个。只有全部端点均不可达时，本批次才被标记为失败，由批处理器的重试机制（`max_retry_count`）接管。

### 批处理器重试机制

APISIX 批处理器提供内置重试能力：

- `max_retry_count`（默认 0）：发送失败时的最大重试次数。
- `retry_delay`（默认 1s）：每次重试前的等待时间。

若重试次数耗尽仍失败，批处理器记录 error 日志并丢弃该批次，保证内存队列不会无限增长。

### 连接错误隔离

错误路径（连接失败、TLS 失败、认证失败、写入失败、读取失败）均会调用 `sock:close()` 主动关闭连接，确保损坏的连接不会被归还至连接池污染后续批次。

### 待处理条目上限

通过插件元数据的 `max_pending_entries` 字段可设置内存队列的最大积压条目数。当 MongoDB 持续不可达导致积压过大时，新日志条目将被丢弃并记录 error 日志，防止内存无限增长影响网关稳定性。

### ffi.cdef 热重载保护

`ffi.cdef` 类型定义被包裹在 `pcall` 中，若遇到"already defined"错误（nginx worker 热重载时 LuaJIT 状态不清空导致）会静默忽略，避免模块重载时抛出 fatal error 导致 worker 崩溃。

## 文档

- [English](docs/en/latest/plugins/mongodb-logger.md)
- [中文文档（含完整属性说明与示例）](docs/zh/latest/plugins/mongodb-logger.md)

## 许可证

[Apache License 2.0](LICENSE)
