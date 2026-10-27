# 修改版冰雪三拼/冰三小鹤

本目录是一份 Rime（小狼毫 Weasel）用户配置目录，主体是**冰雪拼音**系列方案：
以 `snow_pinyin`（全拼带调）为基础，派生出 **冰雪四拼** 与 **冰雪三拼（小鹤键位）** 两套「词顶功」方案。

> 词典文件（`*dict.yaml`）不在本目录内，已由 `.gitignore` 忽略；部署时需要另外准备。

---

## 一、目录里实际生效的方案

`default.custom.yaml` 覆盖了 `schema_list`，实际可切换的是两个：

| 方案 | schema_id | 说明 |
|---|---|---|
| **冰雪四拼** | `snow_sipin` | 每个音节 4 码：声码 + 韵头 + 韵尾 + 声调 |
| **冰雪三拼·小鹤** | `snow_xiaohe` | 每个音节 3 码：声码 + 韵码 + 声调（小鹤双拼键位） |

`snow_pinyin` 只作为基类被 `__include` 引用，不直接出现在方案菜单里。
方案切换热键：`Control+`` `（backtick）。

---


## 二、冰雪三拼·小鹤 `snow_xiaohe`

由冰雪三拼换用**声笔小鹤键位**而来（见 `snow_xiaohe.custom.yaml` 头部注释）。

### 编码：声码 + 韵码 + 调码

**声码**：`zh→z`、`ch→c`、`sh→s`，零声母一律用 `v`，其余声母同字母。

**韵码**（小鹤双拼，占满 26 键）

| 韵 | 码 | 韵 | 码 | 韵 | 码 | 韵 | 码 |
|---|---|---|---|---|---|---|---|
| iang uang | l | ang | h | ing uai | k | iong ong | s |
| üan uan | r | ian | m | an | j | iao | n |
| ia ua | x | ie | p | in | b | iu | q |
| ui | v | ai | d | ao | c | ou | z |
| ei | w | eng | g | en | f | un | y |
| üe ue | t | uo o | o | er | r | | |

**调码**（第 3 码）：`12345 → i e u a o`（与四拼一致）

例：马 `ma3` = `mau`、能 `neng2` = `nge`、马上 = `mau sha`，**去调**即 `ma sh`，所以打 `mas`（三码）/`mash`（四码）都出「马上」。

### 与四拼的关键差异

| 项 | 四拼 | 三拼小鹤 |
|---|---|---|
| 主翻译器 | `script_translator` | `lua_translator@*snow.table_like*t12` + `*jianpin`（模拟码表，`t1/t2/jianpin_pattern` 控制） |
| 略码 / 回头补码 | 有 | 都没有 |
| 顶功 | 按音节计数 | 二码后接**声码不顶**（保证 `mash` 不被顶开） |
| 辅码笔画键 | `e i u o a`（一丨丿丶乙） | 同为 `e i u o a`：第 4 码起 `accept: [aeiou]`，靠位置区分——第 3 码是调码，之后的元音才是笔画 |
| 选重键 | `_23890` | 默认数字 |
| 特有 filter | — | `snow.bihua*filter`、`snow.hint`（一码提示简词、630 注释） |

### 已做的定制（本目录相对原始冰雪三拼的改动）

1. **修正 neng 编码 bug**：`xiaohe_algebra` 中 `xform/ng(?=\d)/g/` 会把「能 neng2」的声母 n 一起吃掉（编成 `ge`，与「各」撞码），导致所有含「能」的词查不到。已改为 `xform/(?<=V)ng(?=\d)/g/`，只处理零声母「嗯」。已用全部 1761 个音节做声码回归验证，无同类问题。
2. **三码出词组候选**：放宽 `t2_pattern` / `enforce_jianpin`（第二字允许只打声码）+ 开 `translator/enable_completion`，打到第三码（如 `mas`）也能出二字词。
3. **顶标点排除 `;=-`**：`speller/popping` 的「标点大写顶」原为 `[^a-z0-9 ]`，会把 `; - =` 当标点顶屏，压住 key_binder 的次选/翻页绑定。
4. **万象快符**：`sbxlm.wx_quick_symbol` 挂在 popping 之前（`@before 4`），`字母 + /` 直接上屏符号（见 `quick_symbol_text`）。
5. **万象排序**：`sbxlm.wx_sequence`，处理器 `@before 8`（在 key_binder 前）、过滤器 `@before 7`（在 uniquifier 前，晚于 `snow.fix`，所以手动排序优先于固顶）。
6. **固顶词表扩充**：`snow_xiaohe.fixed.txt` 现约 4100 条，含一码、二简词、三简二字词 790 条、三简三字词 1945 条、四码固顶 983 条。尽量贴近小鹤音形的手感。

### 键位

| 键 | 作用 |
|---|---|
| `;` | 次选 |
| `-` / `=` | 翻页 |
| `字母 + /` | 快符（如 `q/` 重复上次上屏、`s/` 出……） |
| `Ctrl+u` / `Ctrl+i` | 排序：上移 / 下移 |
| `Ctrl+p` / `Ctrl+l` | 排序：置顶 / 重置该编码 |
| `Ctrl+;` | 固定候选（📌） |
| `Ctrl+j` | toggle buffered |

---

## 三、冰雪四拼 `snow_sipin`

### 编码：声码 + 韵头 + 韵尾 + 声调

一个音节固定 4 码，声调参与编码，所以重码极低、可以「词顶功」。

**声码**（第 1 码）

| 声母 | 码 | 声母 | 码 |
|---|---|---|---|
| zh | w | ch | y |
| sh | v | 零声母（a/o/e 起） | r |
| 零声母（i 起） | f | 零声母（u 起） | s |
| 零声母（ü 起） | k | 其余声母 | 同字母 |

**韵头**（第 2 码）：`ia→u`、`ua→i`、`üa→o`、`ie→e`、`ue→u`、`üe→o`、`io→o`、`uo→o`、`er→i`、`ü→a`

**韵尾**（第 3 码）：`ng→e`、`n→o`、`m→a`

**声调**（第 4 码）：`xlit/12345/ieuao/` → 1=i、2=e、3=u、4=a、5=o

**无理音节**（高频字专用短码）：三 `san1→he3`、五 `wu3→gu2`、日 `ri4→ri1`

例：装 `zhuang1` = w(声) + i(韵头 ua) + e(韵尾 ng) + i(调) = `wiei`；能 `neng2` = `neee`；三 = `heu`

### 功能

| 功能 | 说明 |
|---|---|
| 词顶功 | `speller/popping` 规则：单字/二字/三字/四字分别定义何时把首选顶上屏；`switches` 里 `popping [整句, 顶功]` 可切 |
| 缓冲模式 | `buffered [结束, 缓冲]`，顶功只确认不上屏，便于继续造词 |
| 辅码（形码） | 主码后接 `1` 走**部首反查**；否则用 `e i u o a` = 一丨丿丶乙 走**笔画滤重**；无匹配出 🈚️ |
| 略码 | 大写键触发（`D`的 `L`了 `B`不 `F`一 `R`啊 `U`呀、`A`重复全词、`E`首字、`I`末字、`O`叠词…）。**注意**：`snow_sipin.custom.yaml` 已把略码处理器原位替换为 `lua_processor@*sipin_filter` |
| 回头补码 | `snow.editor`：末音节满码后按元音把码补回首音节 |
| 固顶 | `snow.fix` 读 `snow_sipin.fixed.txt`；`Ctrl+;` 手动固定（见通用功能） |
| 反查 | `a…` 拼音反查（注释直接显示四拼码）、`u…` 笔画反查 |
| 以词定字 | `[` 取首字、`]` 取末字 |
| 功能段 | `o` 前缀：日期时间 `orq/osj/ors`、数字转汉字、计算器、输入统计 `otj` 等 |
| 自定义短语 | `custom_phrase.txt`（`initial_quality: 99`，优先级最高） |

### 键位

| 键 | 作用 |
|---|---|
| `;` | 次选（send 2） |
| `-` / `=` | 上翻页 / 下翻页 |
| `[` / `]` | 以词定字（首字 / 末字） |
| `1` `4` `5` `6` `7` | 光标定位到第 n 个音节 |
| `Ctrl+j` | toggle buffered |
| `Ctrl+'` | 自由加词 |
| `Ctrl+;` | 固定/取消固定当前候选 |

选重键：`_23890`（`alternative_select_keys`），每页 6 个候选。

---


## 四、两方案共有的功能

### 固顶与用户词典（`snow.fix` + `snow.user_dict`）

| 键 | 作用 |
|---|---|
| `Ctrl+;` | 固定/取消固定当前候选到当前位置，显示 📌（上限第 18 位） |
| `Ctrl+'` | 自由加词（再按一次确认） |
| `Ctrl+[` / `Ctrl+]` | 已固定项上移 / 下移 |
| `Ctrl+\` | 重置该编码下所有固定 |

五个键都可用 `translator/fix_key｜add_key｜up_key｜down_key｜reset_key` 覆盖。
`<schema_id>.fixed.txt` 是随方案的固顶表，用户词条记录则写在方案用户词典里。

### 排序标记

被手动调过序/置顶的候选，注释里会追加 `↕`（由 `super_sequence/mark_symbol` 配置，配成空串即关闭）。
与固顶的 📌 可区分：一个词若既固顶又被调序，注释显示 `📌 ↕`。
注意两者**不能混用符号**：`snow.postpone` 靠 `comment` 里是否有 📌/📍 来判断「固定候选不后置」。

### 其它

- **后置** `snow.postpone`：短码时当过首选的字词，长码时自动后置（已被固定的不动）
- **反查**：`a…` 拼音、`u…` 笔画（冰雪笔画 `snow_bihua`，`eiuoa` = 一丨丿丶乙）
- **以词定字**：`[` 首字、`]` 末字
- **功能段**：`o` 前缀的日期/数字/计算/统计（统计存 `snow_statistics.userdb`）
- **符号**：`i` + 字母/数字
- **自定义短语**：`custom_phrase.txt`
- **Unicode 注释**：打开 `unicode` 开关后给单字加码点与分区

---

## 五、文件导览

| 文件 | 作用 |
|---|---|
| `snow_pinyin.schema.yaml` | 冰雪拼音基类（全拼带调），被子方案 `__include` |
| `snow_sipin.schema.yaml` / `.custom.yaml` / `.fixed.txt` | 冰雪四拼：方案、用户补丁、固顶表 |
| `snow_xiaohe.schema.yaml` / `.custom.yaml` / `.fixed.txt` | 冰雪三拼小鹤：方案、用户补丁、固顶表 |
| `snow_bihua.schema.yaml` / `snow_bushou.schema.yaml` | 冰雪附属：笔画反查库、部首反查库（供辅码） |
| `default.custom.yaml` | 方案菜单（`snow_sipin / snow_xiaohe`） |
| `custom_phrase.txt` | 两个方案共用的自定义短语 |
| `lua/snow/*.lua` | 冰雪系列模块：fix（固顶）、user_dict、popping（顶功）、table_like、shape_filter/processor（辅码）、postpone、hint、statistics、datetime/number/calculator 等 |
| `lua/sipin_filter.lua` | 四拼专用：大写韵母筛选（大写不进编码，故不触发顶功） |
| `lua/sbxlm/wx_quick_symbol.lua`、`wx_sequence.lua` | 从万象移植的快符与排序模块，现由冰雪小鹤使用（原声笔系列已移除，模块名保留未改） |

---

## 六、维护与回退

| 改什么 | 是否需要重建棱镜 | 说明 |
|---|---|---|
| `*.custom.yaml`（键位、挂载、开关） | 不需要（但改动件后建议重新部署） | 一键回退就是删掉对应 patch 行 |
| `<schema>.fixed.txt` | 不需要 | 方案数据文件，重新部署或切走再切回即生效 |
| `*.schema.yaml` 的 `*_algebra` | **需要**（部署会明显变慢） | 改编码规则务必重跑音节回归验证 |
| lua 模块 | 不需要 | 快符/排序在 `lua/sbxlm/` 下，但已无其它方案共用 |

踩过的坑，改之前先看一眼：

- `fixed.txt` 里**同一个码只能写一行**：`snow.read_dictionary` 是 `result[code] = words`，同码分两行会被后者覆盖；要多个词就写在一行里用空格分隔（如 `mas	马上 马术`）
- `engine/processors/@before N` 的索引是**按顺序累积**的：快符 `@before 4` 插入后，key_binder 由 7 变成 8，所以排序要用 `@before 8`，且必须写在 `@before 4` 之后
- 排序键不能用 📌/📍（会被 `postpone` 误判为固定项）
- 简码位（1~2 码）不参与排序（`min_code_length: 3`），且排序处理器会把排序键吞掉以防穿透到系统，因此 `Ctrl+u/i` 在 1~2 码有候选时不会触发其它绑定

---

## 七、已知问题

1. `snow_sipin.custom.yaml` 引用 `lua_processor@*sipin_filter` / `lua_filter@*sipin_filter`，对应模块在 `lua/sipin_filter.lua`（四拼大写韵母筛选，依赖 `lua/snow/snow.lua`），不要误删。
2. `radical_sipin.txt` / `radical_sanpin.txt` 不在目录内，部首辅码会退化为空映射（`shape_filter` 不会报错，只是没有部首数据）。
3. `Control+i` 在个别环境可能被识别为 Tab；若下移无效，把 `super_sequence/down` 换成别的组合键。
4. `Control+u` 若被编辑器用于清空输入，仅在「有候选且 ≥3 码」时被排序抢占。
