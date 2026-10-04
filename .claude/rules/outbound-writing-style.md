---
description: Drafts John sends under his own name use his voice — "Hi,", lines filled to 80 columns, "John." — and copyable text is never blockquoted
paths:
  - "**/drafts/**"
  - "**/outbound/**"
  - "**/*.eml"
  - "**/email*"
  - "**/*letter*"
---

# Rule: Outbound Writing Style

## When This Applies

Any text John will **send under his own name** — email, message, letter, issue comment,
booking enquiry, complaint. Not internal prose (commit messages, rules, documentation,
CHANGELOG), which stays in house style.

Also applies, regardless of path, to **any output intended to be copy-pasted** — see
Part 2. That half is not path-scoped in practice; the `paths:` above catch the drafting
case, but Part 2 is a formatting discipline for chat output too.

---

## Part 1: His voice, not yours

The default assistant register — "Hello," … "Many thanks," … full name — is not how John
writes. A draft in the wrong register costs him a rewrite every time.

| Element | Required | Not |
|---|---|---|
| Greeting | `Hi,` | `Hello,` · `Dear …` · `Good morning` |
| Line layout | **Hard-wrapped at 80 columns**, each line filled close to 80 | A newline after every comma or clause · unwrapped paragraphs |
| Sign-off | `John.` | `Many thanks,` · `Best wishes,` · `Kind regards,` · surname |
| Em dashes | Fine — he keeps them | — |
| Paragraph breaks | Blank line between topic blocks | Wall of text |
| Phone number | Omit unless the recipient genuinely needs it (e.g. they must call, not email, to act) | Reflexively appended to every sign-off "for completeness" |

### Don't disclose the phone number by default

His email address already carries his full name, so it identifies him on its
own. The mobile number is private and goes in an outbound email only when
there's a concrete reason the recipient needs to *call* rather than reply —
not as a routine part of the sign-off block. Default sign-off is bare
`John.`; add contact detail only if the ask requires it, and prefer email
over phone when either would do.

### Fill lines to 80 columns

Hard-wrap the body at **80 characters**. Keep adding words to a line while it still
fits within 80; do not start a new line after every comma or clause. Short paragraphs
separated by blank lines carry the structure. Lists stay one item per line, with a
two-space hanging indent if an item wraps. An issue title is a single field and is
not wrapped.

Fill by tool, not by eye: `textwrap.fill(paragraph, 80)` per paragraph, then assert
no body line exceeds 80.

This supersedes the earlier "one clause per line" layout (2026-08-27), which put a
newline after nearly every comma and left most of each line empty.

### Cut questions that pre-empt a reply

Don't ask how to pay before they've confirmed a slot; don't ask about logistics for a
thing that may not happen. It clutters the ask and invites a "well, it depends" reply.
They will tell you when they confirm.

---

## Part 2: Copyable output is never blockquoted

**Anything meant to be copied — an email body, a command, a message — is output as plain
text, and additionally saved as a `.txt` file.**

Markdown blockquotes (`>`) render as **vertical bars down the left margin** in the
Claude Code terminal, and those bars are copied along with the text. The user then has
to strip them line by line, which is precisely the work the draft was meant to save.

| Purpose | Format |
|---|---|
| Text the user will **copy and send/run** | Plain text, no `>` — plus a `.txt` file |
| Text being **quoted back** (a source, their own words, a spec) | Blockquote is fine |

Self-test before formatting: *is this to read, or to copy?* If copy — plain, plus a file.

---

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| `Hello,` / `Many thanks,` / `John Gavin` in a draft | Assistant register, not his | `Hi,` … `John.` |
| Email body wrapped in `>` | Vertical bars get copied | Plain text + `.txt` |
| Newline after every comma or clause | Wastes the line; he asked for full lines | Fill each line to 80 columns |
| Unwrapped paragraph lines | Width depends on the reader's client | Hard-wrap at 80 |
| Asking about payment/logistics before confirmation | Pre-empts a reply not yet earned | Cut it |
| Phone number appended to every sign-off by default | Discloses a private number the recipient didn't need | Bare `John.`; add contact detail only when the ask requires a call |
| Applying this to commit messages or rules | Internal prose stays house style | Part 1 is for outbound only |

## Origin

User, 2026-08-27. A booking email was drafted in assistant register; John rewrote it in
his own style and asked what the difference was. In the same exchange he could not
copy-paste the draft from chat because it had been rendered as a blockquote.

Phone-number clause added 2026-09-22, premortem project: a drafted email to a charity
signed off with full name, email and mobile number appended by default; John asked for
the phone number removed and the rule updated so it isn't disclosed by default again.

80-column layout added 2026-10-04: reviewing two upstream issue drafts written one
clause per line, John asked for emails to be 80 characters wide with no newline after
every comma while the line still has room.

## Related

- [`deslop`](../skills/deslop/SKILL.md) — removes AI writing patterns from prose generally;
  this rule is the narrower question of *whose voice* an outbound draft is in
- `pr-shipping-discipline` — "always embed the issue/PR link"; same family of
  output-formatting discipline
- [`follow-the-reference-fully`](follow-the-reference-fully.md) — same family: when an
  existing artefact is named as the model, audit and apply all of it up front rather
  than one component per correction
