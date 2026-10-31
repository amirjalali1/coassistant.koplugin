-- koassistant/request/privacy_gates.lua: the one place that decides whether a
-- kind of the reader's data may go into a request (data_access_picture.md 4.2,
-- 4.5; slices 1 and 2). A table of layers against expected states, the two
-- columns, the once-allowance, `needs`, the stamp reader, the dispatch
-- provider's precedence, and the guard: no other file compares a privacy
-- switch or walks trusted_providers itself (`-- raw-gate: <reason>` escapes a
-- display-only read).
--
-- Run: lua tests/unit/test_privacy_gates.lua  (or lua tests/run_tests.lua --unit)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
    return plugin_dir
end
local plugin_dir = setupPaths()
require("mock_koreader")
local TestRunner = require("test_runner"):new()
local Gates = require("koassistant.request.privacy_gates")

local function eq(got, want, msg)
    TestRunner:assertTrue(got == want, (msg or "") .. ": expected " .. tostring(want) .. ", got " .. tostring(got))
end

print("\n  [the layers]")

TestRunner:test("nothing set: every kind asks, except reading position and nearby text, which allow", function()
    for _idx, kind in ipairs(Gates.KINDS) do
        local state, layer = Gates.resolve(kind, { features = {}, provider = "openai" })
        if kind == "position" or kind == "nearby_text" then
            eq(state, "allow", kind)
        else
            eq(state, "ask", kind)
        end
        eq(layer, "global", kind .. " layer")
    end
    eq(Gates.resolve("book_text", nil), "ask", "no context asks")
    TestRunner:assertFalse(Gates.allows("book_text", nil), "no context: not allowed")
    TestRunner:assertTrue(Gates.usable("book_text", nil), "no context: usable (the question comes at the run)")
end)

TestRunner:test("each global switch: true allows, \"never\" refuses, false or unset asks, and only its own kind", function()
    for kind, key in pairs(Gates.GLOBAL_KEY) do
        if kind ~= "position" and kind ~= "nearby_text" then
            eq(Gates.resolve(kind, { features = { [key] = true } }), "allow", key .. " true")
            eq(Gates.resolve(kind, { features = { [key] = "never" } }), "never", key .. " never")
            eq(Gates.resolve(kind, { features = { [key] = false } }), "ask", key .. " false")
            for _idx, other in ipairs(Gates.KINDS) do
                if other ~= kind and other ~= "position" and other ~= "nearby_text"
                        and not (kind == "annotations" and other == "highlights")
                        and not (kind == "highlights" and other == "annotations") then
                    eq(Gates.resolve(other, { features = { [key] = true } }), "ask", key .. " leaves " .. other)
                    eq(Gates.resolve(other, { features = { [key] = "never" } }), "ask", key .. " never leaves " .. other)
                end
            end
        end
    end
end)

TestRunner:test("the pairing: allowing notes allows highlights; Never for highlights is Never for notes", function()
    eq(Gates.resolve("highlights", { features = { enable_annotations_sharing = true } }), "allow", "notes allow highlights")
    eq(Gates.resolve("annotations", { features = { enable_highlights_sharing = true } }), "ask", "not the reverse")
    eq(Gates.resolve("annotations", { features = { enable_highlights_sharing = "never" } }), "never", "highlights never = notes never")
    eq(Gates.resolve("annotations", { features = { enable_highlights_sharing = "never", enable_annotations_sharing = true } }),
        "never", "even when notes say allow")
    eq(Gates.resolve("highlights", { features = { enable_highlights_sharing = "never", enable_annotations_sharing = true } }),
        "never", "a highlights Never is not undone by notes")
    eq(Gates.resolve("highlights", { features = { enable_annotations_sharing = "never" } }), "ask", "notes never leaves highlights asking")
end)

TestRunner:test("reading position is two-valued: on unless off, never asked", function()
    eq(Gates.resolve("position", { features = { enable_basic_stats = false } }), "never", "off")
    eq(Gates.resolve("position", { features = { enable_basic_stats = "never" } }), "never", "never spelled out")
    eq(Gates.resolve("position", { features = { enable_basic_stats = "no" } }), "allow", "anything but off is on")
    eq(Gates.resolve("position", { features = { enable_basic_stats = true } }), "allow", "on")
end)

TestRunner:test("the eighth kind, text around what you tap: allow unless set, its own three values", function()
    eq(Gates.resolve("nearby_text", { features = {} }), "allow", "default")
    eq(Gates.resolve("nearby_text", { features = { nearby_text_sharing = "ask" } }), "ask", "ask")
    eq(Gates.resolve("nearby_text", { features = { nearby_text_sharing = "never" } }), "never", "never")
    eq(Gates.resolve("nearby_text", { features = { nearby_text_sharing = "never", enable_book_text_extraction = true } }),
        "never", "independent of book text")
    eq(Gates.resolve("book_text", { features = { nearby_text_sharing = "never", enable_book_text_extraction = true } }),
        "allow", "and the other way")
    eq(Gates.resolve("nearby_text", { features = {}, book = { nearby_text = false } }), "never", "a book's own value")
end)

print("\n  [the two columns]")

TestRunner:test("a trusted provider reads the trusted column: allow by default, its own Ask or Never", function()
    local f = { trusted_providers = { "ollama" } }
    for _idx, kind in ipairs(Gates.KINDS) do
        local state, layer = Gates.resolve(kind, { features = f, provider = "ollama" })
        eq(state, "allow", kind)
        eq(layer, "trusted", kind .. " layer")
    end
    eq(Gates.resolve("book_text", { features = f, provider = "openai" }), "ask", "another provider asks")
    eq(Gates.resolve("book_text", { features = f }), "ask", "no provider: the global column")
    f.trusted_book_text = "never"
    eq(Gates.resolve("book_text", { features = f, provider = "ollama" }), "never", "the trusted column's Never")
    eq(Gates.resolve("book_text", { features = f, provider = "openai" }), "ask", "the global column unchanged")
    f.trusted_notebook = "ask"
    eq(Gates.resolve("notebook", { features = f, provider = "ollama" }), "ask", "the trusted column's Ask")
    f.trusted_position = false
    eq(Gates.resolve("position", { features = f, provider = "ollama" }), "never", "trusted position off")
    TestRunner:assertFalse(Gates.isTrusted({ trusted_providers = "ollama" }, "ollama"), "a list, never a string")
    TestRunner:assertFalse(Gates.isTrusted(nil, "ollama"), "no features")
end)

TestRunner:test("the columns do not short-circuit each other: a global Never does not reach a trusted provider, nor the reverse", function()
    local f = { trusted_providers = { "ollama" }, enable_highlights_sharing = "never" }
    eq(Gates.resolve("highlights", { features = f, provider = "ollama" }), "allow", "trusted column rules for ollama")
    eq(Gates.resolve("highlights", { features = f, provider = "openai" }), "never", "global column for openai")
    f.trusted_annotations = "allow"
    f.trusted_highlights = "never"
    eq(Gates.resolve("annotations", { features = f, provider = "ollama" }), "never", "the pairing inside the trusted column")
end)

print("\n  [the book and the run]")

TestRunner:test("the book's own value: a Never beats trust and the once, an Allow needs no switch", function()
    local f = { trusted_providers = { "ollama" }, enable_book_text_extraction = true }
    local state, layer = Gates.resolve("book_text", { features = f, provider = "ollama", book = { book_text = false },
        once = { book_text = true } })
    eq(state, "never", "deny"); eq(layer, "book", "deny layer")
    state, layer = Gates.resolve("notebook", { features = {}, provider = "openai", book = { notebook = true } })
    eq(state, "allow", "allow"); eq(layer, "book", "allow layer")
    state, layer = Gates.resolve("notebook", { features = { enable_notebook_sharing = "never" }, book = { notebook = true } })
    eq(state, "allow", "a book's Allow over a global Never"); eq(layer, "book", "its layer")
    eq(Gates.resolve("highlights", { features = f, provider = "ollama", book = { notebook = false } }), "allow",
        "another kind's deny is not this kind's")
    TestRunner:assertTrue(Gates.allows("notebook", { features = {}, book = { notebook = true } }), "allows: yes")
    TestRunner:assertFalse(Gates.allows("notebook", { features = { enable_notebook_sharing = true }, book = { notebook = false } }), "allows: no")
    TestRunner:assertFalse(Gates.usable("notebook", { features = {}, book = { notebook = false } }), "usable: not under Never")
    TestRunner:assertTrue(Gates.usable("notebook", { features = {} }), "usable: under Ask")
end)

TestRunner:test("an allowance for this run turns Ask into allow (layer once), for that book or for every book", function()
    local f = {}
    Gates.grantOnce(f, "/b/one.epub", { "highlights", "book_text" })
    eq(Gates.onceFor(f, "/b/one.epub").highlights, true, "granted")
    TestRunner:assertTrue(Gates.onceFor(f, "/b/two.epub") == nil, "another book: nothing")
    TestRunner:assertTrue(Gates.onceFor(f, nil) == nil, "no book named: a book-bound record does not apply")
    local state, layer = Gates.resolve("highlights", { features = f, once = Gates.onceFor(f, "/b/one.epub") })
    eq(state, "allow", "once allows"); eq(layer, "once", "once layer")
    eq(Gates.resolve("notebook", { features = f, once = Gates.onceFor(f, "/b/one.epub") }), "ask", "only the granted kinds")
    Gates.grantOnce(f, "/b/one.epub", { notebook = true })
    eq(Gates.onceFor(f, "/b/one.epub").notebook, true, "merged into the same book's record")
    eq(Gates.onceFor(f, "/b/one.epub").highlights, true, "earlier kinds kept")
    Gates.grantOnce(f, nil, { book_list = true })
    eq(Gates.onceFor(f, "/any/book.epub").book_list, true, "a record without a book covers every book")
    eq(Gates.onceFor(f, nil).book_list, true, "and no book")
    TestRunner:assertTrue(Gates.onceFor(f, "/b/one.epub").highlights == nil, "a new book-less record replaced the old")
    TestRunner:assertTrue(Gates.onceFor({ _data_once = "junk" }, nil) == nil, "a broken record is nothing")
    local ctx = Gates.context(f, "openai", { path = "/x.epub", book = { notebook = true } })
    eq(ctx.book.notebook, true, "context keeps a given book")
    eq(ctx.once.book_list, true, "context carries the once set")
end)

TestRunner:test("summary lists every kind with its state and layer", function()
    local s = Gates.summary({ features = { enable_notebook_sharing = true }, provider = "openai", book = { book_text = false } })
    local n = 0
    for _idx, kind in ipairs(Gates.KINDS) do
        TestRunner:assertTrue(s[kind] and s[kind].state and s[kind].layer, kind .. " present")
        n = n + 1
    end
    eq(n, #Gates.KINDS, "count")
    eq(s.notebook.state, "allow", "notebook"); eq(s.book_text.state, "never", "text"); eq(s.book_text.layer, "book", "text layer")
    eq(s.highlights.state, "ask", "highlights ask")
end)

print("\n  [what a run needs]")

TestRunner:test("needs: the flags, the requirements, the picked source, the stored material", function()
    local ctx = { features = { enable_highlights_sharing = true } }
    local function kinds(list)
        local out = {}
        for _idx, n in ipairs(list) do out[n.kind] = n end
        return out
    end
    -- a notes action: highlights required (the pairing), notes optional
    local n = kinds(Gates.needs({ use_highlights = true, use_annotations = true, requires = { "highlights" } }, ctx))
    TestRunner:assertTrue(n.highlights and n.highlights.required, "highlights required")
    TestRunner:assertTrue(n.annotations and not n.annotations.required, "notes optional")
    eq(n.highlights.state, "allow", "highlights state"); eq(n.annotations.state, "ask", "notes state")
    TestRunner:assertTrue(n.book_text == nil and n.notebook == nil, "nothing else")
    -- X-Ray: text required by declaration
    n = kinds(Gates.needs({ use_book_text = true, requires = { "book_text" }, prompt = "{book_text_section}" }, ctx))
    TestRunner:assertTrue(n.book_text and n.book_text.required, "text required")
    -- a source popup pick: AI knowledge wants nothing; text picked = required; summary = its stamps
    eq(#Gates.needs({ use_book_text = true, prompt = "{document_context_section}" }, ctx, { source = "ai_knowledge" }), 0, "AI knowledge")
    n = kinds(Gates.needs({ use_book_text = true, prompt = "{document_context_section}" }, ctx, { source = "full_text" }))
    TestRunner:assertTrue(n.book_text and n.book_text.required, "a picked text source is required")
    n = kinds(Gates.needs({ use_book_text = true, use_summary_cache = true, prompt = "{document_context_section}" }, ctx,
        { source = "summary", stamps = { summary = { used_book_text = true } } }))
    TestRunner:assertTrue(n.book_text and not n.book_text.required, "a summary built from text asks for text, optional")
    n = kinds(Gates.needs({ use_book_text = true, use_summary_cache = true, prompt = "{document_context_section}" }, ctx,
        { source = "summary", stamps = { summary = { used_book_text = false } } }))
    TestRunner:assertTrue(n.book_text == nil, "a summary built without text asks nothing")
    -- a flag without a placeholder asks nothing; a placeholder with the flag does
    eq(#Gates.needs({ use_book_text = true, prompt = "plain" }, ctx), 0, "no text placeholder")
    n = kinds(Gates.needs({ use_book_text = true, prompt = "{full_document_section}" }, ctx))
    TestRunner:assertTrue(n.book_text and not n.book_text.required, "optional text")
    -- the library kinds, nearby text, the X-Ray cache's stamps
    n = kinds(Gates.needs({ use_library = true, use_advanced_stats = true, requires = { "library" } }, ctx))
    TestRunner:assertTrue(n.book_list and n.book_list.required and n.habits and not n.habits.required, "library kinds")
    n = kinds(Gates.needs({ use_notebook = true }, ctx, { nearby = true }))
    TestRunner:assertTrue(n.notebook and n.nearby_text, "notebook and nearby")
    eq(n.nearby_text.state, "allow", "nearby allows by default")
    n = kinds(Gates.needs({ use_xray_cache = true }, ctx, { stamps = { xray = { used_highlights = true, used_annotations = true } } }))
    TestRunner:assertTrue(n.book_text and n.highlights and n.annotations, "an X-Ray's stamps")
    -- position is never asked
    eq(#Gates.needs({ use_reading_progress = true }, ctx), 0, "position never asked")
    -- order follows KINDS
    local list = Gates.needs({ use_notebook = true, use_highlights = true, use_book_text = true, prompt = "{book_text}" }, ctx)
    eq(list[1].kind, "book_text", "order 1"); eq(list[2].kind, "highlights", "order 2"); eq(list[3].kind, "notebook", "order 3")
end)

print("\n  [the stamps]")

TestRunner:test("stampedKinds: legacy means text; the old annotations stamp meant highlights", function()
    local k = Gates.stampedKinds({})
    TestRunner:assertTrue(k.book_text and not k.highlights and not k.annotations, "no stamps: text only")
    k = Gates.stampedKinds({ used_book_text = false })
    TestRunner:assertFalse(k.book_text, "built without text")
    k = Gates.stampedKinds({ used_annotations = true })
    TestRunner:assertTrue(k.highlights and not k.annotations, "legacy annotations stamp = highlights")
    k = Gates.stampedKinds({ used_highlights = true, used_annotations = true })
    TestRunner:assertTrue(k.highlights and k.annotations, "both tracked")
    k = Gates.stampedKinds({ used_highlights = false, used_annotations = true })
    TestRunner:assertTrue(not k.highlights and k.annotations, "notes without highlights")
    TestRunner:assertTrue(Gates.stampedKinds(nil).book_text, "nil entry: legacy")
end)

print("\n  [the dispatch provider]")

TestRunner:test("precedence: a run option's model, the action's pin, a pending pick, the Quick preset, the base", function()
    local quick = function(features, base) return { provider = "groq", model = "fast" } end
    local act = { accept_quick_answer = true }
    eq(Gates.dispatchProvider({ _run_variant = { provider = "xai" }, _session_model = { provider = "mistral" } }, act, "openai", quick),
        "xai", "run option first")
    eq(Gates.dispatchProvider({ _session_model = { provider = "mistral" } }, { provider = "deepseek" }, "deepseek", quick),
        "deepseek", "a pinned action keeps its base")
    eq(Gates.dispatchProvider({ _session_model = { provider = "mistral" }, _session_quick_answer = true }, act, "openai", quick),
        "mistral", "a pending pick beats the Quick preset")
    eq(Gates.dispatchProvider({ _session_quick_answer = true }, act, "openai", quick), "groq", "the Quick preset's model")
    eq(Gates.dispatchProvider({ _session_quick_answer = true }, {}, "openai", quick), "openai",
        "Quick only for an action that accepts it")
    eq(Gates.dispatchProvider({ _quick_answer_active = true }, act, "openai", function() return nil end), "openai",
        "no preset model: the base")
    eq(Gates.dispatchProvider({ use_action_tiers = false }, { model_tier = "fast" }, "openai", quick), "openai",
        "tier hints off: the base")
    eq(Gates.dispatchProvider(nil, nil, "openai", quick), "openai", "nothing: the base")
end)

print("\n  [the book helpers]")

TestRunner:test("overridesOf and bookOverrides never throw and read as none when nothing is known", function()
    TestRunner:assertTrue(Gates.overridesOf(nil) == nil, "no settings")
    TestRunner:assertTrue(Gates.overridesOf(42) == nil, "not a settings object")
    TestRunner:assertTrue(Gates.bookOverrides("/nowhere/such.epub", nil) == nil, "no such book")
end)

print("\n  [the presets]")

TestRunner:test("the default preset clears every value: each kind reads the default it ships with (B498, B499)", function()
    local f = { enable_book_text_extraction = true, enable_highlights_sharing = "never", nearby_text_sharing = "ask",
        enable_basic_stats = false, enable_library_scanning = true, trusted_book_text = "never",
        trusted_providers = { "ollama" } }
    Gates.applyPreset(f, "default")
    for _idx, kind in ipairs(Gates.KINDS) do
        eq(f[Gates.GLOBAL_KEY[kind]], nil, kind .. " cleared")
        local want = (kind == "position" or kind == "nearby_text") and "allow" or "ask"
        eq(Gates.resolve(kind, { features = f, provider = "openai" }), want, kind .. " reads its default")
    end
    eq(f.trusted_book_text, nil, "the trusted column goes back to its default too (B499)")
    eq(Gates.resolve("book_text", { features = f, provider = "ollama" }), "allow", "trusted: Allow again")
    eq(f.trusted_providers[1], "ollama", "the trusted list is kept")
end)

TestRunner:test("presetOf names the preset the values match, or nil for Custom (B499)", function()
    eq(Gates.presetOf({}), "default", "nothing set: Default")
    eq(Gates.presetOf({ enable_book_text_extraction = false, nearby_text_sharing = "allow" }), "default",
        "explicit default values still read Default")
    eq(Gates.presetOf(Gates.applyPreset({}, "full")), "full", "Allow everything")
    eq(Gates.presetOf(Gates.applyPreset({}, "minimal")), "minimal", "Block everything")
    eq(Gates.presetOf(Gates.applyPreset({ trusted_book_text = "never" }, "minimal")), "minimal",
        "Block everything leaves the trusted column alone and still matches")
    eq(Gates.presetOf({ trusted_book_text = "never" }), nil, "a trusted value off its default: Custom")
    eq(Gates.presetOf({ enable_book_text_extraction = true }), nil, "one kind allowed: Custom")
end)

TestRunner:test("a stored summary is asked for only where the run sends it", function()
    local action = { use_book_text = true, use_summary_cache = true, prompt = "{document_context_section}" }
    local stamps = { summary = { used_book_text = true } }
    local ctx = { features = {}, provider = "openai" }
    local function asksText(source)
        for _idx, n in ipairs(Gates.needs(action, ctx, { source = source, stamps = stamps })) do
            if n.kind == "book_text" then return true end
        end
        return false
    end
    TestRunner:assertFalse(asksText("ai_knowledge"), "AI knowledge: no text, no summary")
    TestRunner:assertTrue(asksText("summary"), "the summary source sends the text-built summary")
    TestRunner:assertTrue(asksText(nil), "no source pick: the action reads its summary")
end)

TestRunner:test("globalState reads a kind's own value for all books, before the pairing", function()
    eq(Gates.globalState({ enable_annotations_sharing = true }, "highlights"), "ask", "own value, not paired")
    eq(Gates.columnState({ enable_annotations_sharing = true }, "highlights", false), "allow", "the column pairs")
    eq(Gates.globalState({ nearby_text_sharing = "never" }, "nearby_text"), "never")
    eq(Gates.globalState({}, "position"), "allow")
end)

TestRunner:test("Allow everything and Block everything set every kind; an unknown preset nothing", function()
    local f = Gates.applyPreset({}, "full")
    for _idx, kind in ipairs(Gates.KINDS) do
        eq(Gates.resolve(kind, { features = f, provider = "openai" }), "allow", "full: " .. kind)
    end
    f = Gates.applyPreset({}, "minimal")
    for _idx, kind in ipairs(Gates.KINDS) do
        eq(Gates.resolve(kind, { features = f, provider = "openai" }), "never", "minimal: " .. kind)
    end
    eq(f.enable_basic_stats, false, "minimal: reading position off")
    f = Gates.applyPreset({ enable_book_text_extraction = true }, "everything")
    eq(f.enable_book_text_extraction, true, "an unknown preset changes nothing")
end)

print("\n  [the guard]")

TestRunner:test("no other file compares a privacy switch or walks trusted_providers itself", function()
    local keys = {}
    for _kind, key in pairs(Gates.GLOBAL_KEY) do keys[#keys + 1] = key end
    for _kind, key in pairs(Gates.TRUSTED_KEY) do keys[#keys + 1] = key end
    local p = io.popen('cd "' .. plugin_dir .. '" && ls main.lua && find koassistant -name "*.lua" | LC_ALL=C sort')
    local files = {}
    for line in p:lines() do files[#files + 1] = line end
    p:close()
    TestRunner:assertTrue(#files > 100, "the tree was listed")
    local hits = {}
    for _idx, rel in ipairs(files) do
        if rel ~= "koassistant/request/privacy_gates.lua" then
            local n = 0
            for line in io.lines(plugin_dir .. "/" .. rel) do
                n = n + 1
                if not line:find("-- raw-gate:", 1, true) and not line:match("^%s*%-%-") then
                    local bad = line:find("ipairs%([^)]*trusted_providers")
                    for _k, key in ipairs(keys) do
                        if line:find(key .. "%s*[=~]=%s*true") or line:find(key .. "%s*[=~]=%s*false")
                                or line:find(key .. '%s*[=~]=%s*"never"') or line:find(key .. '%s*[=~]=%s*"allow"')
                                or line:find(key .. '%s*[=~]=%s*"ask"') then
                            bad = true
                        end
                    end
                    if bad then hits[#hits + 1] = rel .. ":" .. n .. ": " .. line:gsub("^%s+", "") end
                end
            end
        end
    end
    TestRunner:assertTrue(#hits == 0, "raw gate reads:\n      " .. table.concat(hits, "\n      "))
end)

TestRunner:test("a gate context built by hand carries the run's allowance (once) or is marked standing-only", function()
    -- Allow once lands as _data_once on the request's config; a ctx literal
    -- that names a provider but no `once =` cannot see it (2026-10-15: four
    -- such sites made Allow once a no-op on the first desktop try). A site
    -- that needs a standing Allow says so: `-- standing-only: <reason>`.
    -- Position is never asked, usable() and summary() do not enforce.
    local p = io.popen('cd "' .. plugin_dir .. '" && ls main.lua && find koassistant -name "*.lua" | LC_ALL=C sort')
    local files = {}
    for line in p:lines() do files[#files + 1] = line end
    p:close()
    local skip = { ["koassistant/request/privacy_gates.lua"] = true, ["koassistant/ui/data_access.lua"] = true }
    local hits, literals = {}, 0
    for _idx, rel in ipairs(files) do
        if not skip[rel] then
            local lines = {}
            for line in io.lines(plugin_dir .. "/" .. rel) do lines[#lines + 1] = line end
            for i, line in ipairs(lines) do
                local at = line:find("{%s*features%s*=")
                if at and not line:match("^%s*%-%-") then
                    local depth, j, pos, text = 0, i, at, ""
                    repeat
                        local chunk = lines[j]:sub(pos)
                        for c in chunk:gmatch("[{}]") do depth = depth + (c == "{" and 1 or -1) end
                        text = text .. chunk .. "\n"
                        j = j + 1
                        pos = 1
                    until depth <= 0 or j > #lines
                    if text:find("provider%s*=") then
                        literals = literals + 1
                        local window = table.concat(lines, "\n", math.max(1, i - 3), math.min(#lines, j))
                        if not (text:find("once%s*=") or window:find("usable%(") or window:find('"position"')
                                or window:find("%.summary%(") or window:find("-- standing-only:", 1, true)) then
                            hits[#hits + 1] = rel .. ":" .. i .. ": " .. line:gsub("^%s+", "")
                        end
                    end
                end
            end
        end
    end
    TestRunner:assertTrue(literals >= 6, "the gate literals were found (" .. literals .. ")")
    TestRunner:assertTrue(#hits == 0, "gate contexts without the run's allowance:\n      " .. table.concat(hits, "\n      "))
end)

TestRunner:test("the dispatch gather judges on the request's own config, never the source", function()
    -- handlePredefinedPrompt consumes _data_once from the source config right
    -- after temp_config is made; everything the gather reads for the gates
    -- (the extractor's settings, the per-book loop, the cache re-check, the
    -- library branch) must come from temp_config.features.
    local src = io.open(plugin_dir .. "/koassistant/ui/dialogs.lua"):read("*a")
    TestRunner:assertTrue(not src:find("copyPrivacy(config.features", 1, true)
        and not src:find("copyPrivacy(configuration.features", 1, true),
        "an extractor's settings copied from the source config")
    local _, n = src:gsub("copyPrivacy%(temp_config%.features", "")
    TestRunner:assertTrue(n >= 3, "the extractor copies read temp_config (" .. n .. ")")
    TestRunner:assertTrue(src:find("lib_gate = require(\"koassistant.request.privacy_gates\").context(\n            temp_config.features", 1, true) ~= nil,
        "the library branch judges on temp_config")
end)

return TestRunner:summary()
