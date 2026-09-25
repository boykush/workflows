# workflows

`boykush` owner の repo をまたいで呼ぶ reusable workflow と action の置き場。呼び出し側は SHA で固定する。

public にしてあるのは、個人アカウントの private repo に置いた workflow と action は同じ持ち主の private repo からしか呼べず、public な呼び出し側から使えないため。

## 置いているもの

| パス | 種類 | 役割 |
| --- | --- | --- |
| `.github/workflows/ai-review.yml` | reusable workflow | owner の PR をレビューし、Claude GitHub App として承認するか変更を求める |
| `.github/actions/claude-code-token/` | composite action | Claude Code の OAuth token を Parameter Store から、呼び出した run の OIDC で読む |

### ai-review

入れるかどうかは repo ごとに決める。入れる repo が自分で caller を置く:

```yaml
name: ai-review

on:
  pull_request:
    types: [opened, reopened, synchronize, ready_for_review]

permissions: {}

jobs:
  ai-review:
    uses: boykush/workflows/.github/workflows/ai-review.yml@<SHA>
    permissions:
      contents: read
      pull-requests: read
      id-token: write
```

- 見るのは owner の PR だけで、draft は見ない。条件は reusable workflow の中にあるので、ほかの PR でも check は `ai-review / review` の名前で skipped になる
- 判定の基準は、今は [boykush/adr](https://github.com/boykush/adr) の決定だけ。adr の MCP サーバーから読み、ルールの文法は `ade-rule-dsl` の reference で確かめる。接続先も reference も `apm.yml` の依存で、この repo を呼び出された SHA のまま checkout して Claude に渡す
- 違反が無ければ承認し、あれば指摘を本文にして変更を求める。どちらも Claude GitHub App（claude[bot]）として Claude 自身が出す。action は run の OIDC を App の token に替え、終わるときに revoke するので、後の step からは出せない。Claude が打てるのは、この PR 番号と本文のファイルを名指ししたコマンドだけ。読めるのは working directory の中だけなので、その外のものが review の本文に入ることは無い
- 承認するかを Claude が決めるので、最後の step で、読んだ commit への claude[bot] の review が構造化出力の判定と合っているかを確かめ、合わなければ失敗する
- MCP サーバーに繋がらなければ失敗する。繋がらないまま走らせると、決定を1つも読まずに通してしまうため。サーバーを載せている cluster は夜間止まる

入れるときに要るもの:

- その repo に [Claude GitHub App](https://github.com/apps/claude) を install する
- [infrastructure-as-code](https://github.com/boykush/infrastructure-as-code) の `terraform/variables.tf` で、`claude_code_repositories` に repo を足す
- [github-management](https://github.com/boykush/github-management) の catalog で、その repo の Component に依存を書く

caller を足す PR 自身では check が失敗する。App の token の交換は、workflow が default branch にあることを求めるため。

### claude-code-token

- role と parameter は infrastructure-as-code の `terraform/aws.tf` が作り、token を書き込むのも同じ repo の `mise run claude:token`
- 読めるのは、同じ repo の `terraform/variables.tf` にある `claude_code_repositories` に列挙した repo だけ。呼び出す repo を増やすときはそこに足す

## 変えるとき

呼び出し側は SHA で固定しているので、ここを変えたら各 repo の固定を上げる。
