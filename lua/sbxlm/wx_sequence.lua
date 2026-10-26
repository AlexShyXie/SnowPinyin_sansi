-- 声笔小鹤 · 手动自由排序（万象拼音移植版）
-- 原作: amzxyz 万象拼音 super_sequence.lua
-- 移植: 去除万象依赖（wanxiang.lua / userdb.lua / super_filter 联动），适配声笔小鹤
--
-- 快捷键: Control+j 上移 / Control+k 下移 / Control+l 重置 / Control+p 置顶
--   作用对象: 当前编码下、候选菜单中的高亮候选
-- 存储: UserDb（LevelDb）自建库，不与声笔 sbxh.extended 用户词典冲突
-- 标记: 被手动调过序/置顶的候选，注释里追加 super_sequence/mark_symbol（默认 ↕）
--   不想要标记就在该方案的 super_sequence 段配 mark_symbol: ""
--
-- 声笔适配说明:
--   1. 码长不足 min_code_length（默认 3）的输入不参与排序
--      —— 声笔 1~2 码是声母简码位，保持固定节奏，不排序
--   2. 反查/以词定字等特殊段（bihua/sbyp/emoji/zhlf/sbzdy/punct tag）透传不处理
--   3. 本模块处理器挂在 librime key_binder 之前:
--      菜单态按 Ctrl+k/l/p 由本模块接管；非菜单态这些组合仍走声笔原有绑定

local kRejected = 0
local kAccepted = 1
local kNoop = 2

------------------------------------------------------------
-- 一、常量与键位
------------------------------------------------------------
local DEFAULT_SEQ_KEY = {
    up = "Control+j",
    down = "Control+k",
    reset = "Control+l",
    pin = "Control+p",
}

-- 手动调过序/置顶过的候选在注释里追加的标记；
-- 可用 super_sequence/mark_symbol 覆盖，配成空串即关闭标记
local DEFAULT_MARK_SYMBOL = "↕"

local MAX_SORT_CANDIDATES = 100
local DB_POSITION_LIMIT = 500
local POSITION_BASE = 512
local TOMBSTONE_SLOT = 511
local C_MAX = 2147483000
local MAX_VERSION = math.floor((C_MAX - TOMBSTONE_SLOT) / POSITION_BASE)

local RECORD_SEPARATOR = " \t"

-- 声笔特殊段 tag: 反查、以词定字、标点段不参与排序
local SPECIAL_TAGS = {
    bihua = true,  -- 笔画反查
    sbyp = true,   -- 双拼反查
    emoji = true,  -- 表情
    zhlf = true,   -- 联想？
    sbzdy = true,  -- 以词定字
    punct = true,  -- 标点段
}

------------------------------------------------------------
-- 二、UserDb 访问池（内联自万象 userdb.lua 的必要部分）
------------------------------------------------------------
-- UserDb(name, "userdb") 为 librime-lua 全局构造器，
-- "userdb" 类型可随 Rime 用户词典同步机制走。
local db_pool = setmetatable({}, { __mode = "v" })

local function open_sequence_db(db_name)
    local db = db_pool[db_name]
    if db then return db end

    local ok, d = pcall(UserDb, db_name, "userdb")
    if not ok or not d then return nil end

    if not d:loaded() and not d:open() then
        return nil
    end

    db_pool[db_name] = d
    return d
end

local function yield_original_list(input)
    for candidate in input:iter() do
        yield(candidate)
    end
end

------------------------------------------------------------
-- 三、UserDb 记录格式
-- raw key = 输入编码 + " \t" + 候选词
-- 尾巴 = "c=<commits> d=0 t=<tick>"（UserDb 标准尾巴）
-- commits 编码: 正数 = 版本*512 + 槽位(501..500 对应位置1..500)
--              负数 = 墓碑（重置），版本高于旧状态，可随同步传播
------------------------------------------------------------
local function to_integer(value, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge then
        value = 0
    end

    value = value < 0 and math.ceil(value) or math.floor(value)
    if minimum and value < minimum then value = minimum end
    if maximum and value > maximum then value = maximum end
    return value
end

local function parse_record_tail(tail)
    if type(tail) ~= "string" then return 0, 0, false end

    local commits, dee, tick = tail:match(
        "^c=([^%s\t]+) d=([^%s\t]+) t=([^%s\t]+)$"
    )
    commits, dee, tick = tonumber(commits), tonumber(dee), tonumber(tick)

    if not commits or commits ~= math.floor(commits)
        or not dee or dee ~= dee
        or not tick or tick < 0 or tick ~= math.floor(tick)
    then
        return 0, 0, false
    end

    return to_integer(commits, -C_MAX, C_MAX), to_integer(tick, 0), true
end

local function make_record_tail(commits, tick)
    commits = to_integer(commits, -C_MAX, C_MAX)
    tick = to_integer(tick, 0)
    return string.format("c=%d d=0 t=%d", commits, tick)
end

local function make_raw_key(input, item)
    if not input or input == "" or not item or item == "" then return nil end
    return input .. RECORD_SEPARATOR .. item
end

local function decode_state(commits)
    commits = tonumber(commits) or 0
    if commits == 0 then return 0, nil, false end

    local magnitude = math.abs(commits)
    local version = math.floor(magnitude / POSITION_BASE)
    local slot = magnitude % POSITION_BASE

    if commits < 0 then return version, nil, false end
    if slot < 1 or slot > DB_POSITION_LIMIT then return version, nil, false end

    local position = DB_POSITION_LIMIT + 1 - slot
    return version, position, true
end

local function next_version(commits)
    local magnitude = math.abs(tonumber(commits) or 0)
    local version = math.floor(magnitude / POSITION_BASE)

    if version >= MAX_VERSION then return MAX_VERSION end
    return version + 1
end

local function encode_active(version, position)
    version = math.max(1, math.min(MAX_VERSION, tonumber(version) or 1))
    position = math.max(1, math.min(DB_POSITION_LIMIT, tonumber(position) or 1))

    local slot = DB_POSITION_LIMIT + 1 - position
    return version * POSITION_BASE + slot
end

local function encode_tombstone(version)
    version = math.max(1, math.min(MAX_VERSION, tonumber(version) or 1))
    return -(version * POSITION_BASE + TOMBSTONE_SLOT)
end

------------------------------------------------------------
-- 四、DB 状态缓存（Processor / Filter 共享）
------------------------------------------------------------
local RECORD_CACHE_LIMIT = 128
local SEQUENCE_STATES = setmetatable({}, { __mode = "v" })

local function resolve_db_name(config)
    local db_name = config and config:get_string("super_sequence/db_name") or nil
    if not db_name or db_name == "" then return "sbxlm_sequence" end

    db_name = db_name:gsub("\\", "/"):gsub("^/+", "")
    while db_name:match("%.%./") do db_name = db_name:gsub("%.%./", "") end
    db_name = db_name:gsub("%./", "")
    return db_name ~= "" and db_name or "sbxlm_sequence"
end

local function get_sequence_state(env, config)
    if env.sequence_state then return env.sequence_state end

    config = config or env.engine.schema.config
    local db_name = env.sequence_db_name or resolve_db_name(config)
    local state = SEQUENCE_STATES[db_name]

    if not state then
        local db = open_sequence_db(db_name)
        if not db then return nil end

        state = {
            db = db, cache = {},
            cache_size = 0, cache_clock = 0,
        }
        SEQUENCE_STATES[db_name] = state
    end

    env.sequence_db_name = db_name
    env.sequence_state = state
    return state
end

local function release_sequence_state(env)
    if not env then return end
    env.sequence_state = nil
    env.sequence_db_name = nil
    collectgarbage()
end

local function invalidate_input_cache(state, input)
    if not state then return end

    if input then
        if state.cache[input] then
            state.cache[input] = nil
            state.cache_size = math.max(0, state.cache_size - 1)
        end
    else
        state.cache = {}
        state.cache_size = 0
        state.cache_clock = 0
    end
end

local function touch_cached_entry(state, cached)
    state.cache_clock = state.cache_clock + 1
    cached.last_used = state.cache_clock
end

local function trim_record_cache(state)
    if state.cache_size <= RECORD_CACHE_LIMIT then return end

    local oldest_input = nil
    local oldest_clock = math.huge

    for input, cached in pairs(state.cache) do
        local last_used = cached.last_used or 0
        if last_used < oldest_clock then
            oldest_input = input
            oldest_clock = last_used
        end
    end

    if oldest_input then
        state.cache[oldest_input] = nil
        state.cache_size = math.max(0, state.cache_size - 1)
    end
end

local function load_input_records(state, input)
    if not state or not input or input == "" then return {}, false end

    local cached = state.cache[input]
    if cached then
        touch_cached_entry(state, cached)
        return cached.records, cached.has_active
    end

    local records = {}
    local active_count = 0
    local prefix = input .. RECORD_SEPARATOR
    local prefix_len = #prefix
    local accessor = state.db:query(prefix)

    if accessor then
        for raw_key, tail in accessor:iter() do
            if raw_key:find(prefix, 1, true) ~= 1 then break end

            local item = raw_key:sub(prefix_len + 1)
            if item and item ~= "" and not item:match("^i=.- p=") then
                local commits, tick = parse_record_tail(tail)
                local version, position, active = decode_state(commits)

                records[item] = {
                    commits = commits,
                    tick = tick,
                    version = version,
                    position = position,
                    active = active,
                }

                if active then active_count = active_count + 1 end
            end
        end
    end

    accessor = nil

    cached = {
        records = records,
        active_count = active_count,
        has_active = active_count > 0,
    }
    touch_cached_entry(state, cached)

    state.cache[input] = cached
    state.cache_size = state.cache_size + 1
    trim_record_cache(state)

    return records, active_count > 0
end

local function update_cached_record(state, input, item, commits, tick)
    local cached = state.cache[input]
    if not cached then return end

    touch_cached_entry(state, cached)
    local old_record = cached.records[item]
    local old_active = old_record and old_record.active or false
    local version, position, active = decode_state(commits)

    cached.records[item] = {
        commits = commits,
        tick = tick,
        version = version,
        position = position,
        active = active,
    }

    if old_active ~= active then
        if active then
            cached.active_count = cached.active_count + 1
        else
            cached.active_count = math.max(0, cached.active_count - 1)
        end
    end

    cached.has_active = cached.active_count > 0
end

local function write_active_position(state, input, item, position, records)
    local record = records[item]
    local current = record and record.commits or 0
    local tick = record and record.tick or 0
    local version = next_version(current)
    local commits = encode_active(version, position)
    local raw_key = make_raw_key(input, item)

    if not raw_key then return false end

    local tail = make_record_tail(commits, tick)
    if not tail or not state.db:update(raw_key, tail) then return false end

    update_cached_record(state, input, item, commits, tick)
    records[item] = state.cache[input]
        and state.cache[input].records[item]
        or {
            commits = commits,
            tick = tick,
            version = version,
            position = position,
            active = true,
        }

    return true
end

local function write_reset_tombstone(state, input, item, records)
    local record = records[item]
    if not record or not record.active then return true end

    local version = next_version(record.commits)
    local commits = encode_tombstone(version)
    local raw_key = make_raw_key(input, item)
    if not raw_key then return false end

    local tail = make_record_tail(commits, record.tick)
    if not tail or not state.db:update(raw_key, tail) then return false end

    update_cached_record(state, input, item, commits, record.tick)
    records[item] = state.cache[input]
        and state.cache[input].records[item]
        or {
            commits = commits,
            tick = record.tick,
            version = version,
            position = nil,
            active = false,
        }

    return true
end

------------------------------------------------------------
-- 五、排序状态（Processor 写入意图，Filter 执行落库）
------------------------------------------------------------
local curr_state = {}
curr_state.ADJUST_MODE = {
    None = -1,
    Reset = 0,
    Pin = 1,
    Adjust = 2,
}

curr_state.default = {
    selected_phrase = nil,
    offset = 0,
    mode = curr_state.ADJUST_MODE.None,
    highlight_index = nil,
    adjust_code = nil,
    adjust_key = nil,
    dirty = false,
}

function curr_state.reset()
    if curr_state.mode == curr_state.ADJUST_MODE.None then return end
    for key, value in pairs(curr_state.default) do curr_state[key] = value end
end

function curr_state.is_pin_mode()
    return curr_state.mode == curr_state.ADJUST_MODE.Pin
end

function curr_state.is_reset_mode()
    return curr_state.mode == curr_state.ADJUST_MODE.Reset
end

function curr_state.is_adjust_mode()
    return curr_state.mode == curr_state.ADJUST_MODE.Adjust
end

function curr_state.has_adjustment()
    return curr_state.mode ~= curr_state.ADJUST_MODE.None
end

------------------------------------------------------------
-- 六、特殊段判断（原万象 is_function_mode 的声笔版）
------------------------------------------------------------
local function is_special_segment(context)
    if not context or not context.composition or context.composition:empty() then
        return false
    end

    local seg = context.composition:back()
    if not seg then return false end

    for tag in pairs(SPECIAL_TAGS) do
        if seg:has_tag(tag) then return true end
    end
    return false
end

------------------------------------------------------------
-- 七、稳定位置重建
------------------------------------------------------------
local function apply_saved_positions(entries, records)
    local count = #entries
    if count == 0 then return entries end

    local fixed = {}
    local placed = {}
    local slots = {}

    for _, entry in ipairs(entries) do
        local record = records[entry.sort_key]

        if record and record.active and record.position then
            fixed[#fixed + 1] = {
                entry = entry,
                position = math.max(1, math.min(count, record.position)),
                version = record.version or 0,
                magnitude = math.abs(record.commits or 0),
            }
        end
    end

    table.sort(fixed, function(a, b)
        if a.position ~= b.position then return a.position < b.position end
        if a.version ~= b.version then return a.version > b.version end
        if a.magnitude ~= b.magnitude then return a.magnitude > b.magnitude end
        return a.entry.sort_key < b.entry.sort_key
    end)

    local function find_free_slot(target)
        for position = target, count do
            if not slots[position] then return position end
        end

        for position = target - 1, 1, -1 do
            if not slots[position] then return position end
        end

        return nil
    end

    for _, fixed_entry in ipairs(fixed) do
        local slot = find_free_slot(fixed_entry.position)

        if slot then
            slots[slot] = fixed_entry.entry
            placed[fixed_entry.entry] = true
        end
    end

    local raw_index = 1

    for position = 1, count do
        if not slots[position] then
            while entries[raw_index] and placed[entries[raw_index]] do
                raw_index = raw_index + 1
            end

            slots[position] = entries[raw_index]
            if entries[raw_index] then placed[entries[raw_index]] = true end
            raw_index = raw_index + 1
        end
    end

    for position, entry in ipairs(slots) do
        entry.final_position = position
    end

    return slots
end

local function persist_entry_position(state, input, entry, position, records)
    if position == entry.raw_position then
        return write_reset_tombstone(state, input, entry.sort_key, records)
    end

    local record = records[entry.sort_key]

    if record and record.active and record.position == position then
        return true
    end

    return write_active_position(state, input, entry.sort_key, position, records)
end

local function apply_current_adjustment(state, input, entries, records)
    if not curr_state.has_adjustment() or not curr_state.dirty then return end

    local from_position
    local active_before = {}

    -- 只记住操作前已经存在的手动排序记录。普通候选即使被挤动，
    -- 也不会因此被写入数据库。
    for item, record in pairs(records) do
        if record.active then active_before[item] = true end
    end

    for position, entry in ipairs(entries) do
        if entry.cand.text == curr_state.selected_phrase then
            from_position = position
            curr_state.adjust_code = input
            curr_state.adjust_key = entry.sort_key
            break
        end
    end

    if not from_position then
        curr_state.dirty = false
        return
    end

    local selected = entries[from_position]
    local selected_key = selected.sort_key
    local to_position = from_position

    if curr_state.is_adjust_mode() then
        to_position = math.max(
            1,
            math.min(#entries, from_position + curr_state.offset)
        )
    elseif curr_state.is_pin_mode() then
        to_position = 1
    elseif curr_state.is_reset_mode() then
        to_position = math.max(
            1,
            math.min(#entries, selected.raw_position)
        )
    end

    local moved = from_position ~= to_position

    if moved then
        local candidate = table.remove(entries, from_position)
        table.insert(entries, to_position, candidate)
    end

    if curr_state.is_reset_mode() then
        -- 重置只删除当前候选的手动状态。
        write_reset_tombstone(state, input, selected_key, records)
    elseif curr_state.is_pin_mode() or moved then
        -- 主动操作的候选必须保存；置顶即使当前已经在第一位，也要
        -- 保存"保持第一位"的明确意图。
        persist_entry_position(
            state,
            input,
            selected,
            to_position,
            records
        )
    end

    -- 同一轮同时更新最终位置，并在发生移动时修正此前已有手排记录的候选，
    -- 避免对 entries 再做一轮完整扫描。普通候选被动让位仍不落库。
    for position, entry in ipairs(entries) do
        entry.final_position = position

        if moved then
            local key = entry.sort_key
            if key ~= selected_key and active_before[key] then
                persist_entry_position(
                    state,
                    input,
                    entry,
                    position,
                    records
                )
            end
        end
    end

    curr_state.highlight_index = to_position - 1
    curr_state.dirty = false
end

------------------------------------------------------------
-- 八、Processor（拦截 Ctrl+j/k/l/p）
------------------------------------------------------------
local P = {}

function P.init(env)
    local config = env.engine.schema.config
    env.seq_keys = {
        up = config:get_string("super_sequence/up") or DEFAULT_SEQ_KEY.up,
        down = config:get_string("super_sequence/down") or DEFAULT_SEQ_KEY.down,
        reset = config:get_string("super_sequence/reset") or DEFAULT_SEQ_KEY.reset,
        pin = config:get_string("super_sequence/pin") or DEFAULT_SEQ_KEY.pin,
    }
    env.min_code_len = config:get_int("super_sequence/min_code_length") or 3

    get_sequence_state(env, config)
end

function P.fini(env)
    env.seq_keys = nil
    env.min_code_len = nil
    release_sequence_state(env)
end

local function process_adjustment(context)
    local candidate = context:get_selected_candidate()
    curr_state.selected_phrase = candidate and candidate.text or nil
    context:refresh_non_confirmed_composition()

    if context.highlight
        and curr_state.highlight_index
        and curr_state.highlight_index >= 0
    then
        context:highlight(curr_state.highlight_index)
    end
end

---编码过短（声笔简码位）不参与排序
local function code_too_short(text, min_len)
    return type(text) == "string" and #text < (min_len or 3)
end

function P.func(key_event, env)
    local context = env.engine.context
    local key_repr = key_event:repr()
    local seq_keys = env.seq_keys or DEFAULT_SEQ_KEY
    local up = seq_keys.up
    local down = seq_keys.down
    local reset = seq_keys.reset
    local pin = seq_keys.pin

    if is_special_segment(context) then
        curr_state.reset()
        return kNoop
    end

    curr_state.reset()

    local selected_candidate = context:get_selected_candidate()

    if not context:has_menu()
        or not selected_candidate
        or not selected_candidate.text
    then
        return kNoop
    end

    local adjust_code = context.input:sub(1, context.caret_pos)

    -- 简码位不排序，但排序快捷键必须在 Rime 内吞掉，避免穿透给操作系统。
    if code_too_short(adjust_code, env.min_code_len) then
        if key_repr == up or key_repr == down or key_repr == reset or key_repr == pin then
            return kAccepted
        end
        return kNoop
    end

    if key_repr == up then
        curr_state.offset = -1
        curr_state.mode = curr_state.ADJUST_MODE.Adjust
    elseif key_repr == down then
        curr_state.offset = 1
        curr_state.mode = curr_state.ADJUST_MODE.Adjust
    elseif key_repr == reset then
        curr_state.offset = nil
        curr_state.mode = curr_state.ADJUST_MODE.Reset
    elseif key_repr == pin then
        curr_state.offset = nil
        curr_state.mode = curr_state.ADJUST_MODE.Pin
    else
        return kNoop
    end

    -- 排序动作前刷新当前编码缓存，确保读取到最近一次结果。
    invalidate_input_cache(get_sequence_state(env), adjust_code)
    curr_state.dirty = true
    process_adjustment(context)
    return kAccepted
end

------------------------------------------------------------
-- 九、Filter（读取排序记录，重排候选）
------------------------------------------------------------
local F = {}

-- 追加式写候选注释：librime-lua 的 comment 可直接赋值，无需重包 Candidate
-- （重包会丢 preedit 等属性）。与冰雪 snow.comment() 同语义，故不引入外部依赖。
local function append_comment(candidate, comment)
    if not candidate or not comment or comment == "" then
        return candidate
    end

    local current = candidate.comment or ""
    candidate.comment = current ~= "" and (current .. " " .. comment) or comment
    return candidate
end

function F.init(env)
    local config = env.engine.schema.config
    env.page_size = config and config:get_int("menu/page_size") or 5
    env.min_code_len = config:get_int("super_sequence/min_code_length") or 3
    -- 未配置 → 用默认标记；显式配成空串 → 关闭标记（get_string 缺失时返回 nil）
    env.mark_symbol = config:get_string("super_sequence/mark_symbol")
    if env.mark_symbol == nil then
        env.mark_symbol = DEFAULT_MARK_SYMBOL
    end
    get_sequence_state(env, config)
end

function F.fini(env)
    env.page_size = nil
    env.min_code_len = nil
    env.mark_symbol = nil
    release_sequence_state(env)
end

function F.func(input, env)
    local context = env.engine.context

    if is_special_segment(context) then
        curr_state.reset()
        return yield_original_list(input)
    end

    local adjust_code = context.input:sub(1, context.caret_pos)
    if adjust_code == "" then
        return yield_original_list(input)
    end

    -- 简码位不参与手动排序，直接透传，避免进入 sequence DB 查询。
    if code_too_short(adjust_code, env.min_code_len) then
        return yield_original_list(input)
    end

    local state = get_sequence_state(env)
    if not state then
        return yield_original_list(input)
    end

    local records, has_active = load_input_records(state, adjust_code)
    local has_current_action =
        curr_state.has_adjustment() and curr_state.dirty

    if not has_active and not has_current_action then
        return yield_original_list(input)
    end

    local entries = {}
    local seen = {}
    local iterator, iterator_state, iterator_control = input:iter()
    local raw_position = 0
    local scanned = 0

    while scanned < MAX_SORT_CANDIDATES do
        local candidate = iterator(iterator_state, iterator_control)
        iterator_control = candidate
        if not candidate then break end

        scanned = scanned + 1

        local text = candidate.text

        if not seen[text] then
            seen[text] = true
            raw_position = raw_position + 1

            entries[#entries + 1] = {
                cand = candidate,
                phrase = text,
                sort_key = text,
                raw_position = raw_position,
                final_position = raw_position,
            }
        end
    end

    local ordered = apply_saved_positions(entries, records)
    apply_current_adjustment(state, adjust_code, ordered, records)

    for _, entry in ipairs(ordered) do
        -- 只给「有手动排序记录」的候选打标记；records 已被本轮操作更新，
        -- 所以刚用 Ctrl+u/i/p 调过的词会立刻带上标记，Ctrl+l 重置后消失。
        local record = records[entry.sort_key]
        if env.mark_symbol ~= "" and record and record.active then
            append_comment(entry.cand, env.mark_symbol)
        end
        yield(entry.cand)
    end

    -- 第 101 个及之后的候选不参与排序，保持上游顺序继续惰性透传。
    while true do
        local candidate = iterator(iterator_state, iterator_control)
        iterator_control = candidate
        if not candidate then break end

        local text = candidate.text

        if not seen[text] then
            seen[text] = true
            yield(candidate)
        end
    end
end

------------------------------------------------------------
-- 导出: 同一文件承载 Processor 与 Filter
-- 挂载: lua_processor@*sbxlm.wx_sequence*P  与  lua_filter@*sbxlm.wx_sequence*F
------------------------------------------------------------
return { P = P, F = F }
