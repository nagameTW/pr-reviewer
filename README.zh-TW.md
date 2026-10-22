# pr-reviewer

[English](README.md) | 繁體中文

本文件譯自英文版，內容以英文版為準。

[![CI](https://github.com/nagameTW/pr-reviewer/actions/workflows/ci.yml/badge.svg)](https://github.com/nagameTW/pr-reviewer/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/nagameTW/pr-reviewer?style=flat-square&logo=opensourceinitiative&logoColor=white&color=3DA639)](./LICENSE)
[![bash 3.2+](https://img.shields.io/badge/bash-3.2%2B-4EAA25)](#需求)

**在你自己的機器上，以你自己的 Claude Code 登入執行的 pull request 審查工具。
不需要 GitHub Action、App、webhook，也不需要 repo 管理權限。**

它會監看你列出的 repo。每個開啟中的 PR 只要作者是
[受信任的作者](docs/operations.md#whose-prs-it-reviews)，每出現一個新的 head
（PR 最新的提交），它便請無介面（headless）的
[Claude Code](https://code.claude.com/docs/en/overview) 做一次審查，檢查回傳的內容，
再貼出一則附有判定與各項發現的留言。除非你設定
[GitHub App](docs/github-app.md)，留言會以你自己的 `gh` 帳號發出。整個工具是建立在
`gh`、`git`、`jq` 與 `claude` 之上的純 bash，由一個迴圈每分鐘輪詢一次。

- **只留言。** 它不會送出 GitHub 核准，不會以正式 review 要求修改，也不會合併。
- **模型只能讀取。** `--tools` 把 Claude Code 限制在每個 PR 專屬的 worktree（git
  的獨立工作目錄）內，只能使用 `Read`、`Grep` 與 `Glob`。模型沒有 shell，沒有網路
  工具，你的程式碼也不會被執行。
- **規則由預設分支決定。** `CLAUDE.md`、`AGENTS.md` 與 repo 的其他慣例檔，取自預設
  分支最新的 commit，因此 PR 無法放寬自己的審查標準。
- **它會反駁自己提出的阻擋項。** 每項阻擋型發現（每輪最多六項）會再收到第二次呼叫，
  嘗試推翻它，以降低誤報。
- **步驟失敗時不貼文。** 無法解析或無法掃描的回答不會貼出。經過修復的回答，判定不會
  是核准。

<p align="center">
  <img src="docs/images/demo.gif" alt="終端機對一個測試 PR 執行 prreview once。日誌顯示三項阻擋型發現，包含一項 CRITICAL 的 SQL injection 與兩項 HIGH 發現，每項都經反駁呼叫確認並附上理由，最後貼出判定為 request_changes 的留言，花費 $0.54。PR 留言顯示 Changes requested, 3 blocking，其中 CRITICAL 發現展開後可見追蹤路徑與引用的 A05:2025 Injection、CWE-89。一次把搜尋詞改為綁定參數的 commit 之後，第 2 輪貼出 Changes requested, 1 blocking：三項發現中兩項已修正，分頁發現標為 Carried over。一次把頁碼改為從 1 起算的 commit 之後，第 3 輪貼出 Approved。" width="100%">
</p>

此展示是在測試 PR 上的一次真實執行（Run A），已剪去等待時間：三次推送、三輪審查，
第 3 輪核准。

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/overview-dark.svg">
  <img src="docs/images/overview.svg" alt="pr-reviewer 的架構。它在你的機器上執行。只要有 pull request 處於開啟狀態，審查迴圈每分鐘開始一輪。一輪會透過 gh 從 GitHub 讀取開啟中的 PR，建立每個 PR 專屬的 worktree，並把 prompt 送給 Claude Code。Claude Code 只有 Read、Grep 與 Glob 三個工具。一輪會把 PR 文字與每則留言比對你的 sensitive-patterns 檔。每個新的 head 貼出一則留言。來自不受信任作者的 fork PR 預設會被略過。審查工具從不核准或合併。" width="100%">
</picture>
</p>

## 信任與成本

**信任。** 完整的安全模型見 [SECURITY.md](SECURITY.md)。

- **請在只有你使用的機器上執行。** 服務以你的使用者身分執行，使用你的 `gh` 與
  Claude Code 登入；若你設定了 GitHub App，也會用到它的金鑰。任何能以該使用者身分
  操作的人，都能以你的名義留言。
- **它審查三種 PR：** 來自 repo 本身分支的 PR、作者登入名稱列在
  `PRREVIEW_GATE_TRUSTED_AUTHORS` 的 PR，以及你用 `prreview once --pr` 指定的 PR。
  其他的 fork PR 一律略過，也不會在上面留言。
- **PR 文字視為資料。** prompt 中有這項聲明。這只是對模型的指示，不能當作沙箱。即使
  模型被誘騙，上述工具限制仍然有效，但需要 Claude Code 2.1.305 或更新版本。
- **每則含有 PR 文字或模型輸出的留言，貼出前都會比對你的 `sensitive-patterns` 檔。**
  命中，或掃描無法執行，該則留言會改為一則簡短的通知，通知中不會引用命中的值。
- **它貼出的是模型寫的內容。** 如果你的 repo 中有 bot 會依留言指令（例如 `/lgtm`
  或 `bors r+`）動作，請改用該 bot 不接受其指令的 GitHub App 發留言。
- **它使用你的 Claude Code 登入。** 全天候運作的審查工具是否屬於訂閱方案的一般個人
  使用，由 Anthropic 決定，其條款也曾變動。請閱讀最新條款。改用 API key 可避開這個
  問題，但在 shell 中設定的 key 不會傳給背景服務。請在有該 key 的終端機執行
  `prreview run`（[詳情](docs/operations.md#where-to-run-it)）。

**成本。**

- 每次推送到該 PR，都會立即開始新的一輪。編輯 PR 的標題、描述或 base 分支，以及
  推送到堆疊式 PR（stacked PR）的父分支，也會開始新的一輪。若 head 未變，後兩種
  情況會等到審查工具上一則留言滿 10 分鐘（`PRREVIEW_GATE_PR_COOLDOWN_MIN`）才處理。
- 一輪最多可能發出以下呼叫：每個切片（diff 切出的一小段，約 250 行）一次審查呼叫
  （最多 8 個切片；第一輪遇到 1000 行以上的 diff，或免拆分的 PR 時，每個切片兩次）、每項阻擋型發現
  一次反駁呼叫（最多 6 次），以及一次修復呼叫。最大的第一輪會有 16 次審查、6 次反駁
  與 1 次修復呼叫。尚無測試執行涵蓋這種情況，因此費用未知。
- 展示的第 1 輪花費 $0.54，三輪共 $1.14（Run A）。第二個測試 PR 花費 $0.75，之後一次
  沒有改動內容的推送花費 $0.73（Run B）。在一個小型且沒有問題的 PR 上，紅隊使 $0.34
  的審查增加 $0.23（Run C）。這些執行發生在 2026 年 9 月與 10 月，早於 v0.2.0 更換
  預設模型，因此不代表目前預設值的花費。金額取自 `claude -p` 的回報。使用訂閱方案
  時，這些金額會計入用量上限，而非帳單。

## 狀態與限制

- **1.0 之前。** 版本之間任何事都可能改變。升級前請閱讀 [CHANGELOG.md](CHANGELOG.md)。
- **偵測能力尚未量測。** 沒有人統計過它找出多少 bug，或產生多少誤報。
- **它只讀程式碼。** 它不執行你的測試，也不讀取 CI 結果。判定是一則留言，沒有 GitHub
  的 review 狀態。核准橫幅會寫「Automated review, not a GitHub approval.」。
- **只支援 GitHub，且僅在機器處於喚醒狀態時有效。** PC 睡眠時它會暫停。CI 在 Ubuntu
  上以系統內建的 bash 執行測試，在 macOS 上以 `/bin/bash`（bash 3.2）執行測試。WSL2 不在 CI 內，只在維護者自己的
  機器上確認過（[docs/windows.md](docs/windows.md)）。Bedrock、Vertex 與 gateway
  未經測試。
- **一項已知缺口。** 合併進預設分支的 PR，其審查鍵（review key）不包含 base commit
  （[已知限制](SECURITY.md#known-limits)）。
- **不適合的情境：** 多人共用一個 Claude 登入、必須能阻擋合併的必要檢查（required
  check），以及不得傳給 Anthropic 的程式碼。

與其他工具的差異，請見 [docs/comparison.md](docs/comparison.md)。

## 需求

- **macOS 或 Linux。** 在 Windows 上於 WSL2 內執行。
- **bash 3.2 以上。** macOS 內建的 `/bin/bash` 可用。
- **[gh](https://cli.github.com/) 2.63.0 以上**與
  **[Claude Code](https://code.claude.com/docs/en/overview) 2.1.305 以上**
  （`claude update` 會安裝最新版），兩者都需已登入。
- `git`、`jq`、`curl`、`openssl` 與 `flock`；一個 timeout 指令（`timeout` 或
  `gtimeout`）；一個 SHA-256 指令（`sha256sum`、`gsha256sum` 或 `shasum`）。腳本會
  使用最先找到的那一個。
- **Linux 上需 systemd 240 以上**，供背景服務使用。服務以 `StandardOutput=append:`
  寫入日誌。

`prreview setup` 會檢查每一項，並印出適合你系統的安裝指令。macOS 搭配 Homebrew 時，
執行 `brew install git jq gh coreutils flock`。Debian 或 Ubuntu 則執行
`sudo apt install git jq curl openssl util-linux coreutils`，再從
[GitHub 的套件庫](https://github.com/cli/cli/blob/trunk/docs/install_linux.md)安裝
`gh`。

## 快速開始

### 1. 取得程式碼

```bash
git clone https://github.com/nagameTW/pr-reviewer.git ~/pr-reviewer
mkdir -p ~/.local/bin && ln -s ~/pr-reviewer/prreview ~/.local/bin/prreview
```

請不要把 clone 放在 `~/Documents`、`~/Desktop`、`~/Downloads` 與 iCloud Drive
（`~/Library/Mobile Documents`）內，macOS 背景服務無法讀取這些位置。若 `~/.local/bin` 不在 `PATH` 中，請把它加進去。

### 2. 執行 setup

```bash
prreview setup
```

它一次問一個問題，按 Enter 即採用方括號內的值。它會檢查你的工具，以及 `claude` 與
`gh` 的登入狀態，接著詢問要審查的 repo（它會列出你帳號下最多 30 個 repo，其他 repo 請輸入
`owner/repo`；請列入一個你自己擁有的）、由誰發留言、使用
的模型等項目。問到 **Background service** 時，目前請回答 `n`。答案會寫入
`~/.config/pr-reviewer/config`。

### 3. 審查一個測試 PR

從你已列出的 repo 的某個分支開一個小 PR，然後執行：

```bash
prreview once --pr you/repo#12
```

此指令會發出真實的模型呼叫，並以你的 `gh` 帳號貼出留言。結束碼 `0` 表示審查工具對
目前的 head 已有判定。`75` 表示沒有判定，且沒有任何步驟失敗，例如草稿 PR。`1` 表示
該 PR 已非開啟狀態，或無法讀取。

### 4. 啟動服務

> [!WARNING]
> 第一輪會審查每個列出的 repo 中，所有由受信任作者開啟的非草稿 PR，並以你的 `gh`
> 帳號在每個 PR 上留言。每次審查都會消耗模型用量。在你信任它之前，請只列出你自己
> 擁有的 repo。

```bash
prreview start
prreview status
prreview logs -f
```

若 `gh` 以 `ssh` 進行 clone，`prreview start` 會提議把 `gh` 改為 `https`，因為
systemd 使用者服務沒有 ssh-agent（[詳情](docs/operations.md#where-to-run-it)）。沒有
待審 PR 時，迴圈每檢查 15 次才開始一輪。在 Linux 上，你登出時 systemd 會停止
使用者服務；請執行一次 `sudo loginctl enable-linger "$USER"`，服務才會持續運作。在
WSL2 上，服務需要 `systemd=true`，且在 WSL 關閉時停止，詳見
[docs/windows.md](docs/windows.md)。

## 常用指令

| 指令 | 用途 |
| --- | --- |
| `prreview repos add owner/repo`、`prreview repos remove owner/repo` | 變更受審查的 repo |
| `prreview set <name> <value>`、`prreview get <name>`、`prreview unset <name>` | 變更、讀取或重設設定 |
| `prreview once`、`prreview run` | 在此終端機執行一輪，或執行迴圈 |
| `prreview once --pr owner/repo#12` | 立即審查該 PR，fork PR 也包含在內 |
| `prreview stop`、`prreview start`、`prreview restart` | 控制背景服務 |
| `prreview status`、`prreview logs -f` | 顯示狀態與被略過的 PR；持續追蹤日誌 |
| `prreview checks` | 列出、新增或移除審查項目 |
| `prreview uninstall` | 移除背景服務；設定會保留 |

變更設定的指令會重新啟動服務。若要完整移除，請見
[docs/operations.md](docs/operations.md#removing-it)。

## 升級

```bash
cd ~/pr-reviewer
git pull --ff-only
prreview setup
```

所有問題都按 Enter，即可保留原本的答案。到 Checklist 步驟時，回答 `y` 會採用新的
內建項目；按 Enter 則拒絕。setup 會重新啟動服務，因為迴圈在重新啟動之前仍執行舊的
程式碼。若 `claude --version` 或 `gh --version` 低於最低版本，setup 會停止。請更新
該工具後，再執行一次 setup。

在 0.2.0 之後的版本，審查工具會略過 fork PR，除非作者列在
`PRREVIEW_GATE_TRUSTED_AUTHORS` 中。`prreview status` 會顯示略過的數量。設定
`PRREVIEW_GATE_FORK_PRS=1` 可恢復舊行為。

你的檢查清單副本中的項目會保留舊的措辭。若要查看新版改了什麼，請執行
`diff -r ~/pr-reviewer/checks ~/.config/pr-reviewer/checks`。

## 審查如何運作

<p align="center">
  <img src="docs/images/example-comment.png" alt="一則審查留言：Changes requested 橫幅，計有 2 項阻擋、1 項不阻擋的發現；一行摘要；一項 CRITICAL 的 SQL injection 發現，展開後可見從輸入到危險呼叫點（sink）的追蹤路徑，以及引用的 A05:2025 Injection、CWE-89；另有一項 HIGH 的分頁發現。摘要其餘部分、MEDIUM 發現，以及審查無法驗證的內容皆已摺疊。" width="820">
</p>

此留言取自 Run B。留言以判定開頭，每項發現一行。每項發現都指出檔案、行號與修正
方式。每個切片都依同一份共 13 個項目的清單審查，每個項目一個檔案，放在 `checks/`
內。「適用時機」欄說明何時採用該項目。每項發現會標明所屬項目與嚴重度。

| 項目 | 檢查內容 | 適用時機 |
| --- | --- | --- |
| 1 正確性 | 錯誤、未處理的輸入、被破壞的呼叫端、並行問題 | 一律 |
| 2 安全性 | 注入、授權缺口、密碼學與機密、資料暴露 | 一律 |
| 2b AI agent 安全 | Prompt injection、未經檢查的模型輸出、過度的代理權限 | diff 將內容送給 LLM、賦予 LLM 工具，或依其輸出採取動作 |
| 3 敏感資料 | 真實位址、主機名稱、token 或憑證 | 一律 |
| 4 專案限制 | repo 自己寫下的規則 | 一律 |
| 5 測試 | CI 被削弱、修 bug 卻沒有測試、斷言過弱 | 一律 |
| 6 設計 | 過度設計、改動放錯位置 | 一律 |
| 7 文件同步 | 仍在描述舊行為的文件 | 一律 |
| 8 相依套件 | 未宣告，或固定版本的方式與其他套件不一致的相依套件 | 一律 |
| 9 證據優先 | 未經量測便改動的啟發式規則、限制、模型選擇或 prompt | diff 改動其中任一項 |
| 10 工具範圍 | 模型可呼叫、但範圍過廣或無需核准的工具 | diff 定義或變更這類工具 |
| 11 驗收 | diff 未達成關聯 issue 的某項需求 | PR 連結了 issue |
| 12 半套修復 | 相鄰的同類程式碼仍有同樣的缺陷 | 一律 |

不回報的項目：阻斷服務（denial of service，沒有逾時設定的呼叫除外）、記憶體安全語言
中的記憶體安全問題、沒有可利用路徑的漏洞、由 linter 強制的風格問題，以及讚美。
CRITICAL 與 HIGH 的發現會阻擋，MEDIUM 與 LOW 只列出而不阻擋。「阻擋」只決定判定的
文字。你可以[新增、移除或修改項目](docs/configuration.md#adding-your-own-checks)。
完整的檢查清單與嚴重度規則見 [docs/how-it-reviews.md](docs/how-it-reviews.md)。

一輪有七個步驟，前四個步驟不呼叫模型。

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/round-dark.svg">
  <img src="docs/images/round.svg" alt="單一審查輪的七步驟流程圖。步驟 1 到 4 不呼叫模型。1 Pick：挑出目前 head 尚無留言的開啟中 PR。來自不受信任作者的 fork PR 會被略過。若 head 未變，且審查工具上一則留言距今不到 10 分鐘，該輪等待。標題、描述或 base 的編輯，或推送到堆疊式 PR 的父分支，會造成這種等待。推送到 PR 分支從不等待。2 Scan：將標題、描述與關聯 issue 比對你的 sensitive-patterns 檔。若命中，或掃描無法執行，則貼出一則不含該值的 Review withheld 通知，且不審查該 PR。3 Build：merge base 加上 PR diff，再加上取自預設分支的慣例檔。超過 2000 行變更或 40 個檔案時，回覆拆分請求，不進行審查，除非該 PR 屬於豁免情況。4 Slice：切成約 250 行的切片，最多 8 個。5 Review：Claude Code 讀取 worktree。6 Verify：引用了不存在檔案的發現會被丟棄。每項阻擋型發現各用一次呼叫嘗試反駁。7 Post：模型文字經過跳脫處理，留言比對你的 sensitive-patterns 檔，然後貼出一則留言。無法解析的輸出不會貼出。" width="100%">
</picture>
</p>

每次推送都是新的一輪。prompt 要求模型把先前每項阻擋項標為已修正，或加上前綴
`Carried over:` 重複列出。執行流程的腳本不會檢查模型是否照做。

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/rounds-dark.svg">
  <img src="docs/images/rounds.svg" alt="單一發現在多輪之間的狀態圖。每次推送開始新的一輪。新的 CRITICAL 或 HIGH 發現會阻擋。下一次推送時，模型把它標為已修正，或加上前綴 Carried over 重複列出。被延續的發現仍會阻擋，並一直維持延續狀態，直到模型把它標為已修正。對於這次推送未改動、且先前各輪都未引用過的檔案，所產生的新 HIGH 發現會顯示為 MEDIUM，它不阻擋，也不延續。CRITICAL 從不降級。執行流程的腳本不會檢查模型是否正確標記發現。沒有阻擋型發現的一輪會貼出 Approved。若 PR 在判定為 changes requested 時被合併，會收到一則警示留言。" width="100%">
</picture>
</p>

選用的紅隊（red team）會對核准提出反駁。它預設關閉，因為它會讓每次核准都增加成本與
時間。執行 `prreview set PRREVIEW_GATE_REDTEAM 1` 即可開啟。

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/redteam-dark.svg">
  <img src="docs/images/redteam.svg" alt="選用紅隊的流程圖。某一輪沒有阻擋項，即將核准。再多一次呼叫，主張這個核准是錯的。它尋找 diff 中彼此矛盾的部分、位於錯誤層級的限制、被當成成功回傳的錯誤、依其他輸入做決定的分支，以及 repo 自身文件已明文規定的規則。若該次呼叫失敗或逾時，核准維持不變。若沒有 CRITICAL 或 HIGH 的候選項，核准維持不變。最多 3 個候選項，各經一次反駁呼叫。被反駁的候選項會被丟棄，核准維持不變。存活的候選項會被貼出，並標示為由紅隊提出。紅隊預設關閉。指令 prreview set PRREVIEW_GATE_REDTEAM 1 可開啟。" width="100%">
</picture>
</p>

步驟失敗時如何處理，以及各步驟的細節，請見 [docs/operations.md](docs/operations.md)。

## 設定

設定由一個設定檔加上覆寫值組成。設定檔是 `~/.config/pr-reviewer/config`，每行一個
`KEY=value`，由 `prreview set` 寫入。環境中設定的變數會覆寫設定檔。有兩項設定為
必填：`PRREVIEW_GATE_REPOS`，以及 `PRREVIEW_SENSITIVE_PATTERNS_FILE`，也就是
`prreview setup` 寫出的 `sensitive-patterns` 檔。
最常被修改的有 `PRREVIEW_GATE_TRUSTED_AUTHORS`、`PRREVIEW_GATE_FORK_PRS`、
`PRREVIEW_REVIEW_MODEL`、`PRREVIEW_GATE_PARALLEL`、
`PRREVIEW_GATE_PR_COOLDOWN_MIN`、`PRREVIEW_GATE_REDTEAM`、
`PRREVIEW_GATE_TICKETS` 與 `PRREVIEW_ALERT_REPO`。每項設定及其預設值見
[docs/configuration.md](docs/configuration.md)，單一輪的細節與失敗處理見
[docs/operations.md](docs/operations.md)，以 App 身分留言見
[docs/github-app.md](docs/github-app.md)，WSL2 見
[docs/windows.md](docs/windows.md)。

## 開發

```bash
bash tests/run-all.sh
```

該指令會執行 `bash -n`、`shellcheck -S warning` 與每一個 `tests/*.test.sh`，不需要
網路、`gh` 或模型。未安裝 `shellcheck` 時該指令會失敗。請在 `git clone` 的目錄內
執行，因為檢查會用 `git ls-files` 列出腳本，ZIP 下載的內容會在這裡停止。CI 在
Ubuntu 與 macOS 上執行相同的指令。請見
[CONTRIBUTING.md](CONTRIBUTING.md)。本專案把可預測的審查行為，置於審查範圍的廣度
之前。

## 授權

[MIT](LICENSE)
