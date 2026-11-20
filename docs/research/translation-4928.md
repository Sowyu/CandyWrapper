# Translation at Nightly 4928

T3 translates the whole web UI into 9 languages besides English (#31313 added the Language row with Spanish and Chinese; later commits added the rest). CandyWrapper has the Language row with System default and English only. This note says how T3 does it and how CandyWrapper can load T3's own catalogs. Nothing here is built yet.

## How T3 does it

T3 uses General Translation's `gt-react` 11.4.18 and the `gt` CLI 2.27.0 (apps/web/package.json:67, 114).

- `apps/web/gt.config.json` names the locales: `de`, `es`, `fr`, `ja`, `ko`, `pt-BR`, `ru`, `sv` and `zh` (Simplified), with `en` as the default. The CLI scans `apps/web/src`, `packages/client-runtime/src` and `packages/shared/src`.
- The catalogs are `apps/web/src/i18n/translations/<locale>.json`, one flat object per locale. Each key is a 16-hex hash of the source text and its context. `en.json` maps the same keys to the English source, so it doubles as the index from English to key.
- Code marks text three ways: `gt("...")` and `<T>...</T>` inside components, and `msg("...")` for text outside React, resolved later with `m()` or `useMessages()` (apps/web/src/i18n/messages.ts). `$context` separates two meanings of one English string, such as "Start" the verb.
- Messages are ICU MessageFormat: `{name}` arguments and `{count, plural, one {...} other {...}}` blocks. `<T>` blocks with markup are stored as arrays of strings and `{"k": "_gt_value_1"}` placeholders.
- `runtime.ts` loads a locale's catalog on demand, falls back to English for anything missing, and re-renders on a switch. English never touches the catalog.
- The setting is the client setting `language` (contracts settings.ts:585), `"system"` or a locale. `resolveLocale` (client-runtime locales.ts) matches the system's preferred languages to a supported locale. Traditional Chinese tags only match an exact `zh-Hant` catalog, which T3 does not ship. The menu shows each language in its own name (`NATIVE_LANGUAGE_NAMES`).

## The catalogs in numbers

These counts are from the 4928 tag.

- `en.json` has 9,689 entries: 9,462 plain strings and 227 `<T>` arrays.
- 8,779 distinct English strings. 458 English strings appear under more than one key, and 46 of those get different Spanish translations, so context matters for a few.
- 2,017 entries have arguments and 431 have plural blocks.
- Each locale file is 0.6 to 1.0 MB, 7.5 MB for all ten. Russian is the largest at 1.05 MB.

## What CandyWrapper shows that T3 translates

I scanned the Swift string literals in Features, DesignSystem, T3Protocol, T3Store and App/Sources, turned `\(...)` interpolations and ICU arguments into one placeholder, and compared the shapes. `scripts/i18n-coverage.py` repeats the count.

- About 7,100 distinct literals look like UI text. That count still includes log messages, test fixtures and type names.
- 3,853 of them match a T3 English string exactly by shape, so they already have a key in every locale.
- Features/Settings has the most: 2,026 of 2,782. Then Pull requests 457 of 582, Thread 366 of 639, Composer 320 of 502, Sidebar 191 of 307, Usage 174 of 218, Issues 147 of 174 and Scheduled tasks 134 of 157.
- About 1,300 unmatched literals read like UI sentences. Most are one of three kinds. Plurals that CandyWrapper builds by hand, like `"\(n) \(n == 1 ? "thread" : "threads")"`, match T3's ICU plural only after a rewrite. Copy that drifted from T3 by a word or two is a fidelity bug as well as a missing key. The rest is CandyWrapper's own text: Redesign and Dither, native-only settings, the Keychain, Sparkle and helper messages.

## Plan

1. Add `scripts/gen-translations.py`. It reads T3's `en.json` and the 9 locale files at the tag in `T3_VERSION`, scans CandyWrapper's literals as above, and writes `Packages/CandyKit/Sources/DesignSystem/Resources/Translations/<locale>.json` with only the entries CandyWrapper uses, keyed by T3's hash. It also writes `english-index.json`, English text to hash, with the context in the key when T3 has two meanings. Rerun it in the Nightly catch-up after `T3_VERSION` moves.
2. Add `L10n` to DesignSystem: the active locale, a lazy per-locale catalog load from the bundle, and `L10n.text("English", args)` that looks the English up in the index, takes the target string, and formats it. It needs a small ICU formatter for `{name}`, `plural` with `one`/`few`/`many`/`other` and `#`, and `select`. Use `Locale` plural rules through `NSString.localizedStringWithFormat` or a table for the 10 locales. Missing text falls back to English with English plural rules, as `messages.ts` does.
3. Read the `language` client setting the way `resolveLocale` does, with `Locale.preferredLanguages` for `"system"`. Offer the 10 languages in the Language row with their native names. Keep the setting's value identical to T3's so a shared settings file means the same thing in both apps.
4. Wrap literals in `L10n.text` area by area. LabelView, ButtonView, TextBlockView, DialogView, MenuView items, tooltips, toasts and accessibility labels take the wrapped text. Do it when no other agent is in that area, since it touches every view file. Rewrite hand-built plurals to T3's ICU message at the same time, and fix copy that drifted.
5. Make a switch apply live where it is cheap. Settings pages rebuild when opened, so they follow at once. The window chrome, sidebar rows and open threads read text when built, so post a change notification and rebuild the shell's top-level views on it. If that proves too broad, ask to relaunch, and say so in docs/decisions.md as a deviation.
6. CandyWrapper's own strings stay English at first, as T3's untranslated strings do. Later add `candy-<locale>.json` overlays for them, written by a translator, not machine output, and keyed by the English text.

Things to check while doing it:

- Fidelity tests run in English and must not change. Add one offscreen test per locale that renders Settings and the composer and checks nothing truncates where T3 wraps. German and Russian strings run about 30% longer.
- Search in Settings (`gen-settings-search.py`) matches English titles and keywords today. T3 searches the translated title too, so the catalog needs the translated titles.
- Dates and numbers already go through `Locale`; make them use the chosen language's locale, not the system's region, only where T3 does (`getActiveLocale`).
- Redesign is CandyWrapper's own look, but its text still comes from the same calls, so it translates with everything else.

## Size

1. The scan and the generator script: 1 to 2 hours.
2. `L10n` with the ICU formatter and tests: 2 to 3 hours.
3. The Language row, the setting and the live switch: about 1 hour, more if the shell rebuild is messy.
4. Wrapping about 3,850 matched literals and rewriting about 600 to 800 plurals and drifted strings: one long session, 4 to 6 hours of agent work across every Features folder and App/Sources. It has to wait until no other agent is editing those folders.
5. The bundle grows by about 3 MB uncompressed for 9 locales filtered to the keys CandyWrapper uses, against 6.9 MB for T3's full catalogs.

In total that is about 9 to 12 hours of agent work, plus the user's check of a few languages on screen. CandyWrapper's own 500 to 700 strings would need a translator on top of that.
