/**
 * Pre-encode `&` in text content before passing to TUI components.
 *
 * @opentui/solid calls decodeHTML() on all `content` and `text` properties
 * via its SolidJS reconciler. This incorrectly decodes HTML entities like
 * &amp;lt; → < in AI message content that should be displayed literally.
 *
 * Only `&` needs encoding because all HTML entities start with `&`. Encoding
 * `&` to `&amp;` prevents decodeHTML from matching any entity, so the original
 * text passes through unchanged: encode(&) → decodeHTML → original.
 *
 * `<` and `>` do NOT need encoding — the TUI is not a browser and renders
 * them as literal characters regardless.
 */
export function escapeSolidContent(text: string): string {
  return text.replace(/&/g, "&amp;")
}
