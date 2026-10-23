-- zxcvbn-lite.lua -- a pure-Lua port of zxcvbn's matchers and scoring.
--
-- No external process, no C library: one Lua module + one data file.
--   * dictionary matching (93k words) with l33t + reversed variants
--   * spatial matching (qwerty adjacency graph)
--   * repeat, sequence, date and recent-year matching
--   * zxcvbn's "most guessable match sequence" DP and guess model
--
-- Usage (after init_by_lua_block loads the data):
--     local zxcvbn = require "zxcvbn-lite"
--     local score  = zxcvbn.score(password)          -- 0..4, like zxcvbn
--     local guesses = zxcvbn.guesses(password)
--
-- Load once, before the workers fork:
--     init_by_lua_block {
--         local data = require "zxcvbn-data"
--         require("zxcvbn-lite").init(data)
--     }

local M = {}

---------------------------------------------------------------------------
-- tunables (identical to zxcvbn where it matters)
---------------------------------------------------------------------------

local BRUTEFORCE_CARDINALITY = 10
local MIN_GUESSES_BEFORE_GROWING_SEQUENCE = 10000
local MIN_SUBMATCH_GUESSES_SINGLE_CHAR = 10
local MIN_SUBMATCH_GUESSES_MULTI_CHAR = 50
local MIN_YEAR_SPACE = 20
local REFERENCE_YEAR = 2017
local DATE_MAX_YEAR = 2050
local DATE_MIN_YEAR = 1000
local MAX_DELTA = 5
local MAX_L33T_SUBS = 64

local DATE_SPLITS = {
    [4] = { { 1, 2 }, { 2, 3 } },
    [5] = { { 1, 3 }, { 2, 3 } },
    [6] = { { 1, 2 }, { 2, 4 }, { 4, 5 } },
    [7] = { { 1, 3 }, { 2, 3 }, { 4, 5 }, { 4, 6 } },
    [8] = { { 2, 4 }, { 4, 6 } },
}

-- l33t characters -> the letters they can stand for
local L33T = {
    ["4"] = { "a" }, ["@"] = { "a" }, ["8"] = { "b" },
    ["("] = { "c" }, ["{"] = { "c" }, ["["] = { "c" }, ["<"] = { "c" },
    ["3"] = { "e" }, ["6"] = { "g" }, ["9"] = { "g" },
    ["1"] = { "i", "l" }, ["!"] = { "i" }, ["|"] = { "i", "l" },
    ["7"] = { "l", "t" }, ["0"] = { "o" },
    ["$"] = { "s" }, ["5"] = { "s" }, ["+"] = { "t" },
    ["%"] = { "x" }, ["2"] = { "z" },
}

-- characters that require shift on a US layout (zxcvbn's SHIFTED_RX)
local SHIFTED = {}
for c in ([[~!@#$%^&*()_+QWERTYUIOP{}|ASDFGHJKL:"ZXCVBNM<>?]]):gmatch(".") do
    SHIFTED[c] = true
end

local ranks, maxlen = {}, 0
local GRAPH, KEY_START, KEY_DEGREE = {}, 94, 4.5957446808510641

---------------------------------------------------------------------------
-- init
---------------------------------------------------------------------------

function M.init(data)
    local rank = 0
    for line in data.words:gmatch("[^\r\n]+") do
        if line:sub(1, 1) == "#" then
            rank = 0
        else
            rank = rank + 1
            local known = ranks[line]
            if known == nil or rank < known then
                ranks[line] = rank
            end
            if #line > maxlen then
                maxlen = #line
            end
        end
    end

    if maxlen == 0 then
        error("zxcvbn-lite: wordlist is empty - is zxcvbn-data loaded correctly?")
    end

    for line in data.graph:gmatch("[^\r\n]+") do
        local cells = {}
        for cell in (line .. "\t"):gmatch("([^\t]*)\t") do
            cells[#cells + 1] = cell
        end
        local neighbours = {}
        for i = 2, #cells do
            neighbours[i - 1] = (cells[i] ~= "") and cells[i] or false
        end
        GRAPH[cells[1]] = neighbours
    end

    local keys, degree = 0, 0
    for _, neighbours in pairs(GRAPH) do
        keys = keys + 1
        for i = 1, #neighbours do
            if neighbours[i] then
                degree = degree + 1
            end
        end
    end
    KEY_START = keys
    if keys > 0 then
        KEY_DEGREE = degree / keys
    end

    M.ready = true
    return M
end

---------------------------------------------------------------------------
-- maths helpers
---------------------------------------------------------------------------

local function nCk(n, k)
    if k > n then return 0 end
    if k == 0 then return 1 end
    local r = 1
    for d = 1, k do
        r = r * n
        r = r / d
        n = n - 1
    end
    return r
end

local function factorial(n)
    local r = 1
    for i = 2, n do
        r = r * i
    end
    return r
end

---------------------------------------------------------------------------
-- matchers
---------------------------------------------------------------------------

local function add_dictionary_matches(pw, out)
    local n = #pw
    local low = pw:lower()
    for i = 1, n do
        local jmax = n
        if i + maxlen - 1 < jmax then
            jmax = i + maxlen - 1
        end
        for j = i, jmax do
            local word = low:sub(i, j)
            local rank = ranks[word]
            if rank then
                out[#out + 1] = {
                    pattern = "dictionary", i = i, j = j,
                    token = pw:sub(i, j), matched_word = word, rank = rank,
                    reversed = false, l33t = false,
                }
            end
        end
    end
end

local function reverse_dictionary_matches(pw, out)
    local n = #pw
    local rev = pw:reverse()
    local inner = {}
    add_dictionary_matches(rev, inner)
    for _, m in ipairs(inner) do
        local token = m.token:reverse()
        out[#out + 1] = {
            pattern = "dictionary", i = n + 1 - m.j, j = n + 1 - m.i,
            token = token, matched_word = m.matched_word, rank = m.rank,
            reversed = true, l33t = false,
        }
    end
end

-- every way of reading the l33t characters present in this password
local function enumerate_subs(pw)
    local chars = {}
    for i = 1, #pw do
        local c = pw:sub(i, i)
        if L33T[c] and not chars[c] then
            chars[c] = L33T[c]
        end
    end
    local list = {}
    for c in pairs(chars) do
        list[#list + 1] = c
    end
    table.sort(list)

    local subs = { {} }
    for _, c in ipairs(list) do
        local next_subs = {}
        for _, base in ipairs(subs) do
            next_subs[#next_subs + 1] = base            -- leave it unchanged
            for _, letter in ipairs(chars[c]) do
                local copy = {}
                for k, v in pairs(base) do copy[k] = v end
                copy[c] = letter
                next_subs[#next_subs + 1] = copy
            end
        end
        subs = next_subs
        if #subs > MAX_L33T_SUBS then
            break
        end
    end
    return subs
end

local function translate(pw, sub)
    local buf = {}
    for i = 1, #pw do
        local c = pw:sub(i, i)
        buf[i] = sub[c] or c
    end
    return table.concat(buf)
end

local function l33t_matches(pw, out)
    for _, sub in ipairs(enumerate_subs(pw)) do
        if next(sub) then
            local inner = {}
            add_dictionary_matches(translate(pw, sub), inner)
            for _, m in ipairs(inner) do
                local token = pw:sub(m.i, m.j)
                if token:lower() ~= m.matched_word and #token > 1 then
                    local match_sub = {}
                    for subbed, letter in pairs(sub) do
                        if token:find(subbed, 1, true) then
                            match_sub[subbed] = letter
                        end
                    end
                    if next(match_sub) then
                        m.token = token
                        m.l33t = true
                        m.sub = match_sub
                        out[#out + 1] = m
                    end
                end
            end
        end
    end
end

local function spatial_matches(pw, out)
    local n = #pw
    local i = 1
    while i < n do
        local j = i + 1
        local last_direction, turns = nil, 0
        local shifted_count = SHIFTED[pw:sub(i, i)] and 1 or 0
        while true do
            local prev = pw:sub(j - 1, j - 1)
            local neighbours = GRAPH[prev] or {}
            local found, found_direction, cur_direction = false, -1, -1
            if j <= n then
                local cur = pw:sub(j, j)
                for ai = 1, #neighbours do
                    local adj = neighbours[ai]
                    cur_direction = cur_direction + 1
                    if adj and adj:find(cur, 1, true) then
                        found = true
                        found_direction = cur_direction
                        if adj:sub(2, 2) == cur then
                            shifted_count = shifted_count + 1
                        end
                        if last_direction ~= found_direction then
                            turns = turns + 1
                            last_direction = found_direction
                        end
                        break
                    end
                end
            end
            if found then
                j = j + 1
            else
                if j - i > 2 then
                    out[#out + 1] = {
                        pattern = "spatial", i = i, j = j - 1,
                        token = pw:sub(i, j - 1),
                        turns = turns, shifted_count = shifted_count,
                    }
                end
                i = j
                break
            end
        end
    end
end

local function sequence_matches(pw, out)
    local n = #pw
    if n == 1 then return end

    local function update(i, j, delta)
        if (j - i > 1) or (delta ~= 0 and math.abs(delta) == 1) then
            if delta ~= 0 and math.abs(delta) <= MAX_DELTA then
                out[#out + 1] = {
                    pattern = "sequence", i = i, j = j,
                    token = pw:sub(i, j), ascending = delta > 0,
                }
            end
        end
    end

    local i, last_delta = 1, nil
    for k = 2, n do
        local delta = pw:byte(k) - pw:byte(k - 1)
        if last_delta == nil then
            last_delta = delta
        end
        if delta ~= last_delta then
            local j = k - 1
            update(i, j, last_delta)
            i = j
            last_delta = delta
        end
    end
    update(i, n, last_delta)
end

local function regex_year_matches(pw, out)
    for i = 1, #pw - 3 do
        local token = pw:sub(i, i + 3)
        if token:match("^19%d%d$") or token:match("^20[01]%d$") then
            out[#out + 1] = {
                pattern = "regex", i = i, j = i + 3,
                token = token, regex_name = "recent_year", year = tonumber(token),
            }
        end
    end
end

---------------------------------------------------------------------------
-- dates
---------------------------------------------------------------------------

local function two_to_four_digit_year(year)
    if year > 99 then return year end
    if year > 50 then return year + 1900 end
    return year + 2000
end

local function map_ints_to_dm(ints)
    local candidates = { { ints[1], ints[2] }, { ints[2], ints[1] } }
    for _, dm in ipairs(candidates) do
        local d, m = dm[1], dm[2]
        if d >= 1 and d <= 31 and m >= 1 and m <= 12 then
            return { day = d, month = m }
        end
    end
end

local function map_ints_to_dmy(ints)
    if ints[2] > 31 or ints[2] <= 0 then return nil end
    local over_12, over_31, under_1 = 0, 0, 0
    for _, v in ipairs(ints) do
        if (v > 99 and v < DATE_MIN_YEAR) or v > DATE_MAX_YEAR then return nil end
        if v > 31 then over_31 = over_31 + 1 end
        if v > 12 then over_12 = over_12 + 1 end
        if v <= 0 then under_1 = under_1 + 1 end
    end
    if over_31 >= 2 or over_12 == 3 or under_1 >= 2 then return nil end

    local splits = {
        { ints[3], { ints[1], ints[2] } },
        { ints[1], { ints[2], ints[3] } },
    }
    for _, split in ipairs(splits) do
        local y, rest = split[1], split[2]
        if y >= DATE_MIN_YEAR and y <= DATE_MAX_YEAR then
            local dm = map_ints_to_dm(rest)
            if dm then
                return { year = y, month = dm.month, day = dm.day }
            end
            return nil
        end
    end
    for _, split in ipairs(splits) do
        local y, rest = split[1], split[2]
        local dm = map_ints_to_dm(rest)
        if dm then
            return { year = two_to_four_digit_year(y), month = dm.month, day = dm.day }
        end
    end
end

local function date_matches(pw, out)
    local n = #pw
    local found = {}

    -- no separators: 4-8 digits
    for i = 1, n - 3 do
        local jmax = i + 7
        if jmax > n then jmax = n end
        for j = i + 3, jmax do
            local token = pw:sub(i, j)
            if token:match("^%d+$") then
                local candidates = {}
                for _, split in ipairs(DATE_SPLITS[#token] or {}) do
                    local dmy = map_ints_to_dmy({
                        tonumber(token:sub(1, split[1])),
                        tonumber(token:sub(split[1] + 1, split[2])),
                        tonumber(token:sub(split[2] + 1)),
                    })
                    if dmy then candidates[#candidates + 1] = dmy end
                end
                if #candidates > 0 then
                    local best = candidates[1]
                    local best_d = math.abs(best.year - REFERENCE_YEAR)
                    for k = 2, #candidates do
                        local d = math.abs(candidates[k].year - REFERENCE_YEAR)
                        if d < best_d then best, best_d = candidates[k], d end
                    end
                    found[#found + 1] = {
                        pattern = "date", i = i, j = j, token = token,
                        separator = "", year = best.year,
                        month = best.month, day = best.day,
                    }
                end
            end
        end
    end

    -- with separators: 6-10 chars
    local SEP = "[%s/%%\\_.%-]"
    for i = 1, n - 5 do
        local jmax = i + 9
        if jmax > n then jmax = n end
        for j = i + 5, jmax do
            local token = pw:sub(i, j)
            local a, sep, b, sep2, c =
                token:match("^(%d%d?%d?%d?)(" .. SEP .. ")(%d%d?)(" .. SEP .. ")(%d%d?%d?%d?)$")
            if a and b and c and sep == sep2 then
                local dmy = map_ints_to_dmy({
                    tonumber(a), tonumber(b), tonumber(c),
                })
                if dmy then
                    found[#found + 1] = {
                        pattern = "date", i = i, j = j, token = token,
                        separator = sep, year = dmy.year,
                        month = dmy.month, day = dmy.day,
                    }
                end
            end
        end
    end

    -- drop matches that are strict substrings of other matches
    for _, m in ipairs(found) do
        local is_sub = false
        for _, other in ipairs(found) do
            if other ~= m and other.i <= m.i and other.j >= m.j then
                is_sub = true
                break
            end
        end
        if not is_sub then
            out[#out + 1] = m
        end
    end
end

---------------------------------------------------------------------------
-- scoring
---------------------------------------------------------------------------

local estimate_guesses  -- forward declaration

local function bruteforce_guesses(m)
    local tl = #m.token
    local guesses = BRUTEFORCE_CARDINALITY ^ tl
    if tl > 300 then guesses = 1e300 end
    local min_guesses = (tl == 1) and (MIN_SUBMATCH_GUESSES_SINGLE_CHAR + 1)
        or (MIN_SUBMATCH_GUESSES_MULTI_CHAR + 1)
    return guesses > min_guesses and guesses or min_guesses
end

local function uppercase_variations(m)
    local word = m.token
    if word == word:lower() then return 1 end
    if word:match("^%u[^%u]+$") or word:match("^[^%u]+%u$") or word:match("^[^%l]+$") then
        return 2
    end
    local U, L = 0, 0
    for i = 1, #word do
        local c = word:sub(i, i)
        if c:match("%u") then U = U + 1
        elseif c:match("%l") then L = L + 1 end
    end
    local v = 0
    for i = 1, math.min(U, L) do
        v = v + nCk(U + L, i)
    end
    return v
end

local function l33t_variations(m)
    if not m.l33t then return 1 end
    local variations = 1
    local token = m.token:lower()
    for subbed, letter in pairs(m.sub) do
        local S, U = 0, 0
        for i = 1, #token do
            local c = token:sub(i, i)
            if c == subbed then S = S + 1
            elseif c == letter then U = U + 1 end
        end
        if S == 0 or U == 0 then
            variations = variations * 2
        else
            local p = math.min(U, S)
            local possibilities = 0
            for i = 1, p do
                possibilities = possibilities + nCk(U + S, i)
            end
            variations = variations * possibilities
        end
    end
    return variations
end

local function dictionary_guesses(m)
    local reversed_variations = m.reversed and 2 or 1
    return m.rank * uppercase_variations(m) * l33t_variations(m) * reversed_variations
end

local function sequence_guesses(m)
    local first = m.token:sub(1, 1)
    local base
    if first == "a" or first == "A" or first == "z" or first == "Z"
        or first == "0" or first == "1" or first == "9" then
        base = 4
    elseif first:match("%d") then
        base = 10
    else
        base = 26
    end
    if not m.ascending then
        base = base * 2
    end
    return base * #m.token
end

local function regex_guesses(m)
    if m.regex_name == "recent_year" then
        local space = math.abs(m.year - REFERENCE_YEAR)
        return math.max(space, MIN_YEAR_SPACE)
    end
    return 1
end

local function date_guesses(m)
    local space = math.max(math.abs(m.year - REFERENCE_YEAR), MIN_YEAR_SPACE)
    local guesses = space * 365
    if m.separator ~= "" then
        guesses = guesses * 4
    end
    return guesses
end

local function spatial_guesses(m)
    local s, d = KEY_START, KEY_DEGREE
    local guesses = 0
    local L, t = #m.token, m.turns
    for i = 2, L do
        local possible_turns = math.min(t, i - 1) + 1
        for j = 1, possible_turns - 1 do
            guesses = guesses + nCk(i - 1, j - 1) * s * (d ^ j)
        end
    end
    local S = m.shifted_count or 0
    if S > 0 then
        local U = L - S
        if S == 0 or U == 0 then
            guesses = guesses * 2
        else
            local variations = 0
            for i = 1, math.min(S, U) do
                variations = variations + nCk(S + U, i)
            end
            guesses = guesses * variations
        end
    end
    return guesses
end

local function repeat_guesses(m)
    return m.base_guesses * m.repeat_count
end

local SCORERS = {
    bruteforce = bruteforce_guesses,
    dictionary = dictionary_guesses,
    spatial = spatial_guesses,
    ["repeat"] = repeat_guesses,
    sequence = sequence_guesses,
    regex = regex_guesses,
    date = date_guesses,
}

estimate_guesses = function(m, password)
    if m.guesses then return m.guesses end
    local tl = #m.token
    local min_guesses = 1
    if tl < #password then
        if tl == 1 then
            min_guesses = MIN_SUBMATCH_GUESSES_SINGLE_CHAR
        else
            min_guesses = MIN_SUBMATCH_GUESSES_MULTI_CHAR
        end
    end
    local g = SCORERS[m.pattern](m)
    if g < min_guesses then g = min_guesses end
    m.guesses = g
    return g
end

---------------------------------------------------------------------------
-- the DP: most guessable match sequence
---------------------------------------------------------------------------

local most_guessable  -- forward declaration (repeat matching re-enters it)

local function omnimatch(pw, depth)
    local matches = {}
    add_dictionary_matches(pw, matches)
    reverse_dictionary_matches(pw, matches)
    l33t_matches(pw, matches)
    spatial_matches(pw, matches)
    sequence_matches(pw, matches)
    regex_year_matches(pw, matches)
    date_matches(pw, matches)

    if depth < 2 then
        -- repeats need the base token scored, which re-enters this function
        local n = #pw
        local i = 1
        while i <= n - 1 do
            local best
            local limit = math.floor((n - i + 1) / 2)
            for unit_len = 1, limit do
                local unit = pw:sub(i, i + unit_len - 1)
                local count = 1
                while i + unit_len * (count + 1) - 1 <= n
                    and pw:sub(i + unit_len * count, i + unit_len * (count + 1) - 1) == unit do
                    count = count + 1
                end
                if count >= 2 then
                    local total = unit_len * count
                    if not best or total > best.total then
                        best = { total = total, unit = unit, count = count }
                    end
                end
            end
            if best then
                local base = most_guessable(best.unit, omnimatch(best.unit, depth + 1))
                matches[#matches + 1] = {
                    pattern = "repeat", i = i, j = i + best.total - 1,
                    token = pw:sub(i, i + best.total - 1),
                    base_token = best.unit,
                    base_guesses = base,
                    repeat_count = best.count,
                }
                i = i + best.total
            else
                i = i + 1
            end
        end
    end

    return matches
end

most_guessable = function(password, matches)
    local n = #password
    if n == 0 then return 1 end

    local by_j = {}
    for k = 1, n do by_j[k] = {} end
    for _, m in ipairs(matches) do
        if m.j <= n and m.i >= 1 then
            local list = by_j[m.j]
            list[#list + 1] = m
        end
    end
    for k = 1, n do
        table.sort(by_j[k], function(a, b) return a.i < b.i end)
    end

    local opt_m, opt_pi, opt_g = {}, {}, {}
    for k = 1, n do
        opt_m[k], opt_pi[k], opt_g[k] = {}, {}, {}
    end

    local function update(m, l)
        local k = m.j
        local pi = estimate_guesses(m, password)
        if l > 1 then
            local prev = opt_pi[m.i - 1]
            if not prev or not prev[l - 1] then return end
            pi = pi * prev[l - 1]
        end
        local g = factorial(l) * pi + MIN_GUESSES_BEFORE_GROWING_SEQUENCE ^ (l - 1)
        for competing_l, competing_g in pairs(opt_g[k]) do
            if competing_l <= l and competing_g <= g then
                return
            end
        end
        opt_g[k][l] = g
        opt_m[k][l] = m
        opt_pi[k][l] = pi
    end

    local function bruteforce_match(i, j)
        return { pattern = "bruteforce", i = i, j = j, token = password:sub(i, j) }
    end

    local function bruteforce_update(k)
        update(bruteforce_match(1, k), 1)
        for i = 2, k do
            local m = bruteforce_match(i, k)
            for l, last_m in pairs(opt_m[i - 1]) do
                if last_m.pattern ~= "bruteforce" then
                    update(m, l + 1)
                end
            end
        end
    end

    for k = 1, n do
        for _, m in ipairs(by_j[k]) do
            if m.i > 1 then
                for l in pairs(opt_m[m.i - 1]) do
                    update(m, l + 1)
                end
            else
                update(m, 1)
            end
        end
        bruteforce_update(k)
    end

    local best_l, best_g = nil, math.huge
    for l, g in pairs(opt_g[n]) do
        if g < best_g then best_l, best_g = l, g end
    end
    if not best_l then return 1e300, {} end

    -- walk back through the optimal table to rebuild the chosen sequence
    local sequence = {}
    local k, l = n, best_l
    while k >= 1 and l >= 1 do
        local m = opt_m[k][l]
        if not m then break end
        table.insert(sequence, 1, m)
        k = m.i - 1
        l = l - 1
    end

    return best_g, sequence
end

---------------------------------------------------------------------------
-- public API
---------------------------------------------------------------------------

function M.guesses(password)
    if password == nil or password == "" then return 1 end
    local g = most_guessable(password, omnimatch(password, 1))
    return g
end

local BINS = { 1e3, 1e6, 1e8, 1e10 }

local function bin(guesses)
    for i = 1, 4 do
        if guesses < BINS[i] then return i - 1 end
    end
    return 4
end

function M.score(password)
    return bin(M.guesses(password))
end

-- Full analysis: { guesses=..., score=..., sequence={...}, matches={...} }
-- sequence is the optimal match sequence; matches is every match found,
-- which is what the "why was this rejected" message is built from.
function M.analyze(password)
    if password == nil or password == "" then
        return { guesses = 1, score = 0, sequence = {}, matches = {} }
    end
    local all = omnimatch(password, 1)
    local guesses, sequence = most_guessable(password, all)
    return { guesses = guesses, score = bin(guesses), sequence = sequence, matches = all }
end

return M
