# Companion: Accessibility Standards — Worked Examples

Worked code examples and consolidation history split out of the
always-loaded [`accessibility`](../accessibility.md) rule to keep it lean.
The normative content (Four Pillars, Color/Contrast/Alt-Text/Table tables,
the 6 Dark Mode clauses, Mandatory Vignette Toolbar table, Forbidden
Patterns) stays in the rule; this file is the verbatim CSS/YAML snippets and
the dated worked example, loaded on demand.

## Rule Consolidation History

Consolidated from: `accessibility-standards`, `dark-mode-completeness`.

## HTML Accessibility — worked YAML snippet

```yaml
format:
  html:
    axe: true  # MANDATORY
```

## Clause 0 — issue 0027 worked example (private-repo tracker)

**5 merged iterations** fixed the wrong layer (mermaid theme override, CSS
catch-all, vendored mermaid 10, per-diagram `%%{init}%%`, http-server
workaround) before the `color-scheme: dark` meta tag was identified as the
root cause.

## Clause 1 — worked CSS snippet

```css
/* RIGHT */
body.dark-mode #element {
  background: #000000 !important;
  color: #ffffff !important;
}
```

## Clause 3 — worked catch-all CSS snippet

```css
body.dark-mode [style*="background:#fff"],
body.dark-mode [style*="background:#f8"]
{ background: #000000 !important; color: #ffffff !important; }
```
