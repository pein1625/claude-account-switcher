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
│ Phiên bản 0.5.0            Kiểm tra cập nhật    │
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

Link: https://raw.githubusercontent.com/pein1625/claude-account-switcher/main/releases/ClaudeSwitcher-0.5.0.dmg

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
vào hai chỗ live** sau khi cất token live về snapshot (refresh token xoay vòng khi live). Không logout, không
revoke. Mọi mutation chạy dưới một lock (`.switcher/lock`): nhiều session relaunch cùng lúc không snapshot nhầm.

Token live được cất về snapshot của **chủ thật** của nó — app hỏi `GET /api/oauth/profile` — chứ không phải account
`~/.claude.json` đang ghi: session của account khác có thể ghi token vừa refresh của nó đè lên item live bất cứ lúc
nào. Token bị từ chối (401) không được cất vào đâu. Snapshot đích phải đủ cả access + refresh token và, khi hỏi được,
đúng là của account đó; `use` một account đang live không cần snapshot (vòng restart của mọi session đều gọi nó).
Không hỏi được (offline, access token đã hết hạn) → theo `~/.claude.json` như trước.

Format store giống hệt plugin `claude-account` của team DLS, nên máy có cả hai dùng chung được (cùng file, cùng
Keychain service, cùng marker block trong shell rc).

Riêng của app, dưới `~/.claude/accounts/.switcher/`: heartbeat, lịch sử đổi account, cache usage, plan restart,
hop marker theo session, log.

### Đo quota

Mỗi 5 phút (chỉnh được trong Cài đặt: 1 / 2 / 5 / 10 phút) app lấy access token của **từng** account (live từ
item live, còn lại từ snapshot) và gọi `GET https://api.anthropic.com/api/oauth/usage` → `five_hour` / `seven_day`.
**Chỉ đọc** — app không refresh hay tạo token (refresh token xoay vòng; một session cũ còn giữ token cũ sẽ văng nếu
app tự refresh). Token của account không live hết hạn sau vài giờ → dùng số `.quota` đã ghi với quy tắc: cửa sổ đã
qua `resets_at` tính 0%. Nhịp đo không làm chậm phản ứng khi hết quota: session báo rate limit đi qua hook và hop
ngay, không đợi lần đo kế.

Hai thanh **5h** và **7d** luôn có mặt cho mọi account. Lần đo hiện tại không có cửa sổ nào (token account không
live đã hết hạn, hoặc payload thiếu `seven_day`) thì app giữ số đo gần nhất và làm mờ nó; chỉ account chưa từng đo
được mới hiện `—`.

### Hop

Chính sách (`HopPolicy`, có checks): account live **hết** khi 5h ≥ ngưỡng (mặc định 90%, gõ số trong Cài đặt,
100 = chỉ khi cạn hẳn) hoặc 7d ≥ ngưỡng 7d. Ứng viên = account khác chưa hết và snapshot dùng được.
Không hop khi vừa đổi account < 30s, cooldown 10 phút sau lần tự hop trước, hoặc login hiện tại chưa được lưu.

**Chia đều quota tuần** (Cài đặt › Chung, bật mặc định). Hai mục tiêu: không account nào còn quota tuần lúc reset
(phần đó mất trắng), và không account nào cạn 7d sớm (lúc đó chỉ còn cửa sổ 5h của account kia). Cả hai quy về
**tiến độ tuần** của từng account, tính theo giờ reset của chính nó:

```
lệch = 7d đã dùng − 100 × (phần tuần đã trôi qua)      0 = chạm 100% đúng lúc reset
       âm  → chậm: quota sẽ mất khi reset → dùng trước
       dương → nhanh: sẽ cạn trước reset → để dành
```

- Xếp ứng viên: account còn chỗ 5h (5h + khoảng chênh < ngưỡng hop) trước, rồi **chậm tiến độ nhất**, rồi 5h thấp
  nhất. Tắt tuỳ chọn → như cũ: 5h thấp nhất rồi 7d.
- Cân bằng chủ động: account live chưa hết 5h nhưng lệch của nó cao hơn ứng viên tốt nhất **≥ khoảng chênh**
  (mặc định 10 điểm) → chuyển luôn, nếu ứng viên còn chỗ 5h. Khoảng chênh chống nhảy qua lại (mỗi lần chuyển restart
  các session); cooldown và 30s ổn định vẫn áp dụng. Menu hiện "tuần: chậm/nhanh N điểm" cho từng account.
- **Dùng nốt quota sắp reset** (mặc định 24 giờ cuối tuần của mỗi account, 0 = tắt) đứng trước tiến độ: account
  reset trong khoảng đó mà còn quota được dùng trước, reset sớm hơn thì trước — phần còn lại của nó mất khi reset,
  account vừa reset thì còn cả tuần. Ví dụ một account vừa reset (2%), một account cuối ngày reset còn 12%: chuyển sang
  account cuối ngày dù tiến độ hai bên gần bằng nhau; đang ở account đó thì ở lại tới khi hết 5h hoặc hết quota. Chỉ
  chủ động chuyển khi phần còn lại ≥ khoảng chênh (ít hơn không đáng restart mọi session); khi đằng nào cũng hop vì
  hết 5h thì nó vẫn là đích đầu tiên. Hai account reset gần cùng giờ (< 1h) → so theo tiến độ.
- Vì tính theo giờ reset, account 70% sắp reset sau 5 giờ được dùng trước account 40% còn 6 ngày — so % thô thì chọn
  ngược và mất 30% của account kia.
- Dùng nhiều hơn tổng quota hai account thì không tránh được cạn, nhưng cả hai cạn gần cùng lúc thay vì một cái trước.
- Account do người dùng tự chọn (nút Chuyển, `use` từ terminal giữ được ≥ 30s, `/login`) được giữ **1 giờ** trước
  khi cân bằng. Hết quota thì vẫn hop ngay.
- 7d của account không live lấy từ lần đo API gần nhất dù đã cũ (token hết hạn sau vài giờ): 7d chỉ tăng tới lúc
  reset nên số cũ là cận dưới; qua `resets_at` tính 0%.

### Session đang chạy

Một process `claude` giữ token trong RAM cả đời → chỉ đổi account được bằng **restart**:

1. App suy ra account của mỗi session từ **thời điểm start** so với lịch sử đổi account. Session cũ hơn mọi mốc
   đã biết → `~account` (giả định).
2. Khi hop, app ghi pid các session của account cũ vào `.switcher/restart.json`.
3. Hook `claude-switcher hook` chạy ở **cuối mỗi turn**: pid của nó có trong plan, session chạy qua `claude-as`
   (`CLAUDE_AS_LOOP=1`) và đích của plan đúng là account đang live → ghi đích vào `.switcher/hop-<CLAUDE_AS_ID>`,
   session id vào `hop-<CLAUDE_AS_ID>.session`, rồi `kill -TERM` chính nó. Vòng lặp `claude-as` đọc marker của
   **riêng nó**, `claude-switcher use <đích>`, chạy `claude --resume <session id>` (thiếu id → `--continue`, vốn
   lấy hội thoại mới nhất trong thư mục — nhầm sang session khác khi nhiều session chạy chung một thư mục). `use`
   thất bại → vẫn resume trên login đang live, session không bị mất. Session của account mới không bị đụng; nhiều
   session hop cùng lúc không tranh nhau một file.
4. Rate limit giữa turn: hook ghi `events.log`, app đánh dấu account đó 100% và hop ngay; hook chờ tối đa 5s cho
   plan rồi restart luôn.
5. Session "mồ côi": đang chạy trên account đã hết quota trong khi account live còn chỗ (ví dụ sau `/login` sang
   account khác) → app lên plan restart chúng sang account live ở cuối turn, không chờ chính sách hop.

Plan chỉ đưa session **về account đang live**: đổi account (app, CLI, `/login`) thì plan đổi đích theo, session đã ở
account live rơi khỏi plan. App tự thay block `claude-as` cũ của chính nó trong rc (có backup); terminal đang mở
vẫn giữ hàm cũ tới khi `source ~/.zshrc` hoặc mở terminal mới.

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

### Cập nhật

Dòng cuối menu hiện phiên bản đang chạy kèm **Kiểm tra cập nhật**; app cũng tự hỏi 6 tiếng một lần và chỉ lên tiếng
khi có bản mới (thông báo macOS + nút **Cập nhật**). Nguồn: GitHub Release mới nhất và `releases/latest` trong repo,
bản nào cao hơn thì thắng. Bấm cập nhật = chạy chính `scripts/install.sh` (curl → dmg → thư mục đang chứa app), nên
app tự thoát rồi mở lại; log ở `~/.claude/accounts/.switcher/update.log`.

### Lệch Keychain và snapshot hỏng

Mỗi lần item live đổi (session refresh token, đổi account, `/login`) và ít nhất 10 phút một lần, app hỏi
`GET /api/oauth/profile` bằng token live rồi **chép token live vào snapshot của chủ nó** — snapshot không bao giờ tụt
sau một refresh token đã xoay (nguyên nhân chính khiến snapshot chết). Chủ ≠ `~/.claude.json` → cảnh báo
**Sửa lệch**: quyết định lại trên trạng thái lúc bấm, cất token live về đúng chủ, rồi chỉ khôi phục snapshot của
account config khi snapshot đó đầy đủ và đúng chủ.

Snapshot không dùng được (thiếu item, thiếu token, bị 401, hoặc đang giữ token của account khác) → dòng account hiện
lý do màu đỏ + nút **Đăng nhập lại** (cùng luồng đăng nhập trong app, trình duyệt phải đăng nhập đúng account đó;
account đang live thì login live cũng nhận token mới). Hop tự động bỏ qua account đó, và một lần chuyển thất bại giữ
account đích ngoài danh sách trong thời gian cooldown thay vì thử lại mỗi 2 giây.

## CLI

`~/.local/bin/claude-switcher` (shim → app binary; app tự sửa khi bị chuyển chỗ):

```
claude-switcher list | current | names | next
claude-switcher save [name]                snapshot login hiện tại
claude-switcher use <name> [--force]       đổi login live
claude-switcher login <name> [--email x]   đăng nhập account khác (config dir tạm), snapshot, live không đổi
claude-switcher relogin <name>             đăng nhập lại account đã lưu có snapshot chết
claude-switcher realign                    sửa lệch Keychain ↔ ~/.claude.json
claude-switcher remove <name> | rename <old> <new>
claude-switcher status [--no-api] | doctor | whoami   (whoami: account trong config vs. chủ thật của token live)
claude-switcher install [--no-rc] | uninstall [--dry-run] [--keep-app]
```

`claude-as [account] [claude args…]` — mở claude (đổi account trước nếu có tên); `claude` là alias của nó.

## Bản plugin CLI (macOS + Linux)

`plugins/claude-account/` — cùng việc, viết bằng bash, cài như một plugin Claude Code. Chạy được chỗ `.app`
không tới: Linux, VPS, server không màn hình.

```
/plugin marketplace add pein1625/claude-account-switcher
/plugin install claude-account@claude-account-switcher
/claude-account:claude-account install
```

Dùng chung `~/.claude/accounts/` với app, không phải đăng nhập lại. Máy nào chạy cả hai thì đọc
`integration/README.md` trước: hai installer ghi đè block `claude-as` của nhau.

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
- Không refresh token. Không ghi snapshot ngoài `save`/`use`/`login`/`relogin`/Sửa lệch và việc chép token live về
  snapshot của chủ đã xác minh.
- Không kill session không qua `claude-as`; không kill giữa turn trừ khi bấm restart.
