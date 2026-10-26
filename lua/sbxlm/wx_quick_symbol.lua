-- 声笔小鹤 · 快符（万象拼音移植版）
-- 原作: amzxyz 万象拼音 super_processor.lua 中的 QuickSymbol 模块
-- 移植: 抽取按键拦截与映射执行逻辑，去除万象依赖，适配声笔顶功
--
-- 功能: 输入"字母+/"快速上屏预设符号/文本；映射值设为 "repeat" 可重复上一次上屏内容
-- 配置: 方案 custom.yaml 的 quick_symbol_text/ 节点（trigger + symkey），当前由 snow_xiaohe.custom.yaml 使用
-- 键位: 默认触发 ^([a-z])/$，即小写字母后按 /
--   注意: 声笔中单字母是声母简码态，此拦截优先于顶屏，直接上屏快符映射并清码

local M = {}

-- librime-lua 处理结果常量（与万象 wanxiang.lua 保持一致）
local kAccepted = 1
local kNoop = 2

-- 默认符号映射（与万象 schema 默认值一致；q 键默认为重复上屏）
local SYMBOL_DEFAULT = {
    q = "repeat", w = "？", e = "（", r = "）", t = "      ",
    y = "·", u = "『", i = "』", o = "〖", p = "〗",
    a = "！", s = "……", d = "、", f = "“", g = "”",
    h = "‘", j = "’", k = "【", l = "】",
    z = "。", x = "？", c = "！", v = "——",
    b = "%", n = "《", m = "》",
}

function M.init(env)
    local config = env.engine.schema.config
    local context = env.engine.context

    env.qs_trigger = "^([a-z])/$"
    env.qs_mapping = {}
    for k, v in pairs(SYMBOL_DEFAULT) do
        env.qs_mapping[k] = v
    end

    if config then
        local ok, s = pcall(function()
            return config:get_string("quick_symbol_text/trigger")
        end)
        if ok and type(s) == "string" and #s > 0 then
            env.qs_trigger = s
        end

        local ok_map, map = pcall(function()
            return config:get_map("quick_symbol_text/symkey")
        end)
        if ok_map and map then
            local ok_keys, keys = pcall(function() return map:keys() end)
            if ok_keys and keys then
                for _, key in ipairs(keys) do
                    local ok_v, v = pcall(function()
                        return config:get_string("quick_symbol_text/symkey/" .. key)
                    end)
                    if ok_v and v then
                        env.qs_mapping[tostring(key)] = v
                    end
                end
            end
        end
    end

    env.qs_last_commit = ""

    -- 记录上屏内容，供 "repeat" 使用
    env.qs_conn_commit = context.commit_notifier:connect(function(ctx)
        local t = ctx:get_commit_text()
        if t ~= "" then
            env.qs_last_commit = t
        end
    end)
end

function M.fini(env)
    if env.qs_conn_commit then
        env.qs_conn_commit:disconnect()
        env.qs_conn_commit = nil
    end
end

---执行快符：text 形如 "a/"，匹配 trigger 则上屏映射内容
---@param env table
---@param ctx Context
---@param text string
---@return boolean 是否已执行
local function execute_quick_symbol(env, ctx, text)
    local trigger = env.qs_trigger
    local mapping = env.qs_mapping
    if type(trigger) ~= "string" or type(mapping) ~= "table" then
        return false
    end
    local qkey = string.match(text, trigger)
    if qkey then
        local symbol = env.qs_mapping[qkey]
        if symbol and symbol ~= "" then
            if type(symbol) == "string" and symbol:lower() == "repeat" then
                if env.qs_last_commit ~= "" then
                    env.engine:commit_text(env.qs_last_commit)
                end
            else
                env.engine:commit_text(symbol)
            end
            ctx:clear()
            return true
        end
    end
    return false
end

function M.func(key_event, env)
    -- 带修饰键的组合一律放过（声笔中 Ctrl/Alt 组合另有用途）
    if key_event:release() or key_event:alt() or key_event:ctrl()
        or key_event:caps() or key_event:shift() then
        return kNoop
    end

    local ctx = env.engine.context

    -- 仅在编码态拦截；空码时按 / 走声笔原有标点行为
    if not ctx:is_composing() then
        return kNoop
    end

    local kc = key_event.keycode
    if kc < 0x20 or kc > 0x7E then
        return kNoop
    end

    local input = ctx.input or ""
    local next_input = input .. string.char(kc)

    if execute_quick_symbol(env, ctx, next_input) then
        return kAccepted
    end
    return kNoop
end

return M
