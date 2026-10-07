// What JavaScriptCore lacks of the web platform that Synara's dependencies touch as they load
// (the app runs the model catalogue in a bare JSContext, `ChatModelCatalog`): text coding, timers
// that never fire — nothing in the catalogue runs later — a clock, and a quiet console. Imported
// first by src/modelCatalog.ts, so it is in place before anything else loads; a page has all of
// these and takes nothing from here.
const scope = globalThis as unknown as Record<string, unknown>;

if (typeof scope.TextEncoder === "undefined") {
  scope.TextEncoder = class {
    readonly encoding = "utf-8";
    encode(input = ""): Uint8Array {
      const bytes: number[] = [];
      for (const character of input) {
        const code = character.codePointAt(0) ?? 0;
        if (code < 0x80) bytes.push(code);
        else if (code < 0x800) bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
        else if (code < 0x10000) bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
        else bytes.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 0x3f), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
      }
      return new Uint8Array(bytes);
    }
  };
}

if (typeof scope.TextDecoder === "undefined") {
  scope.TextDecoder = class {
    readonly encoding = "utf-8";
    decode(input?: ArrayBufferView | ArrayBuffer): string {
      if (!input) return "";
      const bytes =
        input instanceof Uint8Array ? input : new Uint8Array(input instanceof ArrayBuffer ? input : input.buffer);
      let text = "";
      for (let index = 0; index < bytes.length; ) {
        const lead = bytes[index] ?? 0;
        const length = lead < 0x80 ? 1 : lead < 0xe0 ? 2 : lead < 0xf0 ? 3 : 4;
        let code = length === 1 ? lead : lead & (0xff >> (length + 1));
        for (let offset = 1; offset < length; offset += 1) code = (code << 6) | ((bytes[index + offset] ?? 0) & 0x3f);
        text += String.fromCodePoint(code);
        index += length;
      }
      return text;
    }
  };
}

if (typeof scope.setTimeout === "undefined") {
  let next = 0;
  scope.setTimeout = () => ++next;
  scope.clearTimeout = () => {};
  scope.setInterval = () => ++next;
  scope.clearInterval = () => {};
}

if (typeof scope.queueMicrotask === "undefined") {
  scope.queueMicrotask = (task: () => void) => {
    void Promise.resolve().then(task);
  };
}

if (typeof scope.performance === "undefined") scope.performance = { now: () => Date.now() };

if (typeof scope.console === "undefined") {
  const quiet = () => {};
  scope.console = { log: quiet, info: quiet, warn: quiet, error: quiet, debug: quiet };
}
