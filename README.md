# Claude Switcher (macOS menu bar)

Đăng nhập nhiều account Claude subscription trên một máy, xem quota 5h / 7d của **từng** account ngay
trên menu bar, đổi account bằng một click, và **tự hop** sang account còn quota khi account đang dùng
hết cửa sổ 5 giờ — kể cả khi đang có nhiều session `claude` chạy song song.

App là GUI + daemon đi kèm CLI [`claude-account`](../dls-ai-team/plugins/claude-account) (plugin
`claude-account@dls-ai-team`): dùng chung store, CLI vẫn là **writer duy nhất** cho snapshot/login.

```
┌ Claude Switcher ──────────────── đo 40s trước ↻ ┐
│ ● m04  LIVE  <email> · team · DLS      [⋯]      │
│   5h ████████░░ 46% → 18:30   7d ██░░ 12% → T4  │
│   API 40s trước · 8 session                     │
│ ○ m19        <email> · team · DLS   [Chuyển][⋯] │
│   5h ░░░░░░░░░░  1% → 20:00                     │
│ ─────────────────────────────────────────────── │
│ [on] Tự hop khi 5h ≥ 90%   Ổn: m04 5h 46% < 90% │
│ ▸ 8 session claude đang chạy       m04 8        │
│ ─────────────────────────────────────────────── │
│ [Thêm account…] [Lưu login hiện tại…]    ⚙  ⏻   │
└─────────────────────────────────────────────────┘
```

## Cài

Yêu cầu: macOS 14+, Command Line Tools (`xcode-select --install`, không cần Xcode), `jq`, Claude Code
2.1.x, plugin `claude-account` đã `install` (có `~/.local/bin/claude-account`).

```bash
make install            # swift build -c release → build/ClaudeSwitcher.app → /Applications → open
```

Lần đầu mở: cho phép thông báo; vào **Cài đặt › Hook & CLI › Cài hook** (xem bên dưới); bật
**Chạy khi đăng nhập máy** nếu muốn.

Không dùng Xcode: `make app` chỉ dùng `swift build`, `iconutil`, `codesign --sign -` (adhoc). Mỗi lần
build lại chữ ký đổi → macOS có thể hỏi lại quyền thông báo, không hỏi Keychain (app đọc Keychain qua
`/usr/bin/security`, binary đã được ACL của Claude Code tin).

## Cách hoạt động

### Store dùng chung với CLI

| Gì | Đâu | Ai ghi |
|---|---|---|
| Token OAuth của login live | Keychain `Claude Code-credentials` | Claude Code, CLI `use` |
| Snapshot token từng account | Keychain `Claude Code-credentials-acct-<name>` | CLI `save`/`login`/`use` (app: chỉ khi **Sửa lệch**) |
| Profile (email, org, plan) | `~/.claude/accounts/<name>.json` | CLI |
| Lần đo 5h cuối, format CLI `pct\treset\tlúc` | `<name>.quota` | statusline (CLI `quota`) **và app** (từ API) |
| Cờ hop của `claude-as` loop | `.hop` | CLI `quota`/`use`, hook của app (tức thời trước kill) |
| Heartbeat, lịch sử đổi account, cache usage, plan restart, log | `.switcher/` | app, hook |

### Đo quota

Mỗi 60s (chỉnh được) app lấy access token của **từng** account (live: item live; còn lại: snapshot) và gọi
`GET https://api.anthropic.com/api/oauth/usage` → `five_hour` / `seven_day` (+ opus/sonnet nếu có). Chỉ đọc:
app **không bao giờ refresh hay tạo token** — refresh token xoay vòng, một session cũ còn giữ token cũ sẽ
văng nếu app tự refresh. Token của account không live hết hạn sau vài giờ → app dùng số `.quota` đã ghi
với quy tắc của CLI: cửa sổ đã qua `resets_at` tính 0%. Cron `claude-quota-ping` (nếu còn) làm mới token
các account mỗi 5h nên API thường vẫn đo được.

Số đo ghi ngược vào `<name>.quota` để statusline và `claude-account list/next` thấy cùng một sự thật.

### Hop

Chính sách (`HopPolicy`, có unit test): account live **hết** khi 5h ≥ ngưỡng (mặc định 90%) hoặc 7d ≥ ngưỡng
7d (mặc định 100%). Ứng viên = account khác chưa hết, xếp theo 5h thấp nhất rồi 7d. Không hop khi: vừa đổi
account < 30s (cron ping đang chạy), cooldown 10 phút sau lần tự hop trước, hoặc login hiện tại chưa `save`.

Thực hiện = `claude-account use <next>` (CLI re-snapshot account đang rời, ghi token + profile account mới,
đặt `.current`). Session mới mở sau đó chạy bằng account mới.

### Session đang chạy

Một process `claude` giữ token trong RAM cả đời nó → chỉ đổi account được bằng **restart**. App:

1. Suy ra account của mỗi session từ **thời điểm start** so với lịch sử đổi account (`.switches.log`
   + mtime `.current`). Session cũ hơn mọi mốc đã biết → `~account` (giả định = account ổn định).
2. Khi hop/chuyển tay, ghi pid các session của account cũ vào `.switcher/restart.json`.
3. Hook `Stop`/`StopFailure(rate_limit)` (`~/.local/bin/claude-switcher-hook`, cài từ Cài đặt) chạy ở
   **cuối mỗi turn**: nếu pid của nó có trong plan và session chạy qua `claude-as` (`CLAUDE_AS_LOOP=1`) →
   ghi `.hop=<account mới>` rồi `kill -TERM` chính nó; vòng lặp `claude-as` đọc `.hop`, `use`, mở lại
   `claude --continue`. Session của account mới **không** bị đụng (khác cờ `.hop` toàn cục của plugin).
4. Gặp rate limit giữa turn: hook ghi `events.log`, app đánh dấu account đó 100% và hop ngay, hook chờ
   tối đa 5s cho plan rồi restart luôn.

Session đang chạy chỉ nhận hook mới sau khi nó restart một lần (settings.json đọc lúc start). Session
không qua `claude-as` (“no loop”) app không kill — hiện gợi ý `/exit` rồi `claude --continue`. Nút
**restart** cạnh mỗi session = SIGTERM ngay (cắt turn đang chạy), có xác nhận.

### Lệch Keychain

Mỗi 10 phút app hỏi `GET /api/oauth/profile` bằng token live: nếu uuid ≠ `~/.claude.json` (một session
cũ đã ghi token refresh của nó đè lên store) → cảnh báo + nút **Sửa lệch**: lưu token live về snapshot
của account thật sự sở hữu nó, rồi khôi phục snapshot của account config đang nói. (Chạy `claude-account
use` lúc này sẽ snapshot nhầm — app làm đúng thứ tự.)

## Dùng

- **Thêm account…**: mở Terminal chạy `claude-account login <tên> --email <email>` — đăng nhập account
  khác trong config dir tạm, login hiện tại không bị đụng, snapshot xong tự hiện trong app.
- **Lưu login hiện tại…**: `claude-account save <tên>` cho login đang có (lần đầu dùng).
- **Chuyển**: `claude-account use <tên>` + lên plan restart cho session account cũ (tắt được trong Cài đặt).
- `⋯` › **Xoá snapshot** (không đụng login live).
- Headless: `ClaudeSwitcher --status [--no-api]`, `--doctor`, `--print-hook`.

## Gửi cho người khác

Người nhận cần: macOS 14+, Claude Code 2.1.x đã login claude.ai, `jq`, plugin `claude-account@dls-ai-team`
đã `/claude-account:claude-account install` (có `~/.local/bin/claude-account`). App không tự chứa CLI.

**Cách 1 — gửi source (khuyên dùng trong team dev, không vướng Gatekeeper):**

```bash
git clone <repo> claude-account-switcher && cd claude-account-switcher
make install          # cần Command Line Tools (xcode-select --install), build ~1 phút
```

**Cách 2 — gửi file (.dmg hoặc .zip), universal arm64 + x86_64:**

```bash
make dmg              # → dist/ClaudeSwitcher-<version>.dmg (kéo vào Applications + file hướng dẫn) + .sha256
make dist             # → dist/ClaudeSwitcher-<version>.zip
```

Người nhận: mở dmg, kéo `ClaudeSwitcher.app` vào `Applications`, mở. Vì app ký adhoc (không có Developer
ID / notarize) macOS chặn lần đầu — *"Apple could not verify ClaudeSwitcher is free of malware"* —
**System Settings › Privacy & Security › "Open Anyway"** (macOS 15+ bỏ right-click › Open), hoặc gõ

```bash
xattr -dr com.apple.quarantine /Applications/ClaudeSwitcher.app
```

rồi mở lại. Sau đó: cho phép thông báo → Cài đặt › Hook & CLI › **Cài hook** → Doctor kiểm tra CLI/jq/API.
Có Apple Developer ID thì ký `codesign --sign "Developer ID Application: …" --options runtime` và notarize
(`xcrun notarytool`, cần Xcode) để bỏ bước trên.

Không copy `~/.claude/accounts/` hay Keychain sang máy khác: token gắn theo máy, mỗi máy phải `login` từng account.

## Gỡ cài đặt

Ba cách, cùng một việc: ⚙ › **Gỡ cài đặt** trong app · `ClaudeSwitcher --uninstall --dry-run` (xem) rồi bỏ
`--dry-run` · `make uninstall` / `bash "/Volumes/Claude Switcher <ver>/Uninstall.command"` từ dmg.

Gỡ: hook Stop/StopFailure trong `~/.claude/settings.json` (có backup `.bak-*`) + `~/.local/bin/claude-switcher-hook`,
mục Login Items, `~/.claude/accounts/.switcher/`, preferences `com.hapk.claude-switcher`, app → Thùng rác.
**Không đụng** snapshot Keychain, `<name>.json`, `.quota`, `.current`, login live — gỡ những thứ đó bằng
`claude-account remove <name>` (plugin).

## Phát triển

```bash
make build      # swift build -c release
make test       # swift run ClaudeSwitcherChecks (CLT không có XCTest/Swift Testing → checks là executable)
make status     # .build/release/ClaudeSwitcher --status
make app        # build/ClaudeSwitcher.app (arch máy này)
make dmg        # universal .app → dist/*.dmg để gửi (make dist: .zip)
make uninstall  # gỡ app + hook + file của app (giữ store của claude-account)
```

Cấu trúc: `Sources/ClaudeSwitcherCore` (store, policy, scanner, usage client, CLI wrapper, hook — không UI)
· `Checks/` (assertion runner cho Core) · `Sources/ClaudeSwitcher` (SwiftUI menu bar, AppModel, headless) · `scripts/` (đóng gói, icon) ·
`integration/` (patch plugin tuỳ chọn, xem `integration/README.md`).

Log: `~/.claude/accounts/.switcher/app.log`.

## Không làm

- Không `claude auth logout` (revoke token → snapshot chết). App không có nút này.
- Không refresh token. Không ghi snapshot ngoài trường hợp Sửa lệch.
- Không kill session không qua `claude-as`; không kill session giữa turn trừ khi bấm restart.
