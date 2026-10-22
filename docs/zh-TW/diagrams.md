# 圖表

本頁收錄 pr-reviewer 的四張圖。每張圖預設收合，選取標題即可展開。圖會依瀏覽器的淺色或深色主題切換。英文版圖表見 [Diagrams](../how-it-reviews.md#diagrams)。

## 整體架構

說明各部分如何在使用者的機器上合作。

<details>
<summary>架構：使用者的機器、GitHub 與 Claude Code</summary>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../images/overview-zh-dark.svg">
  <img src="../images/overview-zh.svg" alt="pr-reviewer 的架構。整個流程在使用者的機器上執行。只要有 PR 處於開啟狀態，審查迴圈每分鐘開始一輪。每一輪透過 gh 從 GitHub 讀取開啟中的 PR，範圍限於 PRREVIEW_GATE_REPOS 列出的 repo。每一輪為每個 PR 建立專屬的 worktree，接著 prompt 送給 Claude Code。Claude Code 以 claude -p 在無介面模式執行，只有 Read、Grep 與 Glob 三個工具，不能執行指令，也不能連網。每一輪也以 sensitive-patterns 檔比對 PR 文字與每則留言。每個新的 head 貼出一則留言。預設略過來自不受信任作者的 fork PR。作者列於 PRREVIEW_GATE_TRUSTED_AUTHORS、以 prreview once --pr 指定，或設定 PRREVIEW_GATE_FORK_PRS=1 時才審查。pr-reviewer 從不核准或合併。唯一與合併有關的動作，是關閉尚未審查的 head 上的自動合併。只有設定 PRREVIEW_GATE_DISARM_AUTO_MERGE=1 時，才會執行指令 gh pr merge --disable-auto。審查結果只是一則留言，不構成 GitHub 的核准。" width="720">
</picture>

</details>

## 一輪審查

一輪有七個步驟，前四個步驟不呼叫模型。

<details>
<summary>一輪審查的七個步驟</summary>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../images/round-zh-dark.svg">
  <img src="../images/round-zh.svg" alt="一輪審查的七步驟流程圖。步驟 1 到 4 不呼叫模型。步驟 1 Pick：選出目前 head 尚無留言的開啟中 PR，略過來自不受信任作者的 fork PR。若 head 未變，且上一則審查留言距今不到 10 分鐘，該輪等待。編輯標題、描述或 base，以及推送到堆疊式 PR 的父分支，會造成這種等待。推送到 PR 分支從不等待。步驟 2 Scan：以 sensitive-patterns 檔比對標題、描述與關聯 issue。若命中或掃描無法執行，貼出不含命中內容的 Review withheld 通知，不審查該 PR。步驟 3 Build：組合 merge base 與 PR diff，另加入取自預設分支的審查規則檔。變更超過 2000 行或 40 個檔案的 PR 會收到拆分請求，不予審查，不受大小限制的 PR 除外。步驟 4 Slice：切成約 250 行的 diff 區段，最多 8 個。步驟 5 Review：Claude Code 讀取 worktree。步驟 6 Verify：捨棄引用不存在檔案的問題。每個會擋下核准的問題再呼叫一次模型，請他再次檢查是否誤判。步驟 7 Post：讓模型文字中的特殊文字失效，留言比對 sensitive-patterns 檔後，貼出一則留言。無法解析的輸出不貼出。" width="640">
</picture>

</details>

## 同一個問題在多輪之間的狀態

每次推送都開始新的一輪。prompt 要求模型對先前每個會擋下核准的問題二擇一：標為已修正，或加上前綴 `Carried over:` 重複列出，沿用到下一輪。pr-reviewer 的程式不會檢查模型是否照做。

<details>
<summary>同一個問題在多輪之間的狀態</summary>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../images/rounds-zh-dark.svg">
  <img src="../images/rounds-zh.svg" alt="單一問題在多輪之間的狀態圖。每次推送開始新的一輪。新的 CRITICAL 或 HIGH 問題會擋下核准。下一次推送時，模型有兩種處理。一是標為已修正。二是加上前綴 Carried over 重複列出，沿用到下一輪。沿用的問題仍然擋下核准，直到模型標為已修正。新的 HIGH 問題可能位於本次推送未改動、先前各輪也未引用的檔案。此時問題顯示為 MEDIUM，不擋下核准，也不沿用到下一輪。CRITICAL 從不降級。pr-reviewer 的程式不會檢查模型是否正確標記問題。一輪沒有會擋下核准的問題時貼出 Approved。審查結果為 changes requested 的 PR 合併後，收到一則警示留言。" width="720">
</picture>

</details>

## 紅隊

紅隊是選用功能。pr-reviewer 準備核准時，紅隊多呼叫一次模型，請他主張這個核准是錯的。預設關閉，因為每次核准都會增加成本與時間。執行 `prreview set PRREVIEW_GATE_REDTEAM 1` 即可開啟。

<details>
<summary>選用的紅隊：核准之前多一道檢查</summary>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../images/redteam-zh-dark.svg">
  <img src="../images/redteam-zh.svg" alt="選用紅隊的流程圖。某一輪無會擋下核准的問題，即將核准。紅隊多呼叫一次模型，主張這個核准是錯的。該呼叫在 diff 中尋找五種可疑處。第一種是彼此矛盾的部分。第二種是套用範圍錯誤的限制。第三種是被當成成功結果回傳的錯誤。第四種是根據其他輸入決定結果的判斷分支。第五種是 repo 文件已明文規定的規則。候選問題最多 3 個，各經一次再次檢查是否誤判的呼叫。核准維持不變的情況有三種：無 CRITICAL 或 HIGH 的候選問題；再次檢查後確認是誤判；呼叫失敗或逾時。確認不是誤判的候選問題貼出，並標示為紅隊提出。紅隊預設關閉。指令 prreview set PRREVIEW_GATE_REDTEAM 1 可開啟。" width="720">
</picture>

</details>
