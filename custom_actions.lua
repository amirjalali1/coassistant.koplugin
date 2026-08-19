-- Custom Actions for KOAssistant (fork-local extension point)
--
-- NOTE: this file is gitignored upstream (zeeyado/koassistant.koplugin) by
-- design -- it's meant to be a personal file. In this fork it is
-- deliberately force-tracked with `git add -f` so custom actions travel
-- with the repo. See custom_actions.lua.sample for the full schema
-- reference and more examples.
--
-- Action Schema (subset used below; addCustomAction copies any field
-- verbatim, so built-in-only fields like behavior_variant="dictionary_direct",
-- compact_view, minimal_buttons, reasoning_config, skip_language_instruction,
-- skip_domain all work here too):
--   text            - Display name (button label) [REQUIRED]
--   context         - Where it appears [REQUIRED]
--   prompt          - The instruction sent to AI [REQUIRED]
--
-- NOT usable here: in_dictionary_popup / in_highlight_menu. Those only
-- auto-place BUILT-IN actions (action_service.lua's buildDefaultFromFlags
-- scans self.Actions == require("prompts.actions") only, never the
-- custom-actions cache) -- setting them on a custom action is silently a
-- no-op. To show a custom action in a menu, enable it manually on-device:
-- Settings -> Actions & Prompts -> Manage Actions -> tap the action ->
-- check "+ Highlight Menu" / "+ Dict. Popup" (one-time, per menu).
--
-- RTL/Persian rendering: two layered fixes, both required.
-- (1) koassistant_dialogs.lua's handlePredefinedPrompt now honors an
--     explicit render_markdown field on the action (a small addition to a
--     shared/upstream file -- see its "Per-action Markdown/Plain-Text
--     override" comment). Every action below sets render_markdown = false,
--     forcing Plain Text mode (KOReader's native text renderer), which
--     -- confirmed empirically on-device -- shapes/joins Farsi letterforms
--     correctly. The Markdown/HTML path (MuPDF) does not: neither its
--     hardcoded font-family: 'Noto Sans' (koassistant_chatgptviewer.lua:1105,
--     no Arabic-script fallback) nor its automatic RTL detection (keyed on
--     the global dictionary_language setting for compact/dictionary views,
--     or on RTL being the DOMINANT script for standard views -- neither
--     condition holds for a response that deliberately mixes two
--     similar-length scripts) reliably renders this content.
-- (2) Even in Plain Text mode, a Farsi block that mixes in Latin (IPA,
--     headword, English synonyms) can still order badly -- so every Farsi
--     section below is written to be 100% Persian script, no exceptions.

return {
    -----------------------------------------------------------------------
    -- FA Dictionary: same as the built-in "Dictionary" action, but always
    -- appends a second, complete entry in Persian (Farsi).
    -----------------------------------------------------------------------
    {
        text = "FA Dictionary",
        context = "highlight",
        behavior_variant = "dictionary_direct",
        compact_view = true,
        minimal_buttons = true,
        use_surrounding_context = false,  -- {context_section} channel already carries the passage
        include_book_context = false,
        reasoning_config = "off",
        skip_language_instruction = true,
        skip_domain = true,
        render_markdown = false,  -- Forces Plain Text mode: MuPDF's HTML renderer mis-shapes/scrambles the Farsi section (see header note); confirmed fixed on-device via the MD/TXT toggle
        -- Enable manually on-device: Manage Actions -> FA Dictionary -> "+ Highlight Menu" / "+ Dict. Popup"
        prompt = [[Dictionary entry for "{highlighted_text}"

Provide TWO complete dictionary entries below, in this exact order -- do not skip either one.

1. First entry, written entirely in {dictionary_language}. Only the headword, lemma, and synonyms stay in the word's original language.

**{highlighted_text}** /IPA/ part of speech of **lemma**
Definition(s), numbered if multiple
Etymology (brief)
Synonyms

2. Second entry: Meaning of the word in Persian (Farsi) and then after that a complete Persian (Farsi) dictionary entry for the same word. This entire section must contain ZERO Latin letters -- not the headword, not IPA, not the lemma, not the synonyms. Give the headword as a Persian-script transliteration instead of the Latin spelling (it already appears in Latin in entry 1 above), then part of speech, definition(s), brief etymology, and synonyms, all as Persian words. Do not mix any Latin character into this section under any circumstance, even for names or loanwords -- transliterate everything into Persian script.

{context_section}

Inline bold labels, no headers. Concise. Keep the two entries clearly separated. Entry 2 must be 100% Persian script, no exceptions.]],
        api_params = {
            temperature = 0.3,
        },
    },

    -----------------------------------------------------------------------
    -- FA Explain: same as the built-in "Explain" action (highlight menu
    -- only, template "explain" in prompts/templates.lua:132-137, inlined
    -- here per the custom-action convention -- see research note above),
    -- but always appends a second explanation in Persian (Farsi).
    -----------------------------------------------------------------------
    {
        text = "FA Explain",
        context = "highlight",
        enable_web_search = false,
        accept_quick_answer = true,
        include_book_context = true,  -- matches built-in Explain
        render_markdown = false,  -- Forces Plain Text mode: hasDominantRTL's auto-detect only fires when RTL is the MAJORITY script, which a half-English/half-Farsi response never is; confirmed fixed on-device via the MD/TXT toggle
        -- Enable manually on-device: Manage Actions -> FA Explain -> "+ Highlight Menu"
        prompt = [[Explain this passage:

{highlighted_text}

Be clear and precise. Match the text's tone - a philosophy text deserves rigor, a thriller just needs clarity. {conciseness_nudge}

Then provide a second explanation of the same passage in Persian (Farsi). This second explanation must contain ZERO Latin letters -- transliterate any proper noun or term from the passage into Persian script rather than leaving it in Latin. Keep the two explanations clearly separated.]],
        api_params = {
            temperature = 0.5,  -- matches built-in Explain
        },
    },
}
