# PreConnect Client Protocol

> 本文档描述当前仓库中已经实现并验证通过的真实协议。目标是让移动端或其他客户端可以按当前代码直接完成发现、配对、鉴权和传感器数据拉取。

## 1. 当前模型

- 主机端负责周期性广播自己的服务信息。
- 客户端负责发现主机，并主动发起配对请求。
- 配对成功后，服务端返回一个临时的 sessionToken。
- 客户端后续访问 telemetry 接口时必须携带 sessionToken。
- 主机端不维护“已发现移动端列表”，也不会主动向移动端发送邀请。

这是一个最小可运行版本，重点是先保证联通性和协议稳定性，而不是追求复杂安全模型。

## 2. 角色定义

### 2.1 Provider（主机端）

主机端运行在 Windows PC 上，当前由以下模块组成：

- DiscoveryService
  - 通过 UDP 广播和组播发送主机公告。
- DataProviderHost
  - 通过 HTTP 提供 /api/ping、/api/status、/api/pair、/api/telemetry。
- PairingService
  - 生成 6 位 PIN，验证配对请求，签发 sessionToken。
- HardwareMonitorService
  - 采集 LibreHardwareMonitor 的硬件快照，并作为 telemetry 返回。

### 2.2 Client（客户端）

客户端可以是移动端、桌面端或命令行工具，职责如下：

- 监听并解析主机广播。
- 根据广播中的 endpoint 或 ip/port 确认可访问地址。
- 向 /api/pair 提交 PIN。
- 保存 /api/pair 返回的 sessionToken 和 endpoint。
- 使用 sessionToken 调用 /api/telemetry。

## 3. 发现协议

### 3.1 传输方式

- UDP 广播地址：255.255.255.255
- UDP 组播地址：224.0.0.251
- 默认发现端口：53530
- 默认广播周期：2000 ms

当前实现中，主机端会同时向广播地址和组播地址发送同样的 announce 包。

### 3.2 announce 消息格式

消息类型：preconnect/announce

```json
{
  "type": "preconnect/announce",
  "deviceId": "c9dcbec2-7d77-4f6f-a5d2-b5e2d23f33ce",
  "name": "DESKTOP-ABC123",
  "port": 5005,
  "service": "PreConnect",
  "endpoint": "http://192.168.1.12:5005/"
}
```

字段说明：

- type
  - 固定为 preconnect/announce
- deviceId
  - 主机的持久化设备 ID
- name
  - 主机显示名称，默认是机器名
- port
  - HTTP 服务端口，默认 5005
- service
  - 服务名，默认 PreConnect
- endpoint
  - 建议客户端直接使用的完整 HTTP 根地址

### 3.3 客户端处理建议

- 优先使用 endpoint 字段直接访问服务。
- 若 endpoint 不可用，再结合 UDP 源地址和 port 进行兜底拼接。
- 客户端应对重复 announce 做去重。
- 当前协议没有 ACK、pair-offer、反向发现等机制。

## 4. 配对协议

### 4.1 配对模型

主机端通过 UI 展示一个 6 位 PIN。客户端拿到该 PIN 后主动调用 /api/pair 完成配对。

当前实现特征：

- PIN 默认有效期：5 分钟
- 每次刷新 PIN 会覆盖上一次 PIN
- sessionToken 默认有效期：12 小时
- 当前没有长期信任存储，也没有 TLS 证书绑定

### 4.2 主机端准备

主机端通过 PairingService 生成当前 PIN：

- PIN 为 6 位数字字符串
- UI 中展示 PIN 和过期时间

### 4.3 客户端请求

请求：

```http
POST /api/pair
Content-Type: application/json
```

请求体：

```json
{
  "pin": "758863",
  "deviceId": "test-device-001",
  "name": "TestPhone"
}
```

字段说明：

- pin
  - 必填。主机当前显示的 6 位 PIN。
- deviceId
  - 可选。客户端设备 ID。若不提供，服务端会生成一个 GUID。
- name
  - 可选。客户端设备名。若不提供，服务端会使用 Unknown。

### 4.4 成功响应

HTTP 状态码：200 OK

```json
{
  "ok": true,
  "sessionToken": "Base64TokenValue...",
  "sessionTokenExpiresUtc": "2026-03-13T05:34:52.2777041+00:00",
  "serverName": "DESKTOP-ABC123",
  "endpoint": "http://192.168.1.12:5005/",
  "deviceId": "test-device-001",
  "deviceName": "TestPhone"
}
```

字段说明：

- ok
  - 成功时为 true
- sessionToken
  - 后续访问 /api/telemetry 的会话令牌
- sessionTokenExpiresUtc
  - token 过期时间（UTC）
- serverName
  - 主机端机器名
- endpoint
  - 客户端后续调用接口建议使用的根地址
- deviceId
  - 服务端确认后的客户端设备 ID
- deviceName
  - 服务端确认后的客户端设备名称

### 4.5 失败响应

#### 请求体非法

HTTP 状态码：400 BadRequest

```json
{
  "ok": false,
  "error": "Invalid request"
}
```

#### PIN 无效或已过期

HTTP 状态码：400 BadRequest

```json
{
  "ok": false,
  "error": "PIN invalid or expired"
}
```

#### 服务端内部异常

HTTP 状态码：500 InternalServerError

```json
{
  "ok": false,
  "error": "..."
}
```

## 5. 会话与鉴权

### 5.1 sessionToken 行为

- sessionToken 在 /api/pair 成功时生成。
- sessionToken 当前由服务端保存在内存中。
- 服务端会清理已过期 token。
- 服务重启后，所有 token 都会失效，客户端需要重新配对。

### 5.2 telemetry 鉴权方式

当前 /api/telemetry 需要有效 sessionToken。支持以下三种传递方式：

#### 方式 A：自定义请求头

```http
X-Session-Token: <sessionToken>
```

#### 方式 B：Bearer Token

```http
Authorization: Bearer <sessionToken>
```

#### 方式 C：查询字符串

```http
GET /api/telemetry?sessionToken=<sessionToken>
```

建议优先使用方式 A 或方式 B，不建议长期使用查询字符串方式。

### 5.3 未授权响应

HTTP 状态码：401 Unauthorized

```json
{
  "ok": false,
  "error": "Missing or invalid session token"
}
```

## 6. HTTP 接口

服务根地址默认是：

```text
http://<host>:5005/
```

### 6.1 GET /api/ping

用途：

- 快速探测服务是否在线

成功响应：

```json
{
  "ok": true,
  "name": "PreConnect",
  "time": "2026-03-13T00:00:00+00:00"
}
```

### 6.2 GET /api/status

用途：

- 获取服务状态和基础元数据

成功响应示例：

```json
{
  "name": "PreConnect Data Provider",
  "isRunning": true,
  "endpoint": "http://192.168.1.12:5005/",
  "activeConnections": 1,
  "lastRequestUtc": "2026-03-13T00:00:00+00:00",
  "machineName": "DESKTOP-ABC123",
  "os": "Microsoft Windows NT 10.0.26100.0",
  "version": "1.0.0.0"
}
```

### 6.3 GET /api/telemetry

用途：

- 返回完整硬件快照
- 需要有效 sessionToken

成功响应结构：

```json
{
  "ok": true,
  "deviceId": "test-device-001",
  "deviceName": "TestPhone",
  "expiresAtUtc": "2026-03-13T05:34:52.2777041+00:00",
  "snapshot": {
    "components": [
      {
        "hardwareId": "/motherboard",
        "hardwareName": "ASUS FA507XV",
        "hardwareType": 0,
        "manufacturer": "",
        "sensors": [
          {
            "sensorId": "/gpu-nvidia/load/0",
            "sensorName": "GPU Core",
            "sensorType": 5,
            "value": 42.0,
            "min": 5.0,
            "max": 85.0,
            "hardwarePath": "NVIDIA GeForce RTX ...",
            "index": 0
          }
        ],
        "children": [],
        "properties": {
          "Path": "/motherboard"
        }
      }
    ]
  }
}
```

说明：

- snapshot.components 为硬件组件数组。
- 每个组件包含自己的 sensors 和递归的 children。
- 传感器值使用 float?，若底层采集值无效、非有限数或不可用，则服务端会返回 null。

异常响应：

- 401 Unauthorized

```json
{
  "ok": false,
  "error": "Missing or invalid session token"
}
```

- 500 InternalServerError

```json
{
  "ok": false,
  "error": "...",
  "type": "System.SomeException"
}
```

## 7. 推荐客户端流程

### 7.1 标准流程

1. 监听 UDP preconnect/announce。
2. 解析 endpoint。
3. 调用 GET /api/ping 和 GET /api/status，确认服务可达。
4. 让用户输入主机上显示的 PIN。
5. 调用 POST /api/pair。
6. 保存 sessionToken、sessionTokenExpiresUtc、endpoint。
7. 使用 X-Session-Token 或 Authorization: Bearer 调用 GET /api/telemetry。
8. 按需轮询 telemetry，例如每 1 到 2 秒一次。

### 7.2 客户端最小示例

```http
GET http://192.168.1.12:5005/api/ping
```

```http
POST http://192.168.1.12:5005/api/pair
Content-Type: application/json

{
  "pin": "758863",
  "deviceId": "test-device-001",
  "name": "TestPhone"
}
```

```http
GET http://192.168.1.12:5005/api/telemetry
X-Session-Token: <sessionToken>
```

## 8. 当前限制

以下限制是当前 MVP 的已知设计选择：

- 没有 TLS
- 没有设备长期信任关系持久化
- 没有 token 刷新接口
- 没有 WebSocket 或推送通道
- 没有增量 telemetry，仅返回完整快照
- 服务重启后必须重新配对

## 9. 对接建议

如果你正在实现移动端客户端，建议至少做到：

- 对 announce 做去重和过期淘汰
- 对 /api/pair 的 400/500 做清晰提示
- 对 /api/telemetry 的 401 自动触发重新配对流程
- 对 telemetry JSON 做兼容解析，不依赖固定组件数量
- 在 UI 上展示 token 过期或连接失效状态

## 10. 调试建议

仓库中提供了一个 CLI 工具用于协议验证：

- 项目：PreConnect.EndpointProbe

示例：

```powershell
dotnet run --project .\PreConnect.EndpointProbe\PreConnect.EndpointProbe.csproj -- --base-url http://127.0.0.1:5005/ --pin 123456 --name TestPhone --device-id test-device-001 --poll-count 5 --poll-interval-seconds 2
```

这个工具会：

1. 检查 /api/ping
2. 检查 /api/status
3. 调用 /api/pair
4. 配对成功后持续拉取完整 /api/telemetry

---

如果后续协议发生变化，应以当前代码实现为准，同时同步更新本文档。
