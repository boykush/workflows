# workflows

`boykush` owner の repo をまたいで呼ぶ reusable workflow と action の置き場。呼び出し側は SHA で固定する。

public にしてあるのは、個人アカウントの private repo に置いた workflow と action は同じ持ち主の private repo からしか呼べず、public な呼び出し側から使えないため。

## 置いているもの

| パス | 種類 | 役割 |
| --- | --- | --- |
| `.github/workflows/ai-review.yml` | reusable workflow | PR の差分を [boykush/adr](https://github.com/boykush/adr) の決定と照合し、違反をコメントする |
| `.github/actions/claude-code-token/` | composite action | Claude Code の OAuth token を Parameter Store から、呼び出した run の OIDC で読む |

### ai-review

- 呼び出し側は [github-management](https://github.com/boykush/github-management) が `templates/` から各 repo へ配る。`pull_request` で走り、author が boykush の PR だけを見る
- 決定は adr の MCP サーバーから読み、ルールの文法は `ade-rule-dsl` の reference で確かめる。接続先も reference も `apm.yml` の依存で、この repo を呼び出された SHA のまま checkout して Claude に渡す
- 判定は構造化出力で受け取る。Claude の job は読み取りの token しか持たず、コメントは別の job が書く
- MCP サーバーに繋がらなければ失敗する。繋がらないまま走らせると、決定を1つも読まずに通してしまうため。サーバーを載せている cluster は夜間止まる
- 今は判定をコメントするだけ。ruleset が要求する承認は、これまでどおり approve-pr が出している

### claude-code-token

- role と parameter は [infrastructure-as-code](https://github.com/boykush/infrastructure-as-code) の `terraform/aws.tf` が作り、token を書き込むのも同じ repo の `mise run claude:token`
- 読めるのは、同じ repo の `terraform/variables.tf` にある `claude_code_repositories` に列挙した repo だけ。呼び出す repo を増やすときはそこに足す

## 変えるとき

呼び出し側は SHA で固定しているので、ここを変えたら呼び出し側の固定を上げる。ai-review の呼び出し側は github-management の `templates/` にあり、その apply で各 repo に配られる。
