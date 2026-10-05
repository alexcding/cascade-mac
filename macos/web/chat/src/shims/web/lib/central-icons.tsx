// Shim of apps/web/src/lib/central-icons.tsx.
//
// Synara serves its Central icons as static files (/central-icons-reversed/<name>.svg) and
// paints them through a CSS mask. The chat page is served from a scheme that hands out only
// flat html/css/js files, so the icons are bundled instead: the build inlines the SVGs the
// vendored source names (virtual module "cascade:central-icons", read from
// vendor/synara/apps/web/public) and this module turns one into a data: URL. Everything else
// is Synara's module as it is.
import { forwardRef, type CSSProperties, type HTMLAttributes, type ReactElement } from "react";
import { cn } from "~/lib/utils";
import { CENTRAL_ICONS } from "cascade:central-icons";

const CENTRAL_ICON_SETS = { reversed: "reversed", fill: "fill" } as const;
export type CentralIconVariant = keyof typeof CENTRAL_ICON_SETS;
const DEFAULT_CENTRAL_ICON_VARIANT: CentralIconVariant = "reversed";
const SVG_SUFFIX = ".svg";
const CENTRAL_ICON_NAME_PATTERN = /^[a-z0-9][a-z0-9-]*$/;

export type CentralIconProps = Omit<HTMLAttributes<HTMLSpanElement>, "children"> & {
  name: string;
  label?: string | undefined;
  variant?: CentralIconVariant | undefined;
};

const urls = new Map<string, string | null>();

export function getCentralIconUrl(
  name: string,
  variant: CentralIconVariant = DEFAULT_CENTRAL_ICON_VARIANT,
): string | null {
  if (typeof name !== "string") return null;
  const normalizedName = name.endsWith(SVG_SUFFIX) ? name.slice(0, -SVG_SUFFIX.length) : name;
  if (!CENTRAL_ICON_NAME_PATTERN.test(normalizedName)) return null;
  const key = `${variant}/${normalizedName}`;
  let url = urls.get(key);
  if (url === undefined) {
    const svg = CENTRAL_ICONS[variant]?.[normalizedName] ?? CENTRAL_ICONS.reversed[normalizedName];
    url = svg ? `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}` : null;
    urls.set(key, url);
  }
  return url;
}

const CENTRAL_ICON_BASE_CLASS = "inline-block size-4 shrink-0 bg-current";
export const CENTRAL_ICON_SLOT = "central-icon";

function centralIconMaskValue(iconUrl: string): string {
  return `url("${iconUrl}") center / contain no-repeat`;
}

/** Mirror Button/Toggle `[&_svg:*]` child rules for masked Central icons. */
export function extendButtonIconChildSelectors(className: string): string {
  let result = className;
  result = result.replace(
    /\[&_svg:not\(\[class\*='opacity-'\]\)\]:([^\s"']+)/g,
    (match, util) =>
      `${match} [&_[data-slot=${CENTRAL_ICON_SLOT}]:not([class*='opacity-'])]:${util}`,
  );
  result = result.replace(
    /((?:sm:|not-in-data-\[slot=input-group\]:)?\[&_svg:not\(\[class\*='size-'\]\)\]:[^\s"']+)/g,
    (match) => {
      const central = match.replace("[&_svg:not", `[&_[data-slot=${CENTRAL_ICON_SLOT}]:not`);
      return `${match} ${central}`;
    },
  );
  result = result.replace(
    /\[&_svg\]:([a-z0-9\-/[\].]+)/g,
    (match, util) => `[&_svg,&_[data-slot=${CENTRAL_ICON_SLOT}]]:${util}`,
  );
  return result;
}

export const CentralIcon = forwardRef<HTMLSpanElement, CentralIconProps>(function CentralIcon(
  { name, label, variant, className, style, ...props },
  ref,
) {
  const iconUrl = getCentralIconUrl(name, variant);
  if (!iconUrl) return null;
  const maskValue = centralIconMaskValue(iconUrl);
  const maskStyle = { WebkitMask: maskValue, mask: maskValue, ...style } satisfies CSSProperties;
  return (
    <span
      {...props}
      ref={ref}
      role={label ? "img" : undefined}
      aria-label={label}
      aria-hidden={label ? undefined : true}
      data-slot={CENTRAL_ICON_SLOT}
      className={cn(CENTRAL_ICON_BASE_CLASS, className)}
      style={maskStyle}
    />
  );
});

export function createCentralIconComponent(
  name: string,
  variant?: CentralIconVariant,
): (props: { className?: string }) => ReactElement {
  function CentralIconGlyph({ className }: { className?: string }) {
    return <CentralIcon name={name} variant={variant} className={className} />;
  }
  CentralIconGlyph.displayName = `CentralIconGlyph(${name})`;
  return CentralIconGlyph;
}

export function createCentralIconElement(
  name: string,
  className?: string,
  variant?: CentralIconVariant,
): HTMLSpanElement | null {
  const iconUrl = getCentralIconUrl(name, variant);
  if (!iconUrl) return null;
  const span = document.createElement("span");
  span.setAttribute("aria-hidden", "true");
  span.dataset.slot = CENTRAL_ICON_SLOT;
  span.className = cn(CENTRAL_ICON_BASE_CLASS, className);
  const maskValue = centralIconMaskValue(iconUrl);
  span.style.setProperty("-webkit-mask", maskValue);
  span.style.setProperty("mask", maskValue);
  return span;
}
