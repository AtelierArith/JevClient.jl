# JevClient.jl 仕様書

- **文書版**: 0.1-draft
- **対象実装**: JevClient.jl 0.1.x
- **作成日**: 2026-09-22
- **上流仕様の確認日**: 2026-09-22
- **状態**: 実装開始前レビュー用
- **位置づけ**: TypeSafe AI の非公式 Julia クライアント

> 本文書では「必須（MUST）」「禁止（MUST NOT）」「推奨（SHOULD）」「非推奨（SHOULD NOT）」「任意（MAY）」を規範語として用いる。

---

## 1. 概要

`JevClient.jl` は、TypeSafe AI の System One API、特に Jev モデルを Julia から安全に利用するためのクライアントライブラリである。

本パッケージは単なる HTTP ラッパーではなく、次を主目的とする。

1. `Noul`、`Choice`、`Score` を Julia の型として表現する。
2. API へ送信する前に、構造・サイズ・値域をローカル検証する。
3. API キー、入力本文、質問、応答本文をログや例外へ漏らさない。
4. API キーの送信先を TypeSafe の正規オリジンに固定する。
5. リダイレクト、暗黙のプロキシ、曖昧な自動再試行による情報漏えい・重複課金を抑止する。
6. 応答 JSON を信用せず、型・値域・整合性を検証してからアプリケーションへ渡す。
7. モデル出力を「命令」ではなく「未信頼データ」として扱う設計を利用者に強制・誘導する。

パッケージ名と TypeSafe/Jev の商標・ブランドの関係を誤認させないため、README、パッケージ説明、ドキュメントには **“Unofficial Julia client for TypeSafe AI”** と明記する。

---

## 2. 上流 API の前提

JevClient.jl 0.1 は、2026-09-22 時点の TypeSafe API を基準とする。

### 2.1 エンドポイント

| 操作 | HTTP | エンドポイント |
|---|---:|---|
| System One 評価 | POST | `https://api.typesafe.ai/v1/systemone` |
| モデル一覧 | GET | `https://api.typesafe.ai/v1/models` |

認証方式は次の Bearer 認証である。

```http
Authorization: Bearer <API_KEY>
```

### 2.2 System One リクエスト

```json
{
  "state": "string, object, or array",
  "model": "jev-1.13.0",
  "questions": {
    "question_id": {
      "type": "noul | choice | score",
      "instructions": "string, object, or array",
      "criteria": "type-dependent"
    }
  }
}
```

- `state` は文字列、JSON オブジェクト、JSON 配列のいずれか。
- `model` は必須。
- `questions` は質問 ID から質問へのマップ。
- 質問 ID は応答との対応付けに使われるが、推論モデルには送られない。

### 2.3 質問

#### Noul

Yes である確率を `[0, 1]` で返す。

```json
{
  "type": "noul",
  "instructions": "Does this convey urgency?",
  "criteria": {
    "true": "Explicitly time-sensitive",
    "false": "No urgency expressed"
  }
}
```

#### Choice

定義済み候補から 1 つを選び、全候補の確率分布を返す。上流 API の上限は 255 候補である。

```json
{
  "type": "choice",
  "instructions": "Which team should handle this?",
  "criteria": {
    "billing": "Payments, invoicing, refunds",
    "technical": "Bugs, outages, integrations",
    "sales": "Pricing, upgrades, new accounts"
  }
}
```

#### Score

順序付きレベルに対する確率分布と加重平均を返す。レベル数は 2 以上 10 以下である。

```json
{
  "type": "score",
  "instructions": "How frustrated is the customer?",
  "criteria": ["Calm", "Frustrated", "Very angry"]
}
```

### 2.4 応答

```json
{
  "model": "jev-1.13.0",
  "answers": {
    "is_urgent": {
      "type": "noul",
      "noul": 0.95
    }
  },
  "usage": {
    "input_tokens": 296,
    "output_tokens": 20
  }
}
```

### 2.5 上流エラー

少なくとも次を扱う。

| HTTP status | 意味 |
|---:|---|
| 401 | API キー欠落または無効 |
| 422 | リクエスト検証エラー |
| 429 | レート制限 |
| 529 | 一時的な過負荷 |

上流仕様は 429 と 529 に指数バックオフを推奨している。

### 2.6 モデル

2026-09-22 時点の安定版は `jev-1.13.0` であり、`jev-latest` と `jev-preview` はその時点では同じモデルを指す。ただしエイリアスは将来移動し得る。

同日時点の上流仕様では、1 request の context は合計 64k tokens、`state` と最長 question の組み合わせは 32k tokens、入力は text/structured JSON のみである。レート上限は動的に変更され得る。JevClient.jl は provider と完全一致する tokenizer を持たないため、トークン上限を不正確に事前判定せず、byte・深度・件数制限と上流 422 を用いる。

JevClient.jl は、再現性と閾値の安定性のため、本番利用ではバージョン付きモデル ID を要求する設計とする。

### 2.7 0.1 で固定する wire 契約

上流文書の記述だけでは Score の回答形式、モデル一覧の形式、request ID の所在が実装時に一意に定まらないため、0.1 は次の契約を採用する。これらと異なる応答は互換性のある未知形式として扱わず、検証エラーにする。

System One の質問は次の形式に固定する。

- `Noul.criteria` は省略するか、`{"true": <content>, "false": <content>}` の object とする。
- `Choice.criteria` は候補 ID をキー、候補説明を値とする object とする。
- `Score.criteria` は順序付きの文字列配列とする。Score のレベルは表示用ラベルであり、0-origin の index が wire 上の値となる。

System One の回答は次の形式に固定する。

```json
{
  "model": "jev-1.13.0",
  "answers": {
    "is_urgent": {"type": "noul", "noul": 0.95},
    "department": {
      "type": "choice",
      "choice": "billing",
      "probabilities": {"billing": 0.8, "technical": 0.1, "sales": 0.1},
      "confidence": 0.8
    },
    "frustration": {
      "type": "score",
      "score": 1.2,
      "legend": ["Calm", "Frustrated", "Very angry"],
      "probabilities": [0.1, 0.6, 0.3],
      "confidence": 0.6
    }
  },
  "usage": {"input_tokens": 296, "output_tokens": 20}
}
```

モデル一覧は `{"models": [{"name": <string>, "description": <string>, "release_date": "YYYY-MM-DD"}]}` に固定する。request ID は response header の大文字小文字を区別しない `x-request-id` の値だけを採用し、body 内の値や別名の header は採用しない。これらの wire 契約は上流仕様の確認日とともに更新する。

---

## 3. 対象範囲

### 3.1 対象

- System One API の同期呼び出し
- モデル一覧取得
- Noul、Choice、Score の型付き構築
- 型付き応答
- ローカル検証
- 安全な認証情報管理
- TLS 通信
- レート制限・過負荷時の限定的再試行
- タイムアウト、サイズ制限、同時実行数制限
- メタデータのみの安全なログ
- モックトランスポートによるテスト

### 3.2 対象外

0.1 では次を実装しない。

- 文章生成
- Agent フレームワーク
- ストリーミング応答
- 画像、音声、動画、ファイルアップロード
- ブラウザ向け API キー保持
- API キーの永続保存
- 任意の `base_url` や TypeSafe 互換ゲートウェイ
- 任意ヘッダー、`extra_body`、生 JSON 質問の送信
- 生の HTTP request/response の公開
- 入力中の個人情報・秘密情報の完全自動検出
- 正確なトークン数の事前計算
- モデル判定の正しさ、完全性、公平性の保証
- 高影響判断を人間・決定論的検証なしに自動確定する機能

任意エンドポイント対応は 0.2 以降の別仕様とし、TypeSafe 用の資格情報を誤って第三者へ送らない資格情報スコープ機構を必須とする。

---

## 4. セキュリティ目標

### 4.1 保護対象

- TypeSafe API キー
- `state` の本文
- `instructions` と `criteria`
- 応答の確率・分類結果
- 利用量・課金に関する情報
- 上流 request ID
- 利用者の業務ロジックと閾値

### 4.2 想定する脅威

1. 未信頼ユーザーが `state` に敵対的な指示を混入する。
2. ログ設定や例外表示から API キー・入力本文が漏れる。
3. リダイレクト先へ `Authorization` が転送される。
4. 環境変数で `base_url` や proxy が差し替えられ、秘密が第三者へ送られる。
5. 巨大な request/response、深い JSON、圧縮爆弾でメモリや CPU が枯渇する。
6. 429/529 や通信障害で無制限再試行し、費用・負荷が増大する。
7. 不正な応答 JSON、NaN、範囲外確率、欠落回答がアプリケーションへ侵入する。
8. モデル出力がファイルパス、SQL、シェル、URL、認可判断として無検証で使われる。
9. 依存パッケージやリリース工程が侵害される。

### 4.3 明示的な非保証

JevClient.jl は、OS 管理者権限、プロセスメモリダンプ、Julia ランタイムや TLS 実装そのものの侵害から秘密を保護できない。また Julia の `String`、HTTP スタック、GC の性質上、API キーや本文の完全なメモリ消去は保証できない。ゼロ化は可能な範囲で行う防御的措置であり、暗号学的保証ではない。

---

## 5. Julia バージョンと依存関係

### 5.1 対応バージョン

- Julia `1.10` 以上
- 初期 CI 対象: Julia 1.10 と最新安定版

### 5.2 直接依存

| パッケージ | 用途 |
|---|---|
| `HTTP.jl` 2.x | HTTPS クライアント、接続プール、ストリーム読み取り |
| `JSON3.jl` | JSON の読み書き |
| `StructTypes.jl` | 内部型の明示的な JSON マッピング |

標準ライブラリとして `Dates`、`Logging`、`Random`、`UUIDs` を用いてよい。

### 5.3 依存関係ポリシー

- 依存は最小限に保つ。
- `deps/build.jl` を置かない。
- ビルド、インストール、precompile 中にネットワークアクセスしない。
- バイナリアーティファクトを同梱しない。
- 一般的な任意オブジェクトの自動シリアライズを行わない。
- 互換範囲を `Project.toml` で明示する。

---

## 6. 公開 API

モジュール名と同名の型は定義できないため、クライアント型は `JevClient.Client` とする。

### 6.1 エクスポート候補

```julia
export Client
export EnvCredential, StaticCredential, CredentialCallback
export PinnedModel, MovingAlias
export QuestionSet, Noul, NoulCriteria, Choice, Score
export SystemOneResponse, NoulAnswer, ChoiceAnswer, ScoreAnswer, Usage
export ModelInfo, ModelList
export system_one, list_models, answer, request_id
export with_client
export RetryPolicy, TimeoutPolicy, ResourceLimits
export JevError
```

具体的な例外型は catch のため公開してよいが、内部 HTTP 型は公開しない。

### 6.2 クライアント構築

```julia
client = Client(
    model = PinnedModel("jev-1.13.0"),
    credential = EnvCredential("TYPESAFE_API_KEY"),
)
```

基本シグネチャ:

```julia
Client(;
    model::AbstractModelRef,
    credential::AbstractCredentialProvider = EnvCredential("TYPESAFE_API_KEY"),
    retry::RetryPolicy = RetryPolicy(),
    timeout::TimeoutPolicy = TimeoutPolicy(),
    limits::ResourceLimits = ResourceLimits(),
    max_inflight::Integer = 8,
)
```

要件:

- `model` は必須キーワードとし、暗黙のモデルを選ばない。
- `PinnedModel` を既定の推奨形とする。
- `jev-latest` や `jev-preview` を使う場合、`MovingAlias("jev-latest")` のように移動エイリアスであることを明示させる。
- `Client` はタスク間で共有可能とする。
- `Base.close(client)` と `Base.isopen(client)` を実装する。`close` / `isopen` を独自 export しない。
- `close(client)` 後の呼び出しは `ClosedClientError`。
- `finalizer` は補助として用いてよいが、利用者は明示的に `close` する。

スコープ付き構築として `with_client` を提供する。

```julia
with_client(; kwargs...) do client
    system_one(client; state, questions)
end
```

- `with_client(f::Function; kwargs...)` は `Client(; kwargs...)` を構築し、`f(client)` の戻り値を返す。
- `f` が正常終了しても例外を投げても、`finally` で `close(client)` を必ず呼ぶ。
- keyword は `Client` の constructor へそのまま転送する。

### 6.3 資格情報

```julia
EnvCredential("TYPESAFE_API_KEY")
StaticCredential(secret)
CredentialCallback(() -> read_secret_from_keychain())
```

- `EnvCredential` は呼び出し時に値を読み、ローテーションを反映できる。
- `StaticCredential` は内部で可能な限り可変バイト列へコピーし、`close` 時にベストエフォートでゼロ化する。
- `Client` は渡された credential provider を所有する。`close(client)` は、所有する `StaticCredential` も close する。同一 provider の複数 client 間共有はサポートしない。
- `CredentialCallback` の返却値は呼び出しごとに検証し、保持時間を最小化する。外部 keychain 自体のライフサイクルは callback 提供者が管理する。
- `CredentialCallback` は `AbstractString` を返す callable とし、`Vector{UInt8}`、`nothing`、その他の値は拒否する。callback が投げた例外は秘密や例外本文を保持しない `CredentialError` に正規化する。
- `EnvCredential` の環境変数名は非空の ASCII 文字列とし、NUL・制御文字を拒否する。値は取得時に API key 検証を行い、未設定と空値を同じ `CredentialError` として扱う。
- credential の `close` は冪等であり、`Client` が所有する provider を閉じる。`CredentialCallback` と `EnvCredential` の close は、外部保存先を破棄せず provider の利用停止だけを行う。
- `show`、`repr`、例外、ログでは常に `<redacted>` と表示する。
- API key を source code や `Project.toml` に直書きしない。長期稼働環境では `CredentialCallback` と OS/key-management service の利用を推奨する。

### 6.4 質問構築

```julia
questions = QuestionSet(
    "is_urgent" => Noul(
        "Does this ticket convey urgency?";
        criteria = NoulCriteria(
            yes = "Explicitly time-sensitive",
            no = "No urgency expressed",
        ),
    ),
    "department" => Choice(
        "Which team should handle this?";
        criteria = [
            "billing"   => "Payments, invoicing, refunds",
            "technical" => "Bugs, outages, integrations",
            "sales"     => "Pricing, upgrades, new accounts",
        ],
    ),
    "frustration" => Score(
        "How frustrated is the customer?";
        criteria = ["Calm", "Frustrated", "Very angry"],
    ),
)
```

`NoulCriteria` の Julia 側フィールドは `yes` と `no` とし、wire 上ではそれぞれ `"true"` と `"false"` に変換する。

`NoulCriteria` の `yes` と `no` は省略可能だが、少なくとも一方を指定する。指定値は `nothing` を除く許可 JSON 値とする。`Choice` の候補 ID は `AbstractString` に限定し、Symbol からの暗黙変換は行わない。`Choice` の候補説明は `nothing` または許可 JSON 値とする。`Score` の criteria は `AbstractString` のベクターに限定し、空文字列を拒否する。

### 6.5 評価

```julia
response = system_one(
    client;
    state = (document = "I was charged twice. Please fix this ASAP.",),
    questions,
)
```

基本シグネチャ:

```julia
system_one(
    client::Client;
    state,
    questions::QuestionSet,
    timeout::Union{Nothing,TimeoutPolicy} = nothing,
    retry::Union{Nothing,RetryPolicy} = nothing,
)::SystemOneResponse
```

- 呼び出し単位で timeout/retry を狭めることは可能。
- 呼び出し単位で安全制限を緩めることは原則禁止。緩和が必要なら新しい `Client` を明示的に作る。
- 任意ヘッダー、任意 body フィールド、生 JSON は受け付けない。

### 6.6 応答アクセス

```julia
urgent = answer(response, "is_urgent")::NoulAnswer
department = answer(response, "department")::ChoiceAnswer
frustration = answer(response, "frustration")::ScoreAnswer

urgent.noul
department.choice
department.probabilities
department.confidence
frustration.score
response.usage.input_tokens
response.model
request_id(response)
```

`response["is_urgent"]` を `answer` の別名として実装してよい。

`show(response)` はモデル名、回答数、usage、request ID の有無のみを表示し、回答内容や本文を既定では表示しない。

### 6.7 モデル一覧

```julia
models = list_models(client)
```

```julia
struct ModelInfo
    name::String
    description::String
    release_date::Date
end

struct ModelList
    models::Vector{ModelInfo}
end
```

応答の主要型は概念的に次のフィールドを持つ。

```julia
struct Usage
    input_tokens::Int
    output_tokens::Int
end

struct SystemOneResponse
    model::String
    answers       # 質問 ID の順序を保持する内部 map
    usage::Usage
    request_id::Union{Nothing,String}
end
```

`answers` の具体的な格納型は public contract に含めず、`answer` と `getindex` を安定 API とする。

日付が仕様に合わない場合は黙って文字列へ退避せず、`ResponseValidationError` とする。ただし上流が ISO 日付以外へ変更する可能性を考慮し、内部 raw 文字列を例外に含めない。

---

## 7. 入力データ仕様

### 7.1 許可する JSON 互換値

明示的に構築された次の値のみを再帰的に受け入れる。

- `nothing`
- `Bool`
- `AbstractString`
- JSON で安全に表現できる範囲の `Integer`
- 有限な `AbstractFloat`
- `NamedTuple`
- キーが `String` または `Symbol` の辞書
- `Tuple`
- `AbstractVector`

以下は拒否する。

- `NaN`、`Inf`、`-Inf`
- `BigInt` など上限の定まらない数値
- 任意の custom struct
- 関数、Task、IO、ポインタ、配列ビューなど
- バイト列を暗黙に文字列化する処理
- 循環参照
- UTF-8 として不正な文字列

`Date`、`DateTime`、`UUID`、enum などは利用者が意図した文字列表現へ明示変換する。

### 7.2 自動 struct シリアライズの禁止

`StructTypes.jl` の登録済み型であっても、`state` に渡された任意 struct を自動的に展開してはならない。これは access token、password、内部 ID などの意図しない送信を防ぐためである。

将来 custom struct 対応を追加する場合、明示的な `JevClient.to_state(x)` メソッド実装を要求し、汎用 reflection を使わない。

### 7.3 キー正規化

- JSON オブジェクトの `Symbol` キーは文字列へ変換する。
- `:foo` と `"foo"` が同時に存在する場合は重複として拒否する。
- NUL、ASCII 制御文字を含むキーは拒否する。
- オブジェクトの最大深度を制限する。
- 順序が利用結果へ影響し得るため、`QuestionSet` と Choice criteria は挿入順を保持する。

### 7.4 `state`

- トップレベルは文字列、オブジェクト、配列のみ。
- `nothing`、数値、真偽値だけをトップレベルに置くことは拒否する。
- 空文字列、空オブジェクト、空配列は上流契約に反しない限り受理する。ただし有用な判定材料を含まない可能性をドキュメントで説明する。
- 入力に必要以上の文脈を含めないことをドキュメントで推奨する。

### 7.5 QuestionSet と質問 ID

- QuestionSet は 1〜1024 問。
- 1〜128 Unicode scalar values。
- NUL、制御文字、先頭・末尾空白を禁止。
- 重複を禁止。
- ログには既定で質問 ID 自体を出さず、件数と種類の集計だけを出す。

### 7.6 Instructions

- 必須かつ非空。
- 文字列、オブジェクト、配列を許可。
- 最大深度・最大バイト数を適用。
- 上流 Python SDK の柔軟な型よりも、raw API の必須契約を優先する。

### 7.7 Noul

- `instructions` 必須。
- `criteria` は省略可能。
- `criteria` を与える場合、`yes` または `no` の少なくとも一方を指定。
- wire 上のキーは厳密に `true` と `false`。

### 7.8 Choice

- 2〜255 候補。
- 候補 ID は非空かつ一意。
- 候補 ID に NUL・制御文字を禁止。
- 候補説明は文字列、オブジェクト、配列、`nothing`。
- 0 または 1 候補は意味的に無効としてローカル拒否する。

### 7.9 Score

- 2〜10 レベル。
- レベル順を保持する。
- 各レベルは空でない文字列。
- 空のレベル記述を拒否する。

### 7.10 モデル ID

- 非空 ASCII。
- NUL、制御文字、空白を禁止。
- 最大 128 bytes。
- `PinnedModel` と `MovingAlias` を型で区別する。
- `PinnedModel` の文字列形式を過度にハードコードせず、既知の `latest`、`preview` エイリアスを拒否する程度に留める。

---

## 8. ネットワーク仕様

### 8.1 固定オリジン

0.1 の送信先は厳密に次へ固定する。

```text
scheme = https
host   = api.typesafe.ai
port   = 443
```

- `TYPESAFE_BASE_URL` を読まない。
- URL を public constructor から受け取らない。
- userinfo、query、fragment を含む URL を生成しない。
- System One は `/v1/systemone`、モデル一覧は `/v1/models` のみ。

この制約により、設定注入、SSRF、資格情報の誤送信を減らす。

### 8.2 TLS

- 証明書検証を必須とする。
- hostname verification を必須とする。
- `verify=false` に相当する public option を提供しない。
- TLS エラーを再試行しない。
- 証明書ピンニングは、上流が安定したピン運用を公式提供しない限り実装しない。
- private CA は v0.1 では個別指定せず、OS/Julia の信頼ストア管理へ委ねる。

### 8.3 リダイレクト

- HTTP リダイレクトを自動追跡しない。
- 3xx を `RedirectError` とする。
- `Authorization` を別オリジンへ転送しない。
- 同一オリジンのリダイレクトも追跡せず、上流仕様変更として明示的に扱う。

### 8.4 Proxy

- 既定は `NoProxy()`。
- `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` を暗黙に参照しない。
- 明示的な `EnvironmentProxy()` または固定 proxy 対応は、監査可能な別機能として後から追加してよい。
- proxy 対応時も TLS 検証を無効化してはならない。

### 8.5 HTTP ヘッダー

送信するヘッダーは原則次に限定する。

```http
Authorization: Bearer <redacted>
Content-Type: application/json; charset=utf-8
Accept: application/json
Accept-Encoding: identity
User-Agent: JevClient.jl/<version> Julia/<version>
```

- `Authorization`、`Content-Type`、`Accept`、`Host` の上書きを許可しない。
- cookie を送信・保存しない。
- request body を圧縮しない。
- 自動解凍を無効にし、圧縮応答は既定で拒否する。

### 8.6 HTTP.jl の利用方法

- `POST /v1/systemone` と `GET /v1/models` は HTTP 200 のみを成功として扱う。
- HTTP.jl 自体の自動 retry と redirect を無効にする。
- 再試行は JevClient.jl の単一の状態機械で管理する。
- response はサイズ上限付きストリーミングで読み取る。
- `Content-Length` が上限超過なら本文を読む前に中断する。
- chunked response も累積バイト数で中断する。
- underlying transport の request/response オブジェクトを利用者へ公開しない。

### 8.7 1 回の呼び出し処理順序

秘密の保持時間と不要な通信を減らすため、処理順序を固定する。

1. client が open であることを確認する。
2. `state`、questions、model、policy をローカル検証する。
3. JSON content を安全な内部表現へ正規化し、循環・深度・重複キーを検査する。
4. semaphore を取得する。待機時間も total deadline に含める。
5. 各 attempt の直前に request body を serialize し、byte 上限を検査する。
6. 各 attempt の直前に credential provider から API key を取得・検証する。
7. fixed endpoint と固定 header で request を送る。
8. response を上限付きで読み、status・content type・JSON・cross-field を検証する。
9. request body、response raw bytes、error raw bytes、credential の一時バッファを `finally` で可能な範囲でゼロ化する。
10. semaphore を必ず解放する。

backoff 待機中に API key や serialized body を保持しない。retry の各 attempt で body と credential を再構築する。

---

## 9. 既定の安全制限

```julia
ResourceLimits(
    max_request_bytes       = 1 * 1024 * 1024,
    max_response_bytes      = 8 * 1024 * 1024,
    max_error_body_bytes    = 64 * 1024,
    max_json_depth          = 32,
    max_string_bytes        = 1 * 1024 * 1024,
    max_container_items     = 100_000,
    max_questions           = 1024,
    max_question_id_chars   = 128,
    max_model_id_bytes      = 128,
)
```

`max_request_bytes` は UTF-8 JSON にシリアライズした request 全体に適用し、`max_string_bytes` は各文字列の UTF-8 byte 数に適用し、`max_container_items` は各 object/array の要素数に適用する。`max_json_depth` は state、instructions、criteria、response の全てに適用する。これらをシリアライズ前にも検査し、巨大な入力を JSON 化してからしか拒否できない状態を作らない。

```julia
TimeoutPolicy(
    connect = 5.0,
    first_byte = 15.0,
    attempt = 30.0,
    total = 60.0,
)
```

```julia
RetryPolicy(
    max_retries = 2,
    initial_delay = 0.5,
    max_delay = 15.0,
    total_budget = 60.0,
)
```

- byte 上限は上流トークン上限の代替ではない。
- TypeSafe のレート上限値は変動し得るため、クライアントへ固定値として埋め込まない。
- `max_inflight` の既定値は 8。
- semaphore 待機も total timeout に含める。
- `RetryPolicy` の public constructor は status 集合や ambiguous I/O retry を変更させない。0.1 の retry 対象は 429/529 に固定する。
- `max_retries` は 0〜5、`total_budget` は最大 300 秒に制限する。
- `max_retries` は初回送信後の追加 attempt 数を表す。retry 判定は HTTP status 429/529 と response metadata の解析が完了した後だけ行い、ローカル検証、serialize、credential 取得、TLS、redirect、response parse の失敗には適用しない。backoff 待機前に attempt の body と credential の一時バッファを破棄する。

---

## 10. 再試行仕様

### 10.1 既定で再試行するもの

- HTTP 429
- HTTP 529

### 10.2 既定で再試行しないもの

- 400、401、403、404、409、422 などの通常の 4xx
- 500、502、503、504 など、上流仕様で安全な再試行が明記されていない status
- DNS エラー
- TLS/証明書エラー
- redirect
- JSON parse/response validation エラー
- read timeout、connection reset など、request body が送信済みか判定できない I/O エラー

曖昧な I/O 再試行は同一評価の重複実行・重複課金につながり得るため、0.1 では public API から有効化できない。将来追加する場合は、通常の `RetryPolicy` と分離した明示的な unsafe API とする。

### 10.3 バックオフ

- exponential backoff と full jitter を使用する。
- `Retry-After` を優先する。
- `retry-after-ms` が返された場合も安全に解釈してよい。
- 負値、非数、過大値は拒否する。
- server 指定待機時間が total budget を超える場合、指定より早く再試行せず `RetryBudgetExceededError` とする。
- `Retry-After` の HTTP-date は wall clock、内部 deadline は monotonic clock で扱う。

### 10.4 テスト容易性

retry 実装には内部的に次を注入可能とする。

- monotonic clock
- wall clock
- RNG
- sleeper

これらは public stable API にする必要はなく、`MockTransport` と合わせて決定論的テストへ用いる。

---

## 11. 資格情報セキュリティ

### 11.1 API キー検証

公式 SDK と同等以上に次を行う。

1. 先頭・末尾の ASCII whitespace を除去する。
2. 空文字列を拒否する。
3. 内部 whitespace を拒否する。
4. 制御文字を拒否する。
5. 非 ASCII を拒否する。
6. 4 KiB を超える値を拒否する。
7. 特定 prefix や最小長を仮定しない。

エラーにはキーの一部、長さ、prefix、hash を含めない。

### 11.2 保持

- 認証ヘッダーは送信直前に構築する。
- request 完了後、API キーと request body の可変バッファを可能な範囲でゼロ化する。
- immutable `String` や HTTP/TLS 内部コピーの完全消去は保証しない。
- API キーを global constant、Preferences、設定ファイル、precompile cache に書かない。
- API キーを query parameter に入れない。

### 11.3 表示

次の全てでキーを伏せる。

- `show(client)`
- `show(credential)`
- `repr`
- 例外メッセージ
- ログ
- debug dump
- テスト失敗出力

### 11.4 compromise 対応

README と `SECURITY.md` に次を記載する。

- 漏えいが疑われる場合は TypeSafe 側でキーを即時失効・再発行する。
- git 履歴、CI log、artifact から削除する。
- アプリケーションと監視ログを調査する。
- JevClient.jl はキーの失効 API を提供しない。

---

## 12. ログと可観測性

### 12.1 禁止されるログ

どの log level でも次を出力してはならない。

- API キー
- `Authorization` header
- request/response header の生 dump
- `state`
- `instructions`
- `criteria`
- request body
- response body
- remote validation body の生 dump
- Choice の option ID や質問 ID の一覧

公式 Python SDK は debug level で request/response body を記録し得るが、JevClient.jl は意図的にこれを実装しない。

### 12.2 許可されるログ

メタデータのみを構造化ログとして出してよい。

- operation 名
- JevClient.jl version
- requested model / returned versioned model
- question 数と Noul/Choice/Score の件数
- request/response byte 数
- HTTP status
- latency
- retry 回数と理由
- upstream request ID
- token usage
- endpoint origin は固定値として必要時のみ

### 12.3 underlying logger の抑制

ネットワーク呼び出し中は HTTP.jl の wire-level debug が本文やヘッダーを出さないよう、タスクローカルな抑制 logger または専用 redacting logger を使う。JevClient.jl 自身の安全なメタデータログは、その外側で発行する。

利用者が Julia 全体の packet/wire trace、TLS intercept、外部 HTTP debug を有効化した場合までは保証できないため、運用文書で本番禁止を明示する。

### 12.4 例外

例外は次のみを保持する。

- 安全な分類メッセージ
- status
- request ID
- retry-after
- field path
- attempt count

raw body、request、response、API key、入力値を保持しない。

---

## 13. 応答検証

サーバー応答は未信頼入力として扱う。

### 13.1 共通

- `Content-Type` は `application/json` または明示的に許可した `application/*+json`。
- UTF-8 として解析できること。
- byte 上限確認後、JSON object を materialize する前に深度と duplicate key を検査する。
- top-level が JSON object。
- `model` が非空文字列。
- `usage.input_tokens` と `usage.output_tokens` が 0 以上の整数。
- `answers` のキー集合が送信した質問 ID と厳密に一致。
- 各回答 `type` が対応する質問型と一致。
- unknown top-level fields は forward compatibility のため無視してよいが、保存・公開しない。
- unknown answer type は黙って skip せず `ResponseValidationError`。

### 13.2 NoulAnswer

```julia
struct NoulAnswer <: AbstractAnswer
    noul::Float64
end
```

- finite
- `0.0 <= noul <= 1.0`

### 13.3 ChoiceAnswer

```julia
struct ChoiceAnswer <: AbstractAnswer
    choice::String
    probabilities::Vector{Pair{String,Float64}}
    confidence::Float64
end
```

検証:

- probability のキー集合が送信 criteria の候補集合と一致。
- 全 probability が finite かつ `[0,1]`。
- 合計が `1 ± 1e-4`。
- `choice` が既知の候補。
- `choice` の probability が最大値と `1e-6` 以内。tie は許可。
- confidence が finite かつ `[0,1]`。

### 13.4 ScoreAnswer

```julia
struct ScoreAnswer <: AbstractAnswer
    score::Float64
    legend::Vector{String}
    probabilities::Vector{Float64}
    confidence::Float64
end
```

検証:

- level index が `0:(n-1)` に対応。
- legend と probabilities の長さが送信 criteria と一致。
- probability が finite かつ `[0,1]`。
- 合計が `1 ± 1e-4`。
- `score` が `[0,n-1]`。
- `score` と `sum(i * p[i+1])` が `1e-4` 以内。
- confidence が finite かつ `[0,1]`。

上流の丸め方が変更され許容差が不足する場合、まず実測と公式仕様を確認し、黙って大きく緩めない。

### 13.5 raw response の禁止

0.1 の `SystemOneResponse` は raw HTTP response/body を保持しない。forward compatibility を理由に raw body へアクセスする escape hatch も stable API には設けない。

新しい回答型が追加された場合、JevClient.jl を更新し、明示的な型と検証を追加する。

---

## 14. モデル出力の安全な利用

### 14.1 出力は未信頼データ

Jev の結果は、確率付き判定であり、認可・命令・証拠ではない。次へ直接使用してはならない。

- shell command
- SQL fragment
- file path
- URL
- module/type/function 名の動的解決
- 権限付与・拒否
- 資金移動
- データ削除
- 医療、安全、雇用、信用等の高影響判断

Choice の出力は、送信時にアプリケーションが定義した allowlist の ID と厳密一致させ、ID から決定論的な関数へマッピングする。

```julia
handlers = Dict(
    "billing" => handle_billing,
    "technical" => handle_technical,
    "sales" => handle_sales,
)

result = answer(response, "department")::ChoiceAnswer
handler = get(handlers, result.choice, nothing)
handler === nothing && throw(UnexpectedChoiceError())
handler(ticket)
```

文字列補間で関数名やコードへ変換しない。

### 14.2 prompt injection / adversarial state

Jev 1.13 の公式説明では、`state` を敵対的入力として自動的に扱うわけではなく、入力内の指示・誘導で結果が動き得る。

JevClient.jl は schema を守らせることはできても、意味的な prompt injection を除去できない。したがって利用者へ次を要求する。

- 質問を狭く原子的にする。
- criteria に境界事例を明記する。
- 未信頼テキストとポリシーを構造上分ける。
- 不要な context を送らない。
- adversarial corpus を含む評価セットを作る。
- confidence だけで安全性を判定しない。
- 高影響アクションは決定論的ルールまたは人間レビューで gate する。

### 14.3 計算はコードで行う

数値計算、カウント、日時比較、整合条件、閾値判定は Julia コードで行う。モデルに計算させない。

### 14.4 モデル固定

- 本番は `PinnedModel("jev-1.13.0")` のような versioned ID を使う。
- 応答の `model` を必ず保存できるようにする。
- 新モデルへの切り替えは、評価データ上で確率・confidence・閾値を再調整してから行う。
- `MovingAlias` は実験・開発用途とし、client 作成後最初の利用時に warning を 1 回出す。warning に入力内容は含めない。
- 英語以外、特に CJK を含む workload は、英語 workload の閾値や精度を流用せず、その言語の実データで別に評価する。

---

## 15. データ保護とプライバシー

### 15.1 provider retention を仮定しない

TypeSafe は入力をモデル学習・fine-tuning に使用しないと説明している一方、通常サービスの個人データはサービス提供等に合理的に必要な期間保持し得る。また ZDR は enterprise 向けオプションとして案内されている。2026-09-22 時点の Privacy Policy はサービスが米国でホストされるとも説明している。

したがって JevClient.jl は次を行う。

- 通常 API を ZDR と表示しない。
- `zdr=true` のようなクライアントだけで保証できない option を提供しない。
- ZDR 契約の有無は利用者と provider の契約事項として扱う。
- README で privacy policy、DPA、データ所在を確認するよう促す。
- 機微情報は送信前に最小化・仮名化・redact するよう推奨する。

### 15.2 データ最小化

- 必要なフィールドだけを `state` に含める。
- access token、password、private key、session cookie を送らない。
- custom struct の自動展開を禁止する。
- ローカルでフィルタ・計算できるものは送らない。
- response は state を保持せず、回答と usage だけを保持する。

### 15.3 自動 PII 検出を安全機能として宣伝しない

正規表現やヒューリスティックによる PII/secret detection は誤検知・見逃しがあるため、0.1 では完全防御として提供しない。将来追加する場合も defense-in-depth と明記する。

---

## 16. 例外階層

概念的な subtype 階層を次とする。

```text
JevError
├── ConfigurationError
│   ├── CredentialError
│   ├── EndpointPolicyError
│   ├── LocalValidationError
│   └── ClosedClientError
├── TransportError
│   ├── ConnectError
│   ├── TimeoutError
│   ├── TLSVerificationError
│   ├── RedirectError
│   └── ResponseTooLargeError
├── ProtocolError
│   ├── UnexpectedContentTypeError
│   ├── MalformedJSONError
│   └── ResponseValidationError
├── APIError
│   ├── AuthenticationError       # 401
│   ├── PermissionDeniedError     # 403
│   ├── NotFoundError             # 404
│   ├── RemoteValidationError     # 422
│   ├── RateLimitError            # 429
│   ├── OverloadedError           # 529
│   ├── ServerError               # other 5xx
│   └── UnexpectedStatusError
├── RetryBudgetExceededError
└── ConcurrencyLimitError
```

各 concrete exception は、必要に応じて次の安全な context を保持する。

```julia
struct ErrorContext
    message::String
    status::Union{Nothing,Int}
    request_id::Union{Nothing,String}
    retry_after::Union{Nothing,Float64}
    field_path::Union{Nothing,Vector{String}}
    attempt_count::Int
end
```

- concrete exception は `context::ErrorContext` または、その用途に必要な安全な部分集合を持つ。
- `Base.showerror` は安全な context だけを表示する。
- remote body の生データを保存しない。
- 422 の詳細は field path、error code、安全な短い message だけへ正規化する。
- remote message に入力値が含まれる可能性があるため、そのまま表示しない。
- 未知 status は本文なしで `UnexpectedStatusError`。

---

## 17. 並行実行とライフサイクル

- `Client` は複数 Task から安全に共有可能。
- connection pool を client 単位で保持する。
- `max_inflight` semaphore で同時呼び出しを制限する。
- mutable counters は lock または atomic で保護する。
- credential provider が task-safe であることを interface 契約に含める。
- `close` は新規リクエストを拒否し、既存リクエストの完了または cancel を待つ方針を明文化する。
- 初期版では `close` は新規受付を止め、進行中リクエストを中断せず完了させる。
- `system_one` は同期関数とし、並行化は Julia の `@async`、`Threads.@spawn` を利用できる。
- 別の async client 型は作らない。

---

## 18. 内部構成

```text
src/
  JevClient.jl
  client.jl
  config.jl
  credentials.jl
  models.jl
  content.jl
  questions.jl
  responses.jl
  validation.jl
  serialization.jl
  endpoint_policy.jl
  transport.jl
  retry.jl
  errors.jl
  logging.jl
  limits.jl
```

責務:

- `content.jl`: 許可 JSON 値の正規化と循環・深度検査
- `questions.jl`: 質問型と constructor validation
- `serialization.jl`: wire JSON への唯一の変換経路
- `transport.jl`: HTTP.jl 封装、TLS、redirect、proxy、size cap
- `retry.jl`: retry state machine
- `responses.jl`: strict parse と cross-field validation
- `logging.jl`: metadata-only events と underlying logger 抑制
- `credentials.jl`: provider、redacted display、best-effort zeroization

内部 HTTP adapter interface:

```julia
abstract type AbstractTransport end

request(
    transport::AbstractTransport,
    method::String,
    path::String,
    headers,
    body::Vector{UInt8},
    deadline,
)::TransportResponse
```

`MockTransport` は `test/` 内または非 exported internal module に置く。

---

## 19. テスト仕様

### 19.1 Unit tests

- Noul/Choice/Score の valid/invalid constructor
- Symbol/String key collision
- NaN/Inf/BigInt 拒否
- 深度、循環参照、サイズ制限
- API key trim と不正文字拒否
- model alias/pin の区別
- JSON golden tests
- request header の固定
- response validation
- error mapping
- retry schedule
- timeout/deadline
- `close` 後の拒否

### 19.2 セキュリティ回帰テスト

sentinel secret を使い、次へ一切現れないことを機械的に確認する。

- stdout/stderr
- Julia logs
- `show(client)` / `repr(client)`
- `showerror`
- thrown exception fields
- test failure message
- retry logs

追加ケース:

1. 302 で attacker host へ redirect しても追跡しない。
2. 同一 host の 307/308 でも追跡しない。
3. `HTTPS_PROXY` を設定しても既定では使わない。
4. TLS failure を retry しない。
5. 429/529 以外を retry しない。
6. read timeout を既定では retry しない。
7. oversized `Content-Length` を本文読取前に拒否。
8. chunked oversized body を上限で停止。
9. gzip response を拒否。
10. malformed UTF-8、duplicate JSON keys、深すぎる JSON を拒否。
11. answer key の欠落・追加を拒否。
12. probability 合計不正、範囲外、NaN、選択不整合を拒否。
13. unknown answer type を skip しない。
14. remote 422 body 内の sentinel secret を例外へ残さない。

JSON3 の parser が duplicate key を検出できない場合、応答解析前に duplicate-key-aware scanner を追加するか、同じキーを後勝ちで受理しない parser 構成へ切り替える。これは response confusion を防ぐ必須要件とする。

### 19.3 Property/fuzz tests

- ランダムな JSON tree の normalize/serialize/parse
- 境界数値
- Unicode、combining character、NUL、制御文字
- malformed JSON byte stream
- probability vector
- retry header parser

fuzz input に秘密情報を使わない。

### 19.4 Concurrency tests

- `max_inflight` を超えない。
- semaphore 待機 timeout。
- concurrent `close`。
- credential rotation。
- retry 中 close。
- connection pool race。

### 19.5 Live tests

- 既定 CI では実行しない。
- manual workflow または protected environment のみ。
- fork PR へ secret を渡さない。
- request body を CI log に出さない。
- 小さい固定 fixture と最小 token 数を使う。
- live test failure 時も response body を artifact 化しない。

---

## 20. CI・リリース・供給網

### 20.1 必須 CI

- Julia 1.10 と最新安定版
- unit/security tests
- `Aqua.jl` による package quality checks
- 可能な範囲で `JET.jl`
- dependency audit
- secret scan
- format/lint
- docs build（ネットワーク不要）

### 20.2 リリース

- SemVer を採用する。
- signed git tag を推奨する。
- GitHub release と General registry tag の commit を一致させる。
- release workflow の権限を最小化する。
- branch protection、必須レビュー、2FA を有効化する。
- GitHub private vulnerability reporting を有効化する。
- `SECURITY.md` に対応対象 version と報告手順を記載する。
- `Manifest.toml` はアプリでは固定するが、library repository への固定同梱は Julia package 慣例に従う。

### 20.3 名称確認

公開前に次を確認する。

- General registry に同名 package がないこと。
- GitHub 上の名称衝突。
- TypeSafe AI から公式 SDK と誤認されない表記。
- 必要なら名称を `TypeSafeAI.jl` 等へ変更するのではなく、先に商標・公式性の誤認リスクを検討する。

---

## 21. ドキュメント要件

README に最低限次を含める。

1. 非公式 SDK であること。
2. API キーの設定方法。
3. pinned model を使う production example。
4. Noul、Choice、Score の例。
5. body をログしない設計。
6. 通常 API を ZDR と仮定しない注意。
7. prompt injection と adversarial state の制約。
8. model output を認可やコードとして直接使わない例。
9. retry が 429/529 に限定される理由。
10. TypeSafe 公式 docs と legal docs の確認日。

`docs/src/security.md` を独立して作り、threat model、credential、logging、privacy、model safety、incident response を集約する。


---

## 22. セキュリティ要求トレーサビリティ

| ID | 要求 | 検証方法 |
|---|---|---|
| SEC-CRED-001 | API key を本文・ログ・例外・表示へ出さない | sentinel secret test |
| SEC-CRED-002 | key format を送信前に検証する | unit/property test |
| SEC-NET-001 | 宛先を `api.typesafe.ai:443` に固定する | mock DNS/redirect test |
| SEC-NET-002 | TLS/hostname verification を無効化できない | API review、TLS failure test |
| SEC-NET-003 | redirect を追跡しない | 301/302/307/308 test |
| SEC-NET-004 | proxy 環境変数を暗黙利用しない | environment injection test |
| SEC-DATA-001 | 任意 struct を reflection で送信しない | negative serialization test |
| SEC-DATA-002 | request/response/error body のサイズを制限する | oversized stream test |
| SEC-DATA-003 | request/response body をログしない | all-level log capture test |
| SEC-RESP-001 | answer key/type/value/probability を厳格検証する | malformed response matrix |
| SEC-RESP-002 | duplicate JSON keys と unknown answer type を拒否する | parser regression test |
| SEC-RETRY-001 | 既定 retry を 429/529 に限定する | deterministic retry test |
| SEC-RETRY-002 | ambiguous I/O を既定 retry しない | post-send failure test |
| SEC-MODEL-001 | moving alias を明示 opt-in にする | constructor test |
| SEC-MODEL-002 | model output を allowlist 外の動作へ接続しない例を示す | docs review |
| SEC-SUPPLY-001 | build/precompile 中にネットワークアクセスしない | clean sandbox CI |
| SEC-SUPPLY-002 | release secret を fork PR に渡さない | workflow permissions review |

各 pull request は、影響する要求 ID を description または changelog に記載することを推奨する。

---

## 23. MVP 実装順序

### Phase 1: 型と検証

- Question/Answer 型
- JSON content normalizer
- local validation
- golden serialization

### Phase 2: 安全な transport

- fixed endpoint
- TLS verification
- redirect off
- proxy off
- resource limits
- credential providers

### Phase 3: 応答とエラー

- strict parser
- probability consistency
- safe exception hierarchy
- request ID

### Phase 4: retry と concurrency

- 429/529 backoff
- Retry-After
- total budget
- max_inflight
- close lifecycle

### Phase 5: セキュリティ hardening

- log leak tests
- response/body size tests
- duplicate key handling
- fuzz/property tests
- manual live tests

### Phase 6: 公開

- README/docs
- SECURITY.md
- CI/release hardening
- package name check
- General registry registration

---

## 24. 受入基準

0.1.0 を公開可能とするための必須条件:

- [ ] API キーが `show`、ログ、例外、テスト出力へ現れない。
- [ ] request/response body をどの log level でも記録しない。
- [ ] API キーを `api.typesafe.ai:443` 以外へ送れない。
- [ ] redirect を追跡しない。
- [ ] TLS 検証を無効化できない。
- [ ] proxy 環境変数を暗黙利用しない。
- [ ] request/response/error body にサイズ上限がある。
- [ ] 429/529 だけを既定再試行する。
- [ ] ambiguous I/O failure を既定再試行しない。
- [ ] 全回答について type、キー集合、値域、確率合計を検証する。
- [ ] unknown answer type を黙って捨てない。
- [ ] raw HTTP response を公開・保持しない。
- [ ] 任意 struct を自動シリアライズしない。
- [ ] pinned model を使う本番例がある。
- [ ] adversarial input、高影響用途、privacy/ZDR の注意が文書化されている。
- [ ] secret を持たない unit/security CI が全て通る。
- [ ] live test secret が fork PR に露出しない。
- [ ] SECURITY.md と脆弱性報告経路がある。

---

## 25. 初期実装例

```julia
using JevClient

function route_ticket(ticket)
    client = Client(
        model = PinnedModel("jev-1.13.0"),
        credential = EnvCredential("TYPESAFE_API_KEY"),
        retry = RetryPolicy(max_retries = 2),
        limits = ResourceLimits(max_request_bytes = 1_048_576),
    )

    questions = QuestionSet(
        "is_urgent" => Noul(
            "Does this ticket convey urgency?";
            criteria = NoulCriteria(
                yes = "Explicitly time-sensitive",
                no = "No urgency expressed",
            ),
        ),
        "department" => Choice(
            "Which team should handle this?";
            criteria = [
                "billing" => "Payments, invoicing, refunds",
                "technical" => "Bugs, outages, integrations",
                "sales" => "Pricing, upgrades, new accounts",
            ],
        ),
    )

    try
        response = system_one(
            client;
            state = (document = ticket.text,),
            questions,
        )

        urgency = answer(response, "is_urgent")::NoulAnswer
        route = answer(response, "department")::ChoiceAnswer

        # モデル結果を直接コードとして実行しない。
        # 送信前に定義した allowlist から決定論的に選ぶ。
        handlers = Dict(
            "billing" => handle_billing,
            "technical" => handle_technical,
            "sales" => handle_sales,
        )

        route.confidence < 0.80 && return send_to_human_review(ticket)
        handler = get(handlers, route.choice, nothing)
        handler === nothing && return send_to_human_review(ticket)
        return handler(ticket; urgent_probability = urgency.noul)
    finally
        close(client)
    end
end
```

閾値 `0.80` は例示に過ぎず、利用者の評価データと固定モデル version に基づき決定する。

---

## 26. 意図的に公式 SDK より厳しくする点

| 項目 | JevClient.jl 0.1 |
|---|---|
| debug body logging | 常に禁止 |
| 任意 base URL | stable API では禁止 |
| base URL 環境変数 | 読まない |
| proxy 環境変数 | 既定で読まない |
| redirect | 追跡しない |
| raw HTTP response | 公開しない |
| extra body / raw question | 公開しない |
| unknown answer type | warning/skip ではなく失敗 |
| arbitrary struct serialization | 禁止 |
| ambiguous network retry | 既定で禁止 |
| production model | version pin を本番仕様として要求。moving alias は明示 opt-in |

これらは利便性より API キー、入力データ、再現性、課金制御を優先した設計判断である。

---

## 27. 参照した上流文書

2026-09-22 に確認した。

- TypeSafe API reference: `https://docs.typesafe.ai/api`
- TypeSafe Models: `https://docs.typesafe.ai/models`
- Jev 1.13 jaggedness: `https://docs.typesafe.ai/model-jaggedness/jev-1.13`
- TypeSafe Python SDK usage: `https://docs.typesafe.ai/sdk/python/usage`
- TypeSafe Legal: `https://docs.typesafe.ai/legal`
- TypeSafe Privacy Policy: `https://typesafe.ai/legal/privacy-policy`
- TypeSafe Data Processing Addendum: `https://typesafe.ai/legal/data-processing`
- TypeSafe Master Customer Agreement: `https://typesafe.ai/legal/mca`
- HTTP.jl repository/documentation: `https://github.com/JuliaWeb/HTTP.jl`

上流 API、モデル ID、rate limit、価格、legal policy は変更され得る。JevClient.jl の各 release では確認日と追従状況を changelog に記録する。

---

## 28. 実装前レビューで追加した規範

### 28.1 許可 JSON 値の共通型

7 章の「許可 JSON 値」は内部的に次の再帰型として扱う。

```text
JSONValue = nothing | Bool | String | Int64 | Float64
          | Vector{JSONValue} | OrderedMap{String,JSONValue}
```

入力が `Integer` の場合は `Int64` へ変換できる値だけを受理し、範囲外は拒否する。`Float32` などの有限浮動小数点値は `Float64` へ変換してから検証する。辞書のキーは全て UTF-8 の `String` へ正規化し、順序を持つ内部 map を使う。`JSONValue` の alias は stable public API とせず、任意 struct の受け入れを意味しない。`AbstractVector` は受理するが、`SubArray` などの array view は参照元の予期しない保持を避けるため拒否する。

### 28.2 構築 API の曖昧さを解消する

- `QuestionSet` の constructor は `Pair{<:AbstractString,<:AbstractQuestion}...` のみを受け付ける。空の QuestionSet、重複 ID、非文字列 ID は拒否する。
- `Choice` の criteria は `Pair{<:AbstractString,<:Any}` の順序付き collection のみを受け付け、辞書を渡した場合も iteration order をそのまま信頼せず、重複を検査した結果を内部順序へコピーする。
- `NoulCriteria(; yes=nothing, no=nothing)` における `nothing` は「未指定」を表し、wire 上の criteria 値としての `null` は生成しない。
- `answer(response, id)` と `response[id]` は、未知 ID なら `LocalValidationError` を投げる。型の取り違えは利用者が明示的に検査できるよう回答の concrete type を返す。

### 28.3 policy とライフサイクルの検証

`TimeoutPolicy` の値は finite かつ 0 より大きく、`connect <= attempt <= total`、`first_byte <= attempt` を満たす必要がある。`RetryPolicy` の delay と budget も finite かつ 0 以上とし、`initial_delay <= max_delay <= total_budget` を要求する。`ResourceLimits` の全ての byte、depth、件数は正の整数とする。これらを満たさない policy は request 開始前に `LocalValidationError` とする。

`Client` の close は一度でも呼ばれた時点で新規受付を停止する。進行中の request はその request の total deadline まで完了を許し、完了後に semaphore を解放する。`close` と request の競合で新規 request が一部だけ送信される状態を作らない。

### 28.4 duplicate key scanner の適用範囲

duplicate-key 検査は response の JSON object 全てに再帰的に適用する。文字列中の文字、escaped key、Unicode key は JSON の decode 後に同一となるキーを重複として扱う。`JSON3.jl` がこの保証を提供しない場合は、JevClient.jl の bounded scanner で先に検査する。scanner は `max_response_bytes` と `max_json_depth` を共有し、上限超過時に response 全体を保持しない。

### 28.5 依存関係と初期実装の境界

`Project.toml` の直接依存は HTTP.jl、JSON3.jl、StructTypes.jl とし、互換バージョンを明記する。Phase 1 では transport を呼び出さず、質問型、許可 JSON 値の正規化、wire serialization、credential の local validation、response の bounded parser に必要な内部型を実装する。HTTP request、retry、concurrency は Phase 2 以降で、Phase 1 の public API を壊さず追加する。
