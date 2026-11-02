# safeshot

**Beautiful screenshots that never leak your secrets.**

You screenshot a terminal, a dashboard or a config file, drop it in Slack, a GitHub issue or on X — and an
API key, a customer email or a database password goes with it. `safeshot` reads the screenshot **on your
Mac**, finds secrets and personal data, hides them with a redaction that can't be reversed, and then makes
the image look good: gradient background, padding, rounded corners, soft shadow, optional macOS window chrome.

Free, MIT-licensed, one native binary, no network code at all.

| Before (fake secrets) | After `safeshot shot.png --frame macos` |
|---|---|
| ![before](docs/before-terminal.png) | ![after](docs/after-terminal.png) |
| ![before](docs/before-dashboard.png) | ![after](docs/after-dashboard.png) |
| ![before](docs/before-editor.png) | ![after](docs/after-editor.png) |

Every image above was produced by safeshot itself (`safeshot-fixtures` renders the "before" screenshots; all
credentials in them are fake — they contain `FAKE`/`EXAMPLE` or are documented example values).

`--dry-run` shows what would be hidden, labelled by rule:

![dry run](docs/preview-editor.png)

## How it works

```
image ─▶ OCR (Apple Vision, on-device) ─▶ detectors ─▶ per-substring boxes ─▶ redact ─▶ beautify ─▶ file / clipboard
```

1. **OCR** — Vision's accurate recogniser with language correction **off** (secrets aren't words). Vision only
   reports word-level boxes in accurate mode, so safeshot also runs the fast recogniser (real per-glyph
   boxes), aligns the two transcriptions and redacts just the secret part of `API_KEY=sk-…`, not the whole
   word. Extra passes (greyscale/inverted copy, overlapping crops, isolated "uncovered ink" bands) catch lines
   Vision skips in the full frame.
2. **Detect** — a data-driven rule list (see `safeshot rules`), tolerant of OCR noise: Cyrillic/Greek
   look-alikes are normalised, prefixes accept `I/l/1` and `O/0` confusions, credit-card digits are mapped
   back from `O`, `l`, `S`, `B` before the Luhn check, and tokens soft-wrapped onto the next terminal line are
   joined and redacted on both lines.
3. **Redact** — every style first paints the region with the surrounding background colour, so **no pixel of
   the original text survives**. Then:
   - `pixelate` (default): a mosaic of *random* blocks in the text/background colours,
   - `blur`: random glyph-shaped strokes, Gaussian-blurred — looks like blurred text, contains none,
   - `bar`: a rounded bar in a shade of the surrounding background.

   Why not just blur or pixelate the real text? Both are deterministic low-pass filters of the glyphs, and
   short strings rendered in a known font can be recovered by rendering candidates and comparing (this is how
   tools like Depix un-pixelate passwords). safeshot never feeds the secret's pixels into the effect.
4. **Beautify** — gradient presets / solid / transparent / your own image, padding, rounded corners,
   three-layer soft shadow, hairline edge, optional macOS title bar, X/Twitter 16:9 or square canvas.
   **Auto-balance** detects the screenshot's own border colour and re-pads the content evenly when you cropped
   it lopsided (skipped for edge-to-edge UIs). Retina density is kept (144 dpi in, 144 dpi out).

## Install / build

Requires macOS 14+ and the Swift toolchain (Xcode or the Command Line Tools).

```sh
git clone https://github.com/thecidsama/safeshot && cd safeshot
swift build -c release
cp .build/release/safeshot /usr/local/bin/   # or anywhere on your PATH
```

(With recent Command Line Tools the products land in `.build/out/Products/Release/`; `swift build -c release --show-bin-path` prints the directory.)

## Quickstart

```sh
safeshot shot.png                          # -> shot.safeshot.png (redacted + beautified)
safeshot shot.png -o out.png --frame macos --title "zsh" --style sunset
safeshot shot.png --redact bar --style none          # redact only, keep the original framing
safeshot shot.png --dry-run --report                 # outline findings, print what was found
safeshot --clipboard                                 # process the image on the clipboard, put it back
safeshot watch ~/Desktop --out ~/Desktop/safeshot    # auto-process new screenshots
safeshot review shot.png                             # window: toggle each finding, pick a style, Copy/Save
safeshot menubar                                     # menu bar item: "Redact & Beautify Clipboard"
```

A typical flow: <kbd>⌘⇧⌃4</kbd> (screenshot to clipboard) → `safeshot --clipboard` (bind it to a hotkey with
Shortcuts/Raycast/Alfred, or use `safeshot menubar`) → paste.

## CLI reference

```
safeshot <image> [-o out.png] [options]      redact + beautify an image file
safeshot --clipboard [options]               process the clipboard image, put the result back
safeshot watch <dir> [--out <dir>] [--once]  auto-process new screenshots appearing in <dir>
safeshot review <image> | --clipboard        review window (toggle each redaction, Copy/Save)
safeshot menubar                             menu bar item
safeshot ocr <image> [--chars]               OCR result as JSON: lines, word boxes, per-glyph boxes
safeshot rules [--json]                      list rules and whether they are enabled
safeshot config init|path|print              create / locate / show the config file

Redaction
  -r, --redact <pixelate|blur|bar|off>  default pixelate
  -n, --dry-run                         outline findings instead of redacting (*.safeshot-preview.png)
      --report [text|json]              print findings: rule, severity, masked preview, pixel box
      --json                            same as --report json
      --report-file <path>              also write the JSON report to a file
      --disable <id,id> / --enable <id,id>
      --fail-on-findings                exit 3 if anything was found (handy in scripts/CI)
      --config <path>                   default ~/.config/safeshot/config.json ($XDG_CONFIG_HOME respected)
Beautify
  -s, --style <preset|#hex|transparent|image:path|none>
        presets: ocean (default), sunset, candy, aurora, forest, peach, midnight, graphite, paper, lavender
  -p, --padding <pt>   --radius <pt>   --shadow none|soft|strong
      --frame none|macos|macos-light|macos-dark   --title <text>
      --size original|16:9|twitter|square|4:3|3:2|4:5|W:H
      --no-balance     --scale <n>
Output
  -o, --output <path>  --out <dir> (watch)  --copy  -q
Exit status: 0 ok, 1 error, 2 usage error, 3 findings present (with --fail-on-findings)
```

Report example (values are masked — the report never contains a full secret):

```
docs/before-terminal.png: 10 findings -> docs/after-terminal.png
  F1   critical anthropic-api-key           sk-ant-…a1F         x=301 y=139 912x40
  F4   critical aws-access-key-id           AKIA…PLE            x=306 y=252 329x43
  F9   high     jwt                         eyJh…Rt4            x=863 y=520 674x37 (+6 boxes)
  F10  medium   email                       j…@….com            x=377 y=634 330x43
```

## What it detects

| id | what |
|---|---|
| `aws-access-key-id`, `aws-secret-access-key` | `AKIA…`/`ASIA…` IDs; 40-char secrets next to an `aws_secret`/`SecretAccessKey` label |
| `github-token`, `github-fine-grained-pat`, `gitlab-token` | `ghp_ gho_ ghu_ ghs_ ghr_`, `github_pat_`, `glpat-` |
| `openai-api-key`, `anthropic-api-key` | `sk-`, `sk-proj-`, `sk-svcacct-`; `sk-ant-` |
| `stripe-secret-key`, `stripe-publishable-key` | `sk_live_ rk_live_ sk_test_`; `pk_live_` (low) |
| `slack-token`, `slack-webhook` | `xoxb- xoxp- xoxa- xoxr- xoxs-`; `hooks.slack.com/services/…` |
| `google-api-key`, `npm-token`, `huggingface-token`, `sendgrid-api-key` | `AIza…`, `npm_`, `hf_`, `SG.…` |
| `jwt` | `eyJ….eyJ….…` |
| `private-key` | `-----BEGIN … PRIVATE KEY-----` and the base64 body on the following lines |
| `connection-string-password` | the password in `scheme://user:password@host` |
| `authorization-header` | `Bearer …`, `Basic …`, `Token …` |
| `secret-assignment` | `KEY=…`, `TOKEN: …`, `"password": "…"`, `--password=…`, `X-Api-Key: …` (placeholders like `${VAR}`, `********`, `os.environ[...]`, type names are ignored) |
| `high-entropy-string` | random-looking 20+ char tokens (Shannon entropy, mixed charset; git SHAs/digests, UUIDs, paths and camelCase identifiers are skipped) |
| `email`, `phone-number` | PII |
| `credit-card` | 13–19 digits, Luhn-validated |
| `ipv4`, `ipv6` | addresses (`127.0.0.1`, `0.0.0.0`, `::1` allowlisted by default) |

## Configuration

`safeshot config init` writes `~/.config/safeshot/config.json`. All keys are optional:

```json
{
  "rules": { "ipv4": false, "phone-number": false },
  "minimumSeverity": "low",
  "customRules": [
    { "id": "acme-token", "description": "ACME internal token",
      "pattern": "acme_[A-Za-z0-9]{32}", "severity": "critical" },
    { "id": "employee-id", "pattern": "EMP-(\\d{6})", "groups": [1], "severity": "medium" }
  ],
  "allowlist": { "strings": ["me@example.com"], "patterns": ["^10\\.0\\.0\\.\\d+$"] },
  "useDefaultAllowlist": true,
  "defaults": { "redact": "pixelate", "style": "ocean", "padding": 64, "radius": 12,
                "shadow": "soft", "frame": "none", "size": "original", "balance": true,
                "watchOutput": "~/Desktop/safeshot" }
}
```

Custom rules use the same schema as the built-ins (`Sources/SafeshotCore/Detection/BuiltinRules.swift`):
`pattern` (ICU regex), `groups` (which capture group is the secret), `caseInsensitive`, `keywords` (context
words required on the line or the line above), `validators` (`luhn`, `entropy`, `tokenish`, `assignment`,
`phone`, `ipv6`), `severity`, `enabled`.

## Privacy

- Everything runs on your Mac. OCR is Apple's Vision framework, which recognises text on-device.
- safeshot contains **no networking code**: no `URLSession`, no sockets, no telemetry, no update checks.
  `grep -rn "URLSession\|NWConnection\|socket(" Sources` comes back empty.
- Reports contain masked previews (`sk-ant-…a1F`) and pixel boxes, never full values.
- Input images are never modified; output defaults to `<name>.safeshot.png` next to the input.

## Compared to paid tools

[Xnapper](https://xnapper.com) and [CleanShot X](https://cleanshot.com) are polished, paid macOS apps. Xnapper
beautifies screenshots and can auto-redact sensitive information; CleanShot X is a full capture suite
(scrolling capture, recording, annotation, cloud sharing). Check their sites for current features and pricing.

safeshot is narrower: it doesn't capture the screen (use macOS's own shortcuts), has no annotation tools and
no cloud. What it offers is free/MIT, scriptable (CLI, clipboard, folder watch, JSON report, exit codes),
inspectable detection rules you can extend, and redaction styles that never reuse the secret's pixels.

## Limitations — always review before you share

- **OCR can miss text.** Tiny, blurry, low-contrast, rotated or heavily stylised text may not be read, and
  what isn't read can't be redacted. In the synthetic test set, Vision never returned one terminal line —
  `{"id": 1042, "email": "jane.doe@example.com", …}` rendered in SF Mono 12pt (light), Courier 14pt (light)
  and SF Mono 11pt @1x (dark) — not even from an isolated crop of that line, so the email in it stays visible
  in those three variants (3 of 106 planted secrets). The same line in Menlo, Monaco or SF Mono 13 is read and
  redacted. Use `--dry-run` or `safeshot review` when it matters.
- Detection is pattern-based. Secrets without a recognisable shape or label (a bare short password, a name,
  an address) aren't found; add custom rules for your own formats. Some false positives are expected.
- Box geometry is approximate for proportional fonts: safeshot errs towards covering a little extra (part of
  an adjacent quote or space) rather than leaving a glyph visible.
- Images and non-text content (QR codes, faces, avatars) are not analysed.
- macOS only (Vision, CoreGraphics, AppKit).

## Development

```sh
swift build                 # debug
swift build -c release
swift test                  # 30 tests: detectors, Luhn, entropy, geometry, rendering, end-to-end
.build/debug/safeshot-fixtures /tmp/fixtures   # render the synthetic screenshots
```

With only the Command Line Tools installed (no Xcode), SwiftPM may not find the swift-testing macro plugin;
point it there explicitly:

```sh
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

The end-to-end test renders 9 synthetic screenshots (Menlo, SF Mono, Monaco, Courier, SF Pro, Helvetica;
dark and light; 11–14pt; 1x and 2x; soft-wrapped tokens), runs the full pipeline with each redaction style,
re-runs OCR on the **output** and asserts that no 8-character window of any planted secret is recoverable and
that ≥90% of the non-secret text is still readable. Current result:

```
recall 103/106 = 97.2%, leaks 0, benign text readable 75/77 = 97.4%
```

(the 3 misses are the unread JSON line described under Limitations).

Layout: `Sources/SafeshotCore` (Detection, OCR, Render, Config, Pipeline, Report), `Sources/safeshot`
(CLI, clipboard, watch, SwiftUI review window, menu bar), `Sources/SafeshotFixtures` (synthetic screenshot
renderer), `Tests/SafeshotCoreTests`.

## License

MIT — see [LICENSE](LICENSE).
