# Reading Analysis Actions

The book actions that work on what you are reading: Recap to get back into a book, Document Summary and Document Analysis, About, Analyze Notes for your own highlights and notes, Key Arguments and Counterarguments, Discussion Questions, Reading Guide, Extract Key Insights and the Quiz. Most save their result as an artifact you can reopen at any time. This page also covers the chapter-end quiz, the recap reminder and the end-of-book suggestion.

## X-Ray

X-Ray builds a browsable reference guide to the book from its text, up to your reading position, and keeps it current as you read. It requires the book's text: it asks the first time, and is refused when the text is set to Never. **X-Ray (Simple)** is a separate prose overview (Characters, Themes, Setting, Key Terms, Where Things Stand) from the AI's training knowledge: no text extraction needed, spoiler-gated by your reading progress, best for well-known books. Both are covered in [Using X-Ray](Using-X-Ray).

## What each action reads

Most of these actions read your own reading data, so they need the matching setting in **Settings → Privacy & Data**:

| Action | What it analyzes | Setting required |
|---|---|---|
| **X-Ray** | Book text up to your current position | Book text (required; asked the first time). Highlights are only listed locally on entry pages; nothing extra is sent |
| **X-Ray (Simple)** | AI training knowledge + reading progress | None |
| **Recap** | Book text up to your current position, or AI knowledge (your choice), + your highlights | Book text (for extracted text), Highlights |
| **Analyze Notes** | Your highlights and annotations, plus the book's notebook and summary when allowed | Highlights (required); your notes need Annotation notes, the notebook Notebook |
| **Key Arguments** | Full text, summary, or AI knowledge (your choice) | Book text (for full text or summary) |
| **Counterarguments** | Full text, summary, or AI knowledge (your choice) | Book text (for full text or summary) |
| **Discussion Questions** | Full text, summary, or AI knowledge (your choice) | Book text (for full text or summary) |
| **Quiz** | Full text, summary, or AI knowledge (your choice) | Book text (for full text or summary) |
| **Extract Key Insights** | Full text, summary, or AI knowledge (your choice) | Book text (for full text or summary) |
| **Reading Guide** | Full text, summary, or AI knowledge (your choice) + reading progress | Book text (for full text or summary) |
| **Document Analysis** | The entire document or a section (your choice) | Book text (required) |
| **Document Summary** | The entire document or a section (your choice) | Book text (required) |
| **About** | AI training knowledge (+ web search when it is on) | None |
| **Suggest from Library** | Library catalog + current book + reading progress | Library Scan (required) + a folder ticked for the run |
| **Next Read** | Library catalog + engagement groups (recently finished, stalled, briefly started) | Library Scan (required) + a folder ticked for the run; Reading habits (optional, adds engagement data) |
| **Discover New** | Library catalog + engagement groups (deep reads, recently finished) | Library Scan (required) + a folder ticked for the run; Reading habits (optional) |
| **Analyze Library** | Library catalog + all engagement groups | Library Scan (required) + a folder ticked for the run; Reading habits (optional) |
| **Challenge My Taste** | Library catalog + engagement groups (deep reads, stalled, briefly started) | Library Scan (required) + a folder ticked for the run; Reading habits (optional) |

The last four are library actions: see [Contexts and Chat](Contexts-and-Chat) for library mode and [Privacy and Data](Privacy-and-Data) for what each setting shares. Suggest from Library shows its scan folders to tick before it runs ([the folder window](Privacy-and-Data#the-folder-window)); the four library actions use the folders ticked in the library dialog's **Library Scan ▾**.

These actions don't get your reading data unless you allow it: each kind is asked for the first time an action wants it (the question names the action, the provider and the amount), and your answer can be kept for the book. With book text set to Never, an action with source selection has only **AI knowledge only** available; the other actions fall back to the AI's training knowledge, with a "*Response generated without: ...*" notice in the chat. X-Ray, Document Summary and Document Analysis are the exception: they are refused, with a message that names where the value comes from and a button to it (the book's Privacy & Data screen, or the settings), and for X-Ray the message points to X-Ray (Simple) instead. A result you generated earlier stays viewable after you set the text to Never, but you cannot regenerate or redo it.

With **AI knowledge only** as the source, an action that normally runs without web search follows your web search setting, since without the book's text a search can help check what the AI recalls.

> **Book text:** Settings → Privacy & Data → Text Extraction → Book text, Ask by default (the question names the amount, to avoid unexpected token costs), Allow to skip the question, Never to refuse.

Highlight actions use text extraction too: **Explain in Context** and **Analyze in Context** send the document text through their source popup (`{document_context_section}`: the full text, a section, the summary or the passages smart retrieval finds, as you pick) to understand your passage within the work. See [Contexts and Chat](Contexts-and-Chat#source-selection).

## Where to find them

- **Quick Actions panel:** X-Ray, Recap, About, Document Summary, Analyze Notes, Extract Key Insights, Key Arguments, Discussion Questions, Quiz and Suggest from Library, in that order, by default.
- **The book's input dialog** (Chat/Action) lists several of them; **Show More Actions…** shows the rest.
- **File browser:** long-press a book. About is one of the long-press buttons by default, and Chat/Action lists the actions that work without opening the book (see [Reading mode and the file browser](#reading-mode-and-the-file-browser)).

You can add any of them to Quick Actions, the file browser or a gesture: see [Actions and Menus](Actions-and-Menus). An action that already has a saved result opens a popup first, to view it, bring it up to date or run it anew: see [Artifacts and Caching](Artifacts-and-Caching).

## Recap

A "Previously on..." refresher to help you get back into a book after time away: the situation so far, recent events (in the most detail), the active threads, and the moment where you stopped. It adapts to the content: a "Previously on..." narrative for fiction, a "Where we left off..." refresher for non-fiction, a "Research progress so far..." refresher for academic papers. Deep into a book it first walks the whole arc so far in brief, then gives the recent stretch the detail. When highlights are shared it weaves in what you found notable; it reads your highlights, never your notes ([Privacy and Data](Privacy-and-Data)). A fresh Recap also tells the AI how long ago you last read the book (for example "Last read: 3 days ago"), from KOReader's reading statistics; nothing is sent when the statistics have no record of the book or when Reading position is off.

Recap works with source selection: choose between extracted text (recommended, with incremental updates as you read) or AI knowledge only.

- **With the book's text** (recommended): the AI analyzes the actual book content and produces accurate, book-specific results. Results are cached and labeled "Based on extracted document text."
- **Without it** (when you pick AI knowledge, or the text is set to Never): the AI uses only the title and author and its training knowledge. This works reasonably for well-known titles but produces generic results. Results are labeled "Based on AI training data knowledge."

A recap always runs up to your current position: its scope row reads **Up to current position (NN%)**, and **From section… (to NN%)** starts it at a chapter you pick. It cannot be pointed at an arbitrary section or a section range (a catch-up is always up to where you are), and a summary cannot stand in for the text.

**Updating.** After you read further, **Update** sends only the text since the last recap, and the AI builds on its previous recap instead of starting over. With AI knowledge as the source, an update writes the recap afresh for your new position. [Artifacts and Caching](Artifacts-and-Caching) explains incremental updates.

Use KOReader's hidden flows to limit Recap to specific chapters or parts of the book ([Using X-Ray](Using-X-Ray) explains how hidden flows change what KOAssistant reads). Marking a book finished stands spoiler protection down but does not change what Recap extracts: it still reads up to your actual page position, not to 100%. When it reads the book's text, Recap runs without web search. To be reminded to run it, see [Recap reminder](#recap-reminder).

## Document Summary

A comprehensive summary that keeps the key details, arguments and structure and covers the whole work evenly from beginning to end. It is saved as the **Summary** artifact, which other actions can use as their document source: actions with source selection can send this summary (a few thousand tokens) instead of the full text (often 100K tokens or more), which is much cheaper for repeated use and follow-up conversations. See [Artifacts and Caching](Artifacts-and-Caching) for the summary as a reusable source.

- It requires the book's text: it asks the first time, is refused when the text is set to Never, and its other sources are grayed out.
- It can target a section. When another action is scoped to that section and uses the summary, the section summary is used.
- For documents you'll query several times, generate the summary early.
- Custom actions read it with `{summary_cache_section}` ([Template Variables](Template-Variables)).

## Document Analysis

A deep analysis suited to the document's type and purpose: the core thesis, argument or narrative, how the ideas are organized, the key insights, findings or themes, the intended audience and context, and strengths and areas for improvement. It is saved as the **Analysis** artifact; custom actions can reference it with `{analyze_cache_section}`.

- It requires the book's text (asked the first time; refused under Never) and reads the entire document or a section.
- It is in neither Quick Actions nor the input dialog's list by default: run it from **Show More Actions…** in the book's input dialog, or add it where you want it.
- It follows your reasoning setting (unlike X-Ray, it has no reasoning pin). On short, dense works more reasoning can noticeably improve it: see [Reasoning, Web Search and Book Tools](Reasoning-Web-Search-and-Book-Tools).

## About

An overview of the work from the AI's own knowledge: what it is about (the premise and central conflict, or the thesis and scope), its historical and cultural context, its major themes and what makes its perspective distinctive, why it matters and where it fits, and the reading experience (style and structure, how much background it needs, who tends to enjoy it). No book data is needed, so it also runs from the file browser.

- It avoids spoilers: it describes the premise and central tensions without their resolution, and with spoiler protection on it also stays within your reading position.
- It uses web search when web search is on, for current information.
- It runs with reasoning off, and the result is saved as an artifact.

For a paper in research mode, About writes a research overview instead: see [Research Mode](Research-Mode). About is not the per-book **Book info** setting, which decides how much of the book's identity rides along with every request ([Book Settings and Book Hub](Book-Settings-and-Book-Hub)). The two do meet: with Book info set to None (**Settings → Privacy & Data → Book info**, or the book's own value in Book Settings → Privacy & Data), About cannot run, because it answers only from what the AI knows about the book, and it says it cannot run without the title. X-Ray (Simple) and the other AI-knowledge actions, such as Find Similar, About Author, Historical Context and Reviews, do the same; the actions that read the book's text, your highlights or a saved summary still run.

## Analyze Notes

Looks at you as a reader, through your highlights and notes, rather than summarizing the work: the kinds of passages that catch your attention, the threads you seem to be tracking and connections between highlights you may not have noticed, what your notes reveal about how your thinking is evolving, the questions you seem to be asking, and suggestions (parts to revisit, themes to watch for, connections to other works). It is asked not to reveal anything beyond your reading position.

- It needs your highlights: it asks the first time and is refused when Highlights is set to Never (Never for highlights is Never for notes too). With highlights only, it works from the highlighted passages; your notes reach it when annotation notes are allowed.
- When the notebook is allowed it also reads the book's notebook. When the book has a Document Summary and the book's text is allowed, it sends the summary too, so the AI knows what your notes are about.
- It reads the book's sidecar files, so it also runs from the file browser.
- The result is saved as an artifact; run it again as you add notes.

## Key Arguments and Counterarguments

**Key Arguments** maps the argument: the core thesis, the supporting arguments, the evidence and method, the assumptions, what critics would say, and the debates the work takes part in. For fiction it analyzes themes and the author's worldview instead; for academic work it stresses methodology, limitations, the work's place in its field and competing interpretations.

**Counterarguments** argues back: the strongest opposing positions as their best defenders would make them, the argument's weakest links, what would falsify it, who disagrees and why (drawing on real published critiques, never invented critics), and a skeptic's verdict. For fiction it challenges the themes and worldview instead; for academic work it stresses methodological critiques and competing interpretations.

Both use source selection (full text, summary or AI knowledge), can target a section, and save their result as an artifact. Key Arguments runs without web search; Counterarguments follows your web search setting, since published critiques help when it is on.

## Discussion Questions

Eight to ten questions that could start a good conversation, for a book club or a class: comprehension (2 to 3), analytical (3 to 4), interpretive questions with more than one valid answer (2 to 3), and personal connection or broader implications (1 to 2). They adapt to fiction (character decisions, themes, craft), non-fiction (arguments, evidence, real-world applications) and academic work (methodology, research design, validity of findings, implications for the field). The questions are written for the complete work; mid-book, ask for spoiler-free ones in a follow-up chat on the result. Source selection, section scope, saved as an artifact.

## Reading Guide

A spoiler-free guide to what lies ahead, built from what you have read: the threads in motion, patterns worth noticing (without saying where they lead), background that helps with what's coming, and how to approach the rest. It uses your reading position to stay safe, and once you have read further its popup offers an update (each update writes the guide afresh). Source selection, section scope, saved as an artifact. It follows your web search setting.

## Extract Key Insights

Distills what is most worth taking away: ideas worth remembering, perspectives that challenge conventional thinking, findings or conclusions with real-world application, and connections to larger questions or other fields, each stated specifically with why it matters. Fewer sharp insights beat many vague ones. Source selection, section scope, saved as an artifact.

## Quiz

An interactive comprehension quiz, one question at a time:

- **Multiple choice** questions are graded for you: tap A, B, C or D. The plugin decides which letter holds the right answer, so its position gives nothing away.
- **Short answer:** tap **Show Answer** for a model answer and its key points, then grade yourself with **Got it right** or **Missed it**.
- **Discussion:** tap **Show Key Points** for what a good answer should cover, then grade yourself.

Questions come grouped by type, multiple choice first. The bottom row moves between them (**‹ Prev**, **Next ›**, the question number to jump to any question, **Close**), and **Finish** on the last question shows your score, overall and per type, with **Copy**, **Export**, **Notebook** (adds the results to the book's notebook) and **Review All**. The quiz is written in your response language even when the book is in another one. Its answer is not streamed onto the screen, so nothing gives the answers away while it arrives, and a notification says so when the AI returns a different number of questions than you asked for. If the answer can't be read as a quiz, the raw response is shown instead.

Run it from Quick Actions: its popup offers the usual scopes and sources (full document or a section; full text, summary or AI knowledge) plus two quiz-only scopes, **Current chapter** and **Current chapter so far**, resolved at the same chapter level as the [chapter-end quiz](#chapter-quiz). **Current chapter so far** shows only when you are partway through a chapter, and while spoiler protection is on, mid-chapter it replaces **Current chapter**. The result is saved as an artifact: tap Quiz again to view it (**Continue / Review** where you left off, or **Take Again**) or to start a **New Quiz…**.

Question count, difficulty and the question types come from the [chapter quiz settings](#chapter-quiz) and apply to every quiz, manual or automatic. The Quiz runs with reasoning off, since thinking can cut its structured answer short.

## Chapter quiz

KOAssistant can offer a quiz when you finish a chapter. It is off by default: turn on **Settings → Reading & Library → Chapter Quiz → Quiz on Chapter End** (the submenu row reads "Chapter Quiz: On" or "Chapter Quiz: Off"). It needs a book with a table of contents.

When you turn the page out of a chapter into the next one, a popup says "End of: *chapter*. Would you like a comprehension quiz?" with **Quiz**, **Skip**, **Not for this book** (turns chapter quizzes off for this book) and **Quiz settings…** (this book's quiz settings, after which the offer comes back). The quiz covers that chapter's own pages (their text is sent when the book's text is allowed; the first time, it asks). If you read through several chapters, the newest offer replaces the previous one.

No offer comes:

- after a jump (a move of more than five pages, such as a table-of-contents jump), when you move back, or while a KOReader search is open;
- when you move from the front matter into the first chapter (there is no finished chapter to quiz);
- for a chapter shorter than **Minimum Chapter Length**, or one you spent less time in than **Minimum Reading Time**;
- for a chapter that already has a saved quiz.

The book's last chapter has no next chapter to cross into, so its quiz is offered when you reach the end of the book; the next-read suggestion then waits ([End of book](#end-of-book)).

**Settings → Reading & Library → Chapter Quiz:**

| Setting | What it does | Default |
|---|---|---|
| **Quiz on Chapter End** | Offer a comprehension quiz when you finish reading a chapter. Requires a book with a table of contents. | Off |
| **Quiz Chapter Level** | Which TOC level counts as a chapter: Auto-detect (the deepest level whose chapters average at least the minimum length below), Top level (Level 1), Level 2, Level 3, or All TOC headings (follows KOReader's TOC tick settings). A fixed level falls back to the deepest level the book actually has. | Level 2 |
| **Minimum Chapter Length (pages)** | Skip the prompt for chapters shorter than this many pages, so short or skimmed sections don't prompt (0 = no minimum; range 0-30). Also the threshold Auto-detect uses to pick the level. | 5 |
| **Minimum Reading Time (minutes)** | Skip the quiz unless you spent at least this many minutes reading the chapter (0 = no minimum; range 0-60). Catches flipping quickly through a long chapter; uses KOReader's reading statistics, and the quiz is still offered if those are unavailable. | 3 |
| **Question Count** | Total number of questions per quiz (3-15). | 8 |
| **Difficulty** | Easy (straightforward recall), Medium (comprehension and application) or Hard (analysis and synthesis). | Medium |
| **Include Multiple Choice** | Auto-graded A/B/C/D questions. | On |
| **Include Short Answer** | View the model answer, then grade yourself. | On |
| **Include Discussion** | View the key points a good answer should cover, then grade yourself. | On |

The level, length and time rows are grayed out while Quiz on Chapter End is off. Count, difficulty and types apply to the manual Quiz too; with every type turned off, a quiz uses multiple choice.

### Quiz settings for one book

**Book Settings → Quiz settings** overrides these for one book, each row starting on **Follow global**: the count, difficulty and question types, the chapter level, the minimum length and reading time, and a **Chapter-end quiz** row that can only silence the chapter-end prompt for that book, as the offer's **Not for this book** button does. Every row is on [Book Settings and Book Hub](Book-Settings-and-Book-Hub#quiz-settings).

## Recap reminder

When you open a book you haven't read in a while, KOAssistant can ask "You haven't read this book in N days. Would you like an AI Recap to help you get back into it?"; **Recap** runs it. It is off by default.

- **Settings → Reading & Library → Remind to Recap on Book Open:** show the reminder (default: Off).
- **Settings → Reading & Library → Days Before Reminder:** how many days since you last opened the book before the reminder appears (default 7, range 1-90; grayed out while the reminder is off).

It skips books you haven't started and books past 95%. For a book with no record yet, it goes by when the book's sidecar folder last changed. The time you last opened a book is recorded whether or not the reminder is on, so switching the reminder on later counts from your real last open.

## End of book

When you reach the end of a book, KOAssistant offers to suggest what to read next from your library ("Would you like an AI suggestion for what to read next from your library?"), just after KOReader's own end-of-book popup. **Suggest** runs **Suggest from Library**, which suggests three to five books you already own, based on the book you are reading and your reading patterns.

- **Settings → Reading & Library → Suggest Next Read on Finish** (default: On). It is offered unless Library Scan is set to Never for your provider (a trusted provider follows its own value), and only when you have a default scan folder or have added a folder on the fly before. **Suggest** runs Suggest from Library, which shows its [folder window](Privacy-and-Data#the-folder-window) (on Ask it is also the question). The settings are **Settings → Reading & Library → Library Scan** and **Default Scan Folders**.
- When the book's last chapter has a quiz to offer, the quiz takes the end-of-book moment and the suggestion is skipped that time.

Suggest from Library is also an ordinary book action, in Quick Actions by default. It sends your library catalog (title, author, series when it has one, reading status, and progress for books you are reading or have on hold; last-read dates only order the list and are not sent): see [Privacy and Data](Privacy-and-Data).

## Scope, sections and spoilers

**Whole-document actions.** Document Analysis, Document Summary, Extract Key Insights, Key Arguments, Counterarguments, Discussion Questions, Quiz and Reading Guide (and, on highlights, Explain in Context, Analyze in Context and Thematic Connection) use the entire document as their context. Document Analysis and Document Summary require the book's text and are refused when it is set to Never, like X-Ray. The actions with source selection let you choose full text, a saved summary or AI knowledge only; [Contexts and Chat](Contexts-and-Chat) describes the scope and source popup. They adapt to your content type and work especially well with [domains](Prompts-Behaviors-and-Domains): with a "Linguistics" domain active, analyzing a linguistics paper naturally focuses on the relevant aspects.

**Spoiler safety.** Recap, like X-Ray, extracts only up to your current reading position (`{book_text_section}`). The other text-extraction actions default to the full document, but their scope popup also offers **Up to current position**, **From section…** and section ranges, and pre-selects **Up to current position** while spoiler protection is on for the book; running a scope that covers text you haven't read asks once first ([Spoiler Protection](Spoiler-Protection)). For a spoiler-free variant of a custom action, use `{book_text_section}` instead of `{full_document_section}` ([Template Variables](Template-Variables)).

**Sections.** Most text-extraction book actions can focus on a chapter or part instead of the whole document. In the scope popup, **Pick section…** chooses one from a hierarchical TOC picker, and **Pick section range…** and **From section… (to NN%)** cover spans. Section results are stored as their own artifacts (for example "Section Summary: Chapter 5") and appear as groups in the Artifact Browser ("View Section Summaries (N)" and so on). While you are reading inside a section's page range, a quick **View** button for that section appears in the action's popup. Naming a section with the same page range as an existing one asks whether to replace the old entry. The section's text reaches the AI under its own heading, naming the section and its pages. Supported actions: Document Summary, Document Analysis, Key Arguments, Counterarguments, Discussion Questions, Quiz, Extract Key Insights and Reading Guide (X-Ray has its own section X-Rays). Section scoping follows KOReader's custom (handmade) TOC: create custom chapter boundaries to define your own scopes.

> **Tip:** Make specialized versions for your workflow. Copy a built-in action, adjust the prompt for your field (for example "Focus on methodology and statistical claims" for scientific papers), and pair it with a matching domain. Turn off built-ins you don't use in the Action Manager (tap to toggle). See [Actions and Menus](Actions-and-Menus).

## Reading mode and the file browser

Book actions work in two places: in **reading mode** (the book is open) and from the **file browser** (long-press a book in your library).

- The file browser has the book's **metadata** (title, author, identifiers) plus its **sidecar data** (highlights, annotations, notebook, reading progress), read from the book's files on disk.
- Reading mode adds the **live document**: extracted text, page text, chapter and TOC information, reading statistics.

**Reading-only actions** (hidden in the file browser): X-Ray, Recap, Document Analysis, Document Summary, and every other action with source selection (Key Arguments, Counterarguments, Discussion Questions, Quiz, Reading Guide, Extract Key Insights). They need live text extraction or the scope popup, which only exist once the book is open.

**Available from the file browser:** About, X-Ray (Simple), Analyze Notes, Suggest from Library, and other actions that only need highlights, annotations, the notebook or reading progress. They read the book's sidecar files without opening the document.

Custom actions using `{book_text}`, `{full_document}` or `{page_text}` need reading mode; `{reading_progress}`, `{highlights}`, `{annotations}` and `{notebook}` work in both. The Action Manager marks reading-only actions with `[reading]`.

## Models and reasoning

- X-Ray, About, Quiz, Suggest from Library and Next Read run with reasoning off in their own settings; the others follow your reasoning setting (**Settings → Advanced → Reasoning**). An action's own setting outranks your reasoning stance.
- To change that, or to tie an action to its own provider and model (a stronger model for Document Analysis while a fast one handles everything else, for example), open **Settings → Actions & Prompts → Manage Actions**, hold the action and pick **Edit Settings**, which holds Reasoning, Provider and Model. See [Actions and Menus](Actions-and-Menus).

## Related

- [Using X-Ray](Using-X-Ray): X-Ray, X-Ray (Simple), section X-Rays and hidden flows.
- [Artifacts and Caching](Artifacts-and-Caching): saved results, the View / Update / Redo popup, incremental updates, the summary as a source.
- [Contexts and Chat](Contexts-and-Chat): the scope and source popup, the input dialog, library mode.
- [Privacy and Data](Privacy-and-Data): what each sharing setting sends.
- [Research Mode](Research-Mode): how these actions change for academic papers.
- [Book Settings and Book Hub](Book-Settings-and-Book-Hub): the per-book quiz settings beside every other per-book setting.
