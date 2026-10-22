# Demo run and example comment

This page shows one real run of the reviewer on a test PR, and one real review comment. The [cost table](trust-cost-limits.md#cost) lists the runs by name. Run A is the demo run. Run B is the example comment.

Contents:

- [Demo run](#demo-run)
- [Example comment](#example-comment)

## Demo run

The recording shows Run A. The waits are cut out. The run has three pushes and three rounds. Round 3 approves. Round 1 cost $0.54, and the three rounds cost $1.14.

<details>
<summary>Recording of Run A: three pushes, three rounds</summary>

<p align="center">
  <img src="images/demo.gif" alt="A terminal runs prreview once on a test PR. The log shows three blocking findings. One is a CRITICAL SQL injection and two are HIGH. A refutation call upholds each one and gives its reason. The reviewer posts a comment with verdict request_changes. The run costs $0.54. The PR comment shows Changes requested, 3 blocking. The CRITICAL finding is open and shows its trace and its citation A05:2025 Injection, CWE-89. A commit then binds the search term as a parameter. Round 2 posts Changes requested, 1 blocking. Two of the three findings are fixed. The paging finding is marked Carried over. A commit then makes pages 1-based. Round 3 posts Approved." width="720">
</p>

</details>

## Example comment

This comment is from Run B. It leads with the verdict and one line per finding. Every finding names a file, a line and a fix. Each finding also names its checklist item and a severity. The [checklist](how-it-reviews.md#the-checklist) lists the items.

<details>
<summary>A Changes requested comment with two blocking findings</summary>

<p align="center">
  <img src="images/example-comment.png" alt="A review comment. A Changes requested banner counts 2 blocking findings and 1 finding that does not block. A one-line summary follows. A CRITICAL SQL injection finding is open. It shows its trace from input to sink and its citation A05:2025 Injection, CWE-89. A HIGH paging finding follows. The rest of the summary, the MEDIUM finding and what the review could not verify are folded." width="640">
</p>

</details>
