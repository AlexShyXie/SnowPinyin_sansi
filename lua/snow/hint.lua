-- 提示过滤器
-- 目前仅用于提示冰雪键道和冰雪四拼的 630 简词

local snow = require "snow.snow"

local filter = {}

---@class HintEnv: Env
---@field fixed table<string, string>
---@field reverse_630 table<string, string>
---@field initial_keys string
---@field tone_keys string
---@field affix string[]
---@field pattern_630 string
---@field pattern_char string
---@field pattern_phrase string

---@param env HintEnv
function filter.init(env)
  local id = env.engine.schema.schema_id
  env.fixed = snow.table_from_tsv(rime_api.get_user_data_dir() .. ("/%s.fixed.txt"):format(id))
  local config = env.engine.schema.config
  -- 字母类可由方案覆盖，缺省回落到冰雪三拼/四拼的键道字母类
  env.initial_keys = config:get_string("translator/initial_keys") or "[bpmfdtnlgkhjqxzcsrywe]"
  env.tone_keys = config:get_string("translator/tone_keys") or "[viuoa]"
  local affix_string = config:get_string("translator/hint_affix") or "viuoa"
  ---@type string[]
  env.affix = {}
  for letter in affix_string:gmatch(".") do
    table.insert(env.affix, letter)
  end
  env.pattern_630 = env.initial_keys .. env.tone_keys .. "{1,2}"
  env.pattern_char = env.initial_keys .. env.tone_keys .. "?"
  env.pattern_phrase = env.initial_keys .. "{3,}" .. env.tone_keys .. "*"
  ---@type table<string, string>
  env.reverse_630 = {}
  for key, value in pairs(env.fixed) do
    if rime_api.regex_match(key, env.pattern_630) then
      env.reverse_630[value] = key
    end
  end
end

---@param translation Translation
---@param env HintEnv
function filter.func(translation, env)
  local input = snow.current(env.engine.context) or ""
  local shape_input = env.engine.context:get_property("shape_input")
  local full_input = input
  if shape_input then
    full_input = full_input .. shape_input
  end
  local affix = env.affix
  local first = true
  if rime_api.regex_match(full_input, env.pattern_char) then
    -- 一码，提示 sb 简词
    for candidate in translation:iter() do
      if first then
        yield(candidate)
        for _, letter in ipairs(affix) do
          local code = full_input .. letter
          local word = env.fixed[code]
          if word then
            local hint_candidate = Candidate("hint", candidate.start, candidate._end, word, code)
            hint_candidate.preedit = full_input
            yield(hint_candidate)
          end
        end
      else
        yield(candidate)
      end
      first = false
    end
  elseif rime_api.regex_match(full_input, env.pattern_phrase) then
    -- 四码，提示所有简词
    for candidate in translation:iter() do
      if env.reverse_630[candidate.text] then
        local code = env.reverse_630[candidate.text]
        snow.comment(candidate, ("[630: %s]"):format(code))
      end
      yield(candidate)
    end
  else
    -- 其他情况，直接返回
    for candidate in translation:iter() do
      -- 造词过程中屏蔽二简词
      local segment = env.engine.context.composition:toSegmentation():back()
      if segment then
        local is_not_first_segment = segment.start ~= 0
        if is_not_first_segment and candidate:get_dynamic_type() == "Simple" then
          goto continue
        end
      end
      yield(candidate)
      ::continue::
    end
  end
end

---@param segment Segment
---@param env Env
function filter.tags_match(segment, env)
  return segment:has_tag("abc")
end

return filter
