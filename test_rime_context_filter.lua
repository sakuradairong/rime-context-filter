-- test_rime_context_filter.lua
-- 纯 Lua 单元测试（零外部依赖）
-- 运行: lua test_rime_context_filter.lua

local mod, err_msg = loadfile("rime_context_filter.lua")
if not mod then
  io.stderr:write("FATAL: Could not load rime_context_filter.lua: " .. tostring(err_msg) .. "\n")
  os.exit(1)
end
local ok, rcf = pcall(mod)
if not ok then
  io.stderr:write("FATAL: rime_context_filter.lua threw: " .. tostring(rcf) .. "\n")
  os.exit(1)
end

-- 测试用导出
local utf8_last       = rcf.utf8_last
local serialize       = rcf.serialize
local decay_learned   = rcf.decay_learned
local score_candidates = rcf.score_candidates

----------------------------------------------------------------------
-- Assertion helpers
----------------------------------------------------------------------

local total, passed, failed = 0, 0, 0

local function check(cond, msg)
  total = total + 1
  if cond then passed = passed + 1; return end
  failed = failed + 1
  io.write("  FAIL: " .. (msg or "check") .. "\n")
end

local function eq(got, expected, msg)
  total = total + 1
  if got == expected then passed = passed + 1; return end
  failed = failed + 1
  io.write("  FAIL: " .. (msg or "eq") .. "\n")
  io.write("    expected: " .. tostring(expected) .. "\n")
  io.write("    got:      " .. tostring(got) .. "\n")
end

local function near(got, expected, epsilon, msg)
  total = total + 1
  if math.abs(got - expected) < (epsilon or 0.001) then passed = passed + 1; return end
  failed = failed + 1
  io.write("  FAIL: " .. (msg or "near") .. "\n")
  io.write("    expected ≈ " .. tostring(expected) .. "\n")
  io.write("    got:       " .. tostring(got) .. "\n")
end

----------------------------------------------------------------------
-- Mocks
----------------------------------------------------------------------

local function cand(text) return { text = text } end
local function cands(texts) local c = {} for i, t in ipairs(texts) do c[i] = cand(t) end return c end

----------------------------------------------------------------------
-- 1. utf8_last
----------------------------------------------------------------------

io.write("=== utf8_last ===\n")
eq(utf8_last("hello", 2), "lo")
eq(utf8_last("hello", 1), "o")
eq(utf8_last("hello", 10), "hello")
eq(utf8_last("", 1), "")
eq(utf8_last("任务", 1), "务")
eq(utf8_last("任务", 2), "任务")
eq(utf8_last("接下来的任务", 2), "任务")
eq(utf8_last("接下来的任务", 1), "务")
eq(utf8_last("接下来的", 2), "来的")
eq(utf8_last("接下来的", 1), "的")
eq(utf8_last("任务abc", 2), "bc")
eq(utf8_last("任务abc", 4), "务abc")
io.write("  passed\n")

----------------------------------------------------------------------
-- 2. serialize 格式
----------------------------------------------------------------------

io.write("=== serialize ===\n")

local data = {
  ["接下来的"] = { ["任务"] = 8, ["工作"] = 3 },
  ["完成"]     = { ["任务"] = 5 },
  ["那个"]     = { ["人物"] = 4 },
}
local ser = serialize(data)
check(type(ser) == "string", "is string")
check(ser:match("^return%s*{"), "starts with return {")
check(ser:match("}\n$"), "ends with }\\n")

-- 通过 Lua VM 验证语法正确性
local fn, err = load(ser)
check(fn ~= nil, "serialized output is valid Lua (" .. tostring(err) .. ")")
if fn then
  local ok2, loaded = pcall(fn)
  check(ok2, "executable")
  if ok2 then
    eq(loaded["接下来的"]["任务"], 8)
    eq(loaded["完成"]["任务"], 5)
    eq(loaded["那个"]["人物"], 4)
  end
end

-- 空数据
local empty_ser = serialize({})
check(empty_ser:match("^return {"), "empty starts with return {")
check(empty_ser:match("}\n$"), "empty ends with }\\n")
local fn2, err2 = load(empty_ser)
check(fn2 ~= nil, "empty output is valid Lua (" .. tostring(err2) .. ")")
if fn2 then
  local ok3, empty_data = pcall(fn2)
  check(ok3 and type(empty_data) == "table")
  check(next(empty_data) == nil)
end

io.write("  passed\n")

----------------------------------------------------------------------
-- 3. decay_learned
----------------------------------------------------------------------

io.write("=== decay_learned ===\n")

-- 高频保留，极低频清除
do
  local d = { ["前文"] = { ["高频词"] = 50, ["将消亡"] = 1 } }
  decay_learned(d, 0.95)
  near(d["前文"]["高频词"], 47.5, 0.01, "high freq: 50*0.95")
  eq(d["前文"]["将消亡"], nil, "count 1 * 0.95 < 1.1 → nil")
end

-- 空表清除
do
  local d2 = { ["前文"] = { ["孤例"] = 1 } }
  decay_learned(d2, 0.95)
  eq(d2["前文"], nil, "empty ctx removed after all keys pruned")
  check(next(d2) == nil, "data fully empty")
end

io.write("  passed\n")

----------------------------------------------------------------------
-- 4. score_candidates 基本评分
----------------------------------------------------------------------

io.write("=== score_candidates ===\n")

do
  local s = {}
  score_candidates(cands{"任务", "人物", "工作"}, {"接下来的"}, {
    ["接下来的"] = { ["任务"] = 5, ["工作"] = 3 },
    ["来的"]     = { ["任务"] = 2 },
    ["的"]       = { ["人物"] = 4 },
  }, s)
  -- 精确前文 1.0: 任务 5, 工作 3
  -- last-2-char 0.5 (来的): 任务 1
  -- last-1-char 0.25 (的): 人物 1
  near(s["任务"], 6.0, 0.01, "任务 score")
  near(s["工作"], 3.0, 0.01, "工作 score")
  near(s["人物"], 1.0, 0.01, "人物 score")
end

-- 双词组合
do
  local s = {}
  score_candidates(cands{"任务", "人物"}, {"完成", "接下来的"}, {
    ["接下来的"]   = { ["任务"] = 5 },
    ["完成接下来的"] = { ["任务"] = 10 },
  }, s)
  near(s["任务"], 5 + 10 * 0.4, 0.01, "bigram score")
end

-- 空窗口
do
  local s = {}
  score_candidates(cands{"任务"}, {}, {}, s)
  eq(s["任务"], nil, "empty window => no scores")
end

-- 空候选
do
  local s = {}
  score_candidates({}, {"接下来的"}, {}, s)
  check(next(s) == nil, "no candidates => no scores")
end

io.write("  passed\n")

----------------------------------------------------------------------
-- 5. 表格复用
----------------------------------------------------------------------

io.write("=== scores reuse ===\n")

local s = { ["旧数据"] = 999 }
score_candidates(cands{"任务"}, {"接下来的"}, { ["接下来的"] = { ["任务"] = 3 } }, s)
eq(s["旧数据"], nil, "old keys cleared")
eq(s["任务"], 3.0, "new score set; table reused")

-- 再次复用
score_candidates(cands{"工作"}, {"接下来的"}, { ["接下来的"] = { ["工作"] = 5 } }, s)
eq(s["任务"], nil, "prev scores cleared on reuse")
eq(s["工作"], 5.0, "new score after reuse")

io.write("  passed\n")

----------------------------------------------------------------------
-- 6. 多 weight 累积
----------------------------------------------------------------------

io.write("=== multi-weight accumulation ===\n")

local s = {}
score_candidates(cands{"任务"}, {"接下来的"}, {
  ["接下来的"] = { ["任务"] = 3 },  -- weight 1.0 => 3
  ["来的"]     = { ["任务"] = 4 },  -- weight 0.5 => 2
  ["的"]       = { ["任务"] = 8 },  -- weight 0.25 => 2
}, s)
near(s["任务"], 7.0, 0.01, "3 + 2 + 2 = 7")

io.write("  passed\n")

----------------------------------------------------------------------
-- Results
----------------------------------------------------------------------

io.write("\n" .. string.rep("=", 40) .. "\n")
io.write("RESULTS: " .. total .. " tests, " .. passed .. " passed, " .. failed .. " failed\n")
io.write(string.rep("=", 40) .. "\n")

if failed > 0 then os.exit(1) end
