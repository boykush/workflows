# workflows

`boykush` owner の repo をまたいで呼ぶ reusable workflow と action の置き場。呼び出し側は SHA で固定する。

public にしてあるのは、個人アカウントの private repo に置いた workflow と action は同じ持ち主の private repo からしか呼べず、public な呼び出し側から使えないため。

## 置いているもの

| パス | 種類 | 役割 |
| --- | --- | --- |
| `.github/workflows/ai-review.yml` | reusable workflow | owner の PR をレビューし、Claude GitHub App として承認するか変更を求める |
| `.github/actions/claude-code-token/` | composite action | Claude Code の OAuth token を Parameter Store から、呼び出した run の OIDC で読む |
| `.github/actions/github-app-token/` | composite action | GitHub App のインストールトークンを、private key を AWS KMS に置いたまま、呼び出した run の OIDC で発行する |

### ai-review

入れるかどうかは repo ごとに決める。private repo には入れない。ruleset が無く、承認が merge の条件にならないので、push 前にセッションがルールと照合するのに任せる。

入れる repo が自分で caller を置く:

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
- 判定の基準は、今は [boykush/adr](https://github.com/boykush/adr) のルールだけ。照らし方は adr-remote-mcp の skill `adr-review` に従い、ルールの文法は `ade-rule-dsl` の reference で確かめる。接続先も skill も `apm.yml` の依存で、この repo を呼び出された SHA のまま checkout して Claude に渡す。レビューされる repo が同じ skill を持っていても、読むのはこちらの checkout の方
- 違反が無ければ承認し、あれば指摘を本文にして変更を求める。どちらも Claude GitHub App（claude[bot]）として Claude 自身が出す。action は run の OIDC を App の token に替え、終わるときに revoke するので、後の step からは出せない。Claude が打てるのは、この PR 番号と本文のファイルを名指ししたコマンドだけ。読めるのは working directory の中だけなので、その外のものが review の本文に入ることは無い
- モデルは Sonnet。`--model sonnet` と alias で指定しているので、Claude Code の既定が変わっても入れ替わらず、新しい Sonnet にはここを変えずに上がる
- 承認するかを Claude が決めるので、最後の step で、読んだ commit への claude[bot] の review が構造化出力の判定と合っているかを確かめ、合わなければ失敗する
- MCP サーバーに繋がらなければ失敗する。繋がらないまま走らせると、決定を1つも読まずに通してしまうため。サーバーを載せている cluster は夜間止まる

入れるときに要るもの:

- その repo に [Claude GitHub App](https://github.com/apps/claude) を install する
- [infrastructure-as-code](https://github.com/boykush/infrastructure-as-code) の `terraform/variables.tf` で、`claude_code_repositories` に repo を足す
- [github-management](https://github.com/boykush/github-management) の catalog で、その repo の Component に依存を書く
- この repo の `apm.yml` が SHA で固定している repo なら、caller は SHA ではなく `main` で呼ぶ。互いに SHA で固定すると、Renovate が交互に上げ続けて止まらない

caller を足す PR 自身では check が失敗する。App の token の交換は、workflow が default branch にあることを求めるため。

この repo 自身の PR も `.github/workflows/ai-review-self.yml` から ai-review にかける。ほかの repo と違って SHA で固定せず、`$/` で呼ぶ。自分の HEAD に固定すると、Renovate の bump を merge するたびに HEAD が進み、次の bump が開き続けるため。PR の commit の ai-review.yml が走るので、ai-review.yml を変える PR は、変えた後の版に review される。

### github-app-token

GITHUB_TOKEN で足りない操作をする workflow が App のトークンを取るところ。App の private key は AWS KMS から出ず、run が受け取るのは JWT への署名1回分:

```yaml
      - name: Generate GitHub App token
        id: app-token
        uses: boykush/workflows/.github/actions/github-app-token@<SHA>
        with:
          app: terraform-ci
          permission-contents: write
```

- `app` は [infrastructure-as-code](https://github.com/boykush/infrastructure-as-code) の `terraform/variables.tf` の `github_apps` が書く App の名前。KMS の alias（`alias/github-app-<app>`）も署名する role（`github-actions-github-app-<app>`）もこの名前から決まるので、呼び出し側は ARN を持たない。AWS の account と region もここが持つ
- App の client id / app id もこの名前から引く。台帳は [github-management](https://github.com/boykush/github-management) の catalog（`resource:<app>-app` の annotation）で、action が持つのはその写し。App を足すときは両方に書く——ずれると token の発行が落ちるので、黙って別の App として署名することはない
- job に `id-token: write` が要る。署名できる repo は role の trust policy が列挙するので、新しい repo から呼ぶときは infrastructure-as-code の `github_apps` にその repo を足す
- 権限は渡したものだけがトークンに乗る。1つも渡さないと action が失敗する——App が install 時に持つ権限を丸ごと配らないため。使う scope がここに無ければ action に input を足す
- `owner` を渡すとトークンが installation 全体に広がる。zizmor の `github-app` は呼び出し側を見ても反応しない（action 越しなので）ので、広げた理由は呼び出し側にコメントで残す。実際にどちらで発行したかは run のログに出る

### claude-code-token

- role と parameter は infrastructure-as-code の `terraform/aws.tf` が作り、token を書き込むのも同じ repo の `mise run claude:token`
- 読めるのは、同じ repo の `terraform/variables.tf` にある `claude_code_repositories` に列挙した repo だけ。呼び出す repo を増やすときはそこに足す

## 変えるとき

呼び出し側の SHA は、[renovate-runner](https://github.com/boykush/renovate-runner) の Renovate が main の HEAD まで上げ、automerge する。ここを変えると、次の Renovate の実行で各 repo に届く。
