CLAUDE SWITCHER - cai dat / installation

1. Keo ClaudeSwitcher.app vao thu muc Applications (bieu tuong ben canh).

2. Mo app lan dau. macOS se chan vi app chua notarize (ky adhoc):
     "ClaudeSwitcher" Not Opened / Apple could not verify "ClaudeSwitcher" is free of malware
   Lam MOT trong hai:
     a) System Settings > Privacy & Security > keo xuong cuoi > "Open Anyway" > mo lai app.
     b) Terminal:   xattr -dr com.apple.quarantine /Applications/ClaudeSwitcher.app
   (macOS 15+ khong con right-click > Open cho app chua ky.)

3. Cho phep thong bao khi duoc hoi. Icon xuat hien tren menu bar canh dong ho.

Yeu cau tren may:
  - macOS 14 tro len. Intel hoac Apple Silicon deu duoc (binary universal).
  - Claude Code 2.1.x da dang nhap claude.ai;  jq  (brew install jq).
  - Plugin claude-account@dls-ai-team. Trong Claude Code:
        /plugin marketplace add <marketplace của team>
        /plugin install claude-account@dls-ai-team
        /claude-account:claude-account install
    roi  source ~/.zshrc.  App goi CLI nay de doi account; thieu no app chi hien thi.

Trong app:  (gear) > Doctor  kiem tra CLI / jq / API.
            (gear) > Hook & CLI > Cai hook  de session dang chay tu restart --continue khi hop.

Lan dau dung: "Luu login hien tai..." dat ten cho account dang dang nhap, roi "Them account..."
cho account thu hai (mo Terminal, dang nhap 1 lan). Token gan theo may: KHONG copy
~/.claude/accounts hay Keychain tu may khac sang.

Go cai dat:  mo app > (gear) > "Go cai dat", hoac trong Terminal:
    bash "/Volumes/Claude Switcher 0.1.0/Uninstall.command"
Go: app, hook, ~/.claude/accounts/.switcher, preferences, login item. KHONG dung den snapshot account.
