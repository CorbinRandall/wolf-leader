// Small shared helpers. Nothing here knows about Electron, so the core runs anywhere Node does.

/** The Mac app stores times as seconds since 2001-01-01; chats are shared with it, so we do too. */
export const APPLE_EPOCH = 978307200;
export const nowApple = () => Date.now() / 1000 - APPLE_EPOCH;
export const appleToDate = (apple: number) => new Date((apple + APPLE_EPOCH) * 1000);

/** ISO-8601 UTC with milliseconds, the form the hub compares chat copies by. */
export function isoMs(apple: number): string {
  return appleToDate(apple).toISOString().replace(/(\.\d{3})\d*Z$/, "$1Z");
}

export function oneLine(text: unknown, limit = 90): string {
  const flat = String(text ?? "").replace(/\s+/g, " ").trim();
  return flat.length > limit ? flat.slice(0, limit) + "…" : flat;
}

/** Short, readable text for any JSON value an agent sends (tool inputs and outputs). */
export function describe(value: any, limit = 4000): string {
  if (value === null || value === undefined) return "";
  let text: string;
  if (typeof value === "string") text = value;
  else if (Array.isArray(value)) {
    text = value
      .map((item) => {
        if (item && typeof item === "object") {
          if (typeof item.text === "string") return item.text;
          if ("content" in item) return describe(item.content, limit);
        }
        return describe(item, limit);
      })
      .join("\n");
  } else {
    try {
      text = JSON.stringify(value, null, 2);
    } catch {
      text = String(value);
    }
  }
  return text.length > limit ? text.slice(0, limit) + "\n…" : text;
}

export function uuid(): string {
  return (globalThis.crypto as any).randomUUID().toUpperCase();
}

export function safeSlug(slug: string): string {
  const cleaned = (slug || "").toLowerCase().replace(/[^a-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "");
  return cleaned || "project";
}

export const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
