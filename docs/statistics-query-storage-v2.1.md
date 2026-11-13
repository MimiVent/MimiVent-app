# MimiVent 统计查询与存储 v2.1

> NAS 归档、传输分页、容量交叉检查及连接校时见[蓝牙、MQTT 与 NAS 优化方案 v1.2](ble-mqtt-nas-optimization-v1.md)。本文件仍定义设备统计的冻结时区、批次、完整性和存储迁移语义；传输通道变化不改变这些规则。校时首次回填与已有 UTC 的后续跳变分别处理，补充目标约束见优化方案 §14.2.2；该段包含待实现改造，不表示当前活动合并已全部改用单调时间。

状态：可实现规格（取代 v2 的"设计定稿"；已吸收多轮评审，见附录 B）
范围：MimiVent 固件、MimiVent Android App
目标版本：App `0.5.1+9` 之后、固件 `0.5.1` 之后的统计重构版本
前身：`statistics-query-storage-v2.md`（本文保留其全部设计意图，补齐闭式规则）

> v2 的问题不是方向错，而是**若干关键语义写成了"设计原则"而非"可判定规则"**，导致固件与 App
> 各自按最省事的理解实现后出现口径差异。本版把所有"或/建议/约/通常"替换为唯一判定，
> 并对每条规则标注了它在现有代码里的依据。附录 A 列出 41 条修订项，附录 B 是评审意见的落点索引。

---

## 0. 修订摘要

### 0.1 本版新增/重写的小节

| 小节 | 作用 |
|---|---|
| §3.0 事件字段语义 | 明确 `unixSeconds / durationSeconds / reserved` 的确切含义，活动聚合的全部推导都依赖它 |
| §5.6 每日记录顺序约束 | `daily[]` 的淘汰依赖"按 dayKey 升序"这个从未写下的前提 |
| §8.4 偏移变更策略 | 把"固定偏移"从原则变成产品承诺 + 重置入口，消除"时区变了历史无法识别"的悬空 |
| §9.6 存储格式演进与 OTA 守护 | 唯一会真正丢数据的路径：新固件回退到旧固件会清空 30 天并轮换 `dataEpoch` |
| §10.0 预设查询边界 | "今日/昨日/近7天"三行闭式公式，决定 from/to/桶数/末桶 |
| §10.8 未校时与时间可信度 | timeSynced / pendingUnsynced，未校时数据不得伪造按日统计 |

### 0.2 七个定向决策

| 编号 | 决策 | 一句话 |
|---|---|---|
| D1 | 近7天 = 含今天的 7 个本地自然日 | 与现有 App `startOffset=6, dayCount=7` 对齐，消掉"168 小时"歧义 |
| D2 | 服务端选桶；桶按本地零点对齐；部分桶用 `coveredSeconds` 作分母 | 客户端永远不参与算桶 |
| D3 | 触发归触发日、段归段起点日、跨度按秒切分 | 接受"次日有跨度无段数"的不对称，并写进不变式 |
| D4 | 事件三字段语义定死；延长判定只看 `activeActivityId` | 与事件在数组中的位置解耦 |
| D5 | coverage 二值化 + 每个桶带 `coverageBits`；不可用字段返回 `null` | 不用三态，也不许用 0 冒充 |
| D6 | 事件完整性只有一个判定函数 | 三态固定优先级，且按查询日判定 |
| D7 | 时区偏移永久冻结 + `tzVersion` + 明示 + 重置入口 | 不再有"设备换时区后历史怎么解释"的问题 |

---

## 1. 目标与非目标

### 1.1 目标

- 用 UTC 时间范围统一查询统计，不再新增固定 `today/yesterday/threeDays/sevenDays` 语义。
- 支持 App 顶部：

```text
今日 | 昨日 | 近7天 | 选择时间
```

- "选择时间"支持单日与日期范围。
- 今日、昨日、自定义单日固定 24 个小时桶。
- 1–4 个自然日按小时铺满 24 列；5–14 个自然日使用 12 小时桶（近 7 天 = 14 列）；15 天以上使用 24 小时日桶。柱数恒在 10–30，桶宽整除 24 —— 详见附录 D.2。
- 每日汇总保留 30 天。
- 事件明细保留最多 10 天且最多 256 条（0.7.0 起，见附录 D.6；实际覆盖约 3 天）。
- 单日详情只在事件完整可用时展示；超过保留期或容量截断必须明确提示。
- 旧 schema 4 数据必须保留式迁移，不清空、不更换 `dataEpoch`。

### 1.2 非目标

- 不支持任意超过 30 天的查询。
- 不支持 30 天完整事件明细。
- 不支持 IANA 时区规则和夏令时；本设计只支持设备固定 UTC 偏移，且**偏移一经设定不可变更**（见 §8.4）。
- 不把被容量淘汰的详情伪装成完整详情。

---

## 2. 保留周期与上限

| 数据 | 上限 | 说明 |
|---|---:|---|
| 每日汇总 | 30 个自然日 | `DailyRecordV5`，按设备本地日期键保存 |
| 运行时长小时桶 | 30 天 × 24 小时 | 每天 24 个运行秒数桶 |
| 活动小时桶 | 30 天 × 24 小时 | 触发数、活动段数、活动跨度分别保存 |
| 事件明细 | 10 天且 256 条 | 两者谁先到就按谁截断 |
| 自定义查询范围 | 30 个自然日（含首尾） | 超过则拒绝 |

说明：

- "10 天详情"不是无条件保证。活动事件合并后实际可用天数通常更接近 10 天，但排风、暂停、控制事件多时仍可能提前截断。
- 30 天汇总不依赖事件明细；活动跨度、触发数、段数、入厕平均全部来自每日汇总。

---

## 3. 数据模型事实

### 3.0 事件三字段语义（本版新增，v2 缺失）

v2 的 §5.6 只给了一个 JSON 片段，从未说明三个字段的确切含义，导致"`unixSeconds` 是段起点还是最后触发时刻"没有答案。以现有实现为准，语义固定为：

| 记录 | `unixSeconds` | `durationSeconds` | `reserved` |
|---|---|---|---|
| `activity` | **活动段起点**，段存续期间永不改写 | 首末触发时差（span） | `triggerCount` |
| `automatic` | 排风开始时刻 | 实际运行秒数 | 启动时锁定的 configured 秒数 |
| 其他 kind | 事件发生时刻 | 设定时长（pause）或 0 | 未使用，必须为 0 |

由此可得三条推论，实现时不得偏离：

1. 活动段的跨度在**每次触发时即已完整确定**，不存在"尚未写入的剩余跨度"。
2. 活动事件的 `id` 是段身份，不是触发身份；触发次数是它的 `reserved`。
3. `automatic` 事件的 `state` 不足以区分"正常完成"与"被 PIR 打断"，必须靠新增的 `endReason`（见 §5.1）。

### 3.1 现有 schema 4 结构（迁移基线）

```cpp
struct DailyRecord {          // sizeof == 104
  uint32_t dayKey;
  uint16_t activityCount;
  uint16_t automaticCount;
  uint32_t runtimeBuckets[24];
};

struct EventRecord {          // sizeof == 16
  uint32_t id;
  uint32_t unixSeconds;
  uint32_t durationSeconds;
  uint8_t kind;
  uint8_t state;
  uint16_t reserved;
};
```

schema 4 的每日汇总**只有** `runtime / activityCount / automaticCount`；
活动跨度、触发分布、段数、入厕汇总目前都是从事件实时聚合出来的，因此**一旦事件被容量淘汰就会失真**。
这正是本次重构的动因。

---

## 4. 指标语义

### 4.1 活动

| 字段 | 语义 | 存储位置 |
|---|---|---|
| `activityCount` | PIR 触发次数。连续感应触发 45 次就是 45 | 日标量 + 小时桶 |
| `activitySegmentCount` | 合并后的活动段数量 | 日标量 + 小时桶 |
| `activitySpanSeconds` | 活动段首末触发时差之和 | 日标量 + 小时桶 |
| `activityTriggerBuckets[24]` | 每小时触发次数 | 小时桶 |
| `activitySegmentBuckets[24]` | 每小时活动段数量 | 小时桶 |
| `activitySpanBuckets[24]` | 每小时活动跨度秒数 | 小时桶 |

必须区分：

```text
一次触发（trigger）
一个连续活动段（segment）
一个活动段的跨度（span）
```

**归属规则（D3，本版新增）**：

| 指标 | 归属 |
|---|---|
| `activityCount` / `activityTriggerBuckets[h]` | 每次触发归**该触发所在的本地日/小时** |
| `activitySegmentCount` / `activitySegmentBuckets[h]` | 整段归**段起点所在的本地日/小时**，不拆分 |
| `activitySpanSeconds` / `activitySpanBuckets[h]` | 按实际秒数**跨日、跨小时切分** |

**必须维持的不变式（进测试）**：

```text
Σ_天 activitySegmentCount        == 全部活动段总数
Σ_小时 activitySpanBuckets[h]     == 当天 activitySpanSeconds
Σ_天 activityCount                == 全部触发总数
Σ_小时 activityTriggerBuckets[h]  == 当天 activityCount
```

**显式豁免**：跨午夜的活动段会让次日出现"有触发、有跨度、`activitySegmentCount == 0`"。
这是合法状态，App 不得据此提示异常，也不得反向推算段数。

零跨度单次触发：

```text
activityCount += 1
activitySegmentCount += 1
activitySpanSeconds += 0
activityTriggerBuckets[hour] += 1
activitySegmentBuckets[hour] += 1
```

图表规则：

- 柱高使用 `activitySpanSeconds`；
- 零跨度但有触发/活动段时，用 `activityTriggerCount > 0 && activitySpanSeconds == 0` 画基线标记，不画伪造高度的柱；
- **单次触发当天的跨度为已知零**，写入时必须同时置 span 覆盖位；不得因为"没有增量"而留空，
  否则 App 会把"当天只有一次触发"读成"跨度不可用"；
- 没有任何活动时不画标记。

### 4.2 自动排风与入厕

| 字段 | 语义 |
|---|---|
| `automaticCount` | 自动排风启动次数 |
| `toiletSampleCount` | 完成且达到阈值的有效入厕样本数 |
| `toiletDurationSeconds` | 有效样本的总运行秒数 |
| `toiletAverageSeconds` | `toiletDurationSeconds / toiletSampleCount` |
规则：

- 只统计**已完成**的自动排风。判定依据是 `endReason == COMPLETED`，**不是** `state == kComplete`（见 D18）；
  结束原因由驱动层传入：PIR 打断写 `PIR_INTERRUPTED`、任务被替换写 `REPLACED`、
  用户主动停止写 `CANCELLED`、计时到点写 `COMPLETED`；
- 实际运行时长达到设定时长一半才计入（`effective * 2 >= configured`）；
- 手动排风、强制排风不计入；
- 重启中断、PIR 打断、被新任务替换均不计入；
- 当前正在运行的自动排风不写入持久化汇总，也不计入平均值；
- 归属日期按自动排风**开始时间所在本地日期**；跨午夜运行全部计入开始日；
- `toiletCount` 不再单独存储；旧字段作为 `toiletSampleCount` 的兼容别名返回。

### 4.3 覆盖位与溢出位（本版重写）

`metricCoverage` 是 **8 位、逐指标**的完整真值标记，不是"按天有数据"的意思。

| 位 | 指标 |
|---|---|
| bit0 | `runtime`（`runtimeBuckets` 与运行总时长） |
| bit1 | `activityCount` |
| bit2 | `activitySegmentCount` |
| bit3 | `activitySpanSeconds` |
| bit4 | `activityTriggerBuckets` |
| bit5 | `activitySegmentBuckets` |
| bit6 | `activitySpanBuckets` |
| bit7 | `toilet`（`toiletSampleCount` + `toiletDurationSeconds`） |

`automaticCount` **没有覆盖位**：schema 4 起即存在，恒可用。

**判定规则（唯一）**：

```text
位 = 1  → 该指标当天是完整真值
位 = 0  → 该指标当天不可用；接口必须返回 null，禁止返回 0
"部分覆盖"（未校时窗口、跨日段尾、饱和、丢弃）一律按 0 处理，不允许输出部分和
```

**为什么不做三态**：三态需要在固件、API、App 三处各写一套状态机，而收益只是"少丢半天柱子"。
本设计选择保守降级，代价写在 §4.4。

`overflowFlags` 与 `metricCoverage` 位映射相同，置 1 表示该指标当天曾达上限被饱和（见 §5.4）。

### 4.4 部分覆盖的代价（明示）

| 场景 | 结果 |
|---|---|
| 设备未校时运行 3 小时后补校 | 当天 `activityCount` 可用（校时回填），但 `span` / `triggerBuckets` / `segmentCount` **整天不可用** |
| 跨午夜活动段 | 次日 span 可用、段数可能为 0，但**两者都仍是完整真值**（见 §4.1 豁免） |
| 任一计数饱和 | 该指标当天改用 `null`，并置 `overflowFlags` 对应位 |

上表第一行是本版有意接受的取舍：**宁可整天空图，也不输出真假混排的曲线**。

---

## 5. Schema 5 每日结构

### 5.1 结构

```cpp
struct DailyRecordV5 {
  uint32_t dayKey;                     // 0    本地日期键 YYYYMMDD
  uint16_t activityCount;              // 4    触发次数
  uint16_t activitySegmentCount;       // 6    活动段数量
  uint16_t automaticCount;             // 8    自动排风启动次数（无覆盖位）

  uint32_t runtimeBuckets[24];         // 12   每小时运行秒数
  uint32_t activitySpanBuckets[24];    // 108  每小时活动跨度秒数
  uint16_t activityTriggerBuckets[24]; // 204  每小时触发次数
  uint16_t activitySegmentBuckets[24]; // 252  每小时活动段数量

  uint32_t activitySpanSeconds;        // 300  日级活动跨度（本版新增）
  uint32_t toiletDurationSeconds;      // 304
  uint16_t toiletSampleCount;          // 308

  uint8_t  metricCoverage;             // 310  见 §4.3
  uint8_t  overflowFlags;              // 311  见 §5.4
};
static_assert(sizeof(DailyRecordV5) == 312, "布局变化必须同步提升 storageSchema");
```

```cpp
struct EventRecordV5 {
  uint32_t id;                 // 0
  uint32_t unixSeconds;        // 4
  uint32_t durationSeconds;    // 8
  uint8_t  kind;               // 12
  uint8_t  state;              // 13
  uint8_t  endReason;          // 14  见 StatisticsTypes.h StatisticsEndReason
  uint8_t  flags;              // 15  bit0 = timeUnsynced；其余位必须为 0
  uint16_t reserved;           // 16  activity: triggerCount; automatic: configured 秒
  uint16_t _pad1;              // 18  必须写 0
};
static_assert(sizeof(EventRecordV5) == 20, "布局变化必须同步提升 storageSchema");
```

```cpp
struct StoreHeaderV5 {
  uint32_t magic;                 // 0   "MVST"
  uint16_t schema;                // 4   5
  uint16_t dailyCount;            // 6
  uint16_t eventCount;            // 8
  uint16_t flags;                 // 10  bit0 migrationInProgress, bit2 clockWentBackwards
                                  //     bit1 是已废弃的 nonContiguousDrop，保留不复用；其余必须为 0
  uint32_t generation;            // 12
  uint32_t checksum;              // 16
  uint32_t nextEventId;           // 20
  EventRecordV5 activeRun;        // 24
  uint32_t droppedThrough;        // 44  截至该时刻（含）的事件均已丢弃；0 = 从未丢弃
  int16_t  tzOffsetMinutes;       // 48  统计固定偏移快照
  uint16_t tzVersion;             // 50  首次为 1
};
static_assert(sizeof(StoreHeaderV5) == 52, "布局变化必须同步提升 storageSchema");
```

`endReason` 直接复用 `StatisticsTypes.h` 的枚举，并**新增一个零值成员**：

```cpp
enum class StatisticsEndReason : uint8_t {
  LEGACY_UNKNOWN = 0,   // 迁移前的旧记录；语义是"未知"，不是"已完成"
  COMPLETED = 1,
  REPLACED = 2,
  RESTARTED = 3,
  PIR_INTERRUPTED = 4,
  CANCELLED = 5,
  REBOOT_INTERRUPTED = 6,
  UPGRADE_RESTART = 7,
  OWNER_CHANGED = 8,
};
```

事件标志定义：

```cpp
constexpr uint8_t kEventFlagTimeUnsynced = 1u << 0;
```

`unixSeconds` 的取值必须与 `flags.bit0` 配套读，共三种状态：

| `flags.bit0` | `unixSeconds` | 含义 |
|---|---|---|
| 0 | > 1700000000 | 可信 Unix 秒（正常情况） |
| 0 | 0 | 时间不可用（重启后清零、或回填失败） |
| 1 | 本次开机 uptime 秒 | 未校时；该值只是相对量，**禁止当作 Unix 时间使用** |

**未校时状态禁止借用时间戳的任何位**：否则真实 Unix 时间进入 2038 年高位区间后会与标志冲突（D41）。
`flags` 的其余位必须为 0。

注意：这里是**事件**的 `flags`，与 `StoreHeaderV5.flags` 是两个不同字段，位编号各自独立、不可混用。

**零值必须是"未知"**：结构体被 `memset` 或默认构造时 endReason 自然是 0；若 0 代表 `COMPLETED`，
任何漏初始化的路径都会伪造一次"成功完成"，直接污染入厕汇总。因此**所有完成判定必须写成
`endReason == StatisticsEndReason::COMPLETED` 的严格相等**，禁止 `!= INTERRUPTED` 之类的反向写法。

### 5.2 迁移映射（schema 4 → 5）

| V5 字段 | schema 4 来源 |
|---|---|
| `dayKey` / `activityCount` / `automaticCount` / `runtimeBuckets` | 原样 |
| `activitySegmentCount` / `activitySpanSeconds` / 三类活动桶 | 反向填充为 0，并清对应覆盖位 |
| `toilet*` | 0，清 bit7 |
| `metricCoverage` | `0b00000011`（runtime + activityCount） |
| `overflowFlags` | 0 |

### 5.3 容量与分区预算（本版新增）

| 项 | 大小 |
|---|---:|
| `DailyRecordV5` | 312 B |
| × 30 天 | 9,360 B |
| `EventRecordV5` × 256 | 5,120 B |
| `StoreHeaderV5` | 56 B |
| **单槽快照（最满载）** | **19,656 B** |
| SPIFFS 单槽占用（算法见下） | 20,480 B |
| 双槽稳态 | 40,960 B = 40 KiB |
| 分区（`partitions.csv` `statistics`） | 0x80000 = 512 KiB |
| 稳态占用率 | 7.8% |

**SPIFFS 占用不能只按净荷估**，计算依据：

```text
page        = 256 B，页头 4 B            → 每数据页有效载荷 252 B
dataPages   = ceil(19,656 / 252) = 78
indexPages  = ceil(78 / 63)      = 2     // 每索引页可引用 63 个数据页
totalPages  = 80
block       = 16 页 = 4,096 B
单槽占用    = ceil(80 / 16) × 4,096 = 5 × 4,096 = 20,480 B
```

参数取自当前 Arduino-ESP32 的 SPIFFS 配置（`LOG_PAGE_SIZE=256`）。**实施后必须用 `SPIFFS.info()` 实测校准**：
满载快照写入后，`usedBytes` 与理论值偏差超过 10% 就要回填本节数字，不能沿用估算。

**重写峰值**（v2.1 初稿漏算的一项）：

```text
重写一个槽时旧页尚未被 GC 回收，峰值 ≈ 2 × 单槽 = 10 block = 40 KiB
双槽稳态 40 KiB + 单槽重写峰值 20 KiB = 60 KiB ≈ 分区 12%
```

结论：**不需要第三份槽**——迁移与持久化都是"覆写另一槽"，被覆写槽的数据在写入前已读入内存；
但"不需要第三份"不等于"写入过程零额外占用"，重写峰值必须按 2 × 单槽核算。
512 KiB 分区（128 block）余量充足，真正的约束是**写耗时**，不是空间。

对照：schema 4 满载快照为 11,356 B，schema 5 为 19,656 B（+73%）。**写入耗时同比增加，必须配合 §5.5 的写入节流。**

**主机验收结果**（`test_statistics_capacity.py</B>，30 天 + 256 条同时满载）：快照 14,536 B、
78 数据页 + 2 索引页 = 5 个 4 KiB block = 20,480 B/槽、双槽 40,960 B、剩余 483,328 B，
与本节推算一致。主机 `-O2</B> 下单次写快照约 113 µs、读回校验约 114 µs——这是数量级参考，
**ESP32-C3 上的真实耗时与 SPIFFS 实际占用仍需真机 `SPIFFS.info()</B> 校准**。

`StatisticsConfig.h` 中的 `kLogicalTargetBytes` / `kSingleFanEventBudgetBytes` /
`kMultiEndpointEventBudgetBytes` / `kSegmentTargetBytes` 是历史遗留常量、当前全代码零引用，
**不得作为容量依据**。OTA 传输工作区在 RAM，不占该分区。

### 5.4 计数溢出

- `activityCount`、`activitySegmentCount`、`automaticCount`、`toiletSampleCount` 饱和到 `UINT16_MAX`；
- 小时桶计数饱和到 `UINT16_MAX`；
- 时间桶饱和到 `UINT32_MAX`；
- 不允许回绕。

**饱和即不可用（D12）**：任一指标饱和时，同时置 `overflowFlags` 对应位、清 `metricCoverage` 对应位，
接口对该字段返回 `null` 并在 `overflow` 数组里列出指标名。饱和值不得作为准确值展示。

### 5.5 写入节流（本版新增）

快照从 11,356 B 增至 19,656 B，而 `addEvent()` 与活动延长当前都是**每次触发全量重写**。
规定：

| 触发 | 是否立即 `persist()` |
|---|---|
| 新事件写入（风机开始/停止、自动排风、控制事件） | 是 |
| 活动段**延长** | 否，置脏标记，`kPersistMinIntervalMs` 合并（建议 5000 ms） |
| 校时、迁移、重启前、OTA 前 | 是 |
| 命中淘汰（`prune` 实际删除记录） | 是 |

掉电最多丢失一个合并窗口内的**活动段延长增量**；新段与风机事件永不丢失。

合并写入需要一个收口点：固件主循环每轮调用 `statisticsStoreTick()`，
在距首次置脏超过 `kPersistMinIntervalMs` 时落盘。没有这个调用，最后一段增量会一直停在内存里，
直到下一次触发或关键事件——这是节流唯一的外部依赖，实现时不得省略。

### 5.6 每日记录容器的顺序约束（本版新增，D24）

`daily[]` 是定长数组 + 线性查找，现有的"满了就 `memmove(daily, daily + 1)` 挤掉 `daily[0]`"隐含了一个从未写下的前提：
**`daily[]` 恒按 `dayKey` 升序**。以下情况会破坏它：

- 校时回填把事件写进更早的日期；
- 时钟回拨；
- 跨午夜活动段先创建次日记录、再补写前一日记录。

乱序后 `prune()` 仍能按条件过滤，但 `ensureDaily()` 的淘汰会删掉"数组第一个"而不是"最老的那个"，
导致保留期内的记录被提前丢弃。规定：

```text
ensureDaily(dayKey):
    已存在 → 直接返回
    未满   → 按 dayKey 升序插入（不是追加）
    已满   → 先 prune，仍满则丢弃 dayKey 最小者；再按序插入
    dayKey == 0 或早于保留期下界 → 拒绝创建并返回 nullptr
```

测试必须覆盖："先建 D 日记录，再回填 D-1 日记录，然后把容量占满，验证被淘汰的是 D-1 之外的更早记录"。


---

## 6. 活动聚合写入

### 6.1 新活动段

PIR 触发且没有可延长的上一段时（判定见 §6.2）：

```text
activityCount           += 1                 // 归当前日
activitySegmentCount    += 1                 // 归当前日
activityTriggerBuckets[startHour]  += 1      // 归当前小时
activitySegmentBuckets[startHour]  += 1      // 归当前小时（整段只记一次）
activitySpanSeconds                 不变
activitySpanBuckets                 不变
```

### 6.2 延长活动段

**判定条件（全部满足才延长）**：

- 存在 `activeActivityId`，且该 id 对应的事件仍是最新活动段记录；
- 当前触发时间不早于段的 `last`（时间未回退）；
- 与上次末端的间隔 `<= activeActivityGapSeconds`（间隔**恰好等于**阈值仍属同一段）；
- 设备时间可信（`currentEpoch() != 0`）；
- `triggerCount < UINT16_MAX`（饱和时结束旧段、开新段，不回绕、不静默丢触发）。

**`activeActivityGapSeconds` 在段开始时锁定**，段存续期间不随设置变更而改变。
现有实现即如此（`statisticsStoreRecordActivity(mergeGapSeconds)` 每次传入最新配置，但只在建段时存入），
本版把它写成规则，避免"当前自动排风时长"被理解成动态值。

**清除 `activeActivityId` 的全部时机（缺一不可）**：

```text
写入任何非 activity 事件
该 id 对应记录被容量淘汰
设备重启（statisticsStoreBegin）
校时回填（statisticsStoreSetClock）
活动段因超时或饱和而结束
```

**`triggerCount` 与日桶一致性**：

- 日桶是**唯一真值**，事件里的 `reserved` 只是副本，仅供单日详情展示；
- 两者必须在**同一个 persist 快照**内同步 +1，禁止分两次落盘；
- 查询时不得用事件副本反推日桶，反之亦然。

**跨度增量**：

```text
oldEnd = previous.unixSeconds + previous.durationSeconds   // = 上次触发时刻
newEnd = currentTrigger.unixSeconds
delta  = newEnd - oldEnd
```

处理：

```text
activityCount              += 1
activityTriggerBuckets[currentHour] += 1
activitySpanSeconds         += delta
activitySpanBuckets[所有覆盖小时]   += delta 的切片
activitySegmentCount        不变
activitySegmentBuckets      不变
事件记录：durationSeconds = newEnd - first，reserved = triggerCount
```

禁止：

```text
把更新后的整个 durationSeconds 再加一次
把 delta 同时写进日标量以外的第二处
在查询时再补一次 delta
```

### 6.3 跨午夜

活动段可能跨本地午夜。delta 必须按本地日期和小时拆分：

```text
for 每个被 [oldEnd, newEnd) 覆盖的本地小时 h:
    秒数 = overlap([oldEnd, newEnd), [h.start, h.end))
    DailyRecordV5(h 所属本地日).activitySpanBuckets[h] += 秒数
    DailyRecordV5(h 所属本地日).activitySpanSeconds    += 秒数
```

- 日标量与小时桶必须同步写入，保证 §4.1 的不变式；
- 触发数只记在实际触发所在日/小时，**不拆分**；
- 段数只记在段起点所在日/小时，**不拆分**；
- 本设计不允许偏移变化（§8.4），因此不存在"历史日期需要重映射"的分支。

### 6.4 重启、校时和回填

- **未校时**：事件可以保留，`unixSeconds` 保存 uptime 秒，且 `flags.bit0 = kEventFlagTimeUnsynced`；不写任何可信小时桶，不写日标量；对应覆盖位保持 0。
  这段时间的数据**只存在于事件里**，不生成任何 `DailyRecordV5`（`ensureDaily(0)` 直接拒绝）。
  查询侧只通过 `pendingUnsynced`（§10.8）以"本次开机累计"的形式暴露，不参与按日统计；
  重启后未校时事件时间戳被清零（§9.7），累计随之丢弃，不跨开机累计。
- **校时回填**：只回填 `activityCount`、`automaticCount`、`runtimeBuckets`（现有行为）。
  `activitySegmentCount`、`activitySpanSeconds`、三类活动桶**不回填**，对应覆盖位置 0（代价见 §4.4）。
  未校时期间完成的自动排风无法判断是否达到阈值，回填时会把**该日**的入厕覆盖位清 0——
  该日 `toilet` 整体不可用，不允许用"部分可信 + 部分缺失"拼出一个看起来完整的平均值。
- **重启**：保留已写入的跨度与事件，不推算断电期间活动；所有 `kActive` 记录一律转 `kInterrupted` 且标 `REBOOT_INTERRUPTED`（§9.7）。
- **旧 schema**：不伪造每小时触发分布。
- **事件被容量淘汰**：不再影响已经写入的每日桶。
- **事件回填**只允许在事实可证明完整时进行；默认不反推。

### 6.5 事件本身

活动事件仍保存：

```json
{
  "kind": "activity",
  "time": 1793548800,
  "durationSeconds": 148,
  "triggerCount": 45
}
```

每日桶和事件明细是两套数据：

- 每日桶负责 30 天图表与汇总；
- 事件明细负责单日详情与精确触发展示；
- 两者不能互相替代。

### 6.6 关于"未闭合活动段"（v2 §5.5 已删除）

v2 曾规定"查询今日时可以把尚未写入的当前段剩余跨度临时计入响应"。该规则与 §3.0 的语义冲突：

- 跨度定义为"首末触发时差"，一个活动段在每次触发时跨度即已完整确定，**不存在剩余跨度**；
- 若按"临时补 now − lastTrigger"实现，则零跨度单次触发会立刻出现正跨度，§4.1 的"零跨度画基线标记"分支永不生效；
- 同一天两次刷新之间语义漂移。

因此整条删除。进行中的自动排风同理：只在响应中返回 `activeAutomatic` 状态，不计入任何统计量（§7.2）。

---

### 6.7 事件时间戳的单调性（本版新增，D39）

单个 `droppedThrough` 之所以能精确判定任意一天的详情完整性，依赖一条**未写下的不变量**：

```text
events[] 的数组顺序 == 事件真实时间戳的先后顺序（剔除 0 与 flags.bit0 标记的未校时事件之后）
```

因为淘汰只从头部进行，头部即"时间最早"，所以"已丢事件的最大时间戳"同时也等于"已丢的时间边界"。
若这条不变量不成立，`droppedThrough` 只能证明"某个时间点丢过"，不能证明"该点之前全丢"。

**数组顺序等于时间顺序的来源**：

- 新事件一律 append 到末尾，不排序、不插到中间；
- 活动段延长是就地修改同一条记录，不改变位置，且末次触发时间单调前进；
- **校时回填**（§6.4）按 uptime 把未校时事件换算成真实时间，相对先后保持不变，
  因此回填后数组顺序仍与时间顺序一致；
- 校时之后写入的事件使用真实时间，必然晚于回填结果。

**唯一的破坏来源：时钟回拨**（用户手动改时间、NTP 跳变、OTA 后 RTC 异常）。

```text
写入事件时：
    lastTimestamp = 数组中最后一条"可信时间"事件的 unixSeconds
                   （该条 unixSeconds 为 0 或 flags.bit0 置位则跳过检测）
    若 newTimestamp + kClockRollbackToleranceSeconds < lastTimestamp
        → flags.bit2 = clockWentBackwards，置位后直到换 dataEpoch 才清
        → 事件照常追加（不丢数据），但时间轴不再可信

kClockRollbackToleranceSeconds 建议取 300（5 分钟）：需大于正常 NTP 微调与秒级抖动，
又要能在人为大幅改时间时及时捕获。
```

置位后的判定（见 §10.4）：保留期内的日期一律按 `CAPACITY_LIMITED` 处理。

**为什么不在写入时拒绝回拨**：设备时间可能本来就错了（例如 RTC 跳到 2030 年），
拒绝回拨会让用户无法修复，反而更糟。接受回拨并明确降级，比静默信任一个错误时间轴安全。

**恢复方式**：设置页"重置统计批次"（§8.4 同一入口）清空统计并换 `dataEpoch`，同时清除 bit2。

**prune() 的过期删除同样按 §10.4 的 onEvict 规则更新 `droppedThrough`**。它不影响保留期内日期的判定
（那些日期的时间戳都晚于 `retentionCutoff`），只是让 `droppedThrough` 保持"已丢事件最大时间戳"的字面含义。

**语义退化说明**：即使 bit2 未置位而顺序已轻微错乱，
`droppedThrough` 仍取"已丢事件的最大真实时间"，判定只会**更保守**（多标受限），
不会把不完整的日期说成完整。

---

## 7. 入厕汇总写入

### 7.1 自动排风结束

```cpp
if (kind == kAutomatic &&
    endReason == COMPLETED &&              // 关键：不是 state == kComplete
    effective * 2 >= configured) {
  DailyRecordV5* day = ensureDaily(localDayKey(startTime));
  day->toiletDurationSeconds += effective;
  day->toiletSampleCount     += 1;
  day->metricCoverage        |= kCoverageToilet;
}
```

要求：

- 使用自动排风**开始时间**归属日期；
- 使用实际运行时长 effective；
- 配置时长使用启动时保存的 `reserved`，旧记录无该字段时回退到当前正式配置；
- `endReason != COMPLETED` 一律不进入。

### 7.2 当前运行

查询时如果自动排风仍在运行：

- 不写入每日汇总；
- 不进入平均值；
- 可以在响应中额外返回 `activeAutomatic`（开始时刻 + 已运行秒数），但不能改变 `toiletSampleCount`。

### 7.3 旧数据

schema 4 没有每日入厕汇总：

- 迁移后 `metricCoverage` 的 bit7 为 0；
- 不使用旧事件重建"精确"平均值；
- 接口对该日返回 `toiletSampleCount: null`，UI 显示"该日期入厕汇总不可用"，不显示 0 分钟。

---

## 8. 时区与日期规则

### 8.1 固定偏移

本设计只支持设备固定 UTC 偏移 `timezoneOffsetSeconds`，不实现 IANA 时区、夏令时和旅行时区自动切换。

`timezoneOffsetMinutes` 在**首次可信校时**写入 NVS，此后不再变更；同时写入 `tzVersion = 1`。
`/api/time` 再次调用只校时，**忽略并丢弃传入的 offset**（不报错，回显设备当前固定偏移）。

### 8.2 日期边界（闭式公式）

```text
offset            = timezoneOffsetSeconds
localTimestamp(t) = t + offset
localDayIndex(t)  = floor(localTimestamp(t) / 86400)
localDayStart(t)  = localDayIndex(t) * 86400 - offset      // 该日本地零点对应的 UTC 秒
dayKey(t)         = YYYYMMDD of localTimestamp(t)           // gmtime 后取年月日
```

- 单日：from = localDayStart(from)，to = localDayStart(from) + 86400；
- 今日：from = localDayStart(now)，to = max(now, from + 1)；
- 多日范围：from **必须**落在本地零点，to 可以落在任意时刻（用于"含今天"）；
- 全部区间左闭右开 [from, to)；
- 自然日数：dayCount = localDayIndex(to - 1) - localDayIndex(from) + 1。

### 8.3 今日部分桶

今日始终返回 24 个桶：

- 未来小时 coveredSeconds = 0，数值为 0（不是 null，"还没到"是确定事实）；
- 最后一个有数据覆盖的桶 coveredSeconds < 3600；
- 不使用 now + 1 的包含式边界；
- App 的所有速率/平均值分母一律使用 coveredSeconds，禁止使用 end - start。

示例（from = 1793548800，to = 1793565000，即本地 04:30）：

| 桶 | start | end | coveredSeconds |
|---:|---:|---:|---:|
| 0–3 | from + n×3600 | start + 3600 | 3600 |
| 4 | 1793563200 | 1793566800 | **1800** |
| 5–23 | — | — | 0 |

### 8.4 偏移变更策略（本版新增，D7）

v2 一边声明"固定偏移"，一边要求"偏移变化后返回 TIMEZONE_MISMATCH 或近似提示"，
但没有任何落盘依据能判断哪些 dayKey 属于旧偏移。本版改为**冻结 + 明示 + 重置入口**：

1. **偏移永不自动变更**。设备换城市后，统计仍按首次校时的偏移划分自然日。
2. TIMEZONE_MISMATCH 的语义收紧为"**请求偏移 ≠ 设备固定偏移**"，即只可能是客户端 bug 或 App 缓存过期，不再是设备侧状态。
3. **用户可见位置（三处，缺一不可）**：
   - 配网/首次绑定流程的最后一步："统计时区将固定为当前手机时区（UTC+08:00），之后不会随手机或所在地自动变化。"；
   - 设置页"关于设备"条目常驻显示固定偏移；
   - 统计页首次进入时以一行灰字提示，不弹窗。
   三处文案必须一致，避免用户以为设备时区会跟随手机自动更新。
4. 设置页提供"重置统计批次"入口：二次确认后清空统计分区并轮换 dataEpoch，文案必须写明**会清空 30 天历史**。
5. 重新校时若检测到传入偏移与固定偏移不同，`/api/time` 回显中带 `timezoneFixed: true`，供 App 提示用户。
6. 若将来要支持旅行与夏令时，必须改成由 App 生成每个桶的 UTC 边界，或存储 UTC 小时桶；**不能继续假设每天 24 小时**。

---

## 9. Schema 4 → 5 迁移

### 9.1 现状

当前 readHeader / readSlot 只接受 header.schema == kSchema。
schema 不匹配时两个槽位都不可读，随后会清空统计并切换 dataEpoch。这会直接丢失旧数据，必须先修。

### 9.2 迁移原则

- 不更换 dataEpoch（数据集没有丢失）；
- 保留旧运行时长、活动次数、自动排风次数、事件、nextEventId、droppedThrough；
- 新指标无法准确还原时标为不可用（覆盖位清零），**不填 0 冒充**；
- 先写非活动槽并校验，再覆盖另一槽；
- 任一步失败都必须能收敛到"可用数据集"，且不重复迁移（见 §9.4）；
- 只有两个槽位都损坏时才进入清空和换 epoch 兜底。

### 9.3 读取流程

1. 分别读取两个槽位的 header（接受 schema 4 与 schema 5）；
2. 对每个槽位做完整校验（长度、CRC、dailyCount、eventCount）；
3. 选**有效且 generation 最大**的槽位，相同则取 A；
4. schema 5 直接使用；schema 4 按 §3.1 布局解析并转换为内存中的 V5（映射见 §5.2）；
5. 事件记录按 §5.1 结构转换；旧记录统一填 `LEGACY_UNKNOWN`（0），**不得填 COMPLETED**（理由见 §9.5）。
   schema 4 若用 `kUnsyncedTimeFlag` 编在 `unixSeconds` 高位，必须由 V4 专用解码器剥离旧标志、把 uptime 放入 V5 `unixSeconds`，并设置 V5 `flags.bit0`；不得把旧编码原样复制到 V5；
6. 检查 dataEpoch、nextEventId、activeRun；
7. 进入迁移写入（§9.4）。

### 9.4 迁移状态机（本版重写，D8）

v2 的步骤描述存在自相矛盾：既要求"任一步失败保留旧 schema 4 槽位"，又要求"写另一槽"——覆写之后旧槽就不存在了。
本版用 header 的 flags.bit0 = migrationInProgress 显式表达中间态。

**合法状态**：

| schema | flags.bit0 | 含义 |
|---:|---:|---|
| 4 | 0 | 未迁移 |
| 5 | 1 | 迁移已写入一槽，另一槽尚未补齐 |
| 5 | 0 | 迁移完成 |

**执行序列**（generation 严格 +1，不跳号）：

```text
1. 按 §9.3 选源槽，得到 generation = G
2. 在内存构造 V5 数据集
3. 目标槽 = (G + 1) 的奇偶决定（必须与 persist() 共用同一个槽选择函数）
4. 写目标槽：schema=5, flags=1, generation=G+1, 数据, CRC
5. 读回校验：CRC、schema、dailyCount、eventCount、nextEventId
6. 校验通过 → 写另一槽：schema=5, flags=0, generation=G+2
7. 校验通过 → 迁移完成
```

**掉电收敛规则**（启动时执行，且先于任何写入）：

```text
若存在 schema=5 且 flags=1 且 CRC 有效的槽:
    直接采用该槽数据，只补写另一槽（flags=0, generation = 该槽 generation + 1），不重新迁移
若存在任意有效槽:
    选 generation 最大者正常启动
若两槽均无效:
    清空 + 轮换 dataEpoch（唯一兜底）
```

**关键点**：migrationInProgress **不参与选槽**。选槽永远是"有效 + generation 最大"，
因此掉电在 4/5/6 任意一点都能收敛，既不会重复迁移，也不会选错槽。

### 9.5 迁移后的可用性

旧日期：

| 指标 | 可用性 | 覆盖位 |
|---|---|---|
| runtime | 可用 | bit0 = 1 |
| activityCount | 可用 | bit1 = 1 |
| automaticCount | 可用 | 无位，恒可用 |
| activitySegmentCount | **不可用** | bit2 = 0 |
| activitySpanSeconds | 不可用 | bit3 = 0 |
| 三类活动小时桶 | 不可用 | bit4–6 = 0 |
| toilet | 不可用 | bit7 = 0 |
| endReason | 全部为 `LEGACY_UNKNOWN` | 无位 |

**已知限制（必须写进 UI 文案）**：schema 4 的事件没有 endReason，迁移时统一填 `LEGACY_UNKNOWN`（枚举值 0），
**不是** `COMPLETED`。它表示"未知"，不表示"已完成"：

- 新接口的入厕判定是 `endReason == COMPLETED`，`LEGACY_UNKNOWN` 天然被排除，不会污染 toilet 汇总；
- 事件详情必须把这类记录显示为"升级前记录，完成状态未知"，不得显示为"已完成"或"已中断"；
- 任何维护脚本、回填代码、统计校验**不得**把 `LEGACY_UNKNOWN` 当作完成或中断，也不得据此反推；
- 因此旧日 toilet 仍整体不可用（bit7 = 0），不可用回填值生成平均值。

API 必须返回 coverageBits / coverage，App 根据它显示提示。

### 9.6 存储格式演进与 OTA 守护（本版新增，D17）

这是本次重构中**唯一会真正丢数据**的路径，v2 完全未覆盖。

问题链条：

```text
新固件把两槽升级为 schema 5
  → App 仍按 statisticsSchema=4 判断（v2 要求该字段固定 4 以兼容旧 App）
  → App 的降级门槛认为"目标固件 4 == 设备 4"，放行
  → 旧固件 0.5.1 的 readHeader 拒绝 schema 5（两个槽都不可读）
  → 旧固件进入"统计丢失"分支：清空 + 轮换 dataEpoch
```

必须同时满足以下三条，缺一不可：

1. **固件侧**：FIRMWARE_STATISTICS_SCHEMA 与 MIMIVENT_STATISTICS_SCHEMA marker 升为 **5**；
   同时新增 MIMIVENT_MIN_READABLE_STORAGE_SCHEMA marker = **4**；
   OTA 包元数据同步带上 schema 与 minReadable 两个字段（test_ota_package_builder 必须覆盖）。
2. **状态接口**：`/api/status` 新增 storageSchema 与 minReadableStorageSchema（见 §15.3）。
   旧固件没有这两个字段，分别按 4 与"等于 storageSchema"处理。
3. **App 侧**：firmware_update_page 的安装门槛改读可读区间，不再读 statisticsSchema（判定见下）。

**安装门槛：按目标固件声明的"可读区间"判定（D28，本版修正）**

只比较 schema 数字是不够的：`T > D` 只说明目标固件**写**的是更新格式，
**不能证明它能读** D。所以固件必须声明两个值：

| 字段 | 含义 |
|---|---|
| `storageSchema` | 本固件写入的存储格式（迁移后的目标格式） |
| `minReadableStorageSchema` | 本固件**能读懂的**最低存储格式（迁移的起点） |

判定只有一个式子：

```text
允许安装 ⟺ target.minReadableStorageSchema <= device.storageSchema <= target.storageSchema
```

即"设备当前格式必须落在目标固件的可读区间 [minReadable, storageSchema] 内"。

兼容矩阵：

| 设备当前 D | 目标固件 (storage, minReadable) | 结果 |
|---:|---|---|
| 4 | 0.6.0 → (5, 4) | 允许，升级时迁移 4 → 5 |
| 5 | 0.6.0 → (5, 4) | 允许，同格式 |
| 5 | 0.5.1 → (4, 4) | **阻止**：可读区间 [4,4] 不含 5（这就是原本的丢数据路径） |
| 4 | 0.7.0 → (6, 6) | **阻止**：目标读不了 4，必须先升到 0.6.0 |
| 5 | 0.7.0 → (6, 4) | 允许，迁移 5 → 6 |

字段来源与回退顺序：

1. 优先读 OTA 包元数据的 `minReadableStorageSchema` 字段（包元数据版本 +1，紧随现有 schema 字段）；
2. 缺失时回退到镜像 marker `MIMIVENT_MIN_READABLE_STORAGE_SCHEMA=<n>`；
3. 两者都缺失时按 `minReadableStorageSchema = storageSchema` 保守处理，即只允许同格式安装。

第 3 条专门服务 0.5.1 这类老固件：它们没有声明，也不可能迁移，因此只接受同格式降级。
反过来说，**0.6.0 必须显式声明 `minReadableStorageSchema = 4`**，否则按回退规则会变成
(5,5)，把 4 → 5 的正常升级也挡掉。这一条是发布前置条件，写进 §16.3 验收。

初稿把判定写成 `T != D → 阻止`，会挡住 4 → 5 的正常升级；
改成 `T >= D` 又依赖未声明的兼容保证。两者都不成立，只有可读区间判定是自洽的。

**发版顺序约束**：App 必须先于固件发布。否则用户升级固件后仍持有旧 App，降级门槛无从判断。
App 的 minimumFirmwareVersion 需同步提升，保证旧 App 无法安装新固件。

### 9.7 activeRun 恢复语义（本版修正，D9）

v2 §8.2 要求"迁移保留 activeRun"，这与现有实现相反，也会让脏状态进入统计。定稿：

```text
statisticsStoreBegin():
    activeRun = {}                                  // 无条件清零
    所有 state == kActive 的事件 → state = kInterrupted
                                → endReason = REBOOT_INTERRUPTED   // 只对原本 Active 的记录写，不覆盖已确定的原因
    未校时事件（flags.bit0 置位）→ unixSeconds = 0，清除 flags.bit0
```

语义区分：

- **保留**：事件记录本身、已确认的 durationSeconds（重启前最后一次落盘值）；
- **不保留**：运行状态。恢复后一律视为中断，不进入入厕汇总、不进入运行时长。


---

## 10. 统一查询 API

### 10.0 预设查询边界（本版新增，D1）

三个固定 Tab **不再由固件猜语义**，App 按下列公式生成 from/to，固件只做范围校验与聚合。

| 预设 | from | to | bucketHours | bucketCount | 末桶 |
|---|---|---:|---:|---:|---|
| 今日 | localDayStart(now) | max(now, from + 1) | 1 | 24 | coveredSeconds = now − 末桶 start |
| 昨日 | localDayStart(now) − 86400 | localDayStart(now) | 1 | 24 | 完整（86400） |
| 近7天 | localDayStart(now) − 6×86400 | max(now, from + 1) | 24 | 7 | coveredSeconds = now − 今日 00:00 |

**"近7天" = 含今天的 7 个本地自然日**，不是"最近连续 168 小时"。
依据：现有 App 的七日历算法就是 `startOffset = 6, dayCount = 7`（见 statistics_page.dart 的 `_StatisticsRange.sevenDays` 分支）。
若定义为 168 小时，跨夏令时或跨时区时会出现 6 天或 8 天，且与"今日"的边界不一致。

三个预设与自定义范围**共用同一套聚合与响应字段**，唯一差别是 App 传入的 from/to。

### 10.1 接口

```http
GET /api/stats/range?from=<unix>&to=<unix>&tzOffsetSeconds=<n>
```

| 参数 | 必填 | 说明 |
|---|---|---|
| from | 是 | UTC Unix 秒，左闭 |
| to | 是 | UTC Unix 秒，右开 |
| tzOffsetSeconds | 是 | 必须等于设备固定偏移，否则 TIMEZONE_MISMATCH |

**bucketHours 不是请求参数（D13）**。粒度由服务端按 §12 唯一确定，并通过响应回传 `bucketHours` / `bucketCount`。
理由：一套算法只能有一个实现。客户端算桶等于把同一段逻辑复制两份，任何一边改动都会产生静默的口径差异。

旧接口保留，语义不变：

```http
GET /api/stats?mode=today|yesterday|threeDays|sevenDays
```

旧接口继续走**独立的旧聚合路径**（见 §15.2），不读 schema 5 的新增桶。新 App 使用新接口。

### 10.2 响应

示例：7 个自然日的自定义范围，全部日期完整。from = 1793030400（本地 2026-10-27 00:00，UTC+8），
to = 1793635200（本地 2026-11-03 00:00），共 7 个自然日 → 日桶。

```json
{
  "apiVersion": 2,
  "storageSchema": 5,
  "statisticsSchema": 4,
  "from": 1793030400,
  "to": 1793635200,
  "tzOffsetSeconds": 28800,
  "timeSynced": true,
  "dayCount": 7,
  "bucketHours": 24,
  "bucketCount": 7,
  "summary": {
    "runtimeSeconds": 35700,
    "activityCount": 204,
    "activitySegmentCount": 61,
    "activitySpanSeconds": 5880,
    "automaticCount": 24,
    "toiletSampleCount": 20,
    "toiletAverageSeconds": 153
  },
  "coverage": {
    "runtime": true,
    "activityCount": true,
    "activitySegmentCount": true,
    "activitySpan": true,
    "activityTriggerBuckets": true,
    "activitySegmentBuckets": true,
    "activitySpanBuckets": true,
    "toilet": true
  },
  "buckets": [
    {"start":1793030400,"end":1793116800,"coveredSeconds":86400,"coverageBits":255,"runtimeSeconds":3600,"activitySpanSeconds":300,"activityTriggerCount":12,"activitySegmentCount":4},
    {"start":1793116800,"end":1793203200,"coveredSeconds":86400,"coverageBits":255,"runtimeSeconds":5400,"activitySpanSeconds":900,"activityTriggerCount":30,"activitySegmentCount":9},
    {"start":1793203200,"end":1793289600,"coveredSeconds":86400,"coverageBits":255,"runtimeSeconds":4800,"activitySpanSeconds":720,"activityTriggerCount":24,"activitySegmentCount":7},
    {"start":1793289600,"end":1793376000,"coveredSeconds":86400,"coverageBits":255,"runtimeSeconds":6600,"activitySpanSeconds":1200,"activityTriggerCount":41,"activitySegmentCount":12},
    {"start":1793376000,"end":1793462400,"coveredSeconds":86400,"coverageBits":255,"runtimeSeconds":5100,"activitySpanSeconds":810,"activityTriggerCount":27,"activitySegmentCount":8},
    {"start":1793462400,"end":1793548800,"coveredSeconds":86400,"coverageBits":255,"runtimeSeconds":3000,"activitySpanSeconds":450,"activityTriggerCount":15,"activitySegmentCount":5},
    {"start":1793548800,"end":1793635200,"coveredSeconds":86400,"coverageBits":255,"runtimeSeconds":7200,"activitySpanSeconds":1500,"activityTriggerCount":55,"activitySegmentCount":16}
  ],
  "days": [
    {"date":20261027,"start":1793030400,"end":1793116800,"coverageBits":255,"runtimeSeconds":3600,"activityCount":12,"activitySegmentCount":4,"activitySpanSeconds":300,"automaticCount":2,"toiletSampleCount":2},
    {"date":20261028,"start":1793116800,"end":1793203200,"coverageBits":255,"runtimeSeconds":5400,"activityCount":30,"activitySegmentCount":9,"activitySpanSeconds":900,"automaticCount":4,"toiletSampleCount":3},
    {"date":20261029,"start":1793203200,"end":1793289600,"coverageBits":255,"runtimeSeconds":4800,"activityCount":24,"activitySegmentCount":7,"activitySpanSeconds":720,"automaticCount":3,"toiletSampleCount":2},
    {"date":20261030,"start":1793289600,"end":1793376000,"coverageBits":255,"runtimeSeconds":6600,"activityCount":41,"activitySegmentCount":12,"activitySpanSeconds":1200,"automaticCount":5,"toiletSampleCount":4},
    {"date":20261031,"start":1793376000,"end":1793462400,"coverageBits":255,"runtimeSeconds":5100,"activityCount":27,"activitySegmentCount":8,"activitySpanSeconds":810,"automaticCount":3,"toiletSampleCount":3},
    {"date":20261101,"start":1793462400,"end":1793548800,"coverageBits":255,"runtimeSeconds":3000,"activityCount":15,"activitySegmentCount":5,"activitySpanSeconds":450,"automaticCount":1,"toiletSampleCount":1},
    {"date":20261102,"start":1793548800,"end":1793635200,"coverageBits":255,"runtimeSeconds":7200,"activityCount":55,"activitySegmentCount":16,"activitySpanSeconds":1500,"automaticCount":6,"toiletSampleCount":5}
  ],
  "availableFrom": 1793030400,
  "availableThrough": 1793635200
}
```

**自检点**：summary 的每个值必须等于 buckets / days 的对应求和（35700 / 204 / 61 / 5880 / 24 / 20 / 153）。
任何示例提交前都要做这项校验——v2 的三个示例错误全部来自这里。

示例：同一范围但首日为 schema 4 迁移日（覆盖位 = 3）。只列前 3 个桶，其余结构相同：

```json
{
  "apiVersion": 2, "storageSchema": 5, "statisticsSchema": 4,
  "from": 1793030400, "to": 1793635200, "tzOffsetSeconds": 28800, "timeSynced": true,
  "dayCount": 7, "bucketHours": 24, "bucketCount": 7,
  "summary": {
    "runtimeSeconds": 35700,
    "activityCount": 204,
    "activitySegmentCount": null,
    "activitySpanSeconds": null,
    "automaticCount": 24,
    "toiletSampleCount": null,
    "toiletAverageSeconds": null
  },
  "coverage": {
    "runtime": true, "activityCount": true,
    "activitySegmentCount": false, "activitySpan": false,
    "activityTriggerBuckets": false, "activitySegmentBuckets": false,
    "activitySpanBuckets": false, "toilet": false
  },
  "buckets": [
    {"start":1793030400,"end":1793116800,"coveredSeconds":86400,"coverageBits":3,"runtimeSeconds":3600,"activitySpanSeconds":null,"activityTriggerCount":null,"activitySegmentCount":null,"automaticCount":2,"toiletSampleCount":null},
    {"start":1793116800,"end":1793203200,"coveredSeconds":86400,"coverageBits":255,"runtimeSeconds":5400,"activitySpanSeconds":900,"activityTriggerCount":30,"activitySegmentCount":9},
    {"start":1793203200,"end":1793289600,"coveredSeconds":86400,"coverageBits":255,"runtimeSeconds":4800,"activitySpanSeconds":720,"activityTriggerCount":24,"activitySegmentCount":7}
  ]
}
```

要点：

- 单日响应不返回 `days`（多日才返回，用于"每日"列表）；
- 桶对象只包含**可按小时分解**的指标；`automaticCount` 与 `toiletSampleCount` 是日级标量，
  只出现在 `summary` 与 `days[]` 里，不出现在桶对象中；
- `buckets[i].coverageBits` 是该桶覆盖的若干天 `metricCoverage` 的按位与；
- 位为 0 的指标字段必须是 `null`，不是 0；
- `coveredSeconds` 恒存在，与 `end - start` 不等时以它为准。


### 10.3 coverage 语义（D5）

范围级 `coverage` 的 8 个布尔值 = 所有 `buckets[i].coverageBits` 的按位与，再按 §4.3 的位映射展开。

| 字段 | true 的含义 |
|---|---|
| runtime | 范围内每天的运行时长与运行桶都完整 |
| activityCount | 范围内每天的触发总数完整 |
| activitySegmentCount | 范围内每天的段数完整 |
| activitySpan | 范围内每天的日级跨度完整 |
| activityTriggerBuckets | 范围内每天的触发小时桶完整 |
| activitySegmentBuckets | 范围内每天的段数小时桶完整 |
| activitySpanBuckets | 范围内每天的跨度小时桶完整 |
| toilet | 范围内每天的入厕汇总完整 |

硬性规则：

```text
coverage.X == false  →  summary.X 必须为 null
coverage.X == false  →  App 不得显示 0，也不得用其它来源补算
coverage 不提供三态；"部分可用"由每桶的 coverageBits 表达，范围级只有 true/false
```

`detail` 是独立的完整性块，见 §10.4。

### 10.4 详情完整性（D6）

**唯一判定函数**，统计接口与事件接口必须调用同一个实现：

```cpp
struct DetailStatus {
  bool withinRetention;
  bool capacityLimited;
  bool complete;
  const char* status;   // COMPLETE / CAPACITY_LIMITED / OUT_OF_RETENTION
};

DetailStatus statisticsDetailStatus(uint32_t dayStart) {
  DetailStatus s{};
  s.withinRetention = dayStart >= retentionCutoff();
  // 关键：按"丢弃时间点"判定，而不是按"整机是否淘汰过"
  // droppedThrough 是"已丢事件中的最新时间戳"（含端点），因此比较符必须是 >=
  // 时间回拨过（flags.bit2）时时间轴不可信，保留期内一律保守降级（D39）
  s.capacityLimited = s.withinRetention &&
      (((headerFlags & kFlagClockWentBackwards) != 0) || droppedThrough >= dayStart);
  s.complete = s.withinRetention && !s.capacityLimited;

  s.status = s.complete        ? "COMPLETE"
           : s.capacityLimited ? "CAPACITY_LIMITED"
           :                     "OUT_OF_RETENTION";
  return s;
}
```

`retentionCutoff()` 的定义：

```text
retentionCutoff = now - kDetailRetentionDays * 86400     // 精确时刻，不做本地零点对齐
```

只由时间决定，**不掺入**"现存最早事件时间"。否则"保留期过期"与"容量淘汰"会对同一个日期重复上报，
掩盖真正的成因。

**保留边界必须用精确时刻，不能用 `localDayStart(now - 10d)`**：后者会把边界日整天算作可用，
但该日从零点到 `now - 10d` 之间的事件其实早已过期删除。用精确时刻比较 `dayStart` 才与
`prune()` 的实际删除点一致。

**按整日判定，不按查询时间段细分**：判定只比较 `dayStart` 这一个时刻。
边界日（`dayStart < retentionCutoff < dayEnd`，即当天开始后仍有部分事件已超出 10 天窗口）
按**整日过期**处理，报 `OUT_OF_RETENTION`，不细分"前半段可用"。

理由：详情是整日聚合视图，"这个日期的一半能看"对 App 和用户都无法解释。
代价：实际可看详情的自然日约为 9–10 天，与 §2"10 天详情不是无条件保证"一致。

**为什么必须按查询日判定**（v2.1 初稿的缺陷）：初稿写的是
`capacityLimited = eventCount == 256 && droppedThrough != 0`，这是**整机级**判断。
256 条事件在正常使用下两三天就会填满并开始淘汰，于是所有日期都被标成 CAPACITY_LIMITED，
详情页永久显示"已截断"——功能整体失效。

**时间戳语义必须与比较符配套（D37）**：`droppedThrough = T` 定义为
"**截至 T（含）的事件均已丢弃**"，即 T 是"最后一条被丢弃事件的时间戳"，不是排除式截止点。

选 inclusive 语义的依据：它与现有实现一致（`droppedThrough = max(旧值, 被丢事件的 unixSeconds)`），
且判定可直接用 `>=`。

两种语义只能二选一，且必须成对使用：

| 定义 | 含义 | 判定式 | T == dayStart 时 |
|---|---|---|---|
| **inclusive（本设计采用）** | 截至 T（**含**）的事件已丢弃 | `T >= dayStart` | 当天丢过一条 → 不完整，正确 |
| 排除式 | 早于 T 的事件已丢弃，T 本身可能还在 | `T > dayStart` | 当天可能一条没丢 → 不应判受限 |

**不允许定义写一套、比较符用另一套。** v2.1 修订稿就出现过这种错位：正文写的是排除式措辞，
比较符却用了 `>=`；上一轮修正文本时又把排除式应有的 `>` 误写成了 `>=`。实现时以本表为准：
**采用 inclusive，比较符只能是 `>=`**。

**淘汰时如何更新 `droppedThrough`（D38）**：

```cpp
void onEvict(const EventRecordV5& ev) {
  if (ev.unixSeconds != 0 && (ev.flags & kEventFlagTimeUnsynced) == 0) {
    droppedThrough = max(droppedThrough, ev.unixSeconds);
  }
  // 未校时事件（flags.bit0 置位）与已清零事件：不推进
}
```

未校时事件的 `unixSeconds` 是 uptime 秒，但其时间语义不可信，故由独立的 `flags.bit0` 识别并排除出 `max`。
这也避免了把真实 Unix 时间戳的高位误判为未校时标志。

未校时事件被淘汰只让 `pendingUnsynced` 减小（§10.8），**不影响任何日期的 detail 状态**。

| 情况 | 结论 |
|---|---|
| T < dayStart | 被丢弃的事件全部早于该日 → 该日事件完整（只要在保留期内） |
| T >= dayStart | 该日或更晚有事件被丢弃 → 该日不完整 |

**边界用例**：T 恰好等于 `dayStart`（当天 00:00:00 那条记录被丢）。因为 T 本身就是被丢弃的事件，
当天确实少了记录 → 判不完整，正确。这正是 inclusive 语义下 `>=` 的预期行为。

举例：设备已运行 20 天，`droppedThrough = T` 落在**三天前 23:00**。
则今天、昨天、前天的 `dayStart` 都晚于 T，详情可用；三天前及更早的日期满足 `T >= dayStart`，
标为 CAPACITY_LIMITED。

**注意方向**：T 越晚，受影响的日期越少；T 越早，受影响的日期越多。
（v2.1 初稿的示例把方向写反了，与判定式矛盾。）

响应块（下面是响应里的 `detail` 子对象，为便于校验补了外层花括号）：

```json
{
  "detail": {
    "status": "CAPACITY_LIMITED",
    "complete": false,
    "withinRetention": true,
    "capacityLimited": true,
    "timeUntrusted": false,
    "storedEventCount": 256,
    "eventCapacity": 256,
    "oldestAvailableAt": 1793030400,
    "newestAvailableAt": 1793635199
  }
}
```

字段语义（本节即唯一解释，其它章节不得另行定义）：

| 字段 | 含义 |
|---|---|
| status | 三个取值之一，由上面的优先级决定 |
| complete | 等价于 `status == "COMPLETE"` |
| withinRetention | 查询日不早于事件保留窗口起点 |
| capacityLimited | 该日在保留期内，且满足其一：该日范围内确有事件被丢弃（`droppedThrough >= dayStart`）；设备发生过时间回拨（`flags.bit2`） |
| timeUntrusted | 设备发生过时钟回拨（`flags.bit2`）。为 true 时 UI **优先**展示"时间被调整"，不得显示"容量限制被截断" |
（无 `partialGap` 字段：中间缺口已通过"淘汰只从头"消除，见下）
| storedEventCount | 当前存储的**事件总条数**（不是本页匹配数） |
| eventCapacity | 恒为 256 |
| oldestAvailableAt / newestAvailableAt | 现存事件的最早/最晚 `unixSeconds`，闭区间；无事件时省略 |

**命名约束**：`storedEventCount` 表示"存储总量"，事件接口原有的 `total` 表示"本查询匹配量"，
两者不得混用。DTO 层建议用不同命名空间隔离，避免 App 取值串位。

**关于 eventsTruncated**：旧接口保留该字段，语义收紧为 `capacityLimited`（或"起始时间早于 droppedThrough"），
仅用于旧 App。新接口**不返回**该字段。

**中间的缺口：不是加模糊标记，而是消除这个例外（D36）**

现有 `prepareEventSlot()` 为避免挤掉尚未归桶的未校时运行区间，会跳过它们去淘汰更靠后的记录，
在事件序列中间开洞。用"最近一次中间淘汰的时间戳"来标记这种缺口是**不可定位**的：
它只能证明"某个时刻丢过记录"，不能证明更早的日期也丢过；用 `T >= dayStart` 判定会把
受影响日期之前的全部日期一并误标，等价于让这些日期的详情永久不可用。

所以本版不加"可能不完整"的模糊状态，而是直接取消这个例外：

```text
容量淘汰一律从最老的事件（数组头部）开始；
未校时事件不特殊保护，与其他事件按同一顺序淘汰
```

理由：未校时数据本就无法归属日期，且重启即丢（§10.8）。为保住它在中间开洞，
代价是"详情完整性"退化成无法精确判定的状态——用不可靠的数据换不可判定的状态，不划算。

代价（明示）：设备长时间离线、事件累积超过 256 条时，最早的未校时记录会先被挤掉，
`pendingUnsynced` 相应减少。这与"重启即丢"是同一性质的损失，只发生在极端场景。

**唯一例外：正在运行的排风。** 该次运行开始时写入的记录若已被淘汰，停止时按 §6.7 的豁免
**追加一条完整记录**（未校时记录不参与时间顺序不变量，追加是允许的）。因此"离线期间启动、
离线期间结束"的那次排风，其运行时长在校时后仍能归账，不会因为 PIR 洪流而被静默丢弃。

由此：**缺口只可能出现在头部**，单个 `droppedThrough` 就足以精确判定任意一天，
`partialGap` 状态与 `nonContiguousDropThrough` 字段一并删除。

### 10.5 事件接口

```http
GET /api/events?start=<unix>&end=<unix>&kind=all&limit=32&beforeId=<id>
```

- 一律按 `[start, end)` 查询，与统计接口使用同一套本地日期边界；
- 新增返回：`detailComplete`、`detailStatus`、`withinRetention`、`capacityLimited`、
  `timeUntrusted`、`storedEventCount`、`eventCapacity`、`oldestAvailableAt`、`newestAvailableAt`；
- 完整性按 **start 所在本地日**判定；范围跨多日时 `detailStatus = "MULTI_DAY"`、`detailComplete = false`，
  其余字段照常返回，App 不得据此拼单日详情；
- 上述字段全部来自 §10.4 的同一函数，禁止在事件接口里另算一套。

**分页一致性**：

- 新 App 的单日详情**只用 `beforeId` 游标分页**，不用 `offset`。
  原因：`offset` 在两次请求之间若有新事件写入或旧事件被淘汰，会重复或跳过记录；
  `beforeId` 是稳定游标（事件 id 单调且不复用）。
- `offset` 参数仅为旧接口/旧 App 保留。
- 单日详情的 `end` 必须是**固定时刻**（今日取请求发起时刻），不能在翻页过程中重新取 now。

**多日范围的明细按柱窗口拉取**：

- 多日范围（近 7 天、自定义区间）**不整段拉取事件**——32 条一页远不足以覆盖数天；
- 用户点某根柱时，App 只以**该柱的时间窗**（`bucketHours` 决定，12 小时或 1 天）发起一次
  `/api/events` 请求，结果存入独立的 `intervalEvents` 槽位；
- 整范围刷新（每分钟）只重写 `events`，**不覆盖 `intervalEvents`**，否则用户正在看的详情会被冲掉；
- 超出 10 天保留期的区间，事件接口本身返回空，UI 退回"该范围不提供明细"，不得用日桶数据拼凑。

### 10.6 错误码

| 错误 | HTTP | 含义 |
|---|---:|---|
| INVALID_RANGE | 400 | from >= to；非法时间；多日范围 from 未落在本地零点 |
| RANGE_TOO_LARGE | 400 | 自然日数 > 30 |
| RANGE_OUT_OF_RETENTION | 400 | 早于每日汇总保留期 |
| TIMEZONE_MISMATCH | 409 | 请求偏移 ≠ 设备固定偏移 |
| STATS_NOT_READY | 503 | 统计尚未初始化 |

`BUCKET_INVALID` 已随 D13 删除（不再有 bucketHours 入参）。
错误响应必须保留 HTTP 状态码和机器可读错误码；App 不根据中文文本做逻辑判断。

### 10.7 availableFrom / availableThrough（D14）

```text
availableFrom    = 设备现存最早一条 DailyRecord 的本地日零点（UTC 秒）
availableThrough = 设备现存最晚一条 DailyRecord 的次日本地零点（UTC 秒，右开）
```

- 反映**设备汇总数据的实际覆盖范围**，不随查询范围变化（v2 示例里它恒等于 from/to，等于没定义）；
- 与事件侧的 `oldestAvailableAt / newestAvailableAt` 是两套东西，见下表；
- 设备无任何记录时两字段均省略。

**保留期内某天没有 `DailyRecord`，按"已知为零"处理，不降级 coverage。**
理由：日汇总在当天首个事件时创建，保留期内没有记录只可能是"当天没有任何事件"（含设备关机），
这个零是确定的；真正的数据丢失会通过 `dataEpoch` 轮换与保留期边界体现，不会伪装成零。
只有迁移日与未校时窗口才会出现"部分位不可用"。

| 字段 | 数据源 | 边界 | 变化时机 |
|---|---|---|---|
| availableFrom / availableThrough | 每日汇总 | 左闭右开 | 跨日、prune 后 |
| oldestAvailableAt / newestAvailableAt | 事件明细 | 闭区间 | 事件写入、淘汰后 |

### 10.8 未校时与时间可信度（本版新增，D30）

设备上电后若未校时，`currentEpoch()` 为 0，日汇总根本无法建立（`ensureDaily(0)` 拒绝创建）。
此时统计既不是 0，也不是"没有数据"，而是**无法按日期归属**——接口必须有字段明确表达这件事。

| 字段 | 出现条件 | 含义 |
|---|---|---|
| timeSynced | 恒出现 | 设备当前是否有可信时钟 |
| pendingUnsynced | 仅 `timeSynced == false` | 本次开机以来、尚未归属到任何自然日的累计量 |

```json
{
  "timeSynced": false,
  "pendingUnsynced": {
    "runtimeSeconds": 1820,
    "activityCount": 24,
    "automaticCount": 2
  }
}
```

**规则**：

1. `timeSynced == false` 时，`buckets` / `summary` / `days` / `coverage` 全部为空或 null，**不得输出 0**；
2. `pendingUnsynced` 只统计**当前开机周期内**未校时的记录。重启后未校时事件时间戳被清零（§9.7），
   这些量随之丢弃，不跨开机累计——因为已经无法归属到自然日；
   未校时事件在容量满时**不享受优先保留**，与其他事件按同一顺序从头部淘汰（§10.4 D36）；
3. 校时后按 §6.4 回填：只回填 `runtimeSeconds` / `activityCount` / `automaticCount` / `runtimeBuckets`，
   活动段数、跨度、三类活动桶保持覆盖位 0；
4. `pendingUnsynced` 由事件现算（即 `flags.bit0 = kEventFlagTimeUnsynced` 且 `unixSeconds != 0` 的事件），
   不占存储字段，也不写进 `DailyRecordV5`；
5. 未校时**不是错误**：仍返回 200，不使用 `STATS_NOT_READY`（该码只表示统计存储未初始化）；
6. App 在 `timeSynced == false` 时显示"设备时间未校准，暂无法按日期统计"，
   并把 `pendingUnsynced` 作为"本次开机累计"单独展示，不得混入任何按日图表。

---

## 11. 日期范围与单日规则

### 11.1 范围上限

- 最多 30 个自然日，包含首尾；
- 例：10 月 1 日到 10 月 30 日是 30 天；
- 超过 30 天拒绝，不静默裁剪；
- 判定固定为 `dayCount = localDayIndex(to - 1) - localDayIndex(from) + 1`，`dayCount > 30` 即 `RANGE_TOO_LARGE`；
- 范围起点早于每日汇总保留窗口时返回 `RANGE_OUT_OF_RETENTION`：

```text
summaryCutoff = localDayStart(now) - (kSummaryRetentionDays - 1) × 86400
from < summaryCutoff → RANGE_OUT_OF_RETENTION
```

  该判定**只看保留窗口，不看是否真的存在当日记录**：设备关机导致某几天没有 `DailyRecord`
  是合法的空范围（用 coverage 表达），不是越界，不得因此报错。

### 11.2 单日

```text
from        = 当天本地 00:00
to          = 次日本地 00:00
bucketHours = 1
bucketCount = 24
```

### 11.3 一日范围

"日期范围"中 start = end 时，归一为单日：

- 使用 24 个小时桶；
- 如果事件完整，展示详情；
- 不因为入口是"范围"而隐藏详情。

### 11.4 多日范围

- 逐日聚合 `DailyRecordV5`；
- 返回 `days[]` 供"每日"列表使用；
- **整个 `detail` 字段省略**，不返回一个 complete=false 的块——避免 App 把"多日没有详情"误读成"详情已过期"；
- 范围包含今天时，最后一个桶的 `coveredSeconds < bucketHours × 3600`。

---

## 12. 横轴分桶算法

### 12.1 三分支（本版重写，D2）

```text
dayCount == 1        →  bucketHours = 1,   bucketCount = 24
2 <= dayCount <= 6   →  按 §12.3 评分算法选桶
dayCount >= 7        →  bucketHours = 24,  bucketCount = dayCount
```

7 天及以上一律用日桶，理由：

- 与"近7天"预设保持一致——同一段日期无论从哪个入口进，图形一致；
- 与 `days[]` 天然一一对应，图表与每日列表同粒度；
- 桶数恒等于天数，永远落在 7–30 区间，不必再跑评分。

### 12.2 单日

```text
bucketHours = 1
bucketCount = 24
```

今日、昨日、自定义单日都一样。

### 12.3 2–6 天的评分

候选：`1h, 2h, 3h, 4h, 6h, 8h, 12h, 24h`（必须整除 24）。

```text
hours = dayCount × 24
候选过滤：10 <= hours / bucketHours <= 30
评分：   score = |桶数 - 20|
同分：   取更大的 bucketHours
```

### 12.4 桶对齐（D2）

- **桶一律从本地零点对齐**，永不跨本地日；
- 多日范围的 `from` 必须落在本地零点（否则 `INVALID_RANGE`）；
- 桶的理论边界恒为整桶，实际覆盖用 `coveredSeconds` 表达：

```text
start_i        = from + i × bucketHours × 3600
end_i          = start_i + bucketHours × 3600
coveredSeconds = max(0, min(end_i, to) - max(start_i, from))
```

App 的速率、均值、柱高归一化**一律以 `coveredSeconds` 为分母**，禁止用 `end - start`。
这条同时解决"今日末桶是部分桶"和"范围长度非整小时"两个问题。

### 12.5 分桶表（1–30 天）

**规则汇总**：

| 天数 | 选桶 | 桶数 |
|---:|---|---:|
| 1 | 1h | 24 |
| 2–6 | 按 §12.3 评分（见下表） | 16–20 |
| 7–30 | 24h | 等于天数 |

**2–6 天展开**：

| 天数 | 选桶 | 桶数 |
|---:|---|---:|
| 2 | 3h | 16 |
| 3 | 4h | 18 |
| 4 | 6h | 16 |
| 5 | 6h | 20 |
| 6 | 8h | 18 |

两张表都必须与固件实现同步更新，并作为 App 单测的表驱动数据源。

### 12.6 标签

- 单日：`00时`–`23时`；
- 2–6 天：`MM/DD HH`（按桶起始小时），按日期分组避免重叠；
- 7 天以上：`MM/DD`；
- App 不自行推算桶起止，一律使用响应里的 `start/end`。


---

## 13. App 查询层

### 13.1 查询模型

```dart
class StatisticsQuery {
  final int from;
  final int to;
  final int tzOffsetSeconds;
  final StatisticsPreset? preset;   // today / yesterday / last7Days / null(自定义)

  // 派生量，不可由调用方填充
  // 单日 = 覆盖 1 个本地自然日；与"是否满 24 小时"无关（今日的 to = now）
  bool get singleDay => localDayIndex(to - 1) == localDayIndex(from);
}
```

- App **不计算 bucketHours**，只负责按 §10.0 生成 from/to；
- `singleDay` 是派生量，定义为**覆盖 1 个本地自然日**（`localDayIndex(to - 1) == localDayIndex(from)`），
  不能用"to − from == 86400"判定：今日的 `to = now` 永远不满 24 小时，但它是单日，必须能看详情；
- 今日详情的 `end` 固定为**首次进入页面时的请求时刻**，翻页过程中不变；下拉刷新才重新取 now 并重置 `beforeId` 游标；
- 事件查询与统计查询共享同一个 `StatisticsQuery`，避免两处边界算法漂移。

### 13.2 缓存键（D25）

```text
键 = deviceId
   + dataEpoch
   + apiVersion
   + from
   + dayCount + fullOrPartial
   + tzOffsetSeconds
```

查询键采用稳定的日期范围身份：

| 查询 | toQuantized |
|---|---|
| 今日 / 近7天（to = now） | from + dayCount + partial，刷新不改变键 |
| 昨日 / 自定义范围（to 固定） | from + dayCount + full/partial |

理由：v2 直接把 `to = now` 放进键，导致今日的键每秒都变，
"相同查询并发合并"与"旧请求丢弃"两条要求永远不会命中。
响应保留实际 from/to，刷新覆盖相同范围的缓存，避免跨分钟丢失已显示数据。
控制器额外以连接设备身份、dataEpoch 和 apiVersion 隔离查询键；范围接口必须返回 deviceId/dataEpoch。

其它要求：

- 自定义日期不能覆盖今日/昨日缓存（键里已含 from/to，天然隔离）；
- 旧请求返回不能覆盖新页面（见 §13.3 的代际号）；
- `dataEpoch` 或 `deviceId` 变化后全部失效；
- "今日对比昨日"只对今日生效，对比数据单独取昨日聚合，不进今日缓存；
- 事件缓存使用独立命名空间（`eventsIdentityVersion`），见 statistics_event_cache.dart。

### 13.3 并发与代际

- 每次发起查询递增本地 `generation`，响应回来时 generation 不匹配则丢弃；
- 同一键的在途请求合并（`inFlight` 表），不重复发送；
- 切换 Tab 或改变日期时立即作废未完成请求，避免旧响应写回新页面。

### 13.4 旧固件回退

App 通过 §15.3 的能力字段判断：

```text
statsRangeApiVersion >= 2  →  使用 /api/stats/range
否则                        →  今日/昨日/近7天走旧 mode；"选择时间"隐藏并提示需要升级固件
```

- 不发送新接口给不支持的设备；
- 能力值必须**按 deviceId + firmwareVersion 缓存**，并在固件版本变化时失效（升级后能力会变）；
- 能力探测失败（超时、无该字段）按"不支持"处理。

### 13.5 UI 状态

必须覆盖以下互斥状态，任何不可用状态都不能用 0 代替：

| 状态 | 触发条件 | 呈现 |
|---|---|---|
| 加载中 | 请求在途 | 骨架屏 |
| 无数据 | 设备无任何 DailyRecord | "暂无统计数据" |
| 范围部分不可用 | 任一 `coverage.X == false` | 对应卡片显示"该指标在所选范围内不可用"，不画 0 |
| 明细过保留期 | `detail.status == OUT_OF_RETENTION` | "该日期明细已过保留期" |
| 时间轴不可信 | `detail.timeUntrusted && detail.status != OUT_OF_RETENTION` | "设备时间曾被调整，明细完整性无法保证；可在设置中重置统计批次" |
| 明细被容量截断 | `detail.status == CAPACITY_LIMITED && !detail.timeUntrusted` | "事件记录已因容量限制被截断" |
| 设备时间未校准 | 响应 `timeSynced == false` | "设备时间未校准，暂无法按日期统计"；另把 `pendingUnsynced` 作为"本次开机累计"单独展示（§10.8） |
| 固件不支持范围查询 | §13.4 回退分支 | "当前固件不支持选择时间，请升级" |

**详情降级文案的判定顺序（唯一）**：`OUT_OF_RETENTION > timeUntrusted > CAPACITY_LIMITED`。
超出保留期优先说明"过保留期"，其次说明"时间被调整"，最后才是"容量截断"——
三者不会同时出现两条文案。

---

## 14. UI 设计

### 14.1 Tab

```text
今日 | 昨日 | 近7天 | 选择时间
```

移除固定"近3天"Tab；"近3天"可由日期范围选择得到。旧接口的 `threeDays` 语义保留（兼容旧 App），只是不再有入口。

### 14.2 选择时间

底部弹层：

```text
单日
日期范围
```

单日：

- 日期选择器，可选最近 30 天；
- 详情可用性按整日判定（§10.4），因此实际可看详情的是**最近 9–10 个自然日**，不是固定 10 天；
- 11–30 天只显示总统计和图表；
- 超过 30 天不可选。

日期范围：

- 起止日期；
- 最多 30 个自然日；
- 不展示详情；
- 显示范围总统计、每日列表（`days[]`）与日桶图表。

### 14.3 图表

- 今日、昨日、自定义单日：24 个小时桶；
- 2–6 天：按 §12.3 自动分桶；
- 15 天以上：日桶，每桶对应 `days[]` 的一行；5–14 天为 12 小时桶（见附录 D.2）；
- 下方详情只用于单日；
- 活动跨度用黄色，排风用绿色；
- 零跨度活动（`activityTriggerCount > 0 && activitySpanSeconds == 0`）画基线标记，不画假柱；
- 柱高归一化与均值一律以 `coveredSeconds` 为分母；
- 某桶 `coverageBits` 对应位为 0 时，该指标该桶留空（灰色斜线或占位），不得画 0。

### 14.4 详情

详情只允许：

```text
singleDay == true
detail.complete == true
```

- `coverage` 只有 §10.3 的 8 个指标字段，**没有 `detail`**（v2.1 初稿误写，会让 App 取到 undefined）；
- 多日范围不返回 `detail` 字段，且 `singleDay` 为 false，两个条件都不满足。

否则显示 §13.5 对应的降级文案。

### 14.5 文案表

| 场景 | 文案 |
|---|---|
| 明细超期 | 该日期明细已过保留期 |
| 容量截断 | 事件记录已因容量限制被截断 |
| 时间被调整 | 设备时间曾被调整，明细完整性无法保证 |
| 入厕不可用 | 该日期入厕汇总不可用 |
| 跨度不可用 | 该时段活动跨度不可用 |
| 旧数据（schema 4） | 该日期为升级前数据，部分指标不可用 |
| 时区固定 | 统计时区已固定为 UTC+08:00 |

---

## 15. 兼容与能力发现

### 15.1 版本号与能力字段（D16）

```text
storageSchema           = 5    内部存储结构（新，供 OTA 与能力判断）
minReadableStorageSchema= 4    本固件能读的最低存储格式（OTA 安装门槛用）
apiVersion              = 2    新统计接口
statisticsSchema        = 4    旧 App 兼容字段，固定 4
```

**不要把内部存储 schema 直接暴露成旧 App 的 `statisticsSchema`**，否则当前 App 的
`statisticsSchema == 4` 兼容判断会失效。

### 15.2 旧接口投影映射（D15）

旧接口继续走**独立的旧聚合路径**（从事件实时聚合），一行都不读 schema 5 的新增桶。映射如下：

| 旧字段 | 来源 | 历史日（schema 4 迁移）行为 |
|---|---|---|
| runtimeSeconds | Σ runtimeBuckets | 同（V4 本就有） |
| activityCount | Σ activityCount | 同 |
| automaticCount | Σ automaticCount | 同 |
| toiletCount / toiletSampleCount | 旧路径：从事件计算 | 同（沿用旧事件） |
| toiletAverageSeconds | 旧路径 | 同 |
| bucketSeconds | runtimeBuckets 按旧桶切 | 同 |
| activityBucketSeconds | **旧路径：从事件聚合 span** | 同 |
| activityBucketCount | 旧路径：从事件计数 | 同 |
| days[] | 逐日聚合 | 同 |
| statisticsSchema | 固定常量 4 | 同 |
| eventsTruncated | capacityLimited（该日确有事件被丢弃） | 同 |

**两条路径并存是有意设计**：

- 旧接口对新指标的口径**不变**：例如 toilet 仍按"state 到达 complete"统计，包含被 PIR 打断的自动排风；
- 新接口按 §4.2 的 `endReason == COMPLETED` 统计；
- 因此**同一时刻新旧接口可能给出不同的 toilet 数字**，这是预期行为，禁止混用或互相校验。

这样做的代价是双份聚合代码；收益是旧 App 行为零变化，且迁移风险被限制在新接口内。

### 15.3 能力发现（D16）

全部收敛到 `/api/status`（HTTP 与 BLE 同一 payload）：

```json
{
  "firmware": "0.6.0",
  "statisticsSchema": 4,
  "storageSchema": 5,
  "minReadableStorageSchema": 4,
  "statsRangeApiVersion": 2,
  "summaryRetentionDays": 30,
  "eventRetentionDays": 10,
  "tzOffsetSeconds": 28800,
  "timezoneFixed": true,
  "capabilities": ["ble.control", "ble.stats", "ble.ota", "wifi.configure"]
}
```

规则：

- App **只信 `/api/status`**；`/api/stats` 里的 `statisticsSchema` 仅服务旧 App 兼容；
- `storageSchema` 缺失按 4 处理（旧固件）；
- `statsRangeApiVersion` 缺失按 0 处理（不支持范围查询）；
- `minReadableStorageSchema` 缺失时按 `= storageSchema` 处理（只允许同格式安装），
  该值的用途是 §9.6 的安装门槛，不是能力探测；
- `tzOffsetSeconds` 必须由设备提供——否则 App 无法在首次请求时填对这个必填参数；
- 注意 `ControlApi::statusResponse` 的 `payload[900]` 是硬编码缓冲，新增 5 个字段前必须核算长度，
  或改成流式/动态拼装，避免被 `snprintf` 截断成非法 JSON。

### 15.4 新 App 回退总结

| 设备能力 | 今日/昨日/近7天 | 选择时间 | 详情 |
|---|---|---|---|
| statsRangeApiVersion >= 2 | /api/stats/range | 可用 | 按 §14.4 |
| 无该字段 | 旧 /api/stats?mode= | 隐藏 | 旧逻辑 |

发版顺序：**App 先发**（先具备能力探测与降级门槛），固件后发（见 §9.6）。


---

## 16. 测试与验收

### 16.1 固件

**存储与迁移**

- schema 4 → 5 双槽迁移；`dataEpoch` 不变；
- 迁移在步骤 4 / 5 / 6 任意一点掉电，启动后必须收敛到可用数据集，且不重复迁移；
- 单槽损坏 + 另一槽有效 → 不清空、不换 epoch；
- 两槽都损坏 → 清空 + 换 epoch（唯一兜底）；
- 旧运行/活动/自动排风计数保留，覆盖位为 `0b00000011`；
- 30 天满载 + 256 事件满载同时成立的快照大小 == 14,536 B（`static_assert` + 运行时断言）；
- `SPIFFS.info()` 报告的 `usedBytes` 与 §5.3 理论值偏差 < 10%，单槽重写峰值后剩余空间 > 400 KiB；
- 迁移后旧事件的 `endReason` 全为 `LEGACY_UNKNOWN`，且入厕汇总不因它们变化（迁移前后 toilet 计数一致）；
- 容量淘汰只从头：构造"未校时风机事件位于数组前部 + 256 条满载"的场景，
  验证被淘汰的一定是最早写入的事件，事件序列中不出现中间洞（D36）；
- `droppedThrough` 边界：把 `droppedThrough` 精确设为某日 `dayStart`，该日必须判为 `CAPACITY_LIMITED`（D37）；
- 未校时事件被淘汰时 `droppedThrough` 保持不变：构造"未校时事件位于数组头部 + 满载淘汰"，
  验证 `droppedThrough` 不变，且保留期内所有日期仍为 `COMPLETE`（D38）；
- schema 4 迁移：构造含旧式高位 `kUnsyncedTimeFlag` 编码的事件，验证 V5 解码后时间戳只剩 uptime、`flags.bit0` 置位；
- Unix 时间戳高位边界：构造 2038 年及之后的有效时间戳，验证不会被识别为未校时；
- 时钟回拨：把系统时间后退 2 小时再写入事件，`flags.bit2` 必须置位，保留期内全部日期转为
  `CAPACITY_LIMITED`；执行"重置统计批次"后恢复 `COMPLETE`（D39）；
- 校时回填后事件时间戳序列仍非递减：取回填前后的相邻两条记录，验证 `t[i] <= t[i+1]`（D39）。

**活动聚合**

- 活动段延长只累加增量，不重复累加整段；
- 跨午夜段：Σ小时桶 == 日 span 标量；Σ日段数 == 总段数；次日段数为 0 且不报异常；
- 零跨度单次触发：触发桶 +1、段数 +1、span 不变；
- 触发数与段数分别正确（45 次触发 1 段 → count 45 / segment 1）；
- 段内 `triggerCount` 达 `UINT16_MAX` 时开新段，不回绕；
- 非 activity 事件写入后不再延长旧段；
- 目标活动记录被容量淘汰后，`activeActivityId` 被清除。

**入厕**

- 自动排风完成且 >= 一半 → 计入；< 一半 → 不计；
- PIR 打断、被替换、重启中断 → 不计入；
- 跨午夜按开始日归属；
- 运行中的自动排风不计入，仅返回 `activeAutomatic`。

**查询**

- 1/2/3/4/5/6/7/10/14/30 天的选桶与桶数符合 §12.5；
- 今日末桶 `coveredSeconds` 正确，未来桶为 0；
- 多日 non-aligned `from` 返回 `INVALID_RANGE`；
- 30 / 31 天边界：30 可查，31 拒绝；
- 任一覆盖位为 0 时，对应字段为 `null` 而非 0；
- 旧接口在 schema 5 下响应与 schema 4 逐字段一致（含 toilet 口径差异的稳定性）；
- BLE 与 HTTP 同一查询返回一致（分片重组后）。

### 16.2 App

- 今日/昨日/近7天三预设的 from/to 公式与 §10.0 一致；
- 单日/范围选择；30 天边界；
- 1–30 天分桶表驱动测试（数据源 = §12.5）；
- 缓存键：今日连续两次刷新（同分钟内）必须命中，实测命中率 > 0；
- `dataEpoch` / `deviceId` 变化后全部失效；
- 并发旧请求丢弃（代际号）；
- 旧固件回退（能力字段缺失）；
- 详情降级的三类文案（过保留期 / 时间被调整 / 容量截断，见 §13.5）；
- `coverage.X == false` 时不显示 0；
- 时间格式化（秒/分钟/小时）；
- 旧 schema 数据提示。

### 16.3 验收门槛

- 迁移后旧数据可读，`dataEpoch` 不变；
- **升级到 storageSchema 5 后回退 0.5.1 必须被 OTA 拦住**——拦不住即为 P0 缺陷；
- 0.6.0 镜像与 OTA 包必须显式声明 `minReadableStorageSchema = 4`；缺失即视为发布不合格
  （回退规则会把它变成 (5,5)，4 → 5 的升级会被自己挡掉）；
- 可读区间矩阵逐行验证（§9.6 的五种组合），含 (6,6) 挡住 D=4 与 D=5 两个用例；
- 详情保留边界：`dayStart < retentionCutoff < dayEnd` 的边界日必须整日报 `OUT_OF_RETENTION`；
- 时间回拨后 UI 必须走"时间被调整"文案，不得显示"容量限制被截断"（`timeUntrusted` 优先）；
- 30 天范围可查询，11–30 天活动图不伪造数据；
- 单日详情在超期 / 时间被调整 / 容量截断时给出**三种互斥**文案，且优先级符合 §13.5；
- App 不因自定义范围覆盖今日缓存；
- 旧 App 仍能使用旧接口；
- 新旧接口对同一历史日的 toilet 允许不同，且各自稳定；
- 19,656 B 快照下的 persist 耗时与 PIR 状态机延迟（目标 < 20 ms，见 §5.5）。

---

## 17. 实施顺序

**门禁：阶段 0 的文档定稿（本文）是后续所有编码的前置条件。** 数据模型与 API 未定死之前不进入阶段 A。

### 阶段 0：文档（本版）

- §3.0 事件语义、§10.0 预设边界、§12 分桶、§4.3 覆盖位、§10.4 完整性、§8.4 时区、§9.4 状态机；
- 全部规则已给闭式判定，无"建议/或/约"。

### 阶段 A：固件存储与迁移

1. `StatisticsConfig.h`：schema 常量、容量、保留期；删除四个零引用的历史预算常量；
2. 抽出 V4/V5 读取结构；`static_assert` 三处 sizeof；
3. 双槽迁移状态机（§9.4）+ 掉电收敛；
4. `endReason` 落盘；`activeRun` 恢复语义（§9.7）；事件 `flags.bit0` 未校时标志，
   以及 V4 旧高位标志的解码（D41）；
5. 新增每日活动/入厕字段与覆盖位；
6. 增量活动写入 + 跨日切分 + 饱和处理；
7. 写入节流（§5.5）；
8. 迁移、满载、掉电、跨日测试。

### 阶段 B：固件查询

1. `/api/stats/range` 参数解析与校验（HTTP + BLE 两处）；
2. 服务端选桶（§12）与 `coveredSeconds`；
3. coverage / detail 单一判定函数（§10.4）；
4. `days[]`、`availableFrom/Through`；
5. `/api/status` 新增能力字段（核算 `payload[900]`）；
6. 旧接口保持旧路径不动（回归测试证明逐字段一致）。

### 阶段 C：App 查询层

1. 能力探测与缓存（按 deviceId + firmwareVersion）；
2. `StatisticsQuery`（无 bucketHours，singleDay 派生）；
3. 新接口客户端与 DTO（`storedEventCount` 与 `total` 类型隔离）；
4. 缓存键与代际号、`to` 量化；
5. 旧固件回退。

### 阶段 D：App UI

1. Tab 调整（去近3天）；
2. 日期选择（单日 / 范围）；
3. 单日 24 小时图；
4. 多日分桶 + `days[]` 每日列表；
5. `coverageBits` 留空渲染、三类详情降级文案；
6. 回归清单。

### 阶段 E：OTA 与发版

1. `FIRMWARE_STATISTICS_SCHEMA = 5` 与包头部 schema 字段；
2. `firmware_update_page` 降级门槛改读 `storageSchema`；
3. **App 先发**，固件后发；
4. 现场验证：升级 → 回退被拦 → 再升级数据完好。

---

## 18. 实施落点

### 固件

| 文件 | 工作 |
|---|---|
| `StatisticsConfig.h` | schema、容量、保留期、写入节流常量、`kClockRollbackToleranceSeconds`；清理零引用预算常量 |
| `StatisticsTypes.h` | 覆盖位/溢出位常量；`endReason` 使用约定；`kEventFlagTimeUnsynced` |
| `StatisticsStore.h/.cpp` | V4/V5 读取、迁移状态机、每日桶、覆盖位、查询、单一判定函数；淘汰改为只从头（D36）；回拨检测置 flags.bit2（D39）；V4 高位未校时标志解码（D41） |
| `StatisticsActivityCore.h` | 活动段增量、跨日切分纯函数（保持无时钟无持久化） |
| `FanController.cpp` | 传入合并窗口、触发活动写入、构造 `endReason` |
| `FirmwareVersion.h` | `FIRMWARE_STATISTICS_SCHEMA = 5`、API 能力版本 |
| `ControlApi.cpp` | `/api/stats/range` 路由、`/api/status` 新字段、payload 容量核算 |
| `WifiHttpsServer.cpp` | 新路由注册与查询串解析 |
| `BluetoothManager.cpp` | BLE 侧新路由与 form 字段解析 |
| `tests/` | 迁移、满载、掉电、跨日、截断、覆盖位测试 |

### App

| 文件 | 工作 |
|---|---|
| `lib/features/statistics/presentation/statistics_page.dart` | Tab、日期选择、图表（coveredSeconds 分母）、详情、降级文案 |
| `lib/data/mimivent_controller.dart` | 查询缓存（键含量化 to）、请求去重、代际号、回退 |
| `lib/data/statistics_event_cache.dart` | 事件缓存键与完整性状态（beforeId 游标） |
| `lib/data/models.dart` | 统计/事件 DTO，`storedEventCount` 与 `total` 隔离 |
| `lib/transport/*` | 新 API 请求与响应解析 |
| `lib/features/firmware_update/firmware_update_page.dart` | 降级门槛改读 `storageSchema` |
| `docs/regression-checklist.md` | 回归项（§16.3） |

---

## 19. 关键决策摘要

```text
单日：24 个小时桶；2–6 天：1/2/3/4/6/8/12h 选 10–30 点；≥7 天：24h × 天数
预设：今日/昨日/近7天(含今天 7 个本地自然日)，from/to 由 App 按 §10.0 生成
桶：服务端唯一决定，客户端不传 bucketHours；桶按本地零点对齐，永不跨日
分母：一律 coveredSeconds，不是 end - start
今日 to = now，左闭右开；未来桶 coveredSeconds = 0
范围最多 30 个自然日；dayCount 用本地日索引差 + 1
活动：触发归触发日、段归段起点日、跨度按秒切分（允许次日段数为 0）
活动跨度日标量与小时桶同步增量累加，Σ小时桶 == 日标量
入厕：仅 endReason == COMPLETED（严格相等）且 >= 一半，按开始日归属；LEGACY_UNKNOWN 不算完成
单日 = 覆盖 1 个本地自然日，不是"满 24 小时"（今日 to = now 仍是单日）
覆盖位：8 位逐指标；位为 0 → 字段为 null，永不返回 0
事件完整性：单一函数，按查询日整日判定（保留边界用精确时刻）；三态 COMPLETE / CAPACITY_LIMITED / OUT_OF_RETENTION
淘汰只从头 → 缺口只可能在头部 → 单标量 droppedThrough（含端点）即可精确判定
数组顺序 == 时间戳顺序是前提；时钟回拨置 flags.bit2 并整体降级到"重置统计批次"
未校时事件（flags.bit0 标记）被淘汰时不推进 droppedThrough；未校时状态禁止借用时间戳高位（D41）
多日范围省略 detail 字段；详情只允许 singleDay && detail.complete
未校时：timeSynced=false + pendingUnsynced，不得伪造按日数据
分页：新 App 只用 beforeId 游标
时区：偏移永久冻结 + tzVersion；变更需"重置统计批次"
schema 4 → 5 保留式迁移，flags.bit0 表达中间态，不换 dataEpoch
activeRun 恢复后一律视为中断
storageSchema / apiVersion / statisticsSchema 三套版本号分离
OTA 门槛按可读区间：target.minReadableStorageSchema <= 设备 storageSchema <= target.storageSchema，App 先发
迁移后旧事件 endReason = LEGACY_UNKNOWN，不参与任何完成判定
```

---

## 附录 A：v2 → v2.1 变更对照（D1–D41）

| 编号 | 类别 | 问题 | 定稿 | 位置 |
|---|---|---|---|---|
| D1 | 语义 | 预设范围未定义（168h 还是 7 个自然日） | 含今天的 7 个本地自然日，公式表 | §10.0 |
| D2 | 语义 | 桶对齐、部分桶、桶数计算、谁选桶 | 服务端选桶；本地零点对齐；coveredSeconds 作分母 | §12、§10.1 |
| D3 | 语义 | 活动段跨日归属含糊 | 触发/段/跨度三元归属 + 三条不变式 | §4.1 |
| D4 | 语义 | 事件字段语义缺失，延长条件依赖数组位置 | §3.0 事实表；延长只看 activeActivityId | §3.0、§6.2 |
| D5 | 语义 | coverage 位过宽，无法表达部分桶 | 8 位逐指标 + 每桶 coverageBits；部分一律降级 | §4.3、§10.3 |
| D6 | 语义 | 完整性字段重复且无判定逻辑 | 单一函数 + 固定优先级 + beforeId 分页 | §10.4、§10.5 |
| D7 | 语义 | 时区变更无落盘依据 | 偏移永久冻结 + 重置入口 | §8.4 |
| D8 | 迁移 | 双槽原子性不足，步骤自相矛盾 | flags.bit0 状态机 + 掉电收敛规则 | §9.4 |
| D9 | 迁移 | activeRun 恢复语义与实现相反 | 无条件清零，一律视为中断 | §9.7 |
| D10 | 迁移 | 容量估算粗略，无分区预算 | sizeof 实测 312/20/52，快照 19,656 B，补 SPIFFS 算法与重写峰值 | §5.3 |
| D11 | 迁移 | droppedThroughEpoch 无法表达多段缺口 | 更名 droppedThrough，并收紧淘汰策略消除多段缺口 | §5.1、§10.4 |
| D12 | 迁移 | uint16 饱和无"不完整"标志 | 饱和即不可用，置 overflowFlags 与 null | §5.4 |
| D13 | API | bucketHours 必填却称自动选择 | 改为服务端决定，从入参删除 | §10.1 |
| D14 | API | availableFrom/Through 未定义 | 每日汇总覆盖范围，左闭右开，不随查询变化 | §10.7 |
| D15 | API | 旧接口如何投影到 V5 未说明 | 映射表 + 新旧两条聚合路径隔离 | §15.2 |
| D16 | API | 能力字段无落点 | 全部收敛到 /api/status | §15.3 |
| D17 | 安全 | 升级后回退旧固件会清空统计 | storageSchema 门槛 + 标记升 5 + App 先发 | §9.6 |
| D18 | 数据 | "只统计已完成"用现有状态判不出 | EventRecord 新增 endReason | §5.1、§7.1 |
| D19 | 数据 | activitySpanSeconds 日标量缺失 | 结构体 + summary 同时补齐 | §5.1、§10.2 |
| D20 | 语义 | §5.5 未闭合段与 span 定义冲突 | 整节删除，理由留档 | §6.6 |
| D21 | 数据 | 每次触发全量重写，写放大与延迟 | 脏标记 + 5 s 合并 + 强制落盘清单 | §5.5 |
| D22 | 文档 | 示例三处自相矛盾 | 重算示例并加"自检点"要求 | §10.2 |
| D23 | API | 多日响应缺 days[]，近7天列表无数据源 | 多日返回 days[]，与日桶一一对应 | §10.2、§11.4 |
| D24 | 数据 | ensureDaily 依赖 dayKey 递增，乱序会淘汰错记录 | 每日记录必须按 dayKey 有序插入 | §5.6 |
| D25 | App | to=now 进缓存键导致永远不命中 | to 量化到分钟 + 预设 TTL | §13.2 |
| D26 | App | singleDay 可被调用方随意填 | 改为派生量，给出判定式 | §13.1 |
| D27 | 语义 | singleDay 用"满 24 小时"判定，今日永远不是单日 → 今日详情无法展示 | 改为按本地自然日数判定，并规定今日详情固定 end | §13.1 |
| D28 | 安全 | OTA 门槛写成"schema 不相等就拦"，会挡住跨格式升级 | 先改方向性判定，再由 D35 收敛为可读区间 | §9.6 |
| D29 | 语义 | 详情完整性整机判定，容量满后所有日期永久不可查 | 按查询日边界判定；保留期只按时间 | §10.4 |
| D30 | API | 缺 timeSynced，未校时数据归属未定义 | 响应补 timeSynced + pendingUnsynced，新增 §10.8 | §10.8 |
| D31 | 数据 | 迁移 endReason 填 COMPLETED，伪造"已完成" | 新增 LEGACY_UNKNOWN=0，完成判定严格相等 | §5.1、§9.5 |
| D32 | 文档 | 预算只算净荷，"迁移临时占用 0"结论过强 | 补 SPIFFS 计算公式与 2×单槽重写峰值 | §5.3 |
| D33 | 语义 | 详情判定式与示例方向相反；保留边界用 localDayStart 会把边界日整天算可用 | 保留边界改精确时刻，判定按整日，示例方向修正 | §10.4 |
| D34 | UI | 未校时文案在 §13.5 与 §10.8 不一致 | 统一为"暂无法按日期统计"，pendingUnsynced 单独展示 | §13.5 |
| D35 | 安全 | OTA 的 T ≥ D 依赖未声明的兼容保证 | 改为可读区间 minReadable ≤ D ≤ storage，含回退规则 | §9.6、§15.3 |
| D36 | 语义 | 非头部淘汰产生不可定位的缺口，单标量只能"证明丢过"，会误标更早日期 | 取消非头部淘汰（只从头淘汰），删除 partialGap 与 nonContiguousDropThrough | §10.4 |
| D37 | 语义 | droppedThrough 定义与比较符不配套（排除式措辞 + >= 判定），T == dayStart 会误判 | 定义改为含端点，比较符统一为 >=，并给出边界用例 | §5.1、§10.4 |
| D38 | 数据 | 未校时事件时间戳若参与 max 会污染 droppedThrough | 未校时状态改用独立事件 flags；淘汰时不推进 droppedThrough | §5.1、§10.4 |
| D39 | 数据 | 按数组头部淘汰不足以证明时间戳有序（回填/回拨） | 补齐不变量；时钟回拨置 flags.bit2 并整体保守降级 | §6.7 |
| D40 | UI | CAPACITY_LIMITED 有两个成因，UI 一律说"容量截断"会误报时钟回拨 | detail 增加 timeUntrusted，UI 优先展示"时间被调整" | §10.4、§13.5 |
| D41 | 数据 | 将未校时标志编码在 uint32 Unix 时间戳高位会与 2038 年后的真实时间戳冲突 | V5 使用独立事件 flags.bit0；迁移时专门解码 V4 旧标志 | §5.1、§9.3、§10.4 |

---

## 附录 B：评审意见索引

### B.1 语义澄清类

| 原意见 | 结论 | 位置 |
|---|---|---|
| 1 固定 Tab 查询范围未定义 | D1 | §10.0 |
| 2 时间范围与时间桶边界不完整 | D2、D23 | §12.4、§12.5 |
| 3 活动段归属与跨日计数歧义 | D3 | §4.1 |
| 4 可延长条件与持久化事件模型不清 | D4 | §3.0、§6.2 |
| 5 活动小时桶覆盖位含义过宽 | D5 | §4.3 |
| 6 coverage.activity 与字段集合不匹配 | D5 | §10.3 |
| 7 事件完整性字段重复且定义不一致 | D6 | §10.4 |
| 8 跨时区后历史日期不可查无落盘依据 | D7 | §8.4 |

### B.2 迁移与存储类

| 原意见 | 结论 | 位置 |
|---|---|---|
| 双槽迁移原子性不足 | D8 | §9.4 |
| activeRun 恢复语义不明确 | D9 | §9.7 |
| 容量估算与结构声明不一致 | D10 | §5.3 |
| droppedThroughEpoch 语义可疑 | D11 | §5.1、§10.4 |
| uint16 饱和无标志 | D12 | §5.4 |

### B.3 API 与兼容类

| 原意见 | 结论 | 位置 |
|---|---|---|
| bucketHours 必填 vs 自动选择 | D13 | §10.1 |
| tzOffsetSeconds 历史查询无法按旧偏移请求 | D7 | §8.4 |
| availableFrom/Through 含义未定义 | D14 | §10.7 |
| 旧接口如何投影到 V5 未说明 | D15 | §15.2 |
| 能力字段位置与回退规则不明 | D16 | §15.3、§15.4 |

### B.4 补充发现（原意见未覆盖）

| 编号 | 问题 | 位置 |
|---|---|---|
| D17 | OTA 降级会清空 30 天数据（唯一真丢数据路径） | §9.6 |
| D18 | endReason 未落盘，"已完成"判不出 | §7.1 |
| D19 | activitySpanSeconds 日标量缺失 | §5.1 |
| D20 | 未闭合活动段规则与 span 定义冲突 | §6.6 |
| D21 | 每次触发全量重写 | §5.5 |
| D22 | 示例与规则冲突 | §10.2 |
| D23 | days[] 缺失 | §11.4 |
| D24 | 每日记录乱序插入 | §5.6 |
| D25 | 今日缓存键每秒失效 | §13.2 |
| D26 | singleDay 应派生 | §13.1 |

### B.5 第二轮评审（v2.1 初稿）落点

| 原意见 | 结论 | 位置 |
|---|---|---|
| 1 singleDay 让今日详情无法展示 | D27，改为按本地自然日数判定，今日详情固定 end | §13.1 |
| 2 coverage.detail 被引用但响应里没有 | 统一为 detail.complete；coverage 只保留 8 个指标字段 | §14.4、§10.3 |
| 3 详情完整性整机判定过度保守 | D29，改按查询日边界判定；保留期只按时间 | §10.4 |
| 4 迁移 endReason 默认 COMPLETED 不妥 | D31，新增 LEGACY_UNKNOWN=0，完成判定严格相等 | §5.1、§9.5 |
| 5 请求缺 timeSynced 与未校时规则 | D30，新增 §10.8 与 pendingUnsynced | §10.8 |
| 边界1 容量预算只算净荷，"迁移临时占用 0" | D32，补 SPIFFS 公式与 2×单槽重写峰值 | §5.3 |
| 边界2 未校时与 V5 查询模型不衔接 | D30，明确数据只存在于事件里、重启不累计 | §10.8、§6.4 |
| 边界3 OTA 门槛未区分升级/降级 | D28，改为方向性判定 | §9.6 |
| 边界4 时区固定需写入产品行为 | 三处用户可见位置（配网/设置/统计页） | §8.4 |
| 边界5 §12.5 表头格式 | 拆成"规则汇总 + 2–6 天展开"两张规范表 | §12.5 |

### B.6 第三轮评审（v2.1 修订稿）落点

| 原意见 | 结论 | 位置 |
|---|---|---|
| 1 详情完整性判定式与示例冲突；保留边界把边界日整天算可用 | D33：保留边界改精确时刻，判定明确按整日，示例方向修正 | §10.4 |
| 2 未校时 UI 文案沿用旧规则 | D34：§13.5 与 §10.8 统一为"暂无法按日期统计" | §13.5、§10.8 |
| 3 OTA 的 T ≥ D 依赖未写明的兼容保证 | D35：改为可读区间 minReadable ≤ D ≤ storage，含缺失回退 | §9.6、§15.3 |

### B.7 第四轮评审（v2.1 定稿前）落点

| 原意见 | 结论 | 位置 |
|---|---|---|
| 1 nonContiguousDropThrough 无法定位受影响日期，措辞过于确定 | D36：不是加"可能不完整"的模糊标记，而是取消非头部淘汰，让缺口只可能在头部 | §10.4 |
| 2 T == dayStart 时边界可能判错，时间戳语义与比较符不配套 | D37：定义改为"含端点"，比较符统一 >=，补边界用例 | §5.1、§10.4 |
| 3 minReadableStorageSchema 必须代表固件可读的全部范围 | 保持不变；在 §16.3 增加"可读区间矩阵逐行验证" | §16.3 |

### B.8 第五轮评审（定稿前）落点

| 原意见 | 结论 | 位置 |
|---|---|---|
| 1 排除式语义的比较符说明写反 | 已改正：改为对照表，明确"采用 inclusive，比较符只能是 >=" | §10.4 |
| 2 未校时事件被淘汰时 droppedThrough 如何更新未定义 | D38：通过独立事件 flags 识别，淘汰时不推进 droppedThrough，只影响 pendingUnsynced | §5.1、§10.4 |
| 3 按头部淘汰不足以证明时间戳有序 | D39：补单调性不变量、回填保持性、回拨检测与整体降级 | §6.7 |
| 自查 | CAPACITY_LIMITED 的两种成因在 UI 上无法区分 | D40：detail 增加 timeUntrusted，UI 优先展示"时间被调整" | §10.4、§13.5 |

### B.9 第六轮评审（定稿前）落点

| 原意见 | 结论 | 位置 |
|---|---|---|
| 未校时标志占用 Unix 时间戳高位，与 2038 年后的有效时间戳冲突 | D41：V5 改用独立事件标志位，V4 迁移时剥离旧编码并转换 | §5.1、§9.3、§10.4 |

---

## 附录 C：本版有意接受的取舍

| 取舍 | 代价 | 收益 |
|---|---|---|
| coverage 二值化，部分一律降级 | 未校时几小时后当天 span 图整日空 | 固件/API/App 三处都不需要状态机，永不输出真假混排曲线 |
| 桶宽按跨度固定 | 15 天以上看不到小时级细节 | 图形与每日列表同粒度，柱数恒定在 10–30，预设与自定义一致 |
| 时区偏移永久冻结 | 换城市后自然日边界仍按旧偏移 | 历史 dayKey 语义永远自洽，无需存每条的偏移 |
| 新旧两套聚合路径并存 | 双份聚合代码，同一时刻数字可能不同 | 旧 App 行为零变化，迁移风险限制在新接口 |
| 偏移不可变更 | 需要"重置统计批次"这种破坏性入口 | 消除整个"跨偏移历史解释"问题类 |
| 入厕时长取感应跨度而非排风时长（附录 D.5） | 口径切换当天的"平均入厕时间"是两种口径的混合值，无法回溯；无前置活动的强制排风不计样本 | 入厕时长反映人在卫生间的时间，且短时入厕也能被统计到 |


---

## 附录 D：实现期发现的硬约束（v2.1 定稿后补充）

以下四条都不是设计时能推出来的，全部来自真机联调。它们改变了实现，但**不改变 v2.1 的数据语义**。

### D.1 落盘布局变更必须同时提升 schema

`StoreHeaderV5` 的长度从 52 字节增加到 56 字节（新增 `migratedThroughDayKey`）时，版本号仍停在 5，结果：

```
0.6.0 写入 52 字节布局的快照
0.6.1 按 56 字节布局解析
→ header 字段错位 + CRC 覆盖范围变化 → 两个 slot 全部校验失败
→ 触发 snapshot loss 分支 → 30 天历史被清空
```

**规则**：`sizeof(StoreHeaderV5)`、`DailyRecordV5`、`EventRecordV5` 中任何一个变化，必须同时提升 `FIRMWARE_STATISTICS_SCHEMA`，并同步 `FIRMWARE_MIN_READABLE_STATISTICS_SCHEMA`。schema 5 与 6 的 header 布局不兼容，因此 0.6.2 起 `MIN_READABLE` 直接设为 6，不声称可读 5。

### D.2 选桶规则（替代 §10.2 的"7 天以上日桶"）

约束：柱数落在 **10–30**，且每根柱的小时数能整除 24。

| 跨度 | 桶宽 | 柱数 |
|---|---|---|
| 1 天 | 1h | 24 |
| 2 天 | 2h | 24 |
| 3 天 | 3h | 24 |
| 4 天 | 4h | 24 |
| 5–14 天 | 12h | 10–28 |
| 15–30 天 | 24h | 15–30 |

近 7 天因此从 7 根日柱变成 **14 根 12 小时柱**，明细仍按 10 天保留期可取（点柱时只拉该柱时间窗的事件）。

### D.3 BLE 单响应上限

旧 mode 接口响应 2.7 KB（12 个分片），range 接口单日 24 桶实测 **5.1 KB**（21 个分片）。App 的 `BleProtocol.maximumResponseBytes` 原为 4096，会把 range 响应直接判为超限：

```
FormatException: BLE V2 响应长度超过上限
```

**上限改为 24576**（覆盖 30 天满载）。同时连接建立后请求 `ConnectionPriority.high`，把连接间隔从 30–50 ms 压到 11–15 ms，分片吞吐翻倍。

### D.4 旧固件 WiFi HTTPS 通道的两道资源门槛（现已移除）

**门槛一：服务启动的堆下限。** `WifiHttpsServer::start()` 原本要求空闲堆 ≥ 56 KB，但 schema 5 的常驻统计缓冲（`daily[30]` 9.4 KB + `events[512]` 10 KB，见 D.6 已降到 256 条）把空闲堆压到约 50 KB，WiFi 服务永远起不来：

```
[wifi-read] resource gate blocked
[wifi-read] ready=0 heap=50840 largest=40948
```

改为：空闲堆 ≥ **48 KB** 且最大连续块 ≥ 20 KB；处于 48–56 KB 之间时打一行 `low heap pass` 便于观察。

**门槛二：TLS 栈占用。** 双栈（BLE + WiFi）同时驻留时，`httpd.stack_size = 16384` 会把堆压到极限：

```
E esp-aes: Failed to allocate memory
E esp-tls-mbedtls: mbedtls_ssl_handshake returned -0x0001
BLE client disconnected; reason=0x213
[wifi-read] heap=6160 largest=1524 minimum=52
```

栈降到 **10240** 后：`heap=36888 largest=28660`，TLS 握手与 BLE 连接都恢复。

**门槛三（连带）：range 响应必须精简。** 设备堆只有 22 KB、最大连续块 9.7 KB 时，拼不出 5.1 KB 的 JSON 串，请求返回空体，App 侧表现为 `FormatException: Unexpected end of input`。因此桶与 `days[]` 的键名改为短键，不可用字段整段省略：

```json
// 旧
{"start":..,"end":..,"coveredSeconds":3600,"coverageBits":255,
 "runtimeSeconds":3180,"activitySpanSeconds":null,
 "activityTriggerCount":null,"activitySegmentCount":null}
// 新
{"start":..,"end":..,"cov":3600,"bits":255,"rt":3180}
```

单日响应从 5.1 KB 降到约 3 KB。**省略即代表不可用**，与 `null` 语义一致。

### D.5 入厕时长取感应跨度而非排风时长

原实现在 `fanStopped` 里用自动排风的持续时长作为入厕样本：

```cpp
const uint32_t effective = activeRun.durationSeconds;   // 设备吹了多久
```

但自动排风是"人离开后再吹 N 分钟"，衡量的是设备行为。改为取该次排风对应的活动段跨度：

```cpp
const uint32_t effective = lastActivitySpanSeconds;     // 人在里面待了多久
```

`lastActivitySpanSeconds` 在 `statisticsStoreRecordActivity` 中被延长时更新为 `last - first`，新段开始时清零。**拿不到活动跨度时不计样本**——用排风时长冒充会让平均值系统性偏大。

### D.6 事件容量变更同样属于落盘布局变更

`kEventCapacity` 从 512 降到 256，`EventRecordV5 events[N]` 数组随之变小——快照总长度改变，**这是布局变更，必须升 schema**（6 → 7）。

直接改容量而不升版本会出现与 D.1 完全相同的后果：

```cpp
// probeSlot / readSlotV5 的校验
local.eventCount > kEventCapacity → return false;   // 旧快照 eventCount=512 → 全部判无效
→ 两个 slot 都读不出来 → snapshot loss → 30 天汇总一并清空
```

**迁移实现要点**（`readSlotV5(path, header, acceptSchemaV6: true)`）：

1. 按旧上限放宽：schema 6 允许 `eventCount <= 512`，schema 7 才按 256 校验；
2. **保留最新 256 条**：事件数组按旧到新排列，必须跳过头部多余记录，把尾部最新记录装入数组；
3. **全部记录仍须参与 CRC**，逐条流式读取；对被丢弃头部的可信时间戳取最大值，合并到 droppedThrough。只有原快照 CRC 通过后才采用新的边界；
4. `begin()` 里把 `eventCount` 截断到新容量，再以 schema 7 落盘，日志打印 `Statistics: migrating schema 6 -> 7 (events 512 -> 256)`；
5. `FIRMWARE_MIN_READABLE_STATISTICS_SCHEMA` 保持 6，以便读取旧槽位。

**收益不只是 5 KB**。实测（0.6.9 → 0.7.0）：

```
改前: heap=18,072  largest=7,668   minimum=160
改后: heap=42,140  largest=32,756  minimum=39,488
```

`events[512]` 占用的 10 KB 连续块会把堆切得很碎；缩到 5 KB 后碎片合并，`largest` 涨了约 25 KB。`minimum` 从 160 字节升到 39 KB，说明设备不再贴着内存悬崖运行——这才是 WiFi 握手稳定的根本原因，而不只是「省了 5 KB」。

**连带影响**：事件明细的实际覆盖范围收窄到约 3 天，App 的明细入口同步收敛为「今天 / 昨天 / 前天」；近 7 天与「更多时间」不再拉取事件，只展示图表与按日概览。

### D.7 控制去重记录不能放 NVS

**现象**：App 通过 MQTT 通道下发控制时，设备稳定返回 `503 DEDUP_UNAVAILABLE`，风机不动作；同一设备经 BLE 控制正常。

**根因**：去重记录（32 条 `WriteRecord` 打包成 2,696 字节的 `PersistSlot`）用 `nvs_set_blob` 存在 `mv-p4req` 里，`req-a` / `req-b` 双槽交替写入。NVS 的磨损均衡不会原地覆盖：每次写入都落到新页，旧页标记失效。累计若干次控制后分区耗尽：

```
nvs_set_blob(...) == ESP_ERR_NVS_NOT_ENOUGH_SPACE
→ saveWrites() 返回 false → beginWrite() 返回 -1
→ 503 DEDUP_UNAVAILABLE（App 显示"设备存储不足，无法安全去重"）
```

**为什么会误判成内存问题**：`saveWrites()` 里 `new(std::nothrow) PersistSlot{}` 和 `nvs_set_blob` 失败共用同一个静默 `return false`，而 `new` 那条路径没有日志。串口只看到 503、看不到失败原因，于是被当成堆碎片导致的分配失败——实测 `largest` 有 31 KB，远超 2.7 KB 需求，不是内存问题。

**规则**：NVS 只存**低频、小块、配置类**数据（绑定、时序设置、broker 配置）。高频改写、大块、需要双槽切换的数据一律放 SPIFFS/LittleFS 文件：

| 数据类型 | 存放位置 | 理由 |
|---|---|---|
| 统计快照（19,656 B / 14,536 B） | SPIFFS 双槽 + CRC | 频繁写、大块 |
| 控制去重记录（2,696 B） | 独立双槽文件 | 每次控制都写 |
| WiFi 绑定、时序、broker | NVS | 低频、小块 |

**配套要求**：去重记录写入必须**校验通过后才执行控制**，否则会出现「控制已执行但记录没落盘」，重启后同一条命令可能被重复执行。MQTT 发件箱也要为控制回执预留空间，否则 ack 被丢弃会让 App 卡在 `REQUEST_UNKNOWN`（"上次控制结果仍待确认"）。

### D.8 关闭板载 HTTPS 换取内存余量

**D.4 的三项措施（降低堆门槛、缩小 TLS 栈、精简响应）只是在争取余量，不是终点。** ESP32-C3 长期运行后堆碎片使最大连续块停在约 12 KB，而一次 TLS 握手需要 16–18 KB，`GET /api/status` 因此稳定失败（能取到证书，HTTP 返回 `000`）。真正的解法是关掉这条通道。

编译期关闭 HTTPS（`MIMIVENT_HTTPS_ENABLED=0`，见 `AppConfig.h`；`build_firmware.sh` 的 `read4k` 模式带此宏）后的实测：

```
静态内存: 75,032 → 70,784
heap:     25,148 → 46,376
largest:  12,276 → 36,852
minimum:     196 → 41,184
```

**关闭 HTTPS 时的三个必要改动**，缺一个都会让通道半死不活：

1. `start()` 里 `commandMutex` 与 `loadWrites()` 必须在 `#if` **之前**执行——MQTT 命令通道复用这套设施，提前 return 会让 `wifiHttpsMqttCommand` 因 mutex 为空直接返回 503；
2. `wifiHttpsServerReady()` 必须**如实**返回 `server != nullptr`。谎报 true 会让旧版 App 去连一个不存在的端口，最终报「设备未完成 NAS MQTT 控制」，比如实拒绝更难排查；
3. MQTT 的启动条件改用独立的 `controlChannelReady()`：关闭 HTTPS 时只检查设备身份与绑定，不再要求 HTTP 服务存在。

**读通路迁移**：设备 HTTPS 关闭后，App 的状态读取改走 `App → NAS gateway → MQTT state 快照`。网关需要在订阅里加上 `mimivent/v1/+/state`，并对外提供 `GET /api/v1/devices/{id}/state`；`deviceId` / `bindingState` / `protocolVersion` 这几个字段原本只由 HTTPS 响应追加，MQTT 的 state 里没有，网关返回时要补齐。
