# Gmail Inbox

An Omarchy bar widget for your Gmail inbox: the unread count sits in the bar,
and the panel lists what is waiting — subject, sender, the first line of the
body, and how long it has been there.

![The panel, listing eight messages](screenshots/panel.png)

- **Unread count in the bar.** The exact total for the whole inbox, not just
  what fits in the panel.
- **A dot per unread message**, which doubles as the button that clears it, so
  a newsletter can be dismissed without opening it.
- **Stars**, shown where you set them and settable from the panel. The slot
  stays empty rather than absent, so the ages line up down one column.
- **Your own labels** as chips in front of the subject, resolved from label id
  to the name you gave it. Gmail's own bookkeeping — `INBOX`, the category
  tabs, `IMPORTANT` — is left out; it says nothing you did not know.
- **Mark all as read** from the header, covering every unread message in the
  inbox rather than only the ones on screen.
- **Click a message** to open it in your browser, signed in to the right
  account. It is marked read at the same time.

## Requirements

This widget assumes you already have the [Google Workspace CLI][gws]
installed and authenticated — it owns the OAuth token, and no credential ever
passes through this plugin. `jq` is used for the JSON handling.

If you do not have it yet:

```bash
npm install -g @googleworkspace/cli
gws auth login -s gmail          # opens a browser; needs an interactive terminal
```

The login needs the `gmail.modify` scope, which is what `-s gmail` grants:
reading the inbox is not enough, marking a message as read is a write.

Check it with `gws auth status` — `"token_valid": true` means you are set.

[gws]: https://github.com/googleworkspace/google-workspace-cli

## Install

```bash
omarchy plugin add https://github.com/jankeesvw/omarchy-gmail-inbox
omarchy plugin enable jankeesvw.gmail-inbox
omarchy bar move jankeesvw.gmail-inbox --section right
```

Optionally bind the panel to a key, in `~/.config/omarchy/hypr/bindings.lua`:

```lua
o.bind("SUPER + M", "Gmail", "omarchy-shell shell toggle jankeesvw.gmail-inbox")
```

## Using it

| | |
|---|---|
| Click the bar icon | open the panel |
| Right-click the bar icon | open Gmail in the browser |
| Middle-click the bar icon | refresh now |
| Click a message | open it in the browser and mark it read |
| Click its dot | mark it read, panel stays open |
| Click its star | star or unstar it, panel stays open |
| `↑` `↓` or `j` `k` | move through the list |
| `Enter` or `Space` | open the message under the cursor |
| `r` | mark that one read |
| `s` | star or unstar it |
| `a` | mark everything read |
| `Esc` | close |

The panel refreshes every minute and whenever it is opened.

## Configuration

All optional, set in the environment the shell runs in:

| Variable | Default | |
|---|---|---|
| `OMARCHY_GMAIL_QUERY` | `in:inbox` | any Gmail search query, e.g. `in:inbox category:primary` |
| `OMARCHY_GMAIL_LABEL` | `INBOX` | the label the bar counts |
| `OMARCHY_GMAIL_MAX` | `20` | messages listed in the panel (1–50) |

## How it works

`bin/gmail-inbox` is the whole backend. A refresh costs two API calls: one
`+triage` call for the subjects, senders and read state, and one label read
for the exact unread count.

Snippets and timestamps never change once a message exists, so those are
cached per message id under `$XDG_CACHE_HOME/omarchy-gmail-inbox` (mode 700,
capped at 500 entries) and only fetched for messages that have not been seen
before. An inbox that has not changed therefore costs no extra calls at all.

Labels arrive as ids (`Label_8071185…`), never as names, so the script keeps a
second table beside it. A label you have just created announces itself by
turning up as an id the table cannot resolve, which is the only thing that
triggers a refetch — so renaming or adding a label fixes itself, and the
lookup costs nothing the rest of the time.

Everything the panel draws is shaped by the script; the QML only renders a
list. Every `Text` in it is `Text.PlainText`, because subjects and snippets
are written by whoever sent the mail, and Qt's default would happily render an
`<img src="http://...">` in a subject as real rich text — an outbound request
from your shell process to a server the sender picked.

## Screenshots without your own mail in them

```bash
bin/gmail-inbox demo on     # fixed English inbox, every write becomes a no-op
bin/gmail-inbox demo off
```

## License

MIT
