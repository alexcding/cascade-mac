// Shim of apps/web/src/i18n/locale.ts.
//
// Synara picks its interface language from the stored preference or the system's languages
// (English, Spanish, and Chinese where its Beta features are on, as they are on any scheme that is
// not Synara's own). Cascade's interface is English, so the page is too: every preference, the
// stored one included, resolves to English, and English is the only language offered. The stored
// value is still read and kept as Synara keeps it (appSettings decodes it), so nothing written
// by another page is lost. Same exports.
import { normalizeLanguagePreference } from "@synara/shared/uiLocale";
import type { UiLanguagePreference as LanguagePreference, UiLocale } from "@synara/contracts";

import { APP_SETTINGS_STORAGE_KEY } from "~/appSettingsStorage";

export {
  UI_LANGUAGE_PREFERENCES as LANGUAGE_PREFERENCES,
  UI_LOCALE_REGISTRY,
  normalizeLanguagePreference,
} from "@synara/shared/uiLocale";
export type {
  UiLanguagePreference as LanguagePreference,
  UiLocale as SupportedLocale,
} from "@synara/contracts";

export const UI_LOCALES: UiLocale[] = ["en"];
export const AVAILABLE_LANGUAGE_PREFERENCES: LanguagePreference[] = ["system"];

export function resolveLanguagePreference(_preference: LanguagePreference): LanguagePreference {
  return "system";
}

export function resolveLocale(_preference: LanguagePreference, _languages: readonly string[]): UiLocale {
  return "en";
}

export function readLanguagePreference(storage?: Pick<Storage, "getItem">): LanguagePreference {
  try {
    const raw = (storage ?? globalThis.localStorage)?.getItem(APP_SETTINGS_STORAGE_KEY);
    const settings: unknown = raw ? JSON.parse(raw) : null;
    return typeof settings === "object" && settings !== null && "language" in settings
      ? normalizeLanguagePreference(settings.language)
      : "system";
  } catch {
    return "system";
  }
}
