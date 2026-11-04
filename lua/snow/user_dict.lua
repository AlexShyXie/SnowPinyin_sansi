-- 用户词典处理器
-- 本处理器可帮助用户便捷地更改方案码用户词典
-- 在编写过程中主要参考了露台和魔然的相关实现

local snow = require "snow.snow"

local processor = {}

---@class UserDictEnv: Env
---@field dict table<string, string[]>
---@field user_dict LevelDb|nil
---@field user_dict_name string
---@field add_word string
---@field add_input string
---@field add_index integer
---@field connection Connection
---@field unhandled_connection Connection
---@field property_connection Connection
---@field fix_key KeyEvent
---@field add_key KeyEvent
---@field up_key KeyEvent
---@field down_key KeyEvent
---@field reset_key KeyEvent
---@field pin_key KeyEvent|nil
---@field alt_reset_key KeyEvent|nil
---@field move_unfixed boolean

---@param env UserDictEnv
function processor.init(env)
  local config = env.engine.schema.config
  env.dict = snow.read_dictionary(snow.get_dictionary_path(env))
  if config:get_bool("translator/enable_schema_user_dict") then
    -- 记下方案名，fini 时 engine.schema 已是新方案，见 snow.get_db 的注释
    env.user_dict_name = env.engine.schema.schema_id
    env.user_dict = snow.get_db(env.user_dict_name)
  end
  env.add_word = ""
  env.add_input = ""
  env.add_index = 0
  -- 加词状态机：adding 总开关；add_phase = code（正在输编码）/ word（正在收上屏文字）
  -- 小鹤音形全码顶字上屏，词码打完编码就没了，所以比冰雪多出「先按加词键再输编码」的入口
  env.adding = false
  env.add_phase = "code"
  env.max_code_length = config:get_int("speller/max_code_length") or 4
  env.add_done = false
  env.fix_key = KeyEvent("Control+semicolon")
  env.add_key = KeyEvent("Control+apostrophe")
  env.up_key = KeyEvent("Control+bracketleft")
  env.down_key = KeyEvent("Control+bracketright")
  env.reset_key = KeyEvent("Control+backslash")
  -- 置顶键、第二个重置键默认不启用：本模块三拼四拼共用，新键位只在需要的方案里配
  env.pin_key = nil
  env.alt_reset_key = nil
  env.move_unfixed = config:get_bool("translator/move_unfixed") == true
  for _, field in ipairs({ "fix_key", "add_key", "up_key", "down_key", "reset_key", "pin_key", "alt_reset_key" }) do
    local repr = config:get_string("translator/" .. field)
    if repr then
      ---@diagnostic disable-next-line: no-unknown
      env[field] = KeyEvent(repr)
    end
  end
  env.connection = env.engine.context.commit_notifier:connect(function(ctx)
    if env.adding and env.add_phase == "word" then
      local text = ctx:get_commit_text()
      if text and text ~= "" then
        env.add_word = env.add_word .. text
        ctx:set_property("add_word", env.add_word)
        snow.errorf("正在添加新词：%s", env.add_word)
      end
    end
  end)
  -- 直接上屏不经过 commit_notifier；按实际发出的文字和顺序收集，略码的统计合并量不适用于加词
  env.property_connection = env.engine.context.property_update_notifier:connect(function(ctx, name)
    if name == "direct_commit_text" and env.adding and env.add_phase == "word" then
      env.add_word = env.add_word .. ctx:get_property(name)
      ctx:set_property("add_word", env.add_word)
    end
  end)
  -- 西文模式下的字母、无编码时的数字等按键不经 Rime 上屏，而是放行给应用自己插入，
  -- commit_notifier 收不到；engine 对所有放行的按键都会触发 unhandled_key_notifier，在这里补记
  env.unhandled_connection = env.engine.context.unhandled_key_notifier:connect(function(_, key_event)
    if not (env.adding and env.add_phase == "word") then
      return
    end
    if key_event:release() or key_event:ctrl() or key_event:alt() or key_event:super() then
      return
    end
    local keycode = key_event.keycode
    if keycode >= 0x20 and keycode < 0x7f then
      env.add_word = env.add_word .. string.char(keycode)
    elseif keycode == snow.kEscape then
      -- 西文模式下 Escape 被 ascii_composer 直接放行，到不了 func，只能在这里取消
      processor.cancel_add(env)
      return
    elseif keycode == snow.kBackSpace then
      -- 应用删掉了一个字符，这里也删掉最后一个字符
      local offset = utf8.offset(env.add_word, -1)
      if offset then
        env.add_word = env.add_word:sub(1, offset - 1)
      end
    else
      return
    end
    snow.errorf("正在添加新词：%s", env.add_word)
    env.engine.context:set_property("add_word", env.add_word)
  end)
end

---@param env UserDictEnv
function processor.cancel_add(env)
  env.add_input = ""
  env.add_word = ""
  env.adding = false
  env.add_done = false
  env.add_phase = "code"
  snow.errorf("取消添加新词")
  local ctx = env.engine.context
  ctx:clear()
  ctx:set_property("add_stage", "")
  ctx:set_option("add_code", false) -- 在收词阶段取消时先弹「收词完成」
  ctx:set_option("add", false)      -- 气泡：结束
end

---@param candidate Candidate
function processor.is_fixed(candidate)
  local comment = candidate.comment
  if comment:match(snow.fixed_symbol) or comment:match(snow.fixed_notfound_symbol) then
    return true
  end
  return false
end

---@param input string
---@param index integer
---@param new_index integer
---@param env UserDictEnv
function processor.check_move(input, index, new_index, env)
  local segment = env.engine.context.composition:toSegmentation():back()
  if not segment then
    return
  end
  local candidate = segment:get_candidate_at(index - 1)
  -- 目标位可能压根没有候选
  if not candidate then
    return
  end
  if processor.is_fixed(candidate) then
    local epoch = snow.epoch()
    local word = candidate.text
    local key = snow.key(input, word)
    local value = snow.format(snow.encode(epoch, new_index))
    env.user_dict:update(key, value)
    snow.errorf("时间戳 %d：「%s」在 %s 候选 %d → %d", epoch, word, input, index, new_index)
  end
end

---@param context Context
---@param index integer
function processor.refresh_recover(context, index)
  context:refresh_non_confirmed_composition()
  local segment = context.composition:toSegmentation():back()
  segment.selected_index = index - 1
end

---@param env UserDictEnv
function processor.get_first_available_index(env)
  local segment = env.engine.context.composition:toSegmentation():back()
  if not segment then
    return nil
  end
  for index = 1, snow.MAX_INDEX do
    local candidate = segment:get_candidate_at(index - 1)
    if not candidate then
      return index
    end
    if not processor.is_fixed(candidate) then
      return index
    end
  end
  return nil
end

---userdb + fixed.txt 里找最小空位
--（「先输编码」流程的存词阶段没有候选菜单可用，get_first_available_index 依赖 segment）
---@param env UserDictEnv
---@param input string
---@return integer|nil
function processor.next_free_index(env, input)
  local used = {}
  local fixed = env.dict[input] or {}
  for i = 1, #fixed do
    used[i] = true
  end
  local da = env.user_dict:query(input .. snow.separator)
  for k, v in da:iter() do
    local value = snow.parse(v)
    if value then
      local _, index = snow.decode(value)
      if index and index > 0 then
        used[index] = true
      end
    end
  end
  ---@diagnostic disable-next-line: cast-local-type
  da = nil
  collectgarbage()
  for i = 1, snow.MAX_INDEX do
    if not used[i] then
      return i
    end
  end
  return nil
end

---取消固定的记录值：固顶表里已有的词写 0（保留占位），自造词写 DISABLE_INDEX（隐藏）
---@param env UserDictEnv
---@param input string
---@param word string
---@return string
function processor.unfix_value(env, input, word)
  local found = false
  local entries = env.dict[input] or {}
  for _, entry in ipairs(entries) do
    if entry == word then
      found = true
      break
    end
  end
  return snow.format(snow.encode(snow.epoch(), found and 0 or snow.DISABLE_INDEX))
end

---把 word 写到 input 的第 index 位。该位若已被别的词占着，先把占用者挪到最小空位，
---否则 fix 按 index 填表时两条记录会互相覆盖，占着首位的词凭空消失
---@param env UserDictEnv
---@param input string
---@param index integer
---@param word string
---@param epoch integer
function processor.occupy(env, input, index, word, epoch)
  ---@type table<integer, string>
  local holders = {}
  local da = env.user_dict:query(input .. snow.separator)
  for k, v in da:iter() do
    local existing = k:match("\t(.+)$")
    local value = snow.parse(v)
    if existing and value then
      local _, existing_index = snow.decode(value)
      if existing ~= word and existing_index and existing_index > 0 then
        holders[existing_index] = existing
      end
    end
  end
  ---@diagnostic disable-next-line: cast-local-type
  da = nil
  collectgarbage()
  local holder = holders[index]
  if holder then
    local slot = nil
    for i = 1, snow.MAX_INDEX do
      if i ~= index and not holders[i] then
        slot = i
        break
      end
    end
    -- 18 位排满时无空位可挪，只能隐藏占用者
    local new_index = slot or snow.DISABLE_INDEX
    env.user_dict:update(snow.key(input, holder), snow.format(snow.encode(epoch, new_index)))
    snow.errorf("时间戳 %d：「%s」在 %s 候选 %d → %s", epoch, holder, input, index, slot and tostring(slot) or "隐藏")
  end
  env.user_dict:update(snow.key(input, word), snow.format(snow.encode(epoch, index)))
end

---重置该编码：所有记录置为 DISABLE_INDEX（不删记录，方便再固定回来）
---@param env UserDictEnv
---@param input string
---@param epoch integer
function processor.reset(env, input, epoch)
  local da = env.user_dict:query(input .. snow.separator)
  for k, v in da:iter() do
    local _, existing_index = snow.decode(snow.parse(v) or 0)
    if existing_index ~= snow.DISABLE_INDEX then
      env.user_dict:update(k, snow.format(snow.encode(epoch, snow.DISABLE_INDEX)))
    end
  end
  ---@diagnostic disable-next-line: cast-local-type
  da = nil
  collectgarbage()
  snow.errorf("时间戳 %d：重置在 %s 的候选", epoch, input)
end

---@param key_event KeyEvent
---@param env UserDictEnv
function processor.func(key_event, env)
  local context = env.engine.context
  local config = env.engine.schema.config
  if not config:get_bool("translator/enable_schema_user_dict") then
    return snow.kNoop
  end
  -- 用户词典没能打开，所有读写都无从进行
  if not env.user_dict then
    return snow.kNoop
  end

  -- 存词完成展示态：候选窗显示该编码的候选（含新词）与提示，任意键清屏继续
  if env.add_done then
    if key_event:release() then
      return snow.kAccepted
    end
    env.add_done = false
    context:set_property("add_stage", "")
    context:clear()
    if key_event:eq(env.add_key) then
      env.adding = true
      env.add_phase = "code"
      env.add_word = ""
      env.add_input = ""
      env.add_index = 0
      context:set_option("add", true)
      context:set_property("add_stage", "1")
      snow.errorf("加词：请输入新词编码")
      return snow.kAccepted
    end
    return snow.kNoop -- 清屏后放行，本键按无输入状态正常处理
  end

  if env.adding then
    -- 过滤 keyup：否则编码阶段每个字母会被收两次（如 k → kk）
    if key_event:release() then
      return snow.kAccepted
    end
    if key_event:eq(env.add_key) then
      if env.add_phase == "code" then
        -- 编码输入阶段：确认编码，进入收词阶段
        local input = context.input or ""
        if input:len() == 0 then
          processor.cancel_add(env)
          return snow.kAccepted
        end
        env.add_input = input
        env.add_phase = "word"
        env.add_word = ""
        context:clear()
        context:set_property("add_stage", "2")
        context:set_option("add_code", true) -- 气泡：开始收词
        snow.errorf("编码 %s 已确认，请输入新词内容", input)
        return snow.kAccepted
      end
      -- 收词阶段：存词（冰雪原逻辑）
      -- 去掉首尾空白：上屏后多按的空格会被应用插入，也就被一并记了下来
      local word = env.add_word:match("^%s*(.-)%s*$")
      if word == "" then
        processor.cancel_add(env)
        return snow.kAccepted
      end
      local index = env.add_index
      if not index or index <= 0 then
        index = processor.next_free_index(env, env.add_input)
        if not index then
          snow.errorf("无法添加新词：%s 候选已满", env.add_input)
          processor.cancel_add(env)
          return snow.kAccepted
        end
        env.add_index = index
      end
      local key = snow.key(env.add_input, word)
      local epoch = snow.epoch()
      local value = snow.format(snow.encode(epoch, index))
      env.user_dict:update(key, value)
      snow.errorf("时间戳 %d：添加新词「%s」到 %s 候选 %d", epoch, word, env.add_input, index)
      -- 存词完成：候选窗展示该编码的候选（含新词）与阶段提示，任意键清屏继续
      local code = env.add_input
      env.add_input = ""
      env.add_word = ""
      env.adding = false
      env.add_done = true
      context:set_option("add_code", false) -- 气泡：收词完成
      context:set_option("add", false)      -- 气泡：结束
      context:set_property("add_stage", "3")
      context:set_property("add_word", word)
      context.input = code
      return snow.kAccepted
    elseif key_event.keycode == snow.kEscape then
      processor.cancel_add(env)
      return snow.kAccepted
    elseif env.add_phase == "code" then
      -- 编码输入阶段：字母 / ; / ' 镜像进组合（预编辑与候选可见），
      -- 按键在此被消费、不进 speller，所以全码也不会触发顶字上屏
      if key_event:ctrl() or key_event:alt() or key_event:super() then
        return snow.kNoop
      end
      local keycode = key_event.keycode
      local input = context.input or ""
      if (keycode >= 0x61 and keycode <= 0x7a) or keycode == 0x3b or keycode == 0x27 then
        if input:len() < env.max_code_length then
          context.input = input .. string.char(keycode)
          snow.errorf("正在输入新词编码：%s", context.input)
        end
        return snow.kAccepted
      elseif keycode == snow.kBackSpace then
        if input:len() > 0 then
          context.input = input:sub(1, -2)
          snow.errorf("正在输入新词编码：%s", context.input)
        end
        return snow.kAccepted
      end
      -- 空格/回车/数字/标点：编码阶段一律吞掉，防止意外选中或上屏
      return snow.kAccepted
    end
    return snow.kNoop -- 正在添加新词，忽略其他按键
  end
  -- 前摇过长
  local segment = context.composition:toSegmentation():back()
  local input = snow.current(context)
  if not segment or not input then
    return snow.kNoop
  end
  local shape_input = context:get_property("shape_input")
  if shape_input then
    input = input .. shape_input
  end
  -- 加词入口放在候选检查之前：像 kfc 这种没有任何候选的编码也要能加词
  if key_event:eq(env.add_key) then
    env.adding = true
    env.add_phase = "code" -- 保留当前组合作为编码，可继续补足/修改后再确认
    env.add_word = ""
    env.add_input = ""
    env.add_index = 0
    context:set_option("add", true)
    context:set_property("add_stage", "1")
    -- 强制重建未确认组合的译文：否则 add_hint 过滤器要等下一次输入才会挂上提示
    context:refresh_non_confirmed_composition()
    snow.errorf("加词：编码 %s，可补足后确认", input)
    return snow.kAccepted
  end
  local candidate = context:get_selected_candidate()
  local index = segment.selected_index + 1
  if not candidate then
    return snow.kNoop
  end
  local word = candidate.text
  local key = snow.key(input, word)
  local epoch = snow.epoch()

  if key_event:eq(env.fix_key) then -- 固定/取消固定
    if index > snow.MAX_INDEX then
      snow.errorf("无法固定：%s 候选 %d 超过上限 %d", input, index, snow.MAX_INDEX)
      return snow.kAccepted
    end
    local value = snow.format(snow.encode(epoch, index))
    if processor.is_fixed(candidate) then
      value = processor.unfix_value(env, input, word)
      snow.errorf("时间戳 %d：「%s」取消 %s 候选 %d", epoch, word, input, index)
    else
      snow.errorf("时间戳 %d：「%s」固定 %s 候选 %d", epoch, word, input, index)
    end
    env.user_dict:update(key, value)
    processor.refresh_recover(context, index)
    return snow.kAccepted
  elseif env.pin_key and key_event:eq(env.pin_key) then -- 置顶/取消置顶
    if processor.is_fixed(candidate) and index == 1 then
      env.user_dict:update(key, processor.unfix_value(env, input, word))
      snow.errorf("时间戳 %d：「%s」取消 %s 候选 1", epoch, word, input)
    else
      processor.occupy(env, input, 1, word, epoch)
      snow.errorf("时间戳 %d：「%s」置顶 %s 候选 1", epoch, word, input)
    end
    processor.refresh_recover(context, 1)
    return snow.kAccepted
  elseif key_event:eq(env.up_key) then
    if index <= 1 then
      return snow.kAccepted
    end
    if processor.is_fixed(candidate) then
      local value = snow.format(snow.encode(epoch, index - 1))
      processor.check_move(input, index - 1, index, env)
      env.user_dict:update(key, value)
    elseif env.move_unfixed then
      -- 没固定的候选也直接移：插到目标位，占着那位的固定项顺延到空位
      processor.occupy(env, input, index - 1, word, epoch)
    else
      return snow.kAccepted
    end
    snow.errorf("时间戳 %d：「%s」在 %s 候选 %d → %d", epoch, word, input, index, index - 1)
    processor.refresh_recover(context, index - 1)
    return snow.kAccepted
  elseif key_event:eq(env.down_key) then
    if index >= snow.MAX_INDEX then
      return snow.kAccepted
    end
    if processor.is_fixed(candidate) then
      local value = snow.format(snow.encode(epoch, index + 1))
      processor.check_move(input, index + 1, index, env)
      env.user_dict:update(key, value)
    elseif env.move_unfixed then
      processor.occupy(env, input, index + 1, word, epoch)
    else
      return snow.kAccepted
    end
    snow.errorf("时间戳 %d：「%s」在 %s 候选 %d → %d", epoch, word, input, index, index + 1)
    processor.refresh_recover(context, index + 1)
    return snow.kAccepted
  elseif key_event:eq(env.reset_key) or (env.alt_reset_key and key_event:eq(env.alt_reset_key)) then
    processor.reset(env, input, epoch)
    processor.refresh_recover(context, index)
    return snow.kAccepted
  end
  return snow.kNoop
end

---@param env UserDictEnv
function processor.fini(env)
  env.dict = nil
  if env.user_dict then
    env.user_dict = nil
    snow.release_db(env.user_dict_name)
  end
  if env.connection then
    env.connection:disconnect()
  end
  if env.unhandled_connection then
    env.unhandled_connection:disconnect()
  end
  if env.property_connection then
    env.property_connection:disconnect()
  end
end

return processor
