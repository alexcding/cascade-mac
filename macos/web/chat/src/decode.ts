// Decodes what the app pushes with Synara's own schemas, as Synara's WebSocket transport does
// with what its server sends: optional fields get their defaults, and a payload that does not
// match the contract is reported to the app rather than silently drawn wrong. A payload that
// fails is still used as sent, so one bad field does not blank the conversation.
import {
  OrchestrationEvent,
  OrchestrationThreadDetailSnapshot,
  ServerProviderStatus,
} from "@synara/contracts";
import { Schema } from "effect";

import { logOnce } from "./bridge";

function decoder<S extends Schema.Top>(schema: S, label: string) {
  const decode = Schema.decodeUnknownSync(schema as never) as (value: unknown) => S["Type"];
  return (value: unknown): S["Type"] => {
    try {
      return decode(value);
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      logOnce(`decode:${label}:${detail.slice(0, 200)}`, `A pushed ${label} does not match Synara's contract: ${detail.slice(0, 2000)}`);
      return value as S["Type"];
    }
  };
}

export const decodeThreadSnapshot = decoder(OrchestrationThreadDetailSnapshot, "thread snapshot");
export const decodeOrchestrationEvent = decoder(OrchestrationEvent, "orchestration event");
const decodeStatuses = decoder(Schema.Array(ServerProviderStatus), "provider status list");

let lastStatusesInput: unknown;
let lastStatuses: ReadonlyArray<ServerProviderStatus> = [];
export function decodeProviderStatuses(value: unknown): ReadonlyArray<ServerProviderStatus> {
  if (value === lastStatusesInput) return lastStatuses;
  lastStatusesInput = value;
  lastStatuses = Array.isArray(value) ? decodeStatuses(value) : [];
  return lastStatuses;
}
