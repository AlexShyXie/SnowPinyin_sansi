-- 加词状态提示过滤器
-- 与 lua/snow/user_dict.lua 配合，在候选窗里显示加词三个阶段的提示：
--   ① 输入编码（提示放第 1 位；编码阶段按键全被处理器消费，不会被顶屏）
--   ② 收词中（提示放第 2 位；第 1 位真实候选照常参与全码顶字上屏）
--   ③ 已存词（提示放第 1 位；处理器把组合设为该编码，真实候选含新词）
-- 阶段由 user_dict 写入 context 属性 add_stage，已收集文字写入 add_word。

local filter = {}

---@class AddHintEnv: Env
---@field add_key string

function filter.init(env)
  env.add_key = env.engine.schema.config:get_string("translator/add_key") or "Control+y"
end

---@param segment Segment
---@param env Env
function filter.tags_match(segment, env)
  -- 与 user_dict 的阶段属性联动，不依赖段落标签
  return (env.engine.context:get_property("add_stage") or "") ~= ""
end

---@param translation Translation
---@param env Env
function filter.func(translation, env)
  local context = env.engine.context
  local stage = context:get_property("add_stage")
  local seg = context.composition:toSegmentation():back()
  if not stage or stage == "" or not seg then
    for cand in translation:iter() do
      yield(cand)
    end
    return
  end
  local word = context:get_property("add_word") or ""
  local input = context.input or ""
  local hint = nil
  if stage == "1" then
    hint = Candidate("add_hint", seg.start, seg._end,
      "① 输入编码 " .. (input ~= "" and input or "…"),
      env.add_key .. " 确认（可补码） · Esc 取消")
  elseif stage == "2" then
    hint = Candidate("add_hint", seg.start, seg._end,
      "② 收词 " .. (word ~= "" and word or "…"),
      env.add_key .. " 存词 · Esc 取消")
  elseif stage == "3" then
    hint = Candidate("add_hint", seg.start, seg._end,
      "③ 已存词 " .. word, "按任意键继续")
  end
  if not hint then
    for cand in translation:iter() do
      yield(cand)
    end
    return
  end
  if stage == "2" then
    -- 收词阶段：第 1 位的真实候选要照常顶屏，提示插在第 2 位
    local first_done = false
    for cand in translation:iter() do
      yield(cand)
      if not first_done then
        yield(hint)
        first_done = true
      end
    end
  else
    yield(hint)
    for cand in translation:iter() do
      yield(cand)
    end
  end
end

return filter
