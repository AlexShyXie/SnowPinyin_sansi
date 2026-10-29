-- 自动造词：把「一次输入内多次选字后上屏」记成自造词
-- 覆盖两条路径（关闭 librime 用户词典后它们都失效了，这里用冰雪自有库补回来）：
--   1. 拆字造词：4/5 码时选中只覆盖前一段的单字候选，残余编码成为新段
--      （table_like.lua:51-71，6 码被刻意限制所以拆不了）
--   2. 缓冲造词：Ctrl+j 开缓冲后逐字打码，popping 只 confirm 不 commit
--      （popping.lua:147-156），最后一次 commit 带上全部已确认段
-- 顶功逐字上屏每次只 commit 一段，天然不触发（符合预期）。
--
-- 写入冰雪自有用户词典（与 Ctrl+' 造词完全同款：code \t word → c=epoch*20+index），
-- 由 snow.fix 置顶呈现；不碰 librime 用户词典，因此不引入任何自动调频。
-- 造出来的就是一条普通自造词，Ctrl+; / Ctrl+p / Ctrl+u / Ctrl+i / Ctrl+\ 全都适用。
--
-- 挂接：engine/filters/+: - lua_filter@*snow.auto_phrase（追加到末尾，不扰动既有下标）

local snow = require "snow.snow"

local filter = {}

---@class AutoPhraseEnv: Env
---@field user_dict LevelDb|nil
---@field user_dict_name string
---@field enable boolean
---@field probe boolean
---@field min_code_length integer
---@field max_code_length integer
---@field max_phrase_length integer
---@field input string
---@field seen table<string, table<string, boolean>>
---@field trail table|nil
---@field confirmed table[]
---@field connection Connection

local function trace(env, format, ...)
  local message = "[auto_phrase] " .. string.format(format, ...)
  if env.probe then
    -- 探针期直接落盘，不受 snow.debug 开关限制
    log.error(message)
  else
    snow.errorf("%s", message)
  end
end

--- 是否纯汉字（借鉴万象 auto_phrase.lua:54）
local function is_chinese_only(text)
  if not text or text == "" then
    return false
  end
  if text:match("[%w%p]") then
    return false
  end
  for _, cp in utf8.codes(text) do
    if not ((cp >= 0x4E00 and cp <= 0x9FFF) or (cp >= 0x3400 and cp <= 0x4DBF) or (cp >= 0x20000 and cp <= 0x2EBEF)) then
      return false
    end
  end
  return true
end

--- 二字段编码 → 词库码
-- 二字词 = 声₁韵₁ 声₂韵₂ 调₂ 调₁（README:52），单字全码 = 声 + 韵 + 调
--   via + zia → vi zi a a = viziaa（缓冲造词，6 码）
--   hc  + jli → hc jl i   = hcjli （5 码拆字）
--   vi  + zi  → vizi             （4 码）
---@param codes string[]
---@return string|nil
local function normalize(codes)
  if #codes ~= 2 then
    return nil
  end
  local s1, s2 = codes[1], codes[2]
  local a, b = #s1, #s2
  if a < 2 or a > 3 or b < 2 or b > 3 then
    return nil
  end
  local code = s1:sub(1, 2) .. s2:sub(1, 2)
  if b == 3 then
    code = code .. s2:sub(3, 3) -- 调₂
    if a == 3 then
      code = code .. s1:sub(3, 3) -- 调₁
    end
  end
  return code
end

--- 写入自有用户词典，返回占用的位置
---@return boolean, integer|nil
local function save(env, code, word)
  if not env.user_dict then
    return false, nil
  end
  local used = {}
  local da = env.user_dict:query(code .. snow.separator)
  for k, v in da:iter() do
    local existing = k:match("\t(.+)$")
    -- 已经记过这个词就别再写：无论是固顶、造词还是被 Ctrl+\ 隐藏过，都尊重现状
    if existing == word then
      da = nil
      collectgarbage()
      return false, nil
    end
    local value = snow.parse(v)
    if value then
      local _, index = snow.decode(value)
      if index and index > 0 then
        used[index] = true
      end
    end
  end
  da = nil
  collectgarbage()
  local index = 1
  while used[index] do
    index = index + 1
  end
  if index > snow.MAX_INDEX then
    return false, nil
  end
  env.user_dict:update(snow.key(code, word), snow.format(snow.encode(snow.epoch(), index)))
  return true, index
end

--- 从 composition 收集各段（编码, 选中文本）
---@return table[]|nil, integer
local function collect_segments(ctx, env, input)
  local segmentation = ctx.composition:toSegmentation()
  if not segmentation then
    return nil, 0
  end
  local segments = segmentation:get_segments()
  local count = segments and #segments or 0
  if count < 2 then
    return nil, count
  end
  local items = {}
  for i = 1, count do
    local segment = segments[i]
    local candidate = segment:get_selected_candidate()
    if not candidate then
      if i == count then
        break -- 最后一段还没选，允许跳过
      end
      return nil, count
    end
    local code = input:sub(segment.start + 1, segment._end)
    if code == "" then
      return nil, count
    end
    items[#items + 1] = { code = code, text = candidate.text }
  end
  if #items < 2 then
    return nil, count
  end
  return items, count
end

--- 兜底：用「输入被顶功改写」时累积下来的段
-- buffered 下 popping 会 pop/push input，segmentation 可能被重置，commit 时未必还能取到多段
---@return table[]|nil
local function collect_confirmed(env)
  local items = {}
  for _, item in ipairs(env.confirmed or {}) do
    items[#items + 1] = { code = item.code, text = item.text }
  end
  local trail = env.trail
  if trail and trail.code and trail.code ~= "" and trail.text and trail.text ~= "" then
    items[#items + 1] = { code = trail.code, text = trail.text }
  end
  if #items < 2 then
    return nil
  end
  return items
end

---@param env AutoPhraseEnv
---@param items table[]
---@param text string
---@return boolean
local function try_save(env, items, text)
  local count = #items
  local length = utf8.len(text)
  if not length or length ~= count then
    return false
  end
  if count < 2 or count > env.max_phrase_length then
    return false
  end
  if not is_chinese_only(text) then
    return false
  end
  -- 每段必须是单字，否则无法按三拼规则重排成词库码
  local joined = ""
  local codes = {}
  for _, item in ipairs(items) do
    if utf8.len(item.text) ~= 1 then
      return false
    end
    joined = joined .. item.text
    codes[#codes + 1] = item.code
  end
  if joined ~= text then
    return false
  end
  local code = normalize(codes)
  if not code then
    return false
  end
  if #code < env.min_code_length or #code > env.max_code_length then
    return false
  end
  -- 词库里已经有这个词（本次候选里出现过）就不需要造
  local seen = env.seen and env.seen[code]
  if seen and seen[text] then
    return false
  end
  local saved, index = save(env, code, text)
  if saved then
    trace(env, "造词：%s → %s（第 %d 位）", code, text, index)
  end
  return saved
end

---@param env AutoPhraseEnv
function filter.init(env)
  local config = env.engine.schema.config
  env.enable = config:get_bool("auto_phrase/enable") ~= false
  env.probe = config:get_bool("auto_phrase/probe") == true
  env.min_code_length = config:get_int("auto_phrase/min_code_length") or 4
  env.max_code_length = config:get_int("auto_phrase/max_code_length") or 6
  env.max_phrase_length = config:get_int("auto_phrase/max_phrase_length") or 2
  env.input = ""
  env.seen = {}
  env.confirmed = {}
  env.trail = nil
  if config:get_bool("translator/enable_schema_user_dict") then
    env.user_dict_name = env.engine.schema.schema_id
    env.user_dict = snow.get_db(env.user_dict_name)
  end
  if not env.enable or not env.user_dict then
    return
  end
  env.connection = env.engine.context.commit_notifier:connect(function(ctx)
    -- 造词只是锦上添花，任何异常都不能影响正常上屏
    local ok, err = pcall(filter.commit_handler, ctx, env)
    if not ok then
      trace(env, "commit_handler 出错：%s", tostring(err))
    end
  end)
end

---@param segment Segment
function filter.tags_match(segment, env)
  return segment:has_tag("abc")
end

---@param translation Translation
---@param env AutoPhraseEnv
function filter.func(translation, env)
  local context = env.engine.context
  local input = context.input or ""
  -- 输入不再以旧输入为前缀，说明前一段被顶功消费掉了，记进已确认列表
  if env.trail and env.trail.input ~= "" and input:sub(1, #env.trail.input) ~= env.trail.input then
    if env.trail.code and env.trail.code ~= "" and env.trail.text and env.trail.text ~= "" then
      env.confirmed[#env.confirmed + 1] = { code = env.trail.code, text = env.trail.text }
    end
    env.trail = nil
  end
  if input == "" then
    env.confirmed = {}
    env.trail = nil
  end
  env.input = input
  local code = snow.current(context)
  local seen = nil
  local first = nil
  if code and code ~= "" then
    seen = {}
  end
  for candidate in translation:iter() do
    if seen and candidate.type ~= "fixed" then
      seen[candidate.text] = true
      if not first then
        first = candidate.text
      end
    end
    yield(candidate)
  end
  if seen then
    env.seen[code] = seen
    env.trail = { input = input, code = code, text = first }
  end
end

---@param ctx Context
---@param env AutoPhraseEnv
function filter.commit_handler(ctx, env)
  local input = env.input or ""
  local text = ctx:get_commit_text() or ""
  local items = nil
  local count = 0
  local source = "none"
  if not ctx:get_option("add") then
    items, count = collect_segments(ctx, env, input)
    if items then
      source = "segments"
    else
      items = collect_confirmed(env)
      if items then
        source = "confirmed"
      end
    end
  end
  local saved = false
  if items then
    saved = try_save(env, items, text)
  end
  if env.probe then
    local parts = {}
    for index, item in ipairs(items or {}) do
      parts[index] = string.format("%s=%s", item.code, item.text)
    end
    trace(env, "commit input=%q text=%q segments=%d source=%s saved=%s items=[%s]",
      input, text, count, source, tostring(saved), table.concat(parts, " "))
  end
  env.input = ""
  env.seen = {}
  env.confirmed = {}
  env.trail = nil
end

---@param env AutoPhraseEnv
function filter.fini(env)
  if env.connection then
    env.connection:disconnect()
    env.connection = nil
  end
  if env.user_dict then
    env.user_dict = nil
    snow.release_db(env.user_dict_name)
  end
  env.seen = nil
  env.confirmed = nil
  env.trail = nil
end

return filter
