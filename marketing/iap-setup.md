# Ribatto Pro — App Store Connect 인앱결제 등록용

App Store Connect ▸ 앱 ▸ 수익 창출 ▸ 앱 내 구입 ▸ (+)

- 유형: **비소모품 (Non-Consumable)**
- 참조 이름(내부용): `Ribatto Pro`
- 제품 ID: `com.ribatto.pro`   ← 코드와 반드시 일치. 다르면 페이월이 영원히 '가격 불러오는 중'
- 가격: 로컬 설정은 4400원 기준 (App Store Connect에서 해당 가격대 선택)
- 가족 공유: 켜기

## 현지화 문구 (표시 이름 / 설명)

### English (U.S.)  `en_US`
- 표시 이름: Ribatto Pro
- 설명: Unlimited imports, full-quality export with no watermark, smart vertical crop, follow one player, shot counter and scoreboard burned in. One-time purchase — no subscription, no account, and your video never leaves your iPhone.

### Korean  `ko_KR`
- 표시 이름: Ribatto Pro
- 설명: 영상 무제한 가져오기, 워터마크 없는 원본 화질 저장, 스마트 세로 크롭, 특정 선수 추적, 타구 카운터·점수판 번인. 1회 결제입니다. 구독도 계정도 없고, 영상은 아이폰 밖으로 나가지 않습니다.

### Japanese  `ja_JP`
- 표시 이름: Ribatto Pro
- 설명: 読み込み無制限、ウォーターマークなしの高画質書き出し、スマート縦クロップ、特定の選手を追跡、打球カウンターとスコアの焼き込み。買い切りです。サブスクもアカウントもなく、動画はこの iPhone から出ません。

### Spanish (Spain)  `es_ES`
- 표시 이름: Ribatto Pro
- 설명: Importaciones ilimitadas, exportación en calidad original sin marca de agua, recorte vertical inteligente, seguimiento de un jugador, contador de golpes y marcador grabados. Pago único: sin suscripción y sin cuenta.

### Portuguese (Brazil)  `pt_BR`
- 표시 이름: Ribatto Pro
- 설명: Importações ilimitadas, exportação em qualidade original sem marca d'água, corte vertical inteligente, rastreamento de um jogador, contador de batidas e placar gravados. Compra única: sem assinatura e sem conta.

### German  `de_DE`
- 표시 이름: Ribatto Pro
- 설명: Unbegrenzte Importe, Export in voller Qualität ohne Wasserzeichen, intelligenter Hochformat-Zuschnitt, Verfolgung eines Spielers, eingebrannter Schlagzähler und Punktestand. Einmalkauf – kein Abo, kein Konto.

### French  `fr_FR`
- 표시 이름: Ribatto Pro
- 설명: Imports illimités, export en pleine qualité sans filigrane, recadrage vertical intelligent, suivi d'un joueur, compteur de frappes et score incrustés. Achat unique : sans abonnement ni compte.

### Italian  `it_IT`
- 표시 이름: Ribatto Pro
- 설명: Importazioni illimitate, esportazione alla massima qualità senza filigrana, ritaglio verticale intelligente, tracciamento di un giocatore, contatore dei colpi e punteggio impressi. Acquisto unico: nessun abbonamento e nessun account.

### Chinese (Simplified)  `zh_CN`
- 표시 이름: Ribatto Pro
- 설명: 无限导入、无水印原画质导出、智能竖版裁剪、锁定一位球员、烧录击球计数与比分。一次性购买：无订阅、无账号。

## 심사 정보 (필수)

- **스크린샷**: 앱의 페이월 화면 캡처 1장 (기능 잠금 해제 화면). 없으면 제출 불가.
- 심사 메모 예시:

```
Ribatto Pro is a single one-time non-consumable unlock. Tap the entitlement
pill on the Library tab (or any PRO-marked control) to open the paywall.
It removes the 3-import limit and the watermark, and enables full-quality
export, smart vertical crop, player tracking, shot counter and scoreboard.
There is no subscription and no account.
```

## 놓치기 쉬운 것

- 첫 제출에서는 **앱 버전 페이지에서 이 인앱결제를 함께 선택해 제출**해야 한다.
  따로 두면 앱만 승인되고 결제는 승인되지 않아 출시 직후 페이월이 죽는다.
- 제품 ID는 한 번 만들면 재사용·변경이 불가능하다.
- 세금·금융 계약(유료 앱 계약)이 '활성' 상태여야 인앱결제를 만들 수 있다.
  App Store Connect ▸ 비즈니스 ▸ 계약, 세금 및 금융거래.
