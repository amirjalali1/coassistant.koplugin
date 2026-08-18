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
-- skip_domain, in_dictionary_popup, in_highlight_menu all work here too):
--   text            - Display name (button label) [REQUIRED]
--   context         - Where it appears [REQUIRED]
--   prompt          - The instruction sent to AI [REQUIRED]

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
        in_dictionary_popup = 5,
        in_highlight_menu = 9,
        prompt = [[Dictionary entry for "{highlighted_text}"

Provide TWO complete dictionary entries below, in this exact order -- do not skip either one.

1. First entry, written entirely in {dictionary_language}. Only the headword, lemma, and synonyms stay in the word's original language.

**{highlighted_text}** /IPA/ part of speech of **lemma**
Definition(s), numbered if multiple
Etymology (brief)
Synonyms

2. Second entry, written entirely in Persian (Farsi), same structure as above. Only the headword, lemma, and synonyms stay in the word's original language.

**{highlighted_text}** /IPA/ نوع کلمه از **lemma**
تعریف(ها)، در صورت تعدد شماره‌گذاری شود
ریشه‌شناسی (مختصر)
مترادف‌ها

{context_section}

Inline bold labels, no headers. Concise. Keep the two entries clearly separated.]],
        api_params = {
            temperature = 0.3,
        },
    },
}
