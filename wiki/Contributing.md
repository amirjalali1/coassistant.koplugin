# Contributing

KOAssistant is developed in the open, and most of what makes it better arrives from readers: a bug report with the steps to reproduce it, a note about a provider that changed, a reviewed translation, a corrected sentence on one of these pages. This page says where each kind of contribution goes.

## Bugs, ideas and questions

- **[Issues](https://github.com/zeeyado/koassistant.koplugin/issues)** are for bug reports with reproducible steps, specific feature requests with a clear use case, and problems that need fixing. A screenshot of an error message is gold.
- **[Discussions](https://github.com/zeeyado/koassistant.koplugin/discussions)** are for questions and tips, prompt improvements and better results, findings from custom setups, and ideas for gestures, quick panels and workflows.

A report about a provider is most useful with the provider's name, the model, and the exact error text. A report about a device is most useful with the device, the KOReader version and the plugin version (Settings → About KOAssistant).

## Pull requests

Code changes are welcome as pull requests. The plugin is Lua on the KOReader plugin framework; `luacheck .` and `lua tests/run_tests.lua --unit` must pass, and KOReader's own LuaJIT must load every changed file (Lua 5.1 limits: 60 upvalues per function, 200 locals). See [Advanced Configuration and Development](Advanced-Configuration-and-Development) for the test suite and the request inspector.

## Editing this wiki

The pages you are reading are the `wiki/` folder of the [repository](https://github.com/zeeyado/koassistant.koplugin), one Markdown file per page, published to the GitHub wiki with every release. The wiki itself cannot be edited: a change goes through the repository, where it is reviewed like code. To fix or extend a page:

1. Open the page's file under [`wiki/`](https://github.com/zeeyado/koassistant.koplugin/tree/main/wiki) on GitHub and press the pencil icon. GitHub forks the repository and prepares the pull request for you; no git knowledge needed. If that is more than you want to do, open an issue quoting the sentence that is wrong.
2. Submit the pull request. It is reviewed like a code change and lands on the live wiki with the next release.

Three rules keep the pages navigable (the test suite checks them): links between pages are written `[text](Page-Name)` or `[text](Page-Name#section-anchor)`, never with `.md`; images are absolute URLs; menu paths are written in full, from the top of the KOAssistant menu (`Settings → Reading & Library → X-Ray`, never a shorthand that skips a level), and KOReader's own menus as "KOReader's gear menu → …". Each topic has one owner page, listed in the sidebar; another page that touches it links there instead of repeating it.

**Pages in other languages** are welcome. Name them with a language suffix (`Getting-Started-FR`, `Using-X-Ray-AR`) and add a line at the top saying what they translate. A page translated with AI assistance is useful too; say so at the top, so native speakers know they can improve the phrasing. A guide that has no English equivalent can start in your language.

## Translating the plugin

The plugin's interface is available in 26 languages: French, German, Italian, Spanish, Portuguese, Brazilian Portuguese, Dutch, Finnish, Norwegian Bokmål, Swedish, Russian, Polish, Czech, Ukrainian, Chinese, Japanese, Korean, Vietnamese, Indonesian, Thai, Hindi, Bengali, Urdu, Arabic, Persian (Farsi) and Turkish.

[![AI-translated](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fhosted.weblate.org%2Fapi%2Fprojects%2Fkoassistant%2Fstatistics%2F&query=%24.fuzzy_percent&suffix=%25&label=AI-translated&color=8ab4f8&cacheSeconds=3600)](https://hosted.weblate.org/engage/koassistant/)
[![Human-reviewed](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fhosted.weblate.org%2Fapi%2Fprojects%2Fkoassistant%2Fstatistics%2F&query=%24.translated_percent&suffix=%25&label=human-reviewed&color=brightgreen&cacheSeconds=3600)](https://hosted.weblate.org/engage/koassistant/)

All languages are pre-translated by AI and marked "needs editing" on Weblate, so they may contain inaccuracies or awkward phrasing. Human review and corrections are very welcome:

1. Visit the [KOAssistant project on Weblate](https://hosted.weblate.org/engage/koassistant/).
2. Create an account or log in.
3. Pick a language and start reviewing or translating.
4. Translations sync to the repository on their own and ship with the next release.

To add a new language, open an issue or request it on Weblate. The plugin is under active development, so some strings change between versions; contributions are kept and maintained. If you would rather see the original interface, **Settings → Display Settings → Plugin UI Language** switches it to English. The languages the AI answers in are a separate matter: see [Languages](Languages).

## Helping a provider become tested

Providers marked *Docs-based* in the provider table were implemented from their documentation; the maintainer holds no key for them, so regressions can go unnoticed. You can promote one: try it and open an issue with what worked and what did not, or donate a limited-spend, revocable API key to the contact email on the maintainer's GitHub profile. A few cents of quota is enough to join the automated probe battery, and the key can be revoked at any time. See [Providers and Models](Providers-and-Models).

## Related

- [Advanced Configuration and Development](Advanced-Configuration-and-Development): the test suite, the request inspector, running off the main branch.
- [Troubleshooting](Troubleshooting): what to check before filing a report.
- [Languages](Languages): the AI's languages, as opposed to the interface's.
