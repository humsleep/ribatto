# 앱스토어 등록 — 처음 하는 사람을 위한 전체 절차

> 순서표는 [RELEASE.md](RELEASE.md)에 있다. 이 문서는 그 안의 단계를 자세히 푼 것이다.

무료/프로가 나뉘는 앱이라 **결제(인앱 구입) 설정**이 함께 필요하다.
순서대로 따라가면 되고, 각 단계에서 **내가 해야 할 일**과 **걸리는 시간**을 적어뒀다.

---

## 단계 0. Apple Developer Program 가입 — ✅ 완료

> **2026-09-01 가입·결제 완료.** 아래는 기록용이며 다시 할 일은 없다.
> 여기서부터는 [단계 1](#단계-1-돈을-받을-준비-유료-앱의-필수-관문)로 바로 간다.

**비용**: 연 $99 (약 13~14만원, 매년 자동 갱신)
**기간**: 보통 1~2일, 길면 1주

1. https://developer.apple.com/programs/enroll/ 접속 → Apple ID로 로그인
2. **개인(Individual)** 선택 — 사업자등록 없이 개인으로 가입 가능하다
   - 개인으로 가입하면 앱 판매자 이름이 **본인 실명**으로 표시된다
   - 상호명으로 표시하려면 사업자등록 + D-U-N-S 번호가 필요하고 훨씬 오래 걸린다.
     처음이라면 개인으로 시작하고, 나중에 법인으로 이전하는 게 낫다
3. 결제(연회비) → 애플의 본인 확인 대기
4. 승인 메일이 오면 App Store Connect 사용 가능

> 승인 메일을 받았다면 App Store Connect에 로그인해 **나의 앱** 메뉴가 보이는지로 확인할 수 있다.

---

## 단계 1. 돈을 받을 준비 (유료 앱의 필수 관문)

앱은 무료로 받게 하고 **인앱 구입(US$2.99 권장)** 으로 판매하므로, 이 설정을 안 하면
심사에 통과해도 **인앱 구입이 판매되지 않는다.** 처음 하는 사람이 가장 많이 놓치는 부분이다.

App Store Connect → **비즈니스**(Business) 메뉴에서:

1. **유료 앱 계약(Paid Apps Agreement) 동의**
2. **은행 정보** 입력 — 본인 명의 계좌. 외화 입금 가능한 계좌면 되고, 국내 시중은행 계좌로 충분하다
3. **세금 정보** 입력
   - 미국 세금 양식 **W-8BEN**: 한국 거주 개인은 여기서 조세조약 혜택을 신청해 미국 원천징수를 줄인다
   - 한국 세금 정보도 함께 입력
4. **연락처(재무/기술/법무)** 지정 — 혼자면 전부 본인

### 꼭 신청할 것: App Store Small Business Program

- 애플 수수료는 기본 **30%** 인데, 이 프로그램에 가입하면 **15%** 로 내려간다
- 조건: 직전 연도 매출 **$100만 미만** — 처음 시작하는 개인은 당연히 해당된다
- **자동이 아니라 직접 신청해야 한다**: App Store Connect → 비즈니스 → Small Business Program
- ₩4,400짜리를 팔 때: 수수료 30%면 약 3,080원, 15%면 약 3,740원이 내 몫이다.
  신청 한 번에 건당 660원이 늘어나므로 반드시 하자

### 정산은 언제 들어오나

- 매월 정산, 보통 다음 달 말경 입금
- **최소 지급액**(보통 $150 상당)에 도달해야 송금된다. 초기에는 몇 달치가 쌓여야 들어온다
- 부가세·소득세는 국내 세법에 따라 본인이 신고해야 한다 (해외 매출 = 영세율 대상이 될 수 있으니 세무 상담 권장)

---

## 단계 2. 앱 등록

1. App Store Connect → **나의 앱 → +** → 새로운 앱
   - 플랫폼: iOS
   - 이름: `Ribatto`
   - 기본 언어: **English (U.S.)** (전 세계 대상이므로)
   - 번들 ID: Xcode에서 쓰는 것과 **정확히 일치**해야 한다
     → 현재 `com.ribatto.app`. 이미 남이 선점했다면 `com.본인이름.ribatto` 등으로 바꾸고
       Xcode의 `PRODUCT_BUNDLE_IDENTIFIER`도 같이 바꿔야 한다
   - SKU: `ribatto-001` (내부 식별용, 아무 문자열)
2. **가격**: 앱 자체는 **무료**로 설정 (판매는 인앱 구입으로 한다)

---

## 단계 3. 인앱 구입 만들기

App Store Connect → 앱 → **수익 창출 → 인앱 구입 → +**

| 항목 | 값 |
|---|---|
| 유형 | **비소모품 (Non-Consumable)** ← 한 번 사면 영구 |
| 제품 ID | `com.ribatto.pro` ← 코드의 `PurchaseManager.productID`와 **반드시 동일** |
| 참조명 | Ribatto Pro |
| 가격 | **US$2.99 티어** (한국 약 ₩4,400). 근거는 [APP_STORE.md](APP_STORE.md) 참고 |

그리고 **현지화 정보**(영어/한국어/일본어 표시명·설명)와 **심사용 스크린샷 1장**이 필요하다.
→ 페이월 화면 스크린샷(`ios/Marketing/shot_05.png`)을 쓰면 된다.

> 첫 제출 시에는 **앱과 인앱 구입을 함께 심사에 보내야 한다.** 인앱 구입만 따로 두면
> "심사 대기" 상태로 남아 앱만 승인되고 결제가 동작하지 않는다.

---

## 단계 4. 빌드 올리기

1. Xcode에서 **Signing & Capabilities → Team**에 본인 계정 선택
2. 상단 기기 선택을 **Any iOS Device**로
3. 메뉴 **Product → Archive**
4. Organizer 창이 열리면 **Distribute App → App Store Connect → Upload**
5. 업로드 후 App Store Connect에서 처리에 10~30분 소요

## 단계 5. TestFlight로 먼저 확인 (권장)

- 업로드한 빌드를 TestFlight에서 본인 폰에 설치해 최종 확인
- **인앱 구입이 샌드박스로 동작**하므로 실제 결제 흐름을 돈 안 쓰고 검증할 수 있다
- 지인 몇 명 초대해 출시 첫날 리뷰를 확보하는 용도로도 쓴다

## 단계 6. 제출

App Store Connect의 앱 페이지에서:

- [ ] 스크린샷 (6.9" 필수) — `ios/Marketing/` 5장 사용
- [ ] 이름·부제·설명·키워드 — [APP_STORE.md](APP_STORE.md)에 3개 국어 초안
- [ ] **개인정보 처리방침 URL** — 필수. 초안은 APP_STORE.md에 있고, GitHub Pages나 노션 공개 페이지면 충분
- [ ] 앱 개인정보 보호 설문 → **"데이터를 수집하지 않음"** 전부 선택 (우리 앱은 실제로 아무것도 수집하지 않는다)
- [ ] 연령 등급 설문
- [ ] 심사 정보 메모에 이렇게 적어두면 문의가 줄어든다:
  > No account or sign-in is required.
  >
  > Photos access: the app uses PhotosPicker to select a match video, and also requests
  > Photos permission so it can read the selected video in place (via PHImageManager)
  > instead of duplicating a multi-gigabyte file, and to save exported clips back to the
  > library. Denying access still allows import through the picker using a local copy.
  >
  > All analysis and rendering happen on-device. No server of ours, no analytics; the video
  > never leaves the device. Only two network calls exist: StoreKit, and CLGeocoder for the
  > court name from the video's own GPS tag.
  >
  > IAP "Ribatto Pro" (com.ribatto.pro) is a one-time non-consumable; Restore is at the
  > top right of the paywall.

  (예전 문안 "Uses PHPicker only — no photo library permission prompt"은 **사실과 달랐다**.
   실제 코드는 `PHPhotoLibrary.requestAuthorization`을 호출한다.)
- [ ] **심사를 위해 제출**

**심사 기간**: 보통 24~48시간. 처음이면 좀 더 걸릴 수 있다.

---

## 처음 제출 시 자주 거절되는 이유 (미리 대비)

| 거절 사유 | 우리 앱의 대비 상태 |
|---|---|
| 인앱 구입에 **복원 버튼**이 없음 | ✅ 페이월 우상단 `Restore` 구현됨 |
| 구독처럼 보이는데 조건 표기가 없음 | ✅ "1회 결제, 구독 아님" 명시 |
| 개인정보 처리방침 URL 누락/접속 불가 | ⬜ 본인이 페이지를 올려야 함 |
| 스크린샷이 실제 앱과 다름 | ✅ 전부 실제 화면 캡처 |
| 기능이 부실하다(Minimum Functionality) | ✅ 실제 영상 처리 기능이 핵심이라 해당 없음 |
| 앱이 심사 중 크래시 | ⬜ **실기기 테스트 필수** ([TESTING.md](TESTING.md)) |

---

## 요약: 지금 당장 할 일 순서

가입이 끝났으므로 여기서부터다. **1과 2는 동시에 진행할 수 있다** —
2는 애플의 심사·검증 대기가 섞여 있어 먼저 걸어두는 게 이득이다.

1. **실기기 테스트** ([DEVICE_TESTING.md](DEVICE_TESTING.md), [TESTING.md](TESTING.md))
   — 번들 ID 확보를 겸하므로 가장 먼저 한다
2. **유료 앱 계약 + 은행/세금 정보 + Small Business Program 신청**
   — 이걸 빼먹으면 심사에 통과해도 결제가 안 팔린다
3. 개인정보 처리방침 페이지 게시 (URL 필요)
4. 앱 등록 → 인앱 구입 등록 → Archive 업로드 → TestFlight로 실결제 흐름 확인
5. 메타데이터·스크린샷 채우고 **앱과 인앱 구입을 함께** 제출

### 코드 쪽 준비 상태 (2026-09-01 검증)

| 항목 | 상태 |
|---|---|
| Release 아카이브 빌드·서명 | ✅ ARCHIVE SUCCEEDED |
| 디버그용 Pro 무료해제 코드 | ✅ Release 바이너리에 미포함 확인 |
| 카메라·마이크·사진 권한 문구 | ✅ 4종 모두 설정됨 |
| 수출규정 문항(ITSAppUsesNonExemptEncryption) | ✅ NO로 사전 설정 — 업로드마다 묻지 않음 |
| 앱 아이콘 · 버전(1.0/1) · 최소 iOS 17.0 | ✅ |
| 가로 모드 레이아웃 | ✅ 전 화면 스크롤 구조라 깨지지 않음 |
