// Entry of the chat page. Native pushes the context (which thread, light or dark, read-only),
// the providers and the thread; the page renders Synara's chat for that thread and talks
// back only through the bridge (bridge.ts).
import "./storage";
import "./bridge";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { StrictMode, useEffect, useSyncExternalStore } from "react";
import { createRoot } from "react-dom/client";

import { AnchoredToastProvider, ToastProvider } from "~/components/ui/toast";
import { useAppSettings } from "~/appSettings";
import { useAppDensity } from "~/hooks/useAppDensity";
import { useAppTypography } from "~/hooks/useAppTypography";
import { useChatWidth } from "~/hooks/useChatWidth";
import { useNativeFontSmoothing } from "~/hooks/useNativeFontSmoothing";
import { useTheme } from "~/hooks/useTheme";
import { serverQueryKeys } from "~/lib/serverReactQuery";

import { emit, latestPush, onPush, reportError, type ChatContext } from "./bridge";
import { ChatController } from "./ChatController";
import { currentServerConfig } from "./shims/web/nativeApi";
import { installThreadStream } from "./threadStream";

const queryClient = new QueryClient({
  defaultOptions: {
    // The app answers at once or not at all; Synara's retries would only repeat a refusal.
    queries: { retry: false, refetchOnWindowFocus: false },
    mutations: { retry: false },
  },
});
installThreadStream(queryClient);

// The providers arrive by push, not by asking: server.getConfig is answered from them, so a
// new push refreshes it.
onPush("providers", () => {
  queryClient.setQueryData(serverQueryKeys.config(), currentServerConfig());
});

function subscribeContext(listener: () => void) {
  return onPush("context", listener);
}
function readContext() {
  return latestPush<ChatContext>("context") ?? null;
}

/** What Synara's root route sets up for every screen: theme, type scale, density, width. */
function Appearance({ context }: { context: ChatContext }) {
  const { setTheme } = useTheme();
  const { settings, updateSettings } = useAppSettings();
  useAppTypography();
  useAppDensity();
  useChatWidth();
  useNativeFontSmoothing();
  useEffect(() => {
    if (context.chatFontSizePx && context.chatFontSizePx !== settings.chatFontSizePx) {
      updateSettings({ chatFontSizePx: context.chatFontSizePx });
    }
  }, [context.chatFontSizePx, settings.chatFontSizePx, updateSettings]);
  useEffect(() => {
    setTheme(context.appearance === "dark" ? "dark" : "light");
  }, [context.appearance, setTheme]);
  useEffect(() => {
    if (context.locale) document.documentElement.lang = context.locale;
  }, [context.locale]);
  return null;
}

function Page() {
  const context = useSyncExternalStore(subscribeContext, readContext, readContext);
  useEffect(() => {
    queryClient.setQueryData(serverQueryKeys.config(), currentServerConfig());
  }, [context?.cwd, context?.homeDir]);
  if (!context) return null;
  return (
    <>
      <Appearance context={context} />
      <ChatController key={context.threadId} context={context} />
    </>
  );
}

try {
  const root = document.getElementById("chat");
  if (!root) throw new Error("The chat page has no #chat element.");
  createRoot(root).render(
    <StrictMode>
      <QueryClientProvider client={queryClient}>
        <ToastProvider position="top-center">
          <AnchoredToastProvider>
            <Page />
          </AnchoredToastProvider>
        </ToastProvider>
      </QueryClientProvider>
    </StrictMode>,
  );
  emit("ready");
} catch (error) {
  reportError(error);
}
