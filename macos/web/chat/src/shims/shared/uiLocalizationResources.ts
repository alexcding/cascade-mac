// Shim of packages/shared/src/uiLocalizationResources.ts.
//
// Synara bundles its interface catalogues for English, Spanish and Chinese. The page speaks
// English only (src/shims/web/i18n/locale.ts), so only the English catalogue is bundled: the
// others would be some 860 KB the page never reads. Same export, with the `en` namespaces only.
import chat0 from "@synara/shared/locales/en/chat.json";
import onboarding0 from "@synara/shared/locales/en/onboarding.json";
import workspace0 from "@synara/shared/locales/en/workspace.json";
import settings0 from "@synara/shared/locales/en/settings.json";
import common0 from "@synara/shared/locales/en/common.json";
import computer0 from "@synara/shared/locales/en/computer.json";
import automation0 from "@synara/shared/locales/en/automation.json";
import git0 from "@synara/shared/locales/en/git.json";

export const uiLocalizationResources = {
  en: {
    chat: chat0,
    onboarding: onboarding0,
    workspace: workspace0,
    settings: settings0,
    common: common0,
    computer: computer0,
    automation: automation0,
    git: git0,
  },
} as const;
