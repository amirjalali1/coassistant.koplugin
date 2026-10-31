-- Wiki shots for the Reading Analysis Actions page (docs/assets/wiki_shotlist.txt)
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
local W = dofile(S.PLUGIN .. "/tests/scenarios/wiki_lib.lua")(S)
S.features({ provider = "anthropic", api_keys = { anthropic = W.FAKE.anthropic } })

local ui = S.open(S.shotsBook("standalone") or "Mock Series 3")
-- The book's second chapter (the second contents entry called a chapter)
local toc = ui.toc.toc or {}
local chapters = {}
for i, item in ipairs(toc) do
    if type(item.title) == "string" and item.title:lower():find("^%s*chapter") then chapters[#chapters + 1] = i end
end
local idx = chapters[2] or math.min(2, #toc)
local chapter = toc[idx]
local next_page = toc[idx + 1] and toc[idx + 1].page or (chapter.page + 6)

-- The chapter-end offer
W.page(next_page - 1)
S.plugin:_offerChapterQuiz(idx)
S.settle()
S.note("offer:", table.concat(S.texts(), " | "))
S.wiki("chapter-quiz-offer.png")
S.closeAll()

-- Mid-chapter, the Quiz scope and source popup
W.page(math.floor((chapter.page + next_page) / 2))
S.plugin:onKOAssistantQuickActions()
S.settle()
S.tap({ "^Quiz" })
S.note("quiz popup:", table.concat(S.texts(), " | "))
S.wiki("quiz-scope-popup.png")
S.finish()
