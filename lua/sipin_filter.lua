-- 四拼大写韵母筛选
-- 大写 A E I O U 记进独立属性，不进入编码，因此不触发顶功

local snow = require "snow.snow"

local yun = {
  a = "a", ai = "ai", ao = "au", an = "ao", ang = "ae",
  e = "e", ei = "ei", en = "eo", eng = "ee", er = "i",
  o = "o", ou = "ou", ong = "oe",
  u = "u", ua = "i", uai = "ii", uan = "io", uang = "ie",
  uo = "o", uei = "ui", uen = "uo", ueng = "ue",
  i = "i", ia = "u", iao = "uu", ian = "uo", iang = "ue",
  ie = "e", in = "io", ing = "ie", io = "o", iong = "oe", iou = "ou",
  ["ü"] = "a", ["üan"] = "oo", ["üe"] = "o", ["ün"] = "ao",
}

local ling = {
  a = "ra", ai = "rai", ao = "rau", an = "rao", ang = "rae",
  e = "re", ei = "rei", en = "reo", eng = "ree", er = "ri",
  o = "ro", ou = "rou", ong = "roe",
  wu = "su", wa = "si", wai = "sii", wan = "sio", wang = "sie",
  wo = "so", wei = "sui", wen = "suo", weng = "sue",
  yi = "fi", ya = "fu", yao = "fuu", yan = "fuo", yang = "fue",
  ye = "fe", yin = "fio", ying = "fie", yo = "fo", yong = "foe", you = "fou",
  yu = "ka", yuan = "koo", yue = "ko", yun = "kao",
}

---@param py string
---@return string
local function yunmu(py)
  local base = py:match("^([a-zü]+)%d?$") or py
  if ling[base] then
    return ling[base]
  end
  base = base:gsub("v", "ü")
  local ini = base:match("^(zh|ch|sh)") or base:sub(1, 1)
  local rest = base:sub(#ini + 1)
  if (ini == "j" or ini == "q" or ini == "x") and rest:sub(1, 1) == "u" then
    rest = "ü" .. rest:sub(2)
  end
  if rest == "iu" then
    rest = "iou"
  elseif rest == "ui" then
    rest = "uei"
  elseif rest == "un" then
    rest = "uen"
  end
  return yun[rest] or ""
end

local processor = {}

---@param key KeyEvent
---@param env Env
---@return integer
function processor.func(key, env)
  local ctx = env.engine.context
  if key:release() or key:ctrl() or key:alt() or key:caps() then
    return 2
  end
  if not ctx:is_composing() then
    return 2
  end
  local ch = utf8.char(key.keycode)
  if not ch:match("[AEIOU]") then
    return 2
  end
  local pos = select(2, ctx.input:gsub("[bpmfdtnlgkhjqxzcsrywv]", ""))
  if pos < 1 then
    return 2
  end
  local spec = ctx:get_property("yun_filter") or ""
  ctx:set_property("yun_filter", spec .. pos .. ch:lower() .. ";")
  return 1
end

local filter = {}

---@class YunFilterEnv: Env
---@field lookup ReverseLookup|nil
---@field conn Connection|nil

---@param env YunFilterEnv
function filter.init(env)
  env.lookup = ReverseLookup("snow_pinyin")
  env.conn = env.engine.context.commit_notifier:connect(function(ctx)
    ctx:set_property("yun_filter", "")
  end)
end

---@param env YunFilterEnv
function filter.fini(env)
  if env.conn then
    env.conn:disconnect()
    env.conn = nil
  end
  env.lookup = nil
end

---@param translation Translation
---@param env YunFilterEnv
function filter.func(translation, env)
  local ctx = env.engine.context
  local spec = ctx:get_property("yun_filter") or ""
  if spec == "" then
    for cand in translation:iter() do
      yield(cand)
    end
    return
  end
  local rules = {}
  for pos, code in spec:gmatch("(%d+)([aeiou]+);") do
    table.insert(rules, { pos = tonumber(pos), code = code })
  end
  for cand in translation:iter() do
    local ok = true
    for _, r in ipairs(rules) do
      local char = snow.sub(cand.text, r.pos, r.pos)
      local py = ""
      if char ~= "" and env.lookup then
        py = env.lookup:lookup(char) or ""
      end
      local code = yunmu(py)
      if code == "" or code:sub(1, #r.code) ~= r.code then
        ok = false
        break
      end
    end
    if ok then
      yield(cand)
    end
  end
end

---@param segment Segment
---@param env Env
---@return boolean
function filter.tags_match(segment, env)
  return segment:has_tag("abc")
end

return { processor = processor, filter = filter }