# MimiVent 统计查询与存储 v2 设计

> **已被 v2.1 取代**：本文的语义存在多处二义（预设范围、桶对齐、活动归属、覆盖位粒度、
> 事件完整性判定、双槽迁移原子性、时区变更依据），实施请以
> `statistics-query-storage-v2.1.md` 为准。本文保留作为设计演进记录。

状态：设计定稿，待实施（已被 v2.1 取代）  
范围：MimiVent 固件、MimiVent Android App  
目标版本：App `0.5.1+9` 之后、固件 `0.5.1` 之后的统计重构版本

本文同时约束固件存储、HTTP/BLE 查询协议和 App 展现。固件实现优先遵循本文的数据语义；App 不得从固定 `range` 字符串反推时间范围或桶边界。

---

## 1. 目标与非目标

### 1.1 目标

- 用 UTC 时间范围统一查询统计，不再新增固定 `today/yesterday/threeDays/sevenDays` 语义。
- 支持 App 顶部：

```text
今日 | 昨日 | 近7天 | 选择时间
```

- “选择时间”支持：

```text
单日
日期范围
```

- 今日、昨日、单日固定 24 个小时桶。
- 多日范围在 1/2/3/4/6/8/12/24 小时中自动选择粒度，使横轴保持在 10–30 个点。
- 每日汇总保留 30 天。
- 事件明细保留最多 10 天且最多 512 条。
- 单日详情只在事件完整可用时展示；超过保留期或容量截断必须明确提示。
- 旧 schema 4 数据必须保留式迁移，不清空、不更换 `dataEpoch`。

### 1.2 非目标

- 不支持任意超过 30 天的查询。
- 不支持 30 天完整事件明细。
- 不支持 IANA 时区规则和夏令时；本设计只支持设备固定 UTC 偏移。
- 不把被 512 条容量淘汰的详情伪装成完整详情。

---

## 2. 保留周期与上限

| 数据 | 上限 | 说明 |
|---|---:|---|
| 每日汇总 | 30 个自然日 | `DailyRecordV5`，按设备本地日期键保存 |
| 运行时长小时桶 | 30 天 × 24 小时 | 每天 24 个运行秒数桶 |
| 活动小时桶 | 30 天 × 24 小时 | 触发数、活动段数、活动跨度分别保存 |
| 事件明细 | 10 天且 512 条 | 两者谁先到就按谁截断 |
| 自定义查询范围 | 30 个自然日（含首尾） | 超过则拒绝 |

说明：

- “10 天详情”不是无条件保证。活动事件合并后，实际可用天数通常更接近 10 天，但排风、暂停、控制事件多时仍可能提前截断。
- 30 天汇总不依赖事件明细；活动跨度和入厕平均必须来自每日汇总。

---

## 3. 指标语义

### 3.1 活动

| 字段 | 语义 |
|---|---|
| `activityCount` | PIR 触发次数。连续感应触发 45 次就是 45 |
| `activitySegmentCount` | 合并后的活动段数量 |
| `activitySpanSeconds` | 活动段首末触发时差 |
| `activityTriggerBuckets[24]` | 每小时触发次数 |
| `activitySegmentBuckets[24]` | 每小时活动段数量 |
| `activitySpanBuckets[24]` | 每小时活动跨度秒数 |

必须区分：

```text
一次触发（trigger）
一个连续活动段（segment）
一个活动段的跨度（span）
```

零跨度单次触发：

```text
activitySegmentCount += 1
activityTriggerBuckets[hour] += 1
activitySpanSeconds += 0
```

图表规则：

- 柱高使用 `activitySpanSeconds`；
- 零跨度但有触发/活动段时，画基线标记或点，不画伪造高度的柱；
- 没有任何活动时不画标记。

### 3.2 自动排风与入厕

| 字段 | 语义 |
|---|---|
| `automaticCount` | 自动排风启动次数 |
| `toiletSampleCount` | 完成且达到阈值的有效入厕样本数 |
| `toiletDurationSeconds` | 有效样本的总运行秒数 |
| `toiletAverageSeconds` | `toiletDurationSeconds / toiletSampleCount` |

规则：

- 只统计**已完成**的自动排风；
- 实际运行时长达到设定时长一半才计入；
- 手动排风、强制排风不计入；
- 重启导致的中断不计入；
- 当前正在运行的自动排风不提前写入持久化汇总，也不计入平均值；
- 归属日期按自动排风**开始时间所在本地日期**；
- 跨午夜的运行全部计入开始日；
- `toiletCount` 不再单独存储；旧字段作为 `toiletSampleCount` 的兼容别名返回。

---

## 4. Schema 5 每日结构

### 4.1 结构

```cpp
struct DailyRecordV5 {
  uint32_t dayKey;                    // 本地日期键 YYYYMMDD
  uint16_t activityCount;             // 触发次数
  uint16_t activitySegmentCount;      // 活动段数量
  uint16_t automaticCount;

  uint32_t runtimeBuckets[24];        // 每小时运行秒数
  uint32_t activitySpanBuckets[24];   // 每小时活动跨度秒数
  uint16_t activityTriggerBuckets[24];// 每小时触发次数
  uint16_t activitySegmentBuckets[24];// 每小时活动段数量

  uint32_t toiletDurationSeconds;
  uint16_t toiletSampleCount;

  uint8_t metricCoverage;             // 指标可信位掩码
};
```

### 4.2 `metricCoverage`

```text
bit 0: runtime 可用
bit 1: activityCount / activitySegmentCount 可用
bit 2: activitySpan / activity 小时桶可用
bit 3: toilet 汇总可用
```

旧 schema 4 迁移后：

- `runtime`、`activityCount`、`automaticCount` 可用；
- 活动小时桶和入厕汇总不可用；
- 不允许用 0 冒充“真实的零”。

### 4.3 容量

按 24 小时桶计算，`DailyRecordV5` 约 300 字节，30 天约 9 KB。统计分区为 512 KiB，容量足够；仍需在实现后做 30 天满载验收。

### 4.4 计数溢出

- `activityCount`、`activitySegmentCount`、`automaticCount`、`toiletSampleCount` 饱和到 `UINT16_MAX`；
- 小时桶计数饱和到 `UINT16_MAX`；
- 时间桶饱和到 `UINT32_MAX`；
- 不允许回绕。

---

## 5. 活动聚合写入

### 5.1 新活动段

PIR 触发且没有可延长的上一段时：

```text
activityCount += 1
activitySegmentCount += 1
activityTriggerBuckets[startHour] += 1
activitySegmentBuckets[startHour] += 1
activitySpanBuckets 不变
```

### 5.2 延长活动段

满足以下条件时延长上一段：

- 上一条事件仍是 activity；
- 时间没有回退；
- 与上次末端的间隔不超过当前自动排风时长；
- 设备时间可信；
- 容量允许。

只累计新增跨度：

```text
oldEnd = previous.unixSeconds + previous.durationSeconds
newEnd = currentTrigger.unixSeconds
delta = newEnd - oldEnd
```

处理：

```text
activityCount += 1
activityTriggerBuckets[currentHour] += 1
activitySpanBuckets[所有覆盖小时] += delta 的切片
activitySegmentCount 不变
```

禁止：

```text
把更新后的整个 durationSeconds 再加一次
```

### 5.3 跨午夜

活动段可能跨本地午夜。跨度增量必须按本地日期和小时拆分，分别写入对应的 `DailyRecordV5`。

如果设备时区发生变化，不重新映射历史日期；见第 7 节。

### 5.4 重启、校时和回填

- 未校时：不写可信活动小时桶；事件可保留但标为不可用；
- 重启：保留已写入的跨度和事件，不推算断电期间活动；
- 旧 schema：不伪造每小时触发分布；
- 事件被 512 条容量淘汰：不再影响已经写入的每日桶；
- 事件回填只允许在事实可证明完整时进行；默认不反推。

### 5.5 未闭合活动段

正在进行的活动段：

- 已确认的跨度增量已经写入小时桶；
- 查询今日时，可以把尚未写入的当前段剩余跨度临时计入响应；
- 该临时值不能回写每日桶；
- 下一次触发或段结束时只补写新增部分，不能把临时值再次累计。

这样既能看到当前活动，又不会在延长或重启后重复计数。

### 5.6 事件本身

事件明细仍保存：

```json
{
  "kind": "activity",
  "durationSeconds": 148,
  "triggerCount": 45
}
```

每日桶和事件明细是两套数据：

- 每日桶负责 30 天图表和汇总；
- 事件明细负责单日详情和精确触发展示；
- 两者不能互相替代。

---

## 6. 入厕汇总写入

### 6.1 自动排风结束

自动排风完成时：

```cpp
if (kind == kAutomatic &&
    state == kComplete &&
    effective * 2 >= configured) {
  day = localDay(startTime);
  day.toiletDurationSeconds += effective;
  day.toiletSampleCount += 1;
}
```

要求：

- 使用自动排风开始时间归属日期；
- 使用实际运行时长 `effective`；
- 配置时长使用启动时保存的 `reserved`，旧记录回退到当前正式配置；
- 手动、强制、暂停、持续关闭、重启中断不进入。

### 6.2 当前运行

查询时如果自动排风仍在运行：

- 不写入每日汇总；
- 不进入平均值；
- 可以在响应中额外返回 `activeAutomatic` 状态，但不能改变 `toiletSampleCount`。

### 6.3 旧数据

schema 4 没有每日入厕汇总：

- 迁移后 `metricCoverage.toilet = false`；
- 不使用旧事件重建“精确”平均值；
- UI 显示“该日期入厕汇总不可用”，不显示 0 分钟。

---

## 7. 时区与日期规则

### 7.1 固定偏移

本设计只支持设备固定 UTC 偏移：

```text
timezoneOffsetSeconds
```

不实现 IANA 时区、夏令时和旅行时区自动切换。

### 7.2 日期边界

- 本地日期用设备 `timezoneOffsetSeconds` 计算；
- `dayKey` 是本地日期 `YYYYMMDD`；
- 单日 `from` 为当天本地零点对应的 UTC 时间戳；
- 单日 `to` 为次日本地零点；
- 今日 `to` 为当前时间，使用左闭右开 `[from, to)`。

### 7.3 今日部分桶

今日始终返回 24 个桶：

- 未来小时为空；
- 最后一个桶按实际覆盖时长统计；
- 不使用 `now + 1` 的包含式边界。

### 7.4 时区变化

设备当前没有 IANA 时区数据库。若设备时区偏移发生变化：

- 不回算历史 `dayKey`；
- 旧日期查询应返回 `TIMEZONE_MISMATCH` 或明确的近似提示；
- 不静默把旧数据套到新时区。

如果将来要支持旅行和夏令时，必须改成由 App 生成每个桶的 UTC 边界，或存储 UTC 小时桶；不能继续假设每天 24 小时。

---

## 8. Schema 4 → 5 迁移

### 8.1 现状

当前 `readHeader` / `readSlot` 只接受 `header.schema == kSchema`。schema 不匹配时两个槽位都不可读，随后会清空统计并切换 `dataEpoch`。这会直接丢失旧数据，必须先修。

### 8.2 迁移原则

- 不更换 `dataEpoch`（数据集没有丢失）；
- 保留旧运行时长、活动次数、自动排风次数、事件、`nextEventId`、`activeRun`、`droppedThroughEpoch`；
- 新指标无法准确还原时标为不可用，不填 0；
- 先写临时/非活动槽并校验，再覆盖另一槽；
- 任一步失败保留旧 schema 4 槽位，下次启动重试；
- 只有两个槽位都损坏时才进入清空和换 epoch 兜底。

### 8.3 读取流程

1. 分别读取两个槽位；
2. 接受 schema 4 和 schema 5；
3. 选择 generation 最新的有效槽位；
4. schema 5 直接使用；
5. schema 4 按旧布局解析；
6. 转换为内存中的 V5；
7. 事件记录保持原样；
8. 检查 `dataEpoch`、`nextEventId`、`activeRun`；
9. 进入迁移写入。

### 8.4 迁移写入

```text
选择非活动槽
→ 写 V5 header + V5 daily + events
→ 读回并校验 checksum、计数、schema
→ 写另一槽
→ 两个槽都通过后才完成迁移
```

如果写入中断：

- 下一次启动仍能读到旧 V4 或新 V5；
- 选择有效且 generation 最新的槽；
- 不因为一个槽损坏就清空两个槽。

### 8.5 迁移后的可用性

旧日期：

```text
runtime              可用
activityCount        可用
automaticCount       可用
activitySpanBuckets  不可用
activityTriggerBuckets 不可用
activitySegmentBuckets 不可用
toilet                不可用
```

API 必须返回 `metricCoverage`/`coverage`，App 根据它显示提示。

---

## 9. 统一查询 API

### 9.1 新接口

```http
GET /api/stats/range?from=<unix>&to=<unix>&bucketHours=<n>&tzOffsetSeconds=<n>
```

参数：

| 参数 | 必填 | 说明 |
|---|---|---|
| `from` | 是 | UTC Unix 秒，左闭 |
| `to` | 是 | UTC Unix 秒，右开 |
| `bucketHours` | 是 | 1/2/3/4/6/8/12/24，必须整除 24 |
| `tzOffsetSeconds` | 是 | 设备本地偏移，必须与设备当前偏移一致 |

旧接口保留：

```http
GET /api/stats?mode=today|yesterday|threeDays|sevenDays
```

旧接口继续生成原响应语义，不改变旧 App 行为。新 App 使用新接口。

### 9.2 响应

```json
{
  "apiVersion": 2,
  "storageSchema": 5,
  "from": 1793548800,
  "to": 1793635200,
  "tzOffsetSeconds": 28800,
  "bucketHours": 8,
  "bucketCount": 21,
  "summary": {
    "runtimeSeconds": 2176,
    "activityCount": 348,
    "activitySegmentCount": 126,
    "automaticCount": 16,
    "toiletSampleCount": 11,
    "toiletAverageSeconds": 156
  },
  "buckets": [
    {
      "start": 1793548800,
      "end": 1793577600,
      "runtimeSeconds": 600,
      "activitySpanSeconds": 180,
      "activityTriggerCount": 12,
      "activitySegmentCount": 3
    }
  ],
  "coverage": {
    "runtime": true,
    "activity": true,
    "toilet": false,
    "detail": true
  },
  "detail": {
    "complete": true,
    "capacityLimited": false,
    "oldestAvailableAt": 1793548800,
    "newestAvailableAt": 1793635199
  },
  "availableFrom": 1793548800,
  "availableThrough": 1793635200
}
```

### 9.3 `coverage` 语义

```text
runtime              运行时长完整
activity             活动次数/段数/跨度完整
toilet               入厕汇总完整
detail               查询范围是单日且事件完整
```

范围中只要有一天缺活动或入厕数据，对应字段就是 `false`；不能显示成 0。

### 9.4 详情完整性

事件接口需要额外返回：

```json
{
  "eventsTruncated": true,
  "capacityLimited": true,
  "detailComplete": false,
  "oldestAvailableAt": 1793000000,
  "newestAvailableAt": 1793600000,
  "eventCount": 512,
  "eventCapacity": 512
}
```

区分：

```text
OUT_OF_RETENTION    超出 10 天
CAPACITY_LIMITED    512 条容量淘汰
PARTIAL_GAP         中间存在丢弃区间
COMPLETE            完整
```

单日详情只有全部满足才标记 `detail.complete=true`：

- 查询日在 10 天保留期内；
- 事件没有被 512 条容量截断；
- 没有中间丢弃区间；
- 事件接口返回完整分页。

不能只用 `availableFrom` 判断完整性。

### 9.5 事件接口

单日详情复用现有事件接口：

```http
GET /api/events?start=<unix>&end=<unix>&kind=all&offset=0&limit=32
```

新增返回字段：

```json
{
  "oldestAvailableAt": 1793000000,
  "newestAvailableAt": 1793600000,
  "eventCount": 512,
  "eventCapacity": 512,
  "capacityLimited": true,
  "detailComplete": false
}
```

事件接口必须按 `[start, end)` 查询，且和统计接口使用同一套设备本地日期边界。

### 9.6 错误码

| 错误 | 含义 |
|---|---|
| `INVALID_RANGE` | `from >= to` 或非法时间 |
| `RANGE_TOO_LARGE` | 超过 30 个自然日 |
| `RANGE_OUT_OF_RETENTION` | 早于每日汇总保留期 |
| `BUCKET_INVALID` | `bucketHours` 不在允许集合或不整除 24 |
| `TIMEZONE_MISMATCH` | 请求偏移与设备偏移不一致 |
| `STATS_NOT_READY` | 统计尚未初始化 |

错误响应必须保留 HTTP 状态码和机器可读错误码；App 不根据中文文本做逻辑判断。

---

## 10. 日期范围与单日规则

### 10.1 范围上限

- 最多 30 个自然日，包含首尾；
- 例：10 月 1 日到 10 月 30 日是 30 天；
- 超过 30 天拒绝，不静默裁剪。

### 10.2 单日

```text
from = 当天本地 00:00
to   = 次日本地 00:00
bucketHours = 1
bucketCount = 24
```

### 10.3 一日范围

“日期范围”中 start=end 时，归一为单日：

- 使用 24 个小时桶；
- 如果事件完整，展示详情；
- 不因为入口是“范围”而隐藏详情。

### 10.4 多日范围

- 逐日聚合 `DailyRecordV5`；
- 不返回事件详情；
- 显示范围总统计和图表；
- 横轴粒度由第 11 节算法决定；
- 范围包含今天时，最后一个桶为部分桶。

---

## 11. 横轴分桶算法

### 11.1 候选粒度

```text
1h, 2h, 3h, 4h, 6h, 8h, 12h, 24h
```

必须整除 24。

### 11.2 单日

```text
bucketHours = 1
bucketCount = 24
```

今日、昨日、自定义单日都一样。

### 11.3 多日

```text
hours = 自然日数 × 24
```

候选必须满足：

```text
10 <= hours / bucketHours <= 30
```

评分：

```text
score = |桶数 - 20|
```

同分选择更大的 `bucketHours`。

### 11.4 示例

| 天数 | 选择 | 桶数 |
|---:|---:|---:|
| 1 | 1h | 24 |
| 2 | 3h | 16 |
| 3 | 4h | 18 |
| 4 | 6h | 16 |
| 5 | 6h | 20 |
| 7 | 8h | 21 |
| 10 | 12h | 20 |
| 14 | 24h | 14 |
| 30 | 24h | 30 |

### 11.5 标签

- 单日：`00时`–`23时`；
- 多日：`MM/DD` 或 `MM/DD 00/08/16`；
- 按日期分组，避免横轴标签重叠；
- App 不自行推算桶起止，使用响应里的 `start/end`。

---

## 12. App 查询层

### 12.1 查询模型

```dart
class StatisticsQuery {
  final int from;
  final int to;
  final int bucketHours;
  final int tzOffsetSeconds;
  final bool singleDay;
}
```

固定 Tab 只生成预设查询：

```text
today
yesterday
sevenDays
```

“选择时间”生成单日或范围查询。

### 12.2 缓存键

```text
deviceId
+ dataEpoch
+ from
+ to
+ bucketHours
+ tzOffsetSeconds
+ apiVersion
```

不能继续使用 `range` 字符串。要求：

- 自定义日期不能覆盖今日/昨日缓存；
- 旧请求返回不能覆盖新页面；
- 相同查询并发合并；
- `dataEpoch` 或设备身份变化后全部失效；
- 今日对比只对今日生效；
- 事件缓存使用独立命名空间。

### 12.3 兼容旧固件

App 检查设备能力：

```text
statsRangeApiVersion >= 2
```

没有该能力时：

- 今日/昨日/近7天继续使用旧 `mode`；
- “选择时间”隐藏或提示需要升级固件；
- 不发送新接口。

### 12.4 UI 状态

- 加载中；
- 无数据；
- 范围部分不可用；
- 明细过保留期；
- 事件容量截断；
- 设备时间未校准；
- 固件不支持范围查询。

任何不可用状态都不能用 0 代替。

---

## 13. UI 设计

### 13.1 Tab

```text
今日 | 昨日 | 近7天 | 选择时间
```

移除固定“近3天”Tab；“近3天”可由日期范围选择。

### 13.2 选择时间

底部弹层：

```text
单日
日期范围
```

单日：

- 日期选择器；
- 可选最近 30 天；
- 最近 10 天可看详情；
- 11–30 天只显示总统计和图表；
- 超过 30 天不可选。

日期范围：

- 起止日期；
- 最多 30 个自然日；
- 不展示详情；
- 显示范围总统计和自动分桶图表。

### 13.3 图表

- 今日、昨日、单日：24 个小时桶；
- 多日：按第 11 节自动分桶；
- 下方详情只用于单日；
- 活动跨度用黄色；
- 排风用绿色；
- 零跨度活动画基线标记，不画假柱。

### 13.4 详情

详情只允许：

```text
singleDay == true
coverage.detail == true
```

否则显示：

```text
该日期明细已过保留期
```

或：

```text
事件记录已因容量限制被截断
```

---

## 14. 迁移与兼容决策

### 14.1 两套版本号

```text
storageSchema = 5          内部存储结构
apiVersion = 2             新统计接口
statisticsSchema = 4       旧 App 兼容字段，保持 4
```

不要把内部存储 schema 直接暴露成旧 App 的 `statisticsSchema`，否则当前 App 的 `statisticsSchema == 4` 兼容判断会失效。

### 14.2 旧 App

- 旧 App 继续使用 `/api/stats?mode=...`；
- 固件继续返回旧字段和旧语义；
- v5 的额外字段忽略即可；
- 迁移不清空数据，不更换 `dataEpoch`。

### 14.3 新 App

- 优先使用 `/api/stats/range`；
- 能力不足时回退旧接口；
- 读取 `coverage`、`detail`、`availableFrom`；
- 不根据日期猜测数据完整性。

---

## 15. 测试与验收

### 15.1 固件

必须覆盖：

- schema 4 → 5 双槽迁移；
- 迁移中断、掉电、单槽损坏；
- `dataEpoch` 不变化；
- 旧运行/活动/自动排风计数保留；
- 30 天满载；
- 活动段延长只累加增量；
- 跨午夜活动跨度切分；
- 零跨度单次触发写入触发桶；
- 活动段计数与触发计数区分；
- 512 条容量截断标记；
- 今日部分桶；
- 固定时区偏移；
- 自动排风完成/中断/阈值；
- 旧接口响应兼容。

### 15.2 App

- 今日/昨日/近7天查询；
- 单日/范围选择；
- 30 天边界；
- 1–30 天桶算法表驱动测试；
- 查询缓存键；
- 并发旧请求丢弃；
- 旧固件回退；
- 详情不可用提示；
- 5:5 时间线；
- 秒/分钟格式化；
- 旧 schema 数据提示。

### 15.3 验收门槛

- 迁移后旧数据可读，`dataEpoch` 不变；
- 30 天范围可查询；
- 11–30 天活动图不伪造数据；
- 单日详情在超期/容量截断时明确降级；
- App 不因自定义范围覆盖今日缓存；
- 旧 App 仍能使用旧接口。

---

## 16. 实施顺序

### 阶段 A：固件存储与迁移

1. 抽出 V4/V5 读取结构；
2. 双槽迁移；
3. 新增每日活动/入厕字段；
4. 增量活动写入；
5. 入厕汇总；
6. 迁移和满载测试。

### 阶段 B：固件查询

1. `/api/stats/range`；
2. 时间范围校验；
3. 动态桶聚合；
4. coverage/detail 状态；
5. 旧接口兼容。

### 阶段 C：App 查询层

1. `StatisticsQuery`；
2. 新接口客户端；
3. 缓存键和请求代际；
4. 旧固件回退。

### 阶段 D：App UI

1. Tab；
2. 日期选择；
3. 单日 24 小时图；
4. 多日自动分桶；
5. 不可用/部分可用状态；
6. 回归清单。

---

## 17. 实施落点

### 固件

| 文件 | 工作 |
|---|---|
| `StatisticsConfig.h` | schema、容量、保留期常量 |
| `StatisticsStore.h/.cpp` | V4/V5 读取、迁移、每日桶、查询 |
| `StatisticsActivityCore.h` | 活动段增量/跨日切分纯函数 |
| `FanController.cpp` | 传入合并窗口、触发活动写入 |
| `FirmwareVersion.h` | storage schema、API 能力版本 |
| 统计/OTA 测试目录 | 迁移、满载、跨日、详情截断测试 |
| HTTP/BLE 控制路由 | `/api/stats/range`、事件接口元数据 |

### App

| 文件 | 工作 |
|---|---|
| `lib/features/statistics/presentation/statistics_page.dart` | Tab、日期选择、图表、详情 |
| `lib/data/mimivent_controller.dart` | 查询缓存、请求去重、回退 |
| `lib/data/statistics_event_cache.dart` | 事件缓存键和完整性状态 |
| `lib/data/models.dart` | 统计/事件 DTO |
| `lib/transport/*` | 新 API 请求与响应解析 |
| `docs/regression-checklist.md` | 回归项 |

## 18. 关键决策摘要

```text
单日：24 个小时桶
多日：1/2/3/4/6/8/12/24 小时，10–30 个点
今日 to = now，左闭右开
范围最多 30 个自然日
活动：触发次数、段数、跨度分开存
活动跨度只增量累加
入厕：仅完成且达到阈值，按开始日归属
schema 4 → 5 保留式迁移，不换 dataEpoch
新接口独立，旧接口保留
storageSchema / apiVersion / statisticsSchema 分离
固定 UTC 偏移，不支持夏令时
详情完整 = 10 天 + 512 条 + 无中间缺口
```
