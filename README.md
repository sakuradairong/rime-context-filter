# rime-context-filter

RIME 输入法上下文调频过滤器。根据已上屏的前文自动调整候选词顺序，越用越准。

[![CI](https://github.com/sakuradairong/rime-context-filter/actions/workflows/ci.yml/badge.svg)](https://github.com/sakuradairong/rime-context-filter/actions/workflows/ci.yml)

## 原理

监听每次上屏内容，自动记录「前文 → 当前选的词」的共现关系。之后遇到同样前文时，将对应的候选词提权置顶。

- **纯学习**：零硬编码规则，完全从你的输入习惯中学习
- **跨会话**：学习数据持久化到本地文件，重启不丢
- **轻量**：热路径无文件 I/O，不卡输入
- **跨平台**：自动适配 Windows / macOS / Linux 路径
- **安全**：数据文件在沙箱环境中加载，防止恶意代码执行
- **自动遗忘**：内置衰减机制，长期不用的搭配逐渐消退

## 效果

| 输入 | 第一次 | 多次选择后 |
|---|---|---|
| `接下来的` + `renwu` | 人物 1. 任务 2. 人物 | 任务 1. 任务 2. 人物 |
| `那个` + `renwu` | 任务 1. 人物 2. 任务 | 人物 1. 人物 2. 任务 |
| `完成` + `renwu` | — | 任务 自动置顶 |

所有搭配都是你日常打字中自然学会的。

## 安装

### 1. 放入 Lua 文件

将 `rime_context_filter.lua` 复制到 RIME 用户目录的 `lua/` 下：

| 平台 | 路径 |
|---|---|
| **Windows (Weasel)** | `%APPDATA%\Rime\lua\` |
| **macOS (Squirrel)** | `~/Library/Rime/lua/` |
| **Linux (ibus/fcitx5)** | `~/.config/ibus/rime/lua/` 或 `~/.local/share/fcitx5/rime/lua/` |
| **Android (Trime)** | `/storage/emulated/0/rime/lua/` |

### 2. 激活过滤器

在你想启用的输入方案 `.custom.yaml` 的 `patch:` 下追加到 `engine/filters` 列表末尾。

**雾凇拼音 (rime_ice)**——编辑 `rime_ice.custom.yaml`：

```yaml
patch:
  "engine/filters/@after 6":
    lua_filter@*rime_context_filter
```

**朙月拼音**——编辑 `luna_pinyin.custom.yaml`：

```yaml
patch:
  "engine/filters/+":
    - lua_filter@*rime_context_filter
```

### 3. 重新部署

- **Windows**: 右键托盘图标 → 重新部署
- **macOS**: 点击菜单栏鼠须管图标 → 重新部署
- **Linux**: `ibus-daemon -drx` 或重启 fcitx5
- **Android**: 重新部署 Trime

## 配置

可选参数，写入方案的 `context_filter:` 节：

```yaml
context_filter:
  save_interval: 30      # 每 N 次提交存一次盘（默认 30，增加可减少写入频率）
  data_path: ""           # 自定义数据文件路径，为空则自动检测（见下方）
  decay_enabled: true     # 是否启用衰减遗忘机制（默认 true）
  decay_rate: 0.95        # 每次保存时的衰减因子（默认 0.95）
```

### 参数说明

| 参数 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `save_interval` | 整数 | 30 | 每 N 次提交写一次磁盘。可设为 0 强制每次提交都存盘 |
| `data_path` | 字符串 | 自动 | 自定义数据文件完整路径。设置后覆盖自动检测结果 |
| `decay_enabled` | 布尔 | true | 启用衰减后，旧数据的权重随时间逐渐降低 |
| `decay_rate` | 浮点数 | 0.95 | 每次保存时所有计数的乘数因子（0 < rate < 1） |

### 衰减行为

衰减机制防止数据无限增长，让长期不用的搭配逐渐遗忘。`decay_rate = 0.95` 时：

| 初始计数 | 10 次保存后 | 20 次保存后 | 40 次保存后 | 消亡阈值 (≈1.1) |
|---|---|---|---|---|
| 1 | 已消亡 | — | — | 1 次 |
| 3 | 1.79 | 1.07 → 已消亡 | — | ~20 次 |
| 5 | 2.99 | 1.79 | 0.64 → 已消亡 | ~32 次 |
| 10 | 5.99 | 3.58 | 2.15 | ~44 次 |
| 50 | 29.9 | 17.9 | 6.43 | ~76 次 |

频率越高的搭配保留越久，偶然一次的搭配较快消亡，保持数据库精炼。

## 数据文件

学习数据存储在 RIME 用户目录下的 `context_learned.data`，路径根据平台自动检测：

| 平台 | 默认路径 |
|---|---|
| **Windows** | `%APPDATA%\Rime\context_learned.data` |
| **macOS** | `~/Library/Rime/context_learned.data` |
| **Linux** | `$XDG_DATA_HOME/rime/context_learned.data`，fallback `~/.local/share/rime/context_learned.data` |

也可以配置 `data_path` 指定任意路径。

### 文件格式

格式为 Lua 表字面量，由 Lua VM 原生加载，无需逐行解析。手动编辑此文件可以增删规则或重置学习数据。

```lua
return {
  ["接下来的"]={["任务"]=8,["工作"]=3},
  ["完成"]={["任务"]=5},
  ["那个"]={["人物"]=4},
}
```

### 安全性

数据文件在**沙箱环境**中加载。恶意构造的数据文件无法访问 `os`、`io`、`string` 等系统库，仅允许纯数据（表、数字、字符串）返回。兼容 Lua 5.1 / LuaJIT（自动降级为无沙箱模式并输出警告）。

## 工作原理

### 上下文评分

```
commit_notifier
  ├─ 更新内存 (env.learned)
  ├─ 写入待刷缓冲
  └─ 更新上下文窗口
```

每次录入时，过滤器从当前上下文窗口提取 4 种 key 进行加权查询。截取 key 时按 **UTF-8 字符边界**操作，避免中英混输时的乱码问题。

| Key | 权重 | 示例 |
|---|---|---|
| 精确前文 | 1.0 | `"接下来的"` |
| 末尾 2 字 | 0.5 | `"来的"`（前文 `"接下来的"` 时） |
| 末尾 1 字 | 0.25 | `"的"` |
| 双词组合 | 0.4 | `"接下来的任务"` |

四个 key 的得分加权求和，总分 ≥ 2.0 才参与重排（约 2-3 次选择后生效）。

### 持久化

数据以 **Lua 源码格式** 存储。加载时通过 `load()` 由 Lua VM 一次性编译执行，不用逐行 regex 解析。写入使用原子重写（`.tmp` + `rename`），防止文件损坏。

### 衰减 / 遗忘

每次保存时对全部计数乘以 `decay_rate`（默认 0.95），计数降至 1.1 以下的条目自动清除。频率越高的搭配保留越久，偶然一次的搭配较快消亡。

## 开发

### 运行测试

需要 Lua 5.3+ 或 LuaJIT：

```bash
lua test_rime_context_filter.lua
```

测试覆盖：评分聚合、序列化/反序列化往返、衰减计算、UTF-8 安全截取、表格复用。

### CI

每次推送自动运行：
- `luacheck` 静态分析
- 跨 Lua 5.3 / LuaJIT / Lua 5.1 三平台单元测试

## 版本历史

- **v5.1** — 修复 Linux 数据路径（XDG_DATA_HOME 优先）、UTF-8 按字符截取、Lua 5.3 序列化兼容、scores 表复用减 GC、新增 40 个单元测试 + CI
- **v5** — 跨平台路径自动检测、衰减遗忘机制、沙箱安全加载、热路径 GC 优化
- **v4** — Lua 源码持久化格式（移除 JSON 依赖）
- **v3** — 增量缓冲 + 批量写入
- **v2** — 上下文窗口 + 4 种 key 加权查询
- **v1** — 初版

## License

MIT
