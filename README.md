# Claude Switcher (macOS menu bar)

> Nhiều account Claude Code trên một Mac: xem quota 5h / 7d từng account trên menu bar, đổi account một click,
> **tự hop** sang account còn quota khi account đang dùng hết cửa sổ 5 giờ — session `claude` đang chạy tự mở
> lại và **tiếp tục đúng hội thoại** (`--continue`).

Standalone: một `.app`, không cần plugin hay công cụ nào khác ngoài Claude Code đã đăng nhập claude.ai
(Pro / Max / Team). macOS 14+, Intel hoặc Apple Silicon.

```
┌ Claude Switcher ──────────────── đo 40s trước ↻ ┐
│ ● m04  LIVE  <email> · team · DLS      [⋯]      │
│   5h ████████░░ 59% → 18:30   7d ███░░ 60% → T4 │
│   API 40s trước · 8 session                     │
│ ○ m19        <email> · team · DLS   [Chuyển][⋯] │
│   5h ███░░░░░░░ 29% → 20:00   7d ██░░░ 52%      │
│ ─────────────────────────────────────────────── │
│ [on] Tự hop khi 5h ≥ 90%   Ổn: m04 5h 59% < 90% │
│ ▸ 8 session claude đang chạy       m04 8        │
│ ─────────────────────────────────────────────── │
│ [Thêm account…] [Lưu login hiện tại…]    ⚙  ⏻   │
└─────────────────────────────────────────────────┘
```

## Cài

### Cách 1 — một dòng lệnh (khuyên dùng, không bị hỏi gì)

```bash
curl -fsSL https://raw.githubusercontent.com/pein1625/claude-account-switcher/main/scripts/install.sh | bash
```

Tải dmg mới nhất bằng `curl`, copy app vào `/Applications`, mở. Không có hộp thoại Gatekeeper: Gatekeeper chỉ chặn
file mang cờ quarantine, mà chỉ trình duyệt / AirDrop / Slack mới gắn cờ đó — `curl` thì không.

### Cách 2 — tải file dmg

Link: https://raw.githubusercontent.com/pein1625/claude-account-switcher/main/releases/ClaudeSwitcher-0.3.0.dmg

1. Mở dmg, kéo `ClaudeSwitcher` vào `Applications` (cửa sổ có mũi tên).
2. Mở app từ Applications. Vì app ký adhoc (chưa notarize), macOS hiện hộp thoại:

   > **“ClaudeSwitcher” chưa được mở** — Apple không thể xác minh rằng “ClaudeSwitcher” không chứa phần mềm độc hại…
   > *(“ClaudeSwitcher” Not Opened — Apple could not verify… is free of malware)*

   Bấm **Xong** (Done) — **không** bấm “Chuyển vào Thùng rác”.
3. **System Settings › Quyền riêng tư & Bảo mật** (Privacy & Security) › kéo xuống cuối, mục *Bảo mật* có dòng
   “ClaudeSwitcher” đã bị chặn… › bấm **Vẫn mở** (Open Anyway) › xác nhận Touch ID / mật khẩu › mở app lại
   (hộp thoại mới có nút **Mở**).
   - macOS 15+ không còn right-click › Open để bỏ qua; chỉ có đường này.
   - Nút “Vẫn mở” chỉ hiện trong ~1 giờ sau lần bị chặn. Không thấy → mở app lần nữa cho bị chặn, rồi vào lại.
   - Thay bước 3 bằng Terminal cũng được: `xattr -dr com.apple.quarantine /Applications/ClaudeSwitcher.app`
4. Lần đầu mở, app hỏi cho phép thông báo và **“Bật hop tự động?”** → *Cài* (xem bảng dưới).

### Cách 3 — build từ source (không vướng Gatekeeper; cần Command Line Tools, không cần Xcode)

```bash
xcode-select --install   # nếu chưa có
git clone https://github.com/pein1625/claude-account-switcher.git && cd claude-account-switcher
make install             # swift build → build/ClaudeSwitcher.app → /Applications → open
```

### Sau khi mở lần đầu

App hỏi **“Bật hop tự động?”** → *Cài*. Nó ghi (đều có backup `.bak-*`):

| Gì | Đâu | Để làm gì |
|---|---|---|
| shim `claude-switcher` | `~/.local/bin/claude-switcher` | CLI; hook và `claude-as` gọi qua đây |
| hook `Stop` + `StopFailure(rate_limit)` | `~/.claude/settings.json` | kết thúc đúng session cần hop ở cuối turn |
| hàm `claude-as` + `alias claude='claude-as'` | `~/.zshrc` (hoặc `~/.bashrc`) | vòng lặp mở lại `claude --continue` bằng account mới |

Mở terminal mới sau đó. Account đang đăng nhập được **tự lưu** (tên = phần trước `@` của email; ⋯ › Đổi tên nếu
muốn). Thêm account thứ hai: **Thêm account…** → tên, email → app tự chạy `claude auth login` ngầm và mở trang
đăng nhập trong **cửa sổ riêng tư** của trình duyệt (Chrome/Brave/Edge/Firefox; Safari không có chế độ này qua dòng
lệnh → cửa sổ thường). Đăng nhập bằng account mới, bấm Authorize → app nhận kết quả, snapshot, báo xong ngay trong
menu. Login hiện tại không bị đụng, không cần Terminal.

Vì sao cửa sổ riêng tư: trình duyệt đang giữ phiên claude.ai của account nào thì OAuth **tự duyệt account đó**, không
hỏi, kể cả khi URL có `login_hint`. App từ chối lưu nếu account vừa đăng nhập trùng snapshot đã có (nút *Thử lại
trong cửa sổ riêng tư*). Panel đăng nhập có *Mở lại*, *Copy link*, ô dán code (khi dùng URL dự phòng), *Huỷ*.

Đăng nhập theo cách khác (`/login` trong một session, `claude auth login` ngoài terminal) cũng được: app phát hiện
login live chưa có snapshot, kiểm tra token trong Keychain đúng là của account đó (`GET /api/oauth/profile`), rồi tự
lưu. Cài đặt › Chung có tắt (*Tự lưu login mới*, *cửa sổ riêng tư*, *đăng nhập qua Terminal* để khắc phục sự cố).

## Cách hoạt động

### Store

Claude Code giữ một login tại hai chỗ: token OAuth trong Keychain (`Claude Code-credentials`) và profile
(`oauthAccount`: email, org, plan) trong `~/.claude.json`. App snapshot từng account thành Keychain item
`Claude Code-credentials-acct-<name>` + `~/.claude/accounts/<name>.json`, và **đổi account = ghi snapshot đích
vào hai chỗ live** sau khi re-snapshot account đang rời (refresh token xoay vòng khi live). Không logout, không
revoke. Mọi mutation chạy dưới một lock (`.switcher/lock`): nhiều session relaunch cùng lúc không snapshot nhầm.

Format store giống hệt plugin `claude-account` của team DLS, nên máy có cả hai dùng chung được (cùng file, cùng
Keychain service, cùng marker block trong shell rc).

Riêng của app, dưới `~/.claude/accounts/.switcher/`: heartbeat, lịch sử đổi account, cache usage, plan restart,
hop marker theo session, log.

### Đo quota

Mỗi 60s (chỉnh được) app lấy access token của **từng** account (live từ item live, còn lại từ snapshot) và gọi
`GET https://api.anthropic.com/api/oauth/usage` → `five_hour` / `seven_day`. **Chỉ đọc** — app không refresh hay
tạo token (refresh token xoay vòng; một session cũ còn giữ token cũ sẽ văng nếu app tự refresh). Token của account
không live hết hạn sau vài giờ → dùng số `.quota` đã ghi với quy tắc: cửa sổ đã qua `resets_at` tính 0%.

### Hop

Chính sách (`HopPolicy`, có checks): account live **hết** khi 5h ≥ ngưỡng (mặc định 90%, gõ số trong Cài đặt,
100 = chỉ khi cạn hẳn) hoặc 7d ≥ ngưỡng 7d. Ứng viên = account khác chưa hết, xếp theo 5h thấp nhất rồi 7d.
Không hop khi vừa đổi account < 30s, cooldown 10 phút sau lần tự hop trước, hoặc login hiện tại chưa được lưu.

### Session đang chạy

Một process `claude` giữ token trong RAM cả đời → chỉ đổi account được bằng **restart**:

1. App suy ra account của mỗi session từ **thời điểm start** so với lịch sử đổi account. Session cũ hơn mọi mốc
   đã biết → `~account` (giả định).
2. Khi hop, app ghi pid các session của account cũ vào `.switcher/restart.json`.
3. Hook `claude-switcher hook` chạy ở **cuối mỗi turn**: pid của nó có trong plan và session chạy qua `claude-as`
   (`CLAUDE_AS_LOOP=1`) → ghi đích vào `.switcher/hop-<CLAUDE_AS_ID>` rồi `kill -TERM` chính nó. Vòng lặp
   `claude-as` đọc marker của **riêng nó**, `claude-switcher use <đích>`, chạy `claude --continue`. Session của
   account mới không bị đụng; nhiều session hop cùng lúc không tranh nhau một file.
4. Rate limit giữa turn: hook ghi `events.log`, app đánh dấu account đó 100% và hop ngay; hook chờ tối đa 5s cho
   plan rồi restart luôn.
5. Session "mồ côi": đang chạy trên account đã hết quota trong khi account live còn chỗ (ví dụ sau `/login` sang
   account khác) → app lên plan restart chúng sang account live ở cuối turn, không chờ chính sách hop.

Session đang chạy chỉ nhận hook sau khi restart một lần (settings.json đọc lúc start). Session không qua
`claude-as` (“no loop”) không bị kill — app gợi ý `/exit` rồi `claude --continue`. Nút restart cạnh mỗi session =
SIGTERM ngay (cắt turn đang chạy), có xác nhận.

### Đăng nhập trong app (kỹ thuật)

`claude auth login` là TUI (Ink): cần stdio là tty và raw mode. Chạy nó bằng Foundation `Process` kế thừa terminal
thật thì bị SIGTTOU dừng im lặng (khác process group); chạy không tty thì Ink từ chối. App mở một pseudo-terminal
riêng (`posix_openpt` + `posix_spawn` với `POSIX_SPAWN_SETSID`), chạy claude trong `CLAUDE_CONFIG_DIR` tạm, đặt một
`open` giả đầu PATH để bắt URL claude muốn mở (URL này có `redirect_uri=localhost:<port>` → code tự quay về; URL in
ra màn hình dùng `platform.claude.com` và bắt dán code — app dùng làm dự phòng). Kết thúc: snapshot vào Keychain
`…-acct-<name>` + `<name>.json`, xoá item Keychain tạm, dọn thư mục tạm.

### Lệch Keychain

Mỗi 10 phút app hỏi `GET /api/oauth/profile` bằng token live: uuid ≠ `~/.claude.json` (một session cũ đã ghi token
refresh của nó đè lên store) → cảnh báo + **Sửa lệch**: lưu token live về snapshot của account thật sự sở hữu, rồi
khôi phục snapshot của account config đang nói.

## CLI

`~/.local/bin/claude-switcher` (shim → app binary; app tự sửa khi bị chuyển chỗ):

```
claude-switcher list | current | names | next
claude-switcher save [name]                snapshot login hiện tại
claude-switcher use <name> [--force]       đổi login live
claude-switcher login <name> [--email x]   đăng nhập account khác (config dir tạm), snapshot, live không đổi
claude-switcher remove <name> | rename <old> <new>
claude-switcher status [--no-api] | doctor | whoami   (whoami: account trong config vs. chủ thật của token live)
claude-switcher install [--no-rc] | uninstall [--dry-run] [--keep-app]
```

`claude-as [account] [claude args…]` — mở claude (đổi account trước nếu có tên); `claude` là alias của nó.

## Gửi cho người khác

```bash
make dmg      # → dist/ClaudeSwitcher-<version>.dmg (universal arm64 + x86_64) + .sha256; kèm README + Uninstall.command
make dist     # → .zip
```

`make publish-file` copy dmg vào `releases/` (commit + push) — người nhận dùng lệnh `curl … | bash` hoặc tải file
ở mục **Cài**, không gặp Gatekeeper. `make release` đẩy lên GitHub Releases (cần `gh`), script ưu tiên nguồn này. Gửi dmg tay thì họ phải Open Anyway một lần; bỏ hẳn bước đó chỉ có Apple Developer ID +
notarize (`xcrun notarytool`, cần Xcode). Không copy `~/.claude/accounts/` hay Keychain sang máy khác: token
gắn theo máy.

## Gỡ cài đặt

⚙ › **Gỡ cài đặt** trong app · `claude-switcher uninstall --dry-run` (xem) rồi bỏ `--dry-run` ·
`bash "/Volumes/Claude Switcher/Uninstall.command"` từ dmg · `make uninstall` trong repo.

Gỡ: hook trong `settings.json`, shim, block `claude-as` (chỉ khi là của app), Login Item,
`~/.claude/accounts/.switcher/`, preferences, app → Thùng rác. **Không đụng** snapshot Keychain, `<name>.json`,
`.quota`, `.current`, login live — không phải đăng nhập lại; gỡ snapshot bằng `claude-switcher remove <name>`.

## Phát triển

```bash
make build      # swift build -c release
make test       # swift run ClaudeSwitcherChecks (CLT không có XCTest → checks là executable)
make status     # .build/release/ClaudeSwitcher status
make app        # build/ClaudeSwitcher.app (arch máy này)
make dmg        # universal .app → dist/*.dmg
```

`Sources/ClaudeSwitcherCore` (store native `Switcher`, policy, scanner, usage client, shell/hook installer — không
UI) · `Sources/ClaudeSwitcher` (SwiftUI menu bar, AppModel, CLI, hook runner) · `Checks/` (assertion runner) ·
`scripts/` (đóng gói, icon, uninstall) · `integration/` (ghi chú sống chung với plugin `claude-account`).

Log: `~/.claude/accounts/.switcher/app.log`.

## Không làm

- Không `claude auth logout` (revoke token → snapshot chết). App không có nút này.
- Không refresh token. Không ghi snapshot ngoài `save`/`use`/`login`/Sửa lệch.
- Không kill session không qua `claude-as`; không kill giữa turn trừ khi bấm restart.
