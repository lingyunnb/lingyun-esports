# 祁连山电竞

游戏陪玩 / 代练平台。老板端（Flutter）、管理后台（Vue3）、后端（NestJS），外加一个已经并进老板端的打手端。

跑起来是一条完整的线：浏览服务 → 下单 → 抢单或派单 → 结算 → 聊天 → 提现审核。

MIT 协议，商用改卖随便，不用问。

---

## 端

| | 技术栈 | 干什么 |
|---|---|---|
| 老板端 | Flutter (Android) | 浏览、下单、订单、消息、我的。同一 App 内可切到打手态接单 |
| 打手端 | Flutter (Android) | 已停止更新，能力挪进老板端了，代码留着 |
| 管理后台 | Vue 3 + TS + Vite + Naive UI | 用户、商品、订单、余额、客服、提现审核、系统设置、操作日志 |
| 后端 | NestJS + MySQL 8 + Redis 7 + Socket.IO | 所有业务判定在这里，客户端一律不可信 |
| 共享包 | Dart | 设计 token、API 客户端、模型、云更新 |

```
apps/boss-app/      Flutter 老板端（含打手态）
apps/worker-app/    Flutter 打手端（停更，保留）
apps/packages/core/ 共享 Dart 包
server/             NestJS（/api/v1，Swagger 在 /api-docs）
admin-web/          管理后台
infra/              Docker Compose（MySQL 8.4 + Redis 7）+ 运维脚本
docs/               规范文档
site/               落地页和设计稿
```

---

## 几个做的时候的选择

**不接支付通道。**
充值 = 展示收款码 → 用户线下付款 → 传截图 → 管理员核对后手工加余额。
提现 = 申请时立即扣款锁定 → 管理员线下打款 → 回填凭证，打款失败就驳回并退回。
全站没有支付 SDK、没有回调、没有商户号，也没有"支付成功"这四个字。

**一个 App 装两种身份。**
老板绑定打手账号后，同一个 App 里能切到打手态接单。切过去用的是「伴随会话」——
它只顶自己的旧会话，不会把打手在别处的登录挤掉。12 小时到期要重新输密码。

---

## 跑起来

### 1. 环境变量

```bash
cp infra/.env.example  infra/.env      # 数据库 / Redis 密码
cp server/.env.example server/.env     # JWT 密钥等
```

### 2. 数据库

```bash
npm run infra:start     # Docker：MySQL 8.4 + Redis 7
npm run infra:status    # 看容器和端口状态
```

### 3. 后端

```bash
cd server && npm install && npm run start:dev
# Swagger: http://localhost:3100/api-docs
# Health:  http://localhost:3100/api/v1/health
```

首次启动会跑 migration。管理员账号在 `server/.env` 的 `ADMIN_USERNAME` / `ADMIN_PASSWORD`。

### 4. 管理后台

```bash
cd admin-web && npm install && npm run dev   # http://localhost:5173
```

### 5. 客户端

```bash
cd apps/boss-app && flutter run
```

连远程后端：

```bash
flutter run \
  --dart-define=API_BASE_URL=http://<你的地址>:3100/api/v1 \
  --dart-define=WS_BASE_URL=http://<你的地址>:3100
```

地址也可以写在 `config/client-config.json`（启动时读，支持热切换）。

---

## 已知限制

- **只有 Android 跑通过**。iOS 目录没建，架构没写死但没验证过。
- **打手端停更了**，代码能编译，但功能和老板端里的打手态是重复的。
- **没有测试覆盖率报告**。测试是分散的回归脚本（`scripts/tools/`），不是 CI 里那一套。
- **文档是中文的**，写给自己看的，有些地方默认你懂上下文。
- 云端更新、媒体系统这些依赖具体部署环境的模块，换环境要改配置。

---

## 文档

`docs/` 里按顺序看基本能接上：

| | |
|---|---|
| `00` `01` | 总览、技术栈 |
| `02` `03` | 数据库、接口 |
| `04` | 认证与权限（含伴随会话） |
| `05` `06` | 订单状态机、账务 |
| `07` | WebSocket |
| `08` `09` | 媒体、安全 |
| `11` `16` | 部署、发布 |
| `21` | UI 设计约束（这一版刻意把渐变、圆角、标签压得很克制） |

---

## 许可

MIT，见 [LICENSE](LICENSE)。

用不着署名，也别来找我要支持——这玩意儿是按自己平台的需求写的，你那儿能不能跑通，得自己试。
