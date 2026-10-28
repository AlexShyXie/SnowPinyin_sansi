-- 模拟码表翻译器
-- 适用于：冰雪三拼、冰雪键道

local snow = require "snow.snow"

---@class TableLikeEnv: Env
---@field translator Translator
---@field pattern string
---@field pattern2 string
---@field pattern3 string
---@field tone_keys string
---@field initial_keys string

local t12 = {}

---@param env TableLikeEnv
function t12.init(env)
  -- 翻译器持有 engine，不能跨会话共享，否则原会话销毁后会访问失效的引擎
  env.translator = Component.Translator(env.engine, "translator", "script_translator")
  env.pattern = env.engine.schema.config:get_string("translator/t1_pattern") or "^.+$"
  env.pattern2 = env.engine.schema.config:get_string("translator/t2_pattern") or "^.+$"
  -- 多字词简拼也占用 6 码以上的编码（四字简拼可达 7 码），兜底不能去抢它的位置
  env.pattern3 = env.engine.schema.config:get_string("translator/jianpin_pattern")
end

---@param input string
---@param segment Segment
---@param env TableLikeEnv
function t12.func(input, segment, env)
  -- 一字词
  local matched1 = rime_api.regex_match(input, env.pattern) or env.engine.context:get_option("fluid") == true
  if matched1 then
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
  local matched2 = rime_api.regex_match(input, env.pattern2)
  if matched2 then
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
  -- 兜底：三拼的合法编码最长 6 码（二字词/三字词全码），再多打键时 t1、t2 失配，
  -- jianpin 往往也接不住（只有纯声码+少量调码的简拼才匹配），菜单就彻底变空；
  -- 而 popping 顶屏依赖 has_menu()，空菜单会让后续声码也顶不动，按键只能不断追加
  -- （如 hcjlia 后再打键变成 hcjliaol），Esc 或退格之前完全无法继续输入。
  -- 这里对这类失配长码直接用原始输入整句式查一次，保证始终有候选可顶、可上屏。
  -- 兜底条件与 `speller/popping` 的 `.{7,}` 兜底顶屏规则对齐：jianpin_pattern 只看
  -- 形状，但它实际查的是去掉调码后的纯声码串，像「二字词全码 + 辅码」（fglkeau）
  -- 这种 7 码恰好落在 `[声]{3,}[aeiou]{0,3}` 里，形状匹配却查不到任何多字候选，
  -- 兜底再被抑制菜单就彻底空了。所以 7 码以上一律兜底，简拼串无法音节化，
  -- 整句查询自然返回空，对正常简拼没有副作用。
  local overlong = rime_api.regex_match(input, ".{7,}")
  if not matched1 and not matched2 and
      (overlong or not (env.pattern3 and rime_api.regex_match(input, env.pattern3))) then
    local translation = env.translator:query(input, segment)
    if translation then
      for candidate in translation:iter() do
        -- 原始输入只能解析出前面的一段（hcjliaol 只认得 hc + jl），候选跨度也就
        -- 只覆盖这一段，不补齐的话选中后会留下 iaol 之类的孤立编码。补齐到整段，
        -- 上屏即清空。单字补全词对长码没有意义，一并滤掉以免噪音。
        if utf8.len(candidate.text) >= 2 then
          candidate = snow.prepare(candidate, input, true)
          candidate._end = segment._end
          yield(candidate)
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
