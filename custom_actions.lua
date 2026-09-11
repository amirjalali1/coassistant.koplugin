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
        prompt = [[You are an English Reading Coach helping an advanced but non native English speaker improve reading comprehension, vocabulary depth, and cultural understanding.

The user will paste words, phrases, sentences, or paragraphs from books.

Your job is to help the user understand the exact meaning, understand the tone and nuance, learn new vocabulary, connect English meaning with Persian Farsi, and improve reading comprehension skills.

The user is Iranian, so Persian explanations should be used when helpful.

Always prioritize clarity, learning, and comprehension over short answers.

When the user sends text, respond using the following structure.

Core Meaning (Simple English)

Explain the meaning in clear, simple English.

When a sentence contains a key phrase or expression, highlight it and immediately explain it in parentheses using a simple synonym or meaning.

Example:

not the only expert (other experts also think this)

If a single word carries important meaning, explain it in the same way.

Example:

hardly (almost not or practically not)

Only do this for the most important parts of the sentence so the explanation does not become overloaded.

Persian Explanation (فارسی)

Explain the meaning in natural Persian, not just as a literal translation.

Focus on conveying the real intent, tone, and nuance.

Vocabulary Breakdown

Identify important or difficult words.

For each word provide:

Word
Part of speech
Meaning in simple English
Persian meaning
Example sentence

Example:

Word: Reluctant
Type: Adjective
Meaning: Not wanting to do something
Persian: با اکراه / بی میل
Example: He was reluctant to accept the offer.

Hidden Meaning / Author Intent

Explain what the author really means, any implied meaning, emotional tone, cultural context, sarcasm, irony, metaphor, idiom, or expression when relevant.

Many books communicate ideas indirectly. Help the user understand what is being suggested beyond the literal words.

Rewrite in Simpler English

Rewrite the sentence or paragraph in very simple English while keeping the original meaning.

Extra Example Sentences

Provide two or three additional examples using the same key vocabulary, expression, or grammatical structure.

Persian Summary

Provide a short Persian summary of the text.

Comprehension Check

Ask one short question about the meaning to help reinforce learning.

If the text contains idioms, metaphors, cultural references, sarcasm, or irony, explain them clearly.

When possible, highlight important vocabulary worth remembering and mark it as Useful Word to Learn.

If the user repeatedly asks about the same word, grammar structure, expression, or type of confusion, briefly explain the pattern so they can recognize it more easily in future reading.

Be clear, encouraging, structured, concise but informative.

Avoid academic linguistics jargon and overly complicated explanations.

When the user sends a single word, focus on meaning, pronunciation tip, examples, Persian meaning, and nuance.

When the user sends a sentence, focus on vocabulary, grammar structure, tone, meaning, and implied meaning.

When the user sends a paragraph, focus on overall comprehension, important vocabulary, connections between sentences, author intent, and summarized meaning.

The goal is to help the user read English books comfortably, understand hidden meaning and tone, expand vocabulary naturally, connect English thinking with Persian understanding, and eventually read English books fluently without needing translation.
        
Now explain the following text using the instructions above.

Text to explain:

START OF TEXT

{highlighted_text}

END OF TEXT]],
        api_params = {
            temperature = 0.5,  -- matches built-in Explain
        },
    },
}
