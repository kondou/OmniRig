# OmniRig VFO A/B Split Mode — 設計・実装メモ

## 目的

TS-590SGへのCAT接続（USB-CATの1本）で、OmniRigに2台のリグが接続されているように見せる。

- **Rig1** → VFO A を制御
- **Rig2** → VFO B を制御

これによりAfedri AFE822x（デュアルチャンネルSDR）が2台のリグからそれぞれ周波数・モード情報を受け取れるようにする。SDRのチャンネル1がVFO A追従、チャンネル2がVFO B追従。

## 背景・制約

- 動作環境: BootCamp上のWindows 7
- ビルド環境: Parallels上のWindows 11 + Delphi 12（RAD Studio）
- Delphi 12でビルドしたEXEはWindows 7で動作することをJR8PPG（フォーク作者）に確認済み
- ベースリポジトリ: https://github.com/jr8ppg/OmniRig（VE3NEA/OmniRigのfork、v1.21）
- JR8PPG版の主な追加機能: transceiveモード（PollMs=0でAI2による自発応答を処理）
- WRTC 2026での使用を目的としているため、開発期間に制約あり
- SDRへの書き込みは不要。AfedriのDLLがOmniRigの`Rig.Freq`を読みに来ることはデバッグ済み
- SDRからの不用意な操作によるリグへの影響を避けるため、WriteCommandは定義しない
- COMポートは115200bps

## `.ini`ファイルの背景

現行の`TS-590.ini`はKondou自身がPPG版OmniRigでデバッグして確立した実動作実績のあるファイル。以下の点が確認済み：

- AI2モードでポーリングなし（PollMs=0）が前提
- AfedriのDLLは`Rig.Freq`（`pmFreq`）を参照する（`pmFreqA`/`pmFreqB`は使わない）
- VFO A/Bの区別は`pmFreq` + `pmVfoAA`/`pmVfoBB`で表現
- STATUS2（`FA;`）とSTATUS3（`FB;`）はどちらも`pmFreq`に入れている
- AfedriのDLLは`Rig.Freq`（周波数）だけでなく`FR;`応答による`pmVfoAA`/`pmVfoBB`も参照していることをデバッグで確認済み。SDR側はこれによってVFO A/Bのどちらを追従すべきかを判断している

## TS-590SG CATコマンド（関連分）

| コマンド | 方向 | 内容 |
|---|---|---|
| `AI2;` | 送信 | Auto Information有効化 |
| `FA;` | 受信 | VFO A周波数（`FA00014195000;`形式、14バイト+`;`） |
| `FB;` | 受信 | VFO B周波数（同上） |
| `MD;` | 受信 | モード（`MD0;`形式） |
| `FR;` | 受信 | 受信VFO（`FR0;`=VFO A、`FR1;`=VFO B） |
| `IF;` | 受信 | 全情報一括 |

## AI2モードでのデータ送出順序（実測）

TS-590SGのAI2モードで状態変化が起きたときのリグからのデータ送出順序：

| 操作 | 送出されるコマンド | 順序 |
|---|---|---|
| VFO切り替え（モードも変わる場合） | `FR;` → `MD;` | FRが先、MDが後 |
| VFO切り替え（モードが変わらない場合） | `FR;` のみ | - |
| モードのみ変更 | `MD;` のみ | FRは続かない |

この順序はポーリング時の起動初期化とは異なる。起動時はポーリング順（`FA;`→`FR;`→`MD;`）だが、AI2による自発送出はFR→MDの順。

## ソースコードの変更概要

### 変更ファイル

| ファイル | 変更内容 |
|---|---|
| `CustRig.pas` | MasterRig追加、GetActivePort、DispatchAIData、共有ポート対応、RecvEventでのMDスキップ |
| `Main.pas` | ApplySharedPort、DispatchSlaveAIData（FR/MD振り分けロジック）追加 |
| `RigSett.pas` | ToRig/FromRigで共有スレーブ時のComPort操作スキップ |

### 変更なし

- `RigObj.pas`
- `RigCmds.pas`
- `CmdQue.pas`
- その他

### 共有ポートの仕組み

1. `FormCreate`で`ApplySharedPort`を`ToRig`の**前**に呼ぶ（順序が重要）
2. `Sett1.Port == Sett2.Port`なら共有モードに入る
3. Rig2のComPortをFreeしてRig1のComPortを借用、`Rig2.MasterRig := Rig1`をセット
4. `ToRig`はMasterRig != nilのRigに対してComPort操作をスキップ（二重Open防止）
5. AI2でリグからデータが届いたとき、Rig1（マスター）の`RecvEvent`が受信し`DispatchSlaveAIData`に渡す
6. ポートが別々の場合は従来通りの独立動作（SO2R環境での従来運用と同じ）

### FR/MD振り分けロジック（DispatchSlaveAIData）

```
FA; → Rig1のみに渡す
FB; → Rig2のみに渡す
FR; → VFO判定（FR0=Rig1、FR1=Rig2）してVFO更新、FPendingModeTargetをセット
MD; → FPendingModeTargetが設定されていればそのRigに適用してクリア
      FPendingModeTargetがnilなら（モードのみ変更）FActiveRig（最後にFRで確定したRig）に適用
その他 → 両方に渡す
```

タイムアウト（PENDING_MODE_TIMEOUT_MS = 150ms）：FRの後にMDが来なかった場合、FPendingModeTargetをクリア（VFOのみ変更のケース）。

### RecvEventでのMDスキップ（CustRig.pas）

マスターRig（`FMasterRig = nil`）のRecvEventでAIデータを処理する際、ヘッダが`MD`のときは自身のiniのStatusCmdでの処理をスキップする。MDの処理は`DispatchSlaveAIData`のみに委ねることで、Rig1が常にMDを自己処理して誤ったVFOにモードが適用されるのを防ぐ。

### 排他制御

- `CheckQueue`の先頭でマスターがphIdle以外のとき、スレーブの送信を待機
- スレーブはポートのOpen/Closeをスキップ（マスターが管理）

## INIファイル

### `TS-590SG_VFOA.ini`（Rig1用）

```ini
[INIT]
Command=(AI2;)
ReplyLength=0

[STATUS1]                          ; FA; → pmFreq
Command=(FA;)
ReplyEnd=(;)
Validate=(FA...........;)
Value1=2|11|vfText|1|0|pmFreq

[STATUS2]                          ; FR0; のみ → pmVfoAA
Command=(FR;)
ReplyEnd=(;)
Validate=(FR.;)
Flag1=(..0.)|pmVfoAA

[STATUS3]                          ; MD; → モード（DispatchAIData経由でのみ適用）
Command=(MD;)
ReplyEnd=(;)
Validate=(MD.;)
Flag1=(..1.)|pmSSB_L
...
```

- INIT: `AI2;`を送出（Rig1のみ）
- STATUS3（MD）はRecvEvent内ではスキップされ、`DispatchAIData`経由で呼ばれた場合のみ適用される

### `TS-590SG_VFOB.ini`（Rig2用）

```ini
[INIT]
; なし（Rig1がAI2;を送出済み）

[STATUS1]                          ; FB; → pmFreq
Command=(FB;)
ReplyEnd=(;)
Validate=(FB...........;)
Value1=2|11|vfText|1|0|pmFreq

[STATUS2]                          ; FR1; のみ → pmVfoBB
Command=(FR;)
ReplyEnd=(;)
Validate=(FR.;)
Flag1=(..1.)|pmVfoBB

[STATUS3]                          ; MD; → モード（DispatchAIData経由で適用）
Command=(MD;)
...
```

### 配置場所

```
<OmniRig.exeと同じフォルダ>\Rigs\TS-590SG_VFOA.ini
<OmniRig.exeと同じフォルダ>\Rigs\TS-590SG_VFOB.ini
```

既存の`Rigs\`フォルダの内容（他リグの`.ini`）はそのまま流用。

## OmniRig設定

| 項目 | Rig1 | Rig2 |
|---|---|---|
| リグタイプ | TS-590SG_VFOA | TS-590SG_VFOB |
| COMポート | COM4（実際のポート） | **同じCOMポート** |
| ボーレート | 115200 | 115200 |
| Poll Int. | 0 | 0 |

## デバッグ方法

OmniRigのログを有効にする：

```
C:\Users\<ユーザー名>\AppData\Roaming\Afreet\Products\OmniRig\OmniRig.ini
```

の先頭に以下を追加：

```ini
[Debug]
Log=1
```

ログファイルは同フォルダの`OmniRig.log`に出力される。

SMメーター（`SM...`）データが大量に出力されてログが埋まる場合は、TS-590SG側のAI2設定でSメーター送出を無効化するか、テスト中はリグのボリュームを絞る。

## 動作確認手順

1. `Win32\Release\OmniRig.exe`をWindows 7マシンにコピー
2. `Win32\Release\Rigs\`フォルダごとコピー（既存`Rigs\`と統合）
3. OmniRigを起動してRig1/Rig2を上記設定で設定
4. TS-590SGのCAT接続を確認
5. OmniRig画面でRig1/Rig2ともにOnlineになることを確認
6. VFO A/Bを切り替えてRig1.Freq/Rig2.Freqがそれぞれ追従することを確認
7. VFO切り替え時にモードが正しいVFOに追従することを確認
8. モードのみ変更時にアクティブVFOのRigのみモードが変わることを確認
9. HDSDRでAfedri DLLを起動してチャンネル1/2がVFO A/Bに追従することを確認

## トラブルシューティング

### 「無効なポインタ操作」エラー

`ApplySharedPort`が`ToRig`の後に呼ばれた場合に発生する。`ToRig`内で`Enabled := true`が呼ばれてRig2がポートのOpenを試みた後に`Rig2.ComPort.Free`を呼ぶと二重解放になる。`ApplySharedPort`は必ず`ToRig`の前に呼ぶこと。

### モードが逆のVFOに適用される

Rig1のRecvEventがMDを直接処理してしまっている。`CustRig.pas`のRecvEventでマスターRigのMDスキップ処理が正しく動いているか確認。

### モードが全く変わらない

Rig1/Rig2のiniにSTATUS3（MD）が定義されていないと`DispatchAIData`経由でも処理されない。両iniにSTATUS3が定義されていることを確認。

### SMメーターデータで埋め尽くされる

`SM...;`はValidate不一致でスキップされるが量が多い。TS-590SG側でAI2の送出対象を絞るか、デバッグ後はLog=0に戻す。

## 実装結果

動作確認済み（2026年6月）：

- VFO A/B周波数のRig1/Rig2への独立した追従 ✓
- VFO切り替え時のモード正確な振り分け（FR→MD順序対応） ✓
- モードのみ変更時のアクティブVFOへの正確な適用 ✓
- 通常SO2R運用（ポート別）への影響なし ✓
