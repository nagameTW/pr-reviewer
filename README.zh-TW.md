<div align="center">
  <h1>PR Reviewer</h1>
  <p>
    <a href="https://github.com/nagameTW/pr-reviewer/actions/workflows/ci.yml"><img src="https://github.com/nagameTW/pr-reviewer/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
    <a href="./LICENSE"><img src="https://img.shields.io/github/license/nagameTW/pr-reviewer?style=flat-square&logo=opensourceinitiative&logoColor=white&color=3DA639" alt="License"></a>
    <a href="#需求"><img src="https://img.shields.io/badge/bash-3.2%2B-4EAA25" alt="bash 3.2+"></a>
  </p>
  <p><a href="README.md">English</a> | <a href="README.zh-TW.md">繁體中文</a></p>
</div>

本文件譯自英文版。內容以英文版為準。

pr-reviewer 在使用者自己的機器上審查 pull request（請求把修改合併進專案的申請，簡稱 PR），審查時沿用使用者本人的 Claude Code 登入。pr-reviewer 不需要 GitHub Action、App、webhook，也不需要 repo 的管理員權限。

pr-reviewer 監看使用者列出的 repo（存放專案程式碼的位置）。每檢查這些 repo 一次，稱為一輪。一輪之中，[受信任作者](docs/operations.md#whose-prs-it-reviews)開啟的 PR 只要出現新的 head，pr-reviewer 就以無介面模式（不開啟互動介面）呼叫 [Claude Code](https://code.claude.com/docs/en/overview)（Anthropic 的 AI 寫程式工具）執行審查。head 指 PR 最新的 commit（一筆程式碼修改紀錄）。審查完成後，pr-reviewer 貼出一則留言，內含審查結果（核准或要求修改）與問題清單。

留言以使用者自己的 `gh`（GitHub 的命令列工具）帳號發出。若已設定 [GitHub App](docs/github-app.md)，改由該 App 發出。pr-reviewer 是一組呼叫 `gh`、`git`、`jq` 與 `claude` 的 bash（一種命令列腳本語言）腳本。真實的執行過程與留言見[展示頁](docs/demo.md)。

## 安全與成本

完整說明見 [SECURITY.md](SECURITY.md) 與 [docs/trust-cost-limits.md](docs/trust-cost-limits.md)。

- 只留言。pr-reviewer 不核准 PR，也不合併 PR。
- 模型只能讀取。他只能在每個 PR 專屬的獨立 checkout（git worktree）中使用 `Read`、`Grep` 與 `Glob`。PR 的程式碼不會執行。
- 請在只有使用者本人使用的機器上執行。服務使用使用者的 `gh` 登入與 Claude Code 登入。
- 來自 fork（從他人複製出的 repo）的 PR 一律略過，作者列在受信任名單的 PR 除外。
- pr-reviewer 使用使用者的 Claude Code 登入，因此審查計入使用者的用量上限。審查展示用的 PR 一次花費 $0.54。

## 狀態與限制

- 1.0 之前。版本之間任何內容都可能改變。升級前請閱讀 [CHANGELOG.md](CHANGELOG.md)。
- 尚無人統計 pr-reviewer 找出多少 bug，也尚無人統計誤報（把正常的程式碼誤指為有問題）的數量。
- 只支援 GitHub。可在 macOS、Linux 與 WSL2（在 Windows 上執行 Linux 的功能）上執行。

## 需求

- macOS 或 Linux。在 Windows 上，於 WSL2 內執行。
- bash 3.2 以上。macOS 內建的 `/bin/bash` 可用。
- [gh](https://cli.github.com/) 2.63.0 以上與 [Claude Code](https://code.claude.com/docs/en/overview) 2.1.305 以上。兩者都須已登入。
- `git`、`jq`、`curl`、`openssl` 與 `flock`。另需一個 timeout 指令（`timeout` 或 `gtimeout`），以及一個 SHA-256 指令（`sha256sum`、`gsha256sum` 或 `shasum`）。
- Linux 上需 systemd 240 以上，供背景服務使用。

`prreview setup` 檢查每一項，並印出適合該系統的安裝指令。詳見[安裝工具](docs/install.md#install-the-tools)。

## 快速開始

```bash
git clone https://github.com/nagameTW/pr-reviewer.git ~/pr-reviewer
mkdir -p ~/.local/bin && ln -s ~/pr-reviewer/prreview ~/.local/bin/prreview
prreview setup
prreview once --pr you/repo#12
prreview start
```

1. 取得程式碼，並把 `prreview` 放進 `PATH`（[細節](docs/install.md#1-get-the-code)）。
2. 執行 setup。至少列入一個自己擁有的 repo。在 **Background service** 一項回答 `n`，第 4 步才啟動服務。
3. 對已列出 repo 中的一個測試 PR 執行審查。此步驟發出真實的模型呼叫，並以 `gh` 帳號貼出留言。
4. 啟動服務。`prreview status` 顯示狀態，`prreview logs -f` 持續追蹤日誌（[細節](docs/install.md#4-start-the-service)）。

> [!WARNING]
> 注意：在信任 pr-reviewer 之前，只列出自己擁有的 repo。第一輪會審查所列 repo 中，每個作者受信任、狀態為開啟的非草稿 PR，並以 `gh` 帳號在每個 PR 上留言。每次審查都消耗模型用量。

## 常用指令

| 指令 | 用途 |
| --- | --- |
| `prreview repos add owner/repo`、`prreview repos remove owner/repo` | 變更受審查的 repo |
| `prreview set <name> <value>`、`prreview get <name>`、`prreview unset <name>` | 變更、讀取或重設設定 |
| `prreview once`、`prreview run` | 在此終端機執行一輪，或持續執行每一輪 |
| `prreview once --pr owner/repo#12` | 立即審查該 PR |
| `prreview stop`、`prreview start`、`prreview restart` | 控制背景服務 |
| `prreview status`、`prreview logs -f` | 顯示狀態與略過的 PR，並持續追蹤日誌 |
| `prreview checks` | 列出、新增或移除審查項目 |
| `prreview uninstall` | 移除背景服務，設定保留 |
| `prreview version` | 顯示版本 |
| `prreview <command> --help` | 顯示該指令的用法 |

完整移除的方式見 [Removing it](docs/operations.md#removing-it)。

## 升級

```bash
cd ~/pr-reviewer
git pull --ff-only
prreview setup
```

所有問題都按 Enter，即可保留原本的答案。各版本之間的變更見[升級說明](docs/install.md#upgrading)。

## 審查運作方式

pr-reviewer 依一份 13 個項目的檢查清單審查 diff（PR 的程式碼變更內容）。每個項目是 `checks/` 內的一個檔案。

| 項目 | 檢查內容 |
| --- | --- |
| 1 正確性 | 程式錯誤、未處理的輸入、改動後會失效的呼叫端、並行（同時執行）的問題 |
| 2 安全性 | 注入攻擊、授權缺口、加密與機密處理、資料暴露 |
| 2b AI agent 安全 | Prompt injection（在文字中藏入指令，誘使模型照做）、未經檢查就使用的模型輸出、讓 LLM 能做超出需要的操作 |
| 3 敏感資料 | 真實位址、主機名稱、token（存取憑證）或憑證 |
| 4 專案限制 | repo 自己寫下的規則 |
| 5 測試 | 讓 CI 變弱的改動、修正 bug 卻未加測試、斷言（測試中的判斷條件）過弱 |
| 6 設計 | 過度設計、改動放錯位置 |
| 7 文件同步 | 仍在描述舊行為的文件 |
| 8 相依套件 | 未宣告的相依套件，或鎖定版本的方式與其他套件不一致 |
| 9 證據優先 | 沒有實測數據，就改動依經驗設定的規則、數值上限、所用的模型或 prompt |
| 10 模型能使用哪些工具 | 模型可呼叫的工具範圍過廣，或使用時無需核准 |
| 11 是否完成 issue 的需求 | diff 未達成關聯 issue（記錄需求的頁面）的某項需求 |
| 12 只修一處，附近同類的問題仍存在 | 修了其中一處，相鄰且寫法相同的程式碼仍有同樣的缺陷 |

CRITICAL 與 HIGH 的問題會擋下核准，審查結果為 Changes requested（要求修改）。MEDIUM 與 LOW 的問題只列出，不改變審查結果。審查結果是留言中的文字，不是 GitHub 的 review 狀態。[docs/how-it-reviews.md](docs/how-it-reviews.md) 說明檢查清單、一輪的每個步驟，以及 pr-reviewer 不回報的內容。使用者可以[新增、移除或修改項目](docs/configuration.md#adding-your-own-checks)。四張流程圖收在[圖表頁](docs/zh-TW/diagrams.md)。

## 設定

`prreview setup` 把設定寫到 `~/.config/pr-reviewer/config`。環境變數（在終端機或服務設定中指定的值）可覆寫設定檔。唯一必填的設定是 `PRREVIEW_GATE_REPOS`，也就是 repo 清單。[docs/configuration.md](docs/configuration.md) 列出每項設定及其預設值。

## 專案結構

```
├── prreview                  # 命令列程式
├── review-loop.sh            # 每分鐘執行一輪
├── pr-autoreview.sh          # 一輪審查
├── checks/                   # 13 個檢查項目
├── lib/                      # 共用的 bash 程式碼
├── tests/                    # 測試
├── docs/
│   ├── install.md            #   安裝、setup、啟動、升級
│   ├── configuration.md      #   每項設定、自訂檢查項目
│   ├── operations.md         #   一輪的細節、失敗處理、移除
│   ├── how-it-reviews.md     #   檢查清單、嚴重度、圖表
│   ├── trust-cost-limits.md  #   信任、成本、限制
│   ├── github-app.md         #   以 GitHub App 身分留言
│   ├── windows.md            #   WSL2
│   ├── demo.md               #   展示與範例留言
│   ├── comparison.md         #   與其他審查工具比較
│   └── zh-TW/diagrams.md     #   繁體中文圖表
├── SECURITY.md               # 安全模型
├── CONTRIBUTING.md           # 如何參與貢獻
└── CHANGELOG.md              # 各版本的變更
```

`docs/` 內除 `zh-TW/diagrams.md` 之外，各頁只有英文版。

## 開發

```bash
bash tests/run-all.sh
```

該指令執行 `bash -n`（檢查語法）、`shellcheck -S warning`（腳本靜態檢查）與每一個 `tests/*.test.sh`，不需要網路、`gh` 或模型。詳見 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 授權

[MIT](LICENSE)
