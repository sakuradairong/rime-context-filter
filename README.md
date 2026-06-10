# rime-context-filter

RIME 输入法上下文调频过滤器。根据已上屏的前文自动调整候选词顺序，越用越准。

## 原理

监听每次上屏内容，自动记录「前文 → 当前选的词」的共现关系。之后遇到同样前文时，将对应的候选词提权置顶。

- **纯学习**：零硬编码规则，完全从你的输入习惯中学习
- **跨会话**：学习数据持久化到本地文件，重启不丢
- **轻量**：热路径无文件 I/O，不卡输入

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
  save_interval: 30    # 每 N 次提交存一次盘（默认 30，增加可减少写入频率）
```

## 数据文件

学习数据存储在 RIME 用户目录下的 `context_learned.data`，格式为 Lua 表字面量：

```lua
return {
  ["接下来的"]={["任务"]=8,["工作"]=3},
  ["完成"]={["任务"]=5},
  ["那个"]={["人物"]=4},
}
```

由 Lua VM 原生加载，无需逐行解析。手动编辑这个文件可以增删规则或重置学习数据。

## 工作原理

### 上下文评分

```
commit_notifier
  ├─ 更新内存 (env.learned)
  ├─ 写入待刷缓冲
  └─ 更新上下文窗口
```

每次录入时，过滤器从当前上下文窗口提取 4 种 key 进行加权查询：

| Key | 权重 | 示例 |
|---|---|---|
| 精确前文 | 1.0 | `"接下来的"` |
| 末尾 2 字 | 0.5 | `"的"`（前文 `"的"` 时退化为单字） |
| 末尾 1 字 | 0.25 | `"的"` |
| 双词组合 | 0.4 | `"接下来的任务"` |

四个 key 的得分加权求和，总分 ≥ 2.0 才参与重排（约 2-3 次选择后生效）。

### 持久化

数据以 **Lua 源码格式** 存储。加载时通过 `load()` 由 Lua VM 一次性编译执行，不用逐行 regex 解析。写入使用原子重写（`.tmp` + `rename`），防止文件损坏。

## License

MIT
