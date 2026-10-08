// Shim of apps/web/src/components/chat/ChatEmptyStateHero.tsx.
//
// Synara heads a blank chat with its own logo; in Cascade that mark stands for nothing. The words
// stay, without it. Same exports.
export const ChatEmptyStateHero = function ChatEmptyStateHero({
  projectName,
}: {
  projectName: string | undefined;
}) {
  return (
    <div className="flex flex-col items-center gap-0.5 select-none">
      <h1 className="text-2xl font-semibold text-foreground/90">Let's build</h1>
      {projectName && <span className="text-lg text-muted-foreground/40">{projectName}</span>}
    </div>
  );
};
