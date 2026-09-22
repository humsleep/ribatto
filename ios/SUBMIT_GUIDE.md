# 앱스토어 등록 — 처음 하는 사람을 위한 전체 절차

> 순서표는 [RELEASE.md](RELEASE.md)에 있다. 이 문서는 그 안의 단계를 자세히 푼 것이다.

무료/프로가 나뉘지만 **구매는 없다**(2026-09-15 광고 전용 전환). Pro는 리워드 광고를 끝까지 보면 1시간 열린다.
그래서 유료 앱 계약·은행·세금·인앱 구입 등록이 **필요 없고**, 대신 AdMob 설정이 필요하다.
순서대로 따라가면 되고, 각 단계에서 **내가 해야 할 일**과 **걸리는 시간**을 적어뒀다.

---

## 단계 0. Apple Developer Program 가입 — ✅ 완료

> **2026-09-01 가입·결제 완료.** 아래는 기록용이며 다시 할 일은 없다.
> 여기서부터는 [단계 1](#단계-1-광고-준비-admob)로 바로 간다.

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

## 단계 1. 광고 준비 (AdMob)

인앱 구입이 없으니 App Store Connect의 유료 앱 계약은 건너뛴다. 수익은 AdMob에서 받는다.

1. https://admob.google.com 에서 앱 추가 → **앱 ID**(`ca-app-pub-…~…`) 발급
2. 광고 단위 3개 만들기: **배너**, **전면**, **보상형** → 각 단위 ID(`ca-app-pub-…/…`)
3. Release 빌드 설정 `GAD_APPLICATION_ID`와 `AdsManager.Unit`의 Release 값에 입력 ([RELEASE.md](RELEASE.md) 4-2)
   - 비워 두면 크래시는 없지만 **광고가 안 뜨고 Pro를 열 방법도 없다**
4. AdMob → 결제 → 지급 정보(은행·세금) 입력. 지급 기준액에 도달하면 매월 송금된다
5. `app-ads.txt`를 개발자 웹사이트 루트에 게시 (AdMob이 안내하는 한 줄). 없으면 광고 단가가 떨어진다
6. **EU 동의**: UMP 동의 폼이 연결돼 있지 않다. 연결 전에는 App Store Connect 가격·배포에서 EU 27개국을 끈다

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
2. **가격**: **무료**. 인앱 구입은 만들지 않는다

---

## 단계 3. 빌드 올리기

1. Xcode에서 **Signing & Capabilities → Team**에 본인 계정 선택
2. 상단 기기 선택을 **Any iOS Device**로
3. 메뉴 **Product → Archive**
4. Organizer 창이 열리면 **Distribute App → App Store Connect → Upload**
5. 업로드 후 App Store Connect에서 처리에 10~30분 소요

## 단계 4. TestFlight로 먼저 확인 (권장)

- 업로드한 빌드를 TestFlight에서 본인 폰에 설치해 최종 확인
- **Release 광고 ID로 리워드 광고가 뜨고 Pro가 1시간 열리는지** 확인한다 (자기 광고를 반복해서 누르지 말 것 — AdMob 무효 트래픽)
- 지인 몇 명 초대해 출시 첫날 리뷰를 확보하는 용도로도 쓴다

## 단계 5. 제출

App Store Connect의 앱 페이지에서:

- [ ] 스크린샷 (6.9" 필수) — `marketing/` 5장 (다시 만든 것)
- [ ] 이름·부제·설명·키워드 — [APP_STORE.md](APP_STORE.md)에 3개 국어 초안
- [ ] **개인정보 처리방침 URL** — 필수. 초안은 APP_STORE.md에 있고, GitHub Pages나 노션 공개 페이지면 충분
- [ ] 앱 개인정보 보호 설문 → AdMob 때문에 **"데이터를 수집함"**. 항목은 [APP_STORE.md](APP_STORE.md) §5 표대로 (`PrivacyInfo.xcprivacy`와 일치)
- [ ] 연령 등급 설문
- [ ] 심사 정보 메모: [APP_STORE.md](APP_STORE.md) §4-1 문안을 **그대로** 붙여넣는다 (문안은 그곳 한 군데에서만 관리한다)
- [ ] **심사를 위해 제출**

**심사 기간**: 보통 24~48시간. 처음이면 좀 더 걸릴 수 있다.

---

## 처음 제출 시 자주 거절되는 이유 (미리 대비)

| 거절 사유 | 우리 앱의 대비 상태 |
|---|---|
| 광고 추적 선언 누락 (5.1.2) | ✅ ATT 프롬프트 + `NSPrivacyTracking` true + 설문 "수집함" |
| 광고가 앱 사용을 방해 | ✅ 전면광고는 렌더 완료 직후만, 3분 간격, 편집·재생 중에는 안 뜸 |
| 개인정보 처리방침 URL 누락/접속 불가 | ⬜ 본인이 페이지를 올려야 함 |
| 스크린샷이 실제 앱과 다름 | ⬜ **현재 5장에 삭제된 점수판·"PAY ONCE"가 있다. 다시 만들 것** |
| 기능이 부실하다(Minimum Functionality) | ✅ 실제 영상 처리 기능이 핵심이라 해당 없음 |
| 앱이 심사 중 크래시 | ⬜ **실기기 테스트 필수** ([TESTING.md](TESTING.md)) |

---

## 요약: 지금 당장 할 일 순서

가입이 끝났으므로 여기서부터다. **1과 2는 동시에 진행할 수 있다** —
2는 애플의 심사·검증 대기가 섞여 있어 먼저 걸어두는 게 이득이다.

1. **실기기 테스트** ([DEVICE_TESTING.md](DEVICE_TESTING.md), [TESTING.md](TESTING.md))
   — 번들 ID 확보를 겸하므로 가장 먼저 한다
2. **AdMob 앱·광고 단위 발급 → Release 설정에 입력** (단계 1)
3. 개인정보 처리방침 페이지 게시 (URL 필요)
4. 앱 등록 → Archive 업로드 → TestFlight로 리워드 광고·Pro 해제 확인
5. 스크린샷 다시 만들고 메타데이터 채워 제출

### 코드 쪽 준비 상태 (2026-09-01 검증)

| 항목 | 상태 |
|---|---|
| Release 아카이브 빌드·서명 | ✅ ARCHIVE SUCCEEDED |
| 디버그용 Pro 무료해제 코드 | ✅ Release 바이너리에 미포함 확인 |
| 카메라·마이크·사진 권한 문구 | ✅ 4종 모두 설정됨 |
| 수출규정 문항(ITSAppUsesNonExemptEncryption) | ✅ NO로 사전 설정 — 업로드마다 묻지 않음 |
| 앱 아이콘 · 버전(1.0/1) · 최소 iOS 17.0 | ✅ |
| 가로 모드 레이아웃 | ✅ 전 화면 스크롤 구조라 깨지지 않음 |
