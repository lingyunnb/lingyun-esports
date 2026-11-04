# 客服咨询「已结束仍在列表 / 带红点 / 点开 404」修复 · 验收素材（2026-10-11）

> 本目录**不入 git**（`docs/验收素材/` 全目录未跟踪）。图由 `apps/boss-app/test/visual/cs_closed_visual_test.dart`
> 生成（数据全部注入、可复跑），拷自 `apps/boss-app/build/`。

## 一、负责人报障（真机截图，打手态）

1. 消息 › 客服段：**三行完全一样**的「祁连山客服」（带「客服」标签、无预览、无时间），其中一行 **未读 10**；底部「消息」也是 10。
2. 点开其中一行 → 顶部「祁连山客服 · **本次咨询已结束**」+ 中间「**会话不存在**」+「重试」。
3. 身份细带「打手 · 工号 **W0000**」。

## 二、修复前后台接口证据（`scripts/tmp/cs-closed-e2e.js`，真库 + 真接口 + 打手态 companion）

修复前（脚本首跑，3 PASS / 8 FAIL）：

```
证据 A 打手态 GET /worker/cs/conversations →
 [{"id":"592","type":"cs","status":"closed","unread":0},{"id":"593","type":"cs","status":"closed","unread":0},{"id":"594","type":"cs","status":"open","unread":4}]
证据 B chat_conversation（SQL）→
 [{"id":592,"status":"closed","user_id":1114,"unread_worker":1,"msg_cnt":1,"assigns":null},
  {"id":593,"status":"closed","user_id":1114,"unread_worker":0,"msg_cnt":0,"assigns":null},
  {"id":594,"status":"open","user_id":1112,"unread_worker":4,"assigns":"1114:active"}]
FAIL N1 打手态列表不含已结束客服会话 | closed=["592","593"]
FAIL N3 列表里每一行都能打开 | 594 hist=404 info=404 「会话不存在」
FAIL N5 已结束会话 unread 为 0 | 592 的 unread_worker=1（结束了还挂着未读）
FAIL N7-a 客服结束咨询后从客服侧列表消失 | list=["594:closed","592:closed","593:closed"]
FAIL N7-c 结束后未读清零 | {"status":"closed","unread_worker":4}
```

修复后（14 PASS / 0 FAIL）：同脚本同场景

```
证据 A → [{"id":"600","type":"cs","status":"open","unread":4}]
证据 B → 598/599（自建已结束，unread_user=0/unread_worker=0）、600（进行中，assigns="1114:active"）
PASS N1/N2 两侧列表都不含已结束客服会话
PASS N3    列表里每一行都能打开（hist=200 info=200，infoStatus=open）
PASS N3-b  客服经 /user/conversations/:id/messages 回复：201 + sender_type=worker + 未读记到老板侧（unread_user=1）
PASS N4-a/b/c 未读快照不含已结束；列表未读合计 == 快照合计（打手侧 4==4，老板侧 1==1）
PASS N5    已结束会话 unread_user/unread_worker 全 0
PASS N6-a  已结束会话（属主侧按 id 打开）仍可读历史，不 404
PASS N7-a..e 客服结束咨询 → 两侧列表消失、未读清零、快照不含它、按 id 打开仍 200
```

## 三、出图（修复后）

| 图 | 说明 |
|---|---|
| `01-修复后-消息列表客服段.png` | 打手态（工号 W0000）「客服」段：真机那三行重复里**两条已结束的不再出现**，只留正在服务的一条（未读 10 红点） |
| `02-修复后-已结束会话打开态.png` | 打开已结束的客服会话：顶部「本次咨询已结束」+ 卡片「工号 W0000」+ **历史消息照常可读** + 输入栏「本次会话已结束」；**没有**「会话不存在」/「重试」 |
| `03-修复后-已结束会话不再计入未读.png` | 左右对照：修复后红点 = 进行中那条的 10；修复前把已结束会话残留的未读也算进去（17），与列表对不上 |

## 四、回归与变异

| 项目 | 结果 |
|---|---|
| `scripts/tmp/chat-test.js` | **32 通过 / 0 失败**（基线保持） |
| `scripts/tools/cs-hall-e2e.js` | 见开发日志（**注意：必须单独跑**） |
| `scripts/tmp/cs-closed-e2e.js`（本次新增） | 14 PASS / 0 FAIL |
| `apps/packages/core` `flutter analyze` / `flutter test` | 0 issue / **459 passed**（基线 ≥455，本次 +4） |
| 变异 ①（客户端）| 去掉 `worker_messages_page.dart` 的已结束过滤 → 测试 ①②③ **红**（3 行重复 / 未读 17 / 不空态） |
| 变异 ②（服务端）| 去掉两条列表 SQL 的 `status='open'` → N1/N2/N4 **红** |
