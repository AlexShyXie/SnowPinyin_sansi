-- 模拟码表翻译器
-- 适用于：冰雪三拼、冰雪键道

local snow = require "snow.snow"

---@class TableLikeEnv: Env
---@field translator Translator
---@field pattern string
---@field pattern2 string
---@field tone_keys string
---@field initial_keys string

local t12 = {}

---@param env TableLikeEnv
function t12.init(env)
  -- 翻译器持有 engine，不能跨会话共享，否则原会话销毁后会访问失效的引擎
  env.translator = Component.Translator(env.engine, "translator", "script_translator")
  env.pattern = env.engine.schema.config:get_string("translator/t1_pattern") or "^.+$"
  env.pattern2 = env.engine.schema.config:get_string("translator/t2_pattern") or "^.+$"
end

---@param input string
---@param segment Segment
---@param env TableLikeEnv
function t12.func(input, segment, env)
  -- 一字词
  if rime_api.regex_match(input, env.pattern) or env.engine.context:get_option("fluid") == true then
    -- 代理码不是合法拼写时 query 返回 nil，这一路当作没有候选
    local translation = env.translator:query(input, segment)
    if translation then
      for candidate in translation:iter() do
        yield(snow.prepare(candidate, input, true))
      end
    end
    if input:len() == 2 then
      local proxy = ("%s %s"):format(input:sub(1, 1), input:sub(2))
      local translation2 = env.translator:query(proxy, segment)
      if translation2 then
        for candidate in translation2:iter() do
          yield(snow.prepare(candidate, proxy, true))
        end
      end
    end
  end
  -- 二字词
  if rime_api.regex_match(input, env.pattern2) then
    local proxy = ("%s %s"):format(input:sub(1, 2), input:sub(3))
    if input:len() == 6 then
      proxy = ("%s%s %s"):format(input:sub(1, 2), input:sub(-1, -1), input:sub(3, -2))
    end
    local translation = env.translator:query(proxy, segment)
    if translation then
      for candidate in translation:iter() do
        if utf8.len(candidate.text) <= 2 then
          -- 全码（6 码）的代理码把调码重排成了「调₂调₁」，不再与输入左对齐，
          -- 只覆盖一部分的补全候选（如 bcgoui 里的「包」只吃前 3 码）选中后
          -- 会留下重排过的残余编码（oui），被 `^o.*$` 的表达式段接走。
          -- 所以全码只放行吃满整条代理码的候选。
          if input:len() ~= 6 or candidate._end - candidate._start == proxy:len() then
            yield(snow.prepare(candidate, proxy, true))
          end
        end
      end
    end
  end
end

---@param env TableLikeEnv
function t12.fini(env)
  env.translator = nil
  collectgarbage()
end

local jianpin = {}

---@param env TableLikeEnv
function jianpin.init(env)
  local config = env.engine.schema.config
  env.translator = Component.Translator(env.engine, "jianpin", "script_translator")
  env.pattern = config:get_string("translator/jianpin_pattern") or "^.+$"
  -- 字母类可由方案覆盖，缺省回落到冰雪三拼/四拼的键道字母类
  env.tone_keys = config:get_string("translator/tone_keys") or "[viuoa]"
  env.initial_keys = config:get_string("translator/initial_keys") or "[bpmfdtnlgkhjqxzcsrywe]"
end

---@param input string
---@param segment Segment
---@param env TableLikeEnv
function jianpin.func(input, segment, env)
  -- 多字词
  if rime_api.regex_match(input, env.pattern) then
    -- 多字词只能拿声码串去查：声码本身就是 algebra 的简拼拼写（abbrev），
    -- 是合法的查询串。此前用 `?` 顶替韵码拼出 hdl?e / h?ed?ol?e 之类，
    -- 但 librime 的音节化（algo/syllabifier.cc）只做精确前缀匹配，
    -- 不支持通配符，这些代理码一律解析失败，三字词全码与 4/5 码简码全查不到。
    local proxy = input:gsub(env.tone_keys, "")
    local translation = env.translator:query(proxy, segment)
    if translation then
      for candidate in translation:iter() do
        if utf8.len(candidate.text) >= proxy:len() and candidate.type ~= "sentence" then
          candidate = snow.prepare(candidate, proxy, true)
          -- 调码被丢掉后代理码比输入短，候选只会覆盖前几个码，选中后会留下
          -- 孤立编码（如 hdlee 选中后剩 ee）。补齐到整段，保证上屏即清空。
          candidate._end = segment._end
          yield(candidate)
        end
      end
    end
  end
end

---@param env TableLikeEnv
function jianpin.fini(env)
  env.translator = nil
  collectgarbage()
end

return {
  t12 = t12,
  jianpin = jianpin,
}
