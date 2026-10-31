-- Boot probe: the reader opens a mock book with the plugin loaded, and the
-- X-Ray marks are drawn on a page that names the book's entries.
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")

local ui = S.open("Mock Series 3")
S.check(ui and ui.document ~= nil, "Mock Series 3 opens in the reader")
S.check(S.plugin ~= nil, "the plugin is loaded (ui.koassistant)")

S.chapter("The Orchard Post")
local first = {}
for _idx, m in ipairs(S.marks()) do first[m.name] = true end
S.check(first["Tamsin Vael"] and first["Hollowmere"], "Tamsin Vael and Hollowmere are marked in the first chapter")

S.chapter("The Grafter")
local marks = S.marks()
local names = {}
for _idx, m in ipairs(marks) do names[m.name] = (m.words or "?") end
S.note("marks on \"The Grafter\":", #marks)
for name, words in pairs(names) do S.note(name, "->", words) end
S.check(names["Gil Rook"] ~= nil, "Gil Rook is marked")
-- (the words read back under the mark may take the comma after it, by the
-- screen's pixels)
S.check(names["Jory"] ~= nil and names["Jory"]:match("^Jory,?$") ~= nil, "Jory is marked, the mark on his name alone")
S.check(names["Tamsin Vael"] == nil, "\"Tamsin\" alone is not one of Tamsin Vael's names: no mark")
S.shot("grafter")

S.finish()
