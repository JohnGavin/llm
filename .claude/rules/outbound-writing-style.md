---
description: Drafts John sends under his own name use his voice — "Hi,", one clause per line, "John." — and copyable text is never blockquoted
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
| Line layout | **One clause per line**, broken at natural pauses | Paragraphs left to wrap |
| Sign-off | `John.` | `Many thanks,` · `Best wishes,` · `Kind regards,` · surname |
| Em dashes | Fine — he keeps them | — |
| Paragraph breaks | Blank line between topic blocks | Wall of text |

### One clause per line

Break at natural pauses, **including mid-sentence** after a subordinate clause. Each
line carries a single idea, so the reader takes them one at a time instead of scanning
a wrapped block — and it survives re-wrapping by the recipient's mail client.

Worked example (his own edit of a drafted booking enquiry, 2026-08-27):

```
Hi,

Which Sundays are you running tours over the next few weeks?
Your events calendar shows no upcoming dates and the site still mentions reopening on 5 April,
so I couldn't work out the current schedule.

If you're open this Sunday, 30 August,
I'd like to book one place in the afternoon — either 13:30 or 15:00, whichever suits.
I'm flexible on the date too if that Sunday isn't running.

Also, I gather the mill turns 250 this year — are there any anniversary events planned?

John.
```

Note the break after `If you're open this Sunday, 30 August,` — mid-sentence, at the
clause boundary. That is the pattern, not an accident of width.

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
| Paragraph-shaped email body | He reformats it every time | One clause per line |
| Asking about payment/logistics before confirmation | Pre-empts a reply not yet earned | Cut it |
| Applying this to commit messages or rules | Internal prose stays house style | Part 1 is for outbound only |

## Origin

User, 2026-08-27. A booking email was drafted in assistant register; John rewrote it in
his own style and asked what the difference was. In the same exchange he could not
copy-paste the draft from chat because it had been rendered as a blockquote.

## Related

- [`deslop`](../skills/deslop/SKILL.md) — removes AI writing patterns from prose generally;
  this rule is the narrower question of *whose voice* an outbound draft is in
- `pr-shipping-discipline` — "always embed the issue/PR link"; same family of
  output-formatting discipline
