-- rime_context_filter.lua
-- 纯学习的上下文调频引擎（v4 — Lua 源码持久化）
--
-- 学习：自动记录「上屏的前文 → 当前选的词」的共现关系
-- 匹配：根据当前上下文对候选词加权，越相关的越靠前
-- 持久化：数据以 Lua 表字面量格式存到
--         %APPDATA%\Rime\context_learned.data
--         由 Lua VM 原生加载，不需要逐行 regex 解析
--
-- 配置（可选，写入 rime_ice.custom.yaml patch: 下）：
--   context_filter:
--     save_interval: 30      # 每 N 次提交存一次盘（默认 30）
--
-- 激活：
--   "engine/filters/@after 6":
--     lua_filter@*rime_context_filter

----------------------------------------------------------------------
-- 持久化 — Lua 表字面量格式
----------------------------------------------------------------------

local DATA_FILE = (os.getenv("APPDATA") or "") .. "\\Rime\\context_learned.data"

local function esc(s)
  -- Lua 字符串字面量转义（中文不包含需要转义的字符，聊备一格）
  return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r") .. '"'
end

--- 将内存数据序列化为 Lua 源码
--- 格式：
---   return {
---     ["前文"]={["词"]=5,["词2"]=3},
---     ["前文2"]={["词"]=2},
---   }
local function serialize(data)
  local buf = { "return {\n" }
  for ctx, words in pairs(data) do
    local first = true
    buf[#buf + 1] = "  " .. esc(ctx) .. "={"
    for word, count in pairs(words) do
      if count > 1 then  -- 写入时即剪枝
        if first then first = false else buf[#buf + 1] = "," end
        buf[#buf + 1] = esc(word) .. "=" .. count
      end
    end
    if first then
      buf[#buf] = nil  -- 该前文没有有效词条，跳过
    else
      buf[#buf + 1] = "},\n"
    end
  end
  buf[#buf + 1] = "}\n"
  return table.concat(buf)
end

--- 用 Lua VM 原生加载数据文件（无逐行 regex）
local function load()
  local f = io.open(DATA_FILE, "r")
  if not f then return {}, 0 end

  local content = f:read("*a")
  f:close()
  if not content or #content == 0 then return {}, 0 end

  local loader, err = load(content, "@" .. DATA_FILE)
  if not loader then return {}, 0 end
  local ok, data = pcall(loader)
  if not ok or type(data) ~= "table" then return {}, 0 end

  -- 统计总条目数（仅用于 compaction 判断）
  local entries = 0
  for _, words in pairs(data) do
    for _, count in pairs(words) do
      if count > 1 then entries = entries + 1 end
    end
  end
  return data, entries
end

--- 原子重写整个文件
local function save(data)
  local tmp = DATA_FILE .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  f:write(serialize(data))
  f:close()
  os.remove(DATA_FILE)
  os.rename(tmp, DATA_FILE)
  return true
end

--- 确保文件和目录存在
local function ensure_file()
  local f = io.open(DATA_FILE, "a")
  if f then f:close(); return end
  local dir = DATA_FILE:match("^(.+)\\[^\\]+$")
  if dir then os.execute('if not exist "' .. dir .. '" mkdir "' .. dir .. '"') end
  f = io.open(DATA_FILE, "w")
  if f then f:write("return {}\n"); f:close() end
end

----------------------------------------------------------------------
-- 上下文评分
----------------------------------------------------------------------

local function score_candidates(candidates, window, learned)
  local scores = {}
  local last = window[#window]
  if not last or #last == 0 then return scores end

  -- 候选词快速查找
  local cand_set = {}
  for _, c in ipairs(candidates) do
    cand_set[c.text] = true
  end

  -- context keys with weights
  local keys = { { last, 1.0 } }
  if #last >= 2 then
    keys[#keys + 1] = { last:sub(-2), 0.5 }
  end
  keys[#keys + 1] = { last:sub(-1), 0.25 }
  if #window >= 2 then
    keys[#keys + 1] = { window[#window - 1] .. window[#window], 0.4 }
  end

  for _, kv in ipairs(keys) do
    local key, weight = kv[1], kv[2]
    local e = learned[key]
    if e then
      for word, count in pairs(e) do
        if cand_set[word] then
          scores[word] = (scores[word] or 0) + count * weight
        end
      end
    end
  end

  return scores
end

----------------------------------------------------------------------
-- 组件入口
----------------------------------------------------------------------

local function init(env)
  env.name_space = env.name_space:gsub("^*", "")
  local config = env.engine.schema.config

  env.save_interval = config:get_int(env.name_space .. "/save_interval") or 30

  -- 上下文窗口（最近 3 次上屏）
  env.window = {}

  -- 加载历史数据
  ensure_file()
  env.learned, env.entry_count = load()

  -- 会话级新增缓冲
  env.pending = {}
  env.commit_count = 0

  -- 监听提交
  env.engine.context.commit_notifier:connect(function(ctx)
    local text = ctx:get_commit_text()
    if not text or #text == 0 then return end

    local prev = env.window[#env.window]
    if prev and #prev > 0 then
      -- 更新内存
      local e = env.learned[prev]
      if e then
        e[text] = (e[text] or 0) + 1
      else
        env.learned[prev] = { [text] = 1 }
      end

      -- 待刷缓冲
      local pe = env.pending[prev]
      if pe then
        pe[text] = (pe[text] or 0) + 1
      else
        env.pending[prev] = { [text] = 1 }
      end
    end

    -- 更新窗口
    env.window[#env.window + 1] = text
    if #env.window > 3 then
      table.remove(env.window, 1)
    end

    -- 批量存盘（全量重写，Lua VM 编译加载比逐行 regex 快得多）
    env.commit_count = env.commit_count + 1
    if env.commit_count >= env.save_interval then
      -- 将缓冲合并到 learned
      for ctx, words in pairs(env.pending) do
        local e = env.learned[ctx]
        if not e then
          env.learned[ctx] = words
        else
          for word, count in pairs(words) do
            e[word] = (e[word] or 0) + count
          end
        end
      end
      env.pending = {}
      env.commit_count = 0
      env.entry_count = nil
      save(env.learned)
    end
  end)
end

local function filter(input, env)
  local candidates = {}
  for cand in input:iter() do
    candidates[#candidates + 1] = cand
  end
  if #candidates == 0 then return end

  local scores = score_candidates(candidates, env.window, env.learned)

  -- 阈值 2.0（同一搭配选 2 次以上才生效）
  local max_score = 0
  for _, v in pairs(scores) do
    if v > max_score then max_score = v end
  end
  if max_score < 2.0 then
    for _, cand in ipairs(candidates) do yield(cand) end
    return
  end

  -- 提权降序，同权保持原序
  local order = {}
  for i = 1, #candidates do order[i] = i end
  table.sort(order, function(a, b)
    local sa = scores[candidates[a].text] or 0
    local sb = scores[candidates[b].text] or 0
    if sa ~= sb then return sa > sb end
    return a < b
  end)
  for _, idx in ipairs(order) do
    yield(candidates[idx])
  end
end

return {
  init = init,
  func = filter,
}
