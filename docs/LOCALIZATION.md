# UI wording, help, and localization

English is the source language. The native string catalog contains translations
for all 12 locales below. Run the validation command below for the current entry count. Translations were written directly, without Google Translate
or an external translation service. They have not had independent native-speaker review.

| Locale | Language |
| --- | --- |
| zh-Hans | 简体中文 — Simplified Chinese |
| zh-Hant | 繁體中文 — Traditional Chinese |
| hi | हिन्दी — Hindi |
| es | Español — Spanish |
| fr | Français — French |
| bn | বাংলা — Bengali |
| pt-BR | Português (Brasil) — Brazilian Portuguese |
| ru | Русский — Russian |
| ja | 日本語 — Japanese |
| ko | 한국어 — Korean |
| sv | Svenska — Swedish |
| it | Italiano — Italian |

This is the requested language set, not a claim about a specific population ranking.
Chinese scripts are separate localizations; Portuguese currently uses Brazilian Portuguese.

## Coverage

- Corrected onboarding claims that an agent is required and that Cascade stores no
  credentials. Shell-only sessions are supported; a Jira API token can be saved in settings.
- Replaced obsolete Settings → CLIs directions with Settings → Integrations.
- Clarified polling, ticket limits, status-line behavior, and optional setup.
- Translated notification preferences, review alerts, pull request and Jira activity
  summaries, worktree and webhook events, and automation notices. Preview notices
  distinguish a dry run from executed actions. Activity filters, errors, and log deletion
  confirmations now use localized text; the all-logs confirmation explicitly
  says it removes every log. Raw diagnostic payloads retain their original text.
- Translated project forms, deletion confirmations, workflow editors and run controls.
- Translated Jira controls and automation templates, conditions, actions, and run traces.
  Stored identifiers, JQL, command text, and user-authored content retain their values.
- Translated browser dialogs, file/editor actions, build and simulator guidance, and
  session removal confirmations. Diff labels arrive through the native render payload.
- Chat permissions, tool summaries, composer hints, and Markdown controls use
  localized labels supplied by the native app. Conversation content stays unchanged;
  dates and durations follow the locale.
- Translated dashboard summaries, filters, search, greetings, and usage labels, plus
  menu-bar review and usage panels.
- Translated resource usage, process categories, sampling notes, and unavailable-state
  explanations. CPU percentages and compact usage numbers follow the locale.
- Translated database diagnostics, using complete count labels and localized dates
  for the last successful synchronization. Summary counts stack vertically to
  accommodate longer labels.
- Translated font and keyboard shortcut settings, including reserved-key and conflict
  explanations. Font reset help now refers to View → Actual Size; ⌘0 selects session 10.
- Translated settings for appearance, browsing data, worktrees, terminal rendering,
  editor previews, startup, and microphone access, including validation messages.
  The macOS microphone permission explanation has its own InfoPlist catalog.
  Browser removal dialogs use complete localized questions rather than inserting
  lowercased labels into English grammar.
- Translated onboarding text and CLI installation, authentication, and hook status
  messages. Introductory and completion pages scroll for longer translations.
  The completion page no longer claims all tools were checked successfully when
  checks may still be pending or unavailable.
- Added Help → Cascade Help (Command-?) with eight searchable, offline articles.
  Help → Detailed User Guide (English) preserves access to the existing Help Book.
  All article titles and bodies are translated into all 12 locales. Search matches
  localized titles and article text. The native view supports text selection,
  accessibility headings, and a localized empty state.
- Added a native string catalog for common actions, menu commands, dashboard tab
  labels, settings section names, sidebar headings and session context actions.
- Wired known app-owned dynamic labels through localization. User content is not
  translated: project names, branches, file paths, terminal output, and remote content
  must retain their original text.

macOS selects the app language. Change it under System Settings → General →
Language & Region → Applications, then restart Cascade. Unavailable translations fall back to English.

## Scope and review

Project names, branches, file paths, terminal output, remote pages, and raw server or
CLI diagnostics retain their original text. The detailed legacy Help Book remains
English; the native help articles are available in every supported locale.

Compiler extraction checks catalog coverage of SwiftUI literals and explicit lookups.
It does not prove that every runtime message or layout has been reviewed. Translation
quality has not had independent native-speaker review.

## Authoring rules

Fix the English source before translating. Prefer concrete action names and explain
what is affected before a destructive action. Use the visible settings names.
Keep Git, GitHub, Jira, Cascade, CLI commands, paths, and configuration identifiers
unchanged. Translate session/worktree consistently and keep the two concepts distinct.
Never use a translated label as a stored enum value or API identifier.

SwiftUI literals localize automatically when their initializer accepts
`LocalizedStringKey`. A `String` variable does not: use `String(localized:)` at the
source of app-owned labels or `LocalizedStringKey` at a shared presentation boundary.
AppKit requires an explicit bundle lookup. Do not apply lookups indiscriminately
to user-generated titles or server text. Translate complete interpolated sentences,
not concatenated fragments; add plural variations for quantities when needed.

## Verification

```sh
python3 macos/scripts/check-localizations.py
mkdir -p /private/tmp/cascade-localizations
xcrun xcstringstool compile macos/Resources/Localizable.xcstrings \
  --output-directory /private/tmp/cascade-localizations
```

To inventory missing compiler-extracted keys after building:

```sh
python3 macos/scripts/check-localizations.py \
  --extracted-directory macos/.build/xcode/Build/Intermediates.noindex/Cascade.build/Debug/Cascade.build/Objects-normal/arm64 \
  --report /private/tmp/cascade-untranslated-extracted.json
```

The report includes code examples and symbols that need explicit classification.
Compiler extraction does not include plain String properties, AppKit literals,
backend messages, or the diff page. Review those sources separately.

The check validates completeness of catalog entries, format placeholders, all eight
help articles, and unchanged login commands. It does not measure whole-app coverage.
Layout checks used isolated French dashboard and Help windows. Terminal liveness has
regression tests. These checks are representative, not a visual review of every
screen in every locale.

Build the app with the normal Xcode workflow. For UI checks use an isolated preview
or a separate backend data directory and PTY socket, keeping normal sessions untouched.
