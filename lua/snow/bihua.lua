-- 笔画过滤器
-- 共用带来源标签的笔画反查库，按配置筛选笔画反查和辅助码所用的字形。

---@class BihuaEnv: Env
---@field strokes ReverseLookup|nil
---@field shape_sources table<string, boolean>

---@class BihuaFilterEnv: BihuaEnv
---@field stroke_tag string
---@field stroke_mapping table<string, string>
---@field comment_format Projection

---@type table<string, boolean>
local default_shape_sources = { G = true }

local bihua = {}

---@param env BihuaEnv
function bihua.init(env)
  env.strokes = ReverseLookup("snow_bihua")
  env.shape_sources = default_shape_sources
  local sources = env.engine.schema.config:get_list("translator/shape_sources")
  if sources then
    env.shape_sources = {}
    for i = 0, sources.size - 1 do
      local value = sources:get_value_at(i)
      local source = value and value:get_string()
      if source then env.shape_sources[source] = true end
    end
  end
end

--- 返回允许使用的笔顺，以及这个字在库中是否有记录；未知字和来源被禁用的字必须区分。
---@param text string
---@param env BihuaEnv
---@return string[], boolean
function bihua.codes(text, env)
  local raw = env.strokes and env.strokes:lookup(text) or ""
  ---@type string[]
  local codes = {}
  for entry in raw:gmatch("%S+") do
    local code, sources = entry:match("^([1-5]+)([A-Z]*)$")
    if code and sources then
      ---@cast sources string
      local allowed = sources == ""
      for source in sources:gmatch(".") do
        allowed = allowed or env.shape_sources[source] == true
      end
      if allowed then table.insert(codes, code) end
    end
  end
  return codes, raw ~= ""
end

---@param env BihuaEnv
function bihua.fini(env)
  env.strokes = nil
  collectgarbage()
end

local filter = {}

---@param env BihuaFilterEnv
function filter.init(env)
  bihua.init(env)
  local config = env.engine.schema.config
  -- 反查使用 stroke 命名空间，独立笔画方案使用 translator 命名空间。
  local namespace = config:get_string("translator/dictionary") == "snow_bihua" and "translator" or "stroke"
  env.stroke_tag = config:get_string(namespace .. "/tag") or "abc"
  env.comment_format = Projection(config:get_list(namespace .. "/comment_format") or {})
  local prism = config:get_string(namespace .. "/prism") or "snow_bihua"
  env.stroke_mapping = { e = "1", i = "2", u = "3", o = "4", a = "5" }
  if prism == "snow_jiandao_bihua" then
    env.stroke_mapping = { v = "1", i = "2", u = "3", o = "4", a = "5" }
  end
end

---@param translation Translation
---@param env BihuaFilterEnv
function filter.func(translation, env)
  local input = env.engine.context.input
  for candidate in translation:iter() do
    local genuine = candidate:get_genuine()
    local phrase = genuine:to_phrase()
    -- 冰雪清韵的拼音、笔画共用段标签，按词典语言名识别，不能筛掉拼音候选。
    if not phrase or phrase.lang_name ~= "snow_bihua" then
      yield(candidate)
      goto continue
    end
    -- affix_segmentor 已经去掉前后缀；首笔丿也使用 u，不能再按前缀剥掉一次。
    local code = input:sub(genuine.start + 1, genuine._end):gsub("[ ']+$", ""):gsub(".", env.stroke_mapping)
    local codes = bihua.codes(candidate.text, env)
    for _, strokes in ipairs(codes) do
      if strokes:sub(1, #code) == code then
        -- 原生翻译器已按汉字去重，补全提示可能来自被禁用的另一条笔顺。
        local remaining = strokes:sub(#code + 1)
        candidate.comment = env.comment_format:apply(remaining ~= "" and "~" .. remaining or "", true)
        yield(candidate)
        break
      end
    end
    ::continue::
  end
end

---@param segment Segment
---@param env BihuaFilterEnv
function filter.tags_match(segment, env)
  return segment:has_tag(env.stroke_tag)
end

---@param env BihuaFilterEnv
function filter.fini(env)
  env.comment_format = nil
  bihua.fini(env)
end

bihua.filter = filter

return bihua
