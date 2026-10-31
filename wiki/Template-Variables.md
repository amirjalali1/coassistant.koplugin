# Template Variables

The placeholders an action's prompt can use. Each is replaced at run time with the value it names; the "section" forms carry a label and vanish when they have nothing to say, so a prompt never refers to data that is not there. Where a placeholder needs a privacy setting, the setting is named; without it the placeholder is empty. How to write and edit actions is on [Actions and Menus](Actions-and-Menus).

## The variables

| Variable | Context | Description | Privacy setting |
|---|---|---|---|
| `{highlighted_text}` | Highlight | The selected text | |
| `{user_input}` | Any | The text typed in the input dialog, placed where the placeholder sits (without it, typed text is appended after the prompt). Run without typed text, the placeholder is left in the prompt as written, so such an action belongs in the input dialog: its details screen offers no **+ Highlight Menu** or **+ Dict. Popup** button (the Highlight Menu and Dictionary Popup lists can still add it) | |
| `{title}` | Book, Highlight | Book title; "this book" when [Book info](Privacy-and-Data#what-gets-sent) is None (a quoted `"{title}"` too) | |
| `{author}` | Book, Highlight | Book author; empty when Book info is None | |
| `{author_clause}` | Book, Highlight | " by Author", or empty (always empty when Book info is None) | |
| `{count}` | Library | Number of selected books | |
| `{books_list}` | Library | The selected books as a list, enriched with per-book highlights, annotations and notebook when the action declares those flags | Highlights / Annotation notes / Notebook, when those flags are set; one question for the set |
| `{library}` | Library, Book, Highlight | The library catalog, raw, no label | Library Scan (folders picked at the run) |
| `{library_section}` | Library, Book, Highlight | The catalog with the label "My library:", or empty | Library Scan (folders picked at the run) |
| `{deep_reads}` | Library, Book, Highlight | Finished books with over 5 hours of reading time | Reading habits and Library Scan (folders picked at the run) |
| `{deep_reads_section}` | Library, Book, Highlight | The same with "Books I read extensively:", or empty | Reading habits and Library Scan (folders picked at the run) |
| `{recently_finished}` | Library, Book, Highlight | Finished books last opened in the past 30 days | Reading habits and Library Scan (folders picked at the run) |
| `{recently_finished_section}` | Library, Book, Highlight | The same with "Books I recently finished:", or empty | Reading habits and Library Scan (folders picked at the run) |
| `{stalled}` | Library, Book, Highlight | Unfinished books read past 20% and not opened for over 30 days | Reading habits and Library Scan (folders picked at the run) |
| `{stalled_section}` | Library, Book, Highlight | The same with "Books I started but haven't returned to:", or empty | Reading habits and Library Scan (folders picked at the run) |
| `{briefly_started}` | Library, Book, Highlight | Unfinished books with under 30 minutes of reading time | Reading habits and Library Scan (folders picked at the run) |
| `{briefly_started_section}` | Library, Book, Highlight | The same with "Books I opened briefly:", or empty | Reading habits and Library Scan (folders picked at the run) |
| `{previous_results}` | General | This action's own recent results: the AI's replies from your last 3 saved general-context chats of this action, raw | none (your own AI output) |
| `{previous_results_section}` | General | The same in a labelled "Previous results from earlier runs of this action…" block with an avoid-repeating hint, or empty | none |
| `{translation_language}` | Any | The translation target from the settings | |
| `{dictionary_language}` | Any | The dictionary response language from the settings | |
| `{response_language}` | Any | The primary response language in effect for this request, a per-book override included (with no languages set, KOReader's interface language, else English) | |
| `{context}` | Highlight | The text around the selection, as much as Settings → Dictionary Settings → Context Mode sends (a sentence by default; a book's own setting first). With no context, every prompt line holding it or the words "In context" is dropped | |
| `{context_section}` | Highlight | The context with the label "Word appears in this context:" | |
| `{reading_progress}` | Book, Highlight | The current position, as "42%" | Reading position |
| `{progress_decimal}` | Book, Highlight | The position as an unrounded decimal fraction, "0.4215…" | Reading position |
| `{chapter_title}` | Book, Highlight (reading) | The current chapter's name | Reading position |
| `{chapters_read}` | Book, Highlight (reading) | How many table-of-contents entries begin at or before the current page, "5" | Reading position |
| `{page_number}` | Book, Highlight (reading) | The EPUB's reference page label, "37" (the print edition's page from the book's page map; empty when the EPUB has none) | Reading position |
| `{time_since_last_read}` | Book, Highlight | How long ago KOReader's reading statistics last recorded you reading the book, "3 days ago" (empty when they have no record of the book; a book that is not open is read the same way) | Reading position |
| `{time_since_last_read_section}` | Book, Highlight | "Last read: 3 days ago", or nothing at all when the statistics have no record of the book (Recap uses this form, so no half sentence is sent) | Reading position |
| `{highlights}` | Book, Highlight | The book's highlights, text only (the first 100), each with its chapter or page | Highlights (or Annotation notes) |
| `{annotations}` | Book, Highlight | The book's highlights (the first 100), each with its note when it has one | Annotation notes (degrades to Highlights) |
| `{highlights_section}` | Book, Highlight | Highlights with "My highlights so far:" | Highlights (or Annotation notes) |
| `{annotations_section}` | Book, Highlight | Annotations with an adaptive label: "My annotations:" when the notes may be sent, "My highlights so far:" when degraded to highlights only | Annotation notes (degrades to Highlights) |
| `{notebook}` | Book, Highlight | The book's KOAssistant notebook | Notebook |
| `{notebook_section}` | Book, Highlight | The notebook with "My notebook entries:" | Notebook |
| `{book_text}` | Book, Highlight (reading) | The book's text from the start to the current position | Book text |
| `{book_text_section}` | Book, Highlight (reading) | The same with "Book content so far:" | Book text |
| `{full_document}` | Book, Highlight (reading) | The whole document, start to end, whatever the position (only the section when a run is limited to one) | Book text |
| `{full_document_section}` | Book, Highlight (reading) | The same with "Full document:" | Book text |
| `{surrounding_context}` | Highlight (reading) | The text around the highlighted passage, extracted whenever the prompt carries this placeholder: as much as Settings → Highlight Settings → Surrounding Context sends (a sentence while that is off), at most 2000 characters | |
| `{surrounding_context_section}` | Highlight (reading) | The same in a labelled block that marks the passage with >>> <<< and tells the AI to answer about the passage only | |
| `{page_text}` | Book, Highlight (reading) | The text of the visible page | |
| `{page_text_section}` | Book, Highlight (reading) | The same with "Current page text:" | |
| `{xray_cache}` | Book, Highlight | The saved X-Ray, if any, as stored (normally JSON) | Book text (and Highlights if the X-Ray used them) |
| `{xray_cache_section}` | Book, Highlight | The same as readable text, with a progress label | as above |
| `{analyze_cache}` | Book, Highlight | The saved document analysis, if any | Book text |
| `{analyze_cache_section}` | Book, Highlight | The same with its label | Book text |
| `{summary_cache}` | Book, Highlight | The saved document summary, if any | Book text |
| `{summary_cache_section}` | Book, Highlight | The same with its label | Book text |
| `{document_context_section}` | Book, Highlight (reading) | The unified source block: the full text (or a section's), a saved summary, targeted passages (Smart retrieval) or nothing, as chosen in the source popup of an action with source selection | Book text |
| `{doi_clause}` | Book, Highlight | A new line "DOI: …" when the book's DOI is known (from its metadata, or a scan of its first page while it is open), empty otherwise; most built-in book prompts carry it ([Research Mode](Research-Mode)) | |

**Contexts:** Book = reading mode and the file browser (there, highlights, annotations, the notebook, the reading progress and saved results are read from the book's files on disk, the time since you last read comes from KOReader's reading statistics, and the library and reading-engagement placeholders stay empty); Highlight = reading mode (there is no highlight without an open book); General = a standalone chat with no book; (reading) = reading mode only, an open book required. Whether the file browser offers an action is decided by its flags, not by its placeholders ([Actions and Menus](Actions-and-Menus#tips-for-custom-actions)). The privacy setting is the kind of data under **Settings → Privacy & Data** the variable needs: on Ask the action asks the first time, on Allow it goes, and under Never the variable is empty and its section form disappears ([Privacy and Data](Privacy-and-Data)). Two exceptions: a provider in Trusted Providers follows its own column of values (the library still needs a folder ticked for the run), and a book's own Privacy rows (Book Settings → Privacy & Data) allow or refuse book text, highlights, annotation notes, the notebook and the text around what you tap for that book, a Never winning even over a trusted provider.

## Section and raw forms

A section form carries its label and disappears when empty:

- `{book_text_section}` → "Book content so far:" and the text, or nothing
- `{full_document_section}` → "Full document:" and the text (for a run limited to a section, "Text of section "…":" instead), or nothing
- `{context_section}` → "Word appears in this context:" and the text, or nothing
- `{highlights_section}` → "My highlights so far:" and the highlights, or nothing
- `{annotations_section}` → "My annotations:" and the annotations; "My highlights so far:" when degraded (annotations off, highlights on); nothing when both are off
- `{notebook_section}` → "My notebook entries:" and the notebook, or nothing
- `{surrounding_context_section}` → "Surrounding context from the document (the highlighted passage is marked with >>> <<<)…" and the text, or nothing
- `{page_text_section}` → "Current page text:" and the text, or nothing
- `{xray_cache_section}` → "Previous X-Ray (as of X%):" and the X-Ray, or nothing
- `{analyze_cache_section}` → "Document analysis:" and the analysis, or nothing
- `{summary_cache_section}` → "Document summary:" and the summary, or nothing
- `{previous_results_section}` → "Previous results from earlier runs of this action…" and the results, or nothing
- `{library_section}` → "My library:" and the catalog, or nothing
- `{deep_reads_section}`, `{recently_finished_section}`, `{stalled_section}`, `{briefly_started_section}` → their labels above and the lists, or nothing

The raw forms (`{book_text}`, `{full_document}`, `{highlights}`, `{annotations}`, `{notebook}`, `{surrounding_context}`, `{page_text}`, `{xray_cache}`, `{analyze_cache}`, `{summary_cache}`, `{previous_results}`, `{library}`, `{deep_reads}`, `{recently_finished}`, `{stalled}`, `{briefly_started}`) give the content alone, for a prompt that labels it in its own words.

Use the section forms in most cases: a prompt that says "Look at my highlights: {highlights}" with no highlights gives the AI an instruction about content that is not there, while a section form brings its label only when it has content. A raw form whose data was never fetched (the action lacks the flag, or a saved result is not allowed) is dropped, so the AI sees nothing in its place.

**Privacy.** The section forms follow the privacy settings: a kind of data that is not allowed for the request (set to Never, or declined when asked) leaves its placeholder empty and its section form vanishes. `{highlights_section}` is empty unless Highlights is allowed (or Annotation notes, which implies highlights). Actions never need changing to match your privacy choices.

**Double-gating in custom actions.** Sensitive data needs both the global privacy setting and the action's own permission flag: with Book text on Allow for all books, a new custom action still needs "Allow text extraction" checked to use it. Built-in actions carry the right flags, and a copy made with Duplicate keeps the data-access ones (not the saved-result flags or the source popup). The saved-result placeholders need the permissions of their source: `{xray_cache}` needs text extraction, plus highlights if the X-Ray was built with them; `{analyze_cache}` and `{summary_cache}` need text extraction. Their own flags (`use_xray_cache`, `use_analyze_cache`, `use_summary_cache`) have no box in the action editor, so they work in built-in actions and in actions written in `custom_actions.lua`. The full table is on [Privacy and Data](Privacy-and-Data#text-extraction-and-double-gating).

**`{previous_results_section}`** is not privacy-gated because its content is the AI's own earlier output, going back to the provider. It lets a recurring general-context action (a custom "daily news roundup" cloned from an existing action, say) see its last few results so it stops repeating items. It reads the AI's replies from your newest 3 saved general-context chats that ran this same action, so it needs saved chats; with Auto-save All Chats on (the default) that happens on its own. It is a general-context stopgap; book and library history is not covered.

## Utility placeholders

Reusable prompt fragments for any action:

| Placeholder | Expands to | Behaviour |
|---|---|---|
| `{conciseness_nudge}` | "Be direct and concise. Don't restate or over-elaborate." | always present |
| `{hallucination_nudge}` | "If you don't recognize this or the content seems unclear, say so rather than guessing." (a web-aware form adds "search the web to verify" when web search is on) | always present |
| `{text_fallback_nudge}` | "Note: No document text was provided. Use your knowledge of "{title}" to provide the best response you can. If you don't recognize this work, say so honestly rather than fabricating details." | only when the document text is empty; nothing when text is present |
| `{spoiler_free_nudge}` | "The reader is currently at {reading_progress} of this book. IMPORTANT: Do not reveal…" with a known position, or "The reader has not finished this book. Do not reveal plot twists, endings…" without one | only while spoiler protection is active |
| `{quiz_instructions}` | the question count, difficulty and question types from the quiz settings (Settings → Reading & Library → Chapter Quiz, or the book's own Quiz settings), and the JSON shape to answer in | only in interactive-quiz actions such as Quiz; empty elsewhere |
| `{highlight_analysis_nudge}` | an instruction to add a "reader_engagement" section to a JSON answer: what your highlights show about your interests, 3 to 5 notable ones and how they connect | only when highlights are present; no built-in action uses it any more, it is kept for custom actions |

Why they exist: the conciseness nudge counters verbose models and sits in around 20 built-in actions (Explain, Summarize, ELI5, the context-aware analysis actions); the hallucination nudge stops the AI inventing a book or author it does not know, with the web form encouraging a search first, and sits in many built-ins (About, Find Similar, Connect, Historical Context, every library action); the text fallback nudge gives graceful degradation to actions that use document text, guiding the AI to its own knowledge when extraction is off or empty and expanding to nothing when text is present (Explain in Context, Analyze in Context, Thematic Connection, Recap, Key Arguments, Discussion Questions, Quiz, Extract Key Insights, Reading Guide, Counterarguments, and for actions with source selection whenever "AI knowledge only" is chosen; X-Ray, Document Analysis and Document Summary block instead of degrading); the spoiler nudge tells the AI the reader's exact position and forbids anything beyond it, web-search results included, with the generic form when the position is unknown, and for every covered request it is added at send time and re-checked on each reply, so only a custom action that wants to control where the instruction sits needs the placeholder (AI Wiki, Reviews and About carry it inline) ([Spoiler Protection](Spoiler-Protection)).

Put these at the end of a prompt where they fit; they are replaced at run time. Written out as plain text, the conciseness nudge works just as well, but the others would lose their per-request choice of wording or presence. `{text_fallback_nudge}` belongs in any custom action that uses `{full_document_section}` or `{book_text_section}`, so it still answers when extraction is off.

## Update-prompt placeholders

`{cached_result}`, `{cached_progress}`, `{incremental_book_text}`, `{incremental_book_text_section}` and `{entity_index}` fill in only inside an action's update prompt, the prompt used when an existing saved result is updated instead of regenerated: the result you already have, how far it covers ("30%"), and only the newly read text (the section form labelled "New content since your last analysis:"). `{entity_index}` serves X-Ray updates: the names the X-Ray already has, under "Existing entities in previous analysis:". In an ordinary prompt all five are empty. See [Artifacts and Caching](Artifacts-and-Caching).

## Related

- [Actions and Menus](Actions-and-Menus): creating and editing the actions these go into.
- [Privacy and Data](Privacy-and-Data): the settings that fill or empty them.
- [Prompts, Behaviors and Domains](Prompts-Behaviors-and-Domains): the system prompt around the action's prompt.
