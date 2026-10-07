// The chat page's model list and its model traits, for the app's own pickers to show the same
// (`ChatModelCatalog`). Built beside the page as ChatModelCatalog.js and run by the app in
// JavaScriptCore — never by a page, and with no window, network or backend in reach. It is
// Synara's own code: the catalogue (`MODEL_OPTIONS_BY_PROVIDER`), its default per provider, the
// merge the page's picker runs over what the CLI reported (`mergeDynamicModelOptions`), and the
// trait selection its footer draws (`getComposerTraitSelection`: the effort ladder, speed,
// thinking, the context window) with the option changes each control commits.
import "./jscPolyfills";

import { DEFAULT_MODEL_BY_PROVIDER, MODEL_OPTIONS_BY_PROVIDER, type ProviderKind } from "@synara/contracts";

import {
  getComposerTraitSelection,
  planComposerEffortChange,
  resolveComposerEffortLadderIndex,
  resolveComposerTraitStatusLabel,
  supportsComposerFastModeControl,
} from "~/components/chat/composerTraits";
import { resolveRuntimeModelDescriptor } from "~/components/chat/runtimeModelCapabilities";
import { buildNextProviderOptions, mergeDynamicModelOptions, type ProviderOptions } from "~/providerModelOptions";

type RuntimeModel = { slug: string; name?: string | null; resolvedModel?: string };

declare const globalThis: { cascadeModelCatalog?: unknown };

/** What the CLI reported (`provider.listModels`), as JSON. */
function runtimeModels(runtimeJSON: string): RuntimeModel[] {
  const parsed: unknown = JSON.parse(runtimeJSON);
  return Array.isArray(parsed) ? (parsed as RuntimeModel[]) : [];
}

function selection(provider: ProviderKind, model: string, runtimeJSON: string, optionsJSON: string) {
  const options = JSON.parse(optionsJSON) as ProviderOptions | null;
  const runtimeModel = resolveRuntimeModelDescriptor({
    provider,
    model,
    // The descriptors as the CLI gave them; the fields the page reads are its contract's.
    runtimeModels: runtimeModels(runtimeJSON) as never,
  });
  return { options, traits: getComposerTraitSelection(provider, model, "", options, runtimeModel) };
}

/** What the page's picker lists for `provider`, given what its CLI reported, in the page's order. */
function listModels(provider: ProviderKind, runtimeJSON: string): Array<{ slug: string; name: string }> {
  const staticOptions = MODEL_OPTIONS_BY_PROVIDER[provider] ?? [];
  const dynamicModels = runtimeModels(runtimeJSON).map((model) => ({
    slug: String(model.slug ?? ""),
    ...(model.name != null ? { name: String(model.name) } : {}),
    ...(model.resolvedModel ? { resolvedModel: String(model.resolvedModel) } : {}),
  }));
  const merged = mergeDynamicModelOptions({ provider, staticOptions, dynamicModels });
  return merged.map((option) => ({ slug: option.slug, name: option.name }));
}

globalThis.cascadeModelCatalog = {
  /** The page's list for `provider`, as JSON: `[{ slug, name }]` in the page's order. */
  list(provider: string, runtimeJSON: string): string {
    return JSON.stringify(listModels(provider as ProviderKind, runtimeJSON));
  },

  /**
   * Every listed model's effort ladder and default level, as JSON `{ slug: { levels, defaultEffort } }`:
   * what the page's footer would offer for each, with no options set.
   */
  ladders(provider: string, runtimeJSON: string): string {
    const kind = provider as ProviderKind;
    const ladders: Record<string, { levels: Array<{ value: string; label: string }>; defaultEffort: string | null }> = {};
    for (const { slug } of listModels(kind, runtimeJSON)) {
      const { traits } = selection(kind, slug, runtimeJSON, "null");
      ladders[slug] = {
        levels: traits.effortLevels.map((level) => ({ value: level.value, label: level.label })),
        defaultEffort: traits.defaultEffort,
      };
    }
    return JSON.stringify(ladders);
  },

  /** Synara's default model for `provider`, or null where it has none. */
  defaultModel(provider: string): string | null {
    return (DEFAULT_MODEL_BY_PROVIDER as Record<string, string | undefined>)[provider] ?? null;
  },

  /**
   * The traits the page's footer draws for `model` running with `options` (the provider's model
   * options, as JSON): the effort ladder and where it stands, speed, thinking, and the context
   * window, each as the composer resolves them.
   */
  traits(provider: string, model: string, runtimeJSON: string, optionsJSON: string): string {
    const { traits } = selection(provider as ProviderKind, model, runtimeJSON, optionsJSON);
    return JSON.stringify({
      effortLevels: traits.effortLevels.map((level) => ({ value: level.value, label: level.label })),
      effort: traits.effort,
      defaultEffort: traits.defaultEffort,
      ladderIndex: resolveComposerEffortLadderIndex(traits),
      statusLabel: resolveComposerTraitStatusLabel(traits),
      // Ultrathink in the prompt pins the ladder; the app's forms carry no prompt here.
      locked: traits.ultrathinkPromptControlled,
      supportsFastMode: supportsComposerFastModeControl(traits),
      fastModeEnabled: traits.fastModeEnabled,
      thinkingEnabled: traits.thinkingEnabled,
      contextId: traits.contextWindowDescriptor?.id ?? null,
      contextLabel: traits.contextWindowDescriptor?.label ?? null,
      contextOptions: traits.contextWindowOptions.map((option) => ({ value: option.value, label: option.label })),
      contextWindow: traits.contextWindow,
      defaultContextWindow: traits.defaultContextWindow,
    });
  },

  /**
   * `options` with the effort set to `value`, as JSON, or null for a level the page sets through
   * the prompt (Ultrathink), which these forms do not carry.
   */
  setEffort(provider: string, model: string, runtimeJSON: string, optionsJSON: string, value: string): string | null {
    const kind = provider as ProviderKind;
    const { options, traits } = selection(kind, model, runtimeJSON, optionsJSON);
    const plan = planComposerEffortChange({ provider: kind, selection: traits, prompt: "", value });
    if (!plan || plan.kind !== "options") return null;
    return JSON.stringify(buildNextProviderOptions(kind, options, plan.patch));
  },

  /** `options` with `patch` (speed, thinking, the context window) laid over, as JSON. */
  setTrait(provider: string, optionsJSON: string, patchJSON: string): string {
    const kind = provider as ProviderKind;
    const options = JSON.parse(optionsJSON) as ProviderOptions | null;
    return JSON.stringify(buildNextProviderOptions(kind, options, JSON.parse(patchJSON) as Record<string, unknown>));
  },

  /** `options` back at the model's default effort and standard speed, as the card's reset. */
  resetTraits(provider: string, model: string, runtimeJSON: string, optionsJSON: string): string {
    const kind = provider as ProviderKind;
    const { options, traits } = selection(kind, model, runtimeJSON, optionsJSON);
    const effortIsDefault = traits.ultrathinkPromptControlled || traits.effort === traits.defaultEffort;
    const plan =
      traits.defaultEffort && !effortIsDefault
        ? planComposerEffortChange({ provider: kind, selection: traits, prompt: "", value: traits.defaultEffort })
        : null;
    return JSON.stringify(
      buildNextProviderOptions(kind, options, {
        ...(plan?.kind === "options" ? plan.patch : {}),
        ...(traits.fastModeEnabled ? { fastMode: false } : {}),
      }),
    );
  },
};
