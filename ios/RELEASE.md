# Ribatto 출시 가이드

**기준일 2026-09-07.** 이 문서가 출시까지의 단일 순서표다. 세부 절차는 기존 문서로 연결한다
(계정·정산 절차는 [SUBMIT_GUIDE.md](SUBMIT_GUIDE.md), 메타데이터 원문은
[../marketing/app-store-copy.md](../marketing/app-store-copy.md), 홍보 계획은 [LAUNCH.md](LAUNCH.md)).

---

## 0. 지금 상태

| | |
|---|---|
| 앱 이름 | **Ribatto** (이탈리아어 "되받아친다") |
| 번들 ID | `com.ribatto.app` |
| 수익 | 광고(AdMob) 전용 · 인앱 구입 없음 · 리워드 광고를 끝까지 보면 1시간 Pro 패스 (2026-09-15 구매 제거) |
| 지원 언어 | en ko ja es pt de fr it zh-Hans (9종) |
| 최소 iOS | 17.0 |
| 스크린샷 | `marketing/01~05_*.png` · 1320×2868 (6.9인치) |
| 개인정보 URL | **https://humsleep.github.io/Ribatto/privacy.html** (2026-09-07 발행 확인) |

**코드는 제출 가능한 상태다.** 남은 것은 전부 App Store Connect 안에서, 사람이 눌러야 하는 일이다.

---

## 1. 이름을 확정한다 (제일 먼저)

이름 예약이 실패하면 그 뒤 단계가 전부 헛수고가 된다.

- [ ] **App Store Connect에서 `Ribatto` 이름 예약.** 여기서 통과해야 확정이다. 스토어 검색 API로
      미국·한국 스토어에 동명 앱이 없는 것은 확인했지만, 예약 시점의 판정은 애플이 한다.
- [ ] **`ribatto.com` / `ribatto.app` 도메인 취득.** 둘 다 미등록 상태였다. 시즌 공유 카드에
      `ribatto.app`이 **픽셀로 찍혀 나가므로**(`StatsView`) 남이 선점하면 남의 사이트를 광고하게 된다.
- [ ] **상표 확인 또는 출원** — KIPRIS·USPTO 9류. 자가출원 5~6만원, 변리사 10~20만원.
      "Vollio"를 버린 이유가 VLLO(vimosoft, 2019년 미국 9류 출원)와의 유사성이었으므로,
      같은 실수를 반복하지 않으려면 이번엔 선점해 두는 편이 낫다.

## 2. 개인정보 처리방침 페이지 — ✅ 완료

발행 주소: **https://humsleep.github.io/Ribatto/privacy.html**
(HTTP 200 · 영어/한국어 본문 · 문의처 `humsleep@naver.com` 확인. 원문은 `docs/privacy.html`)

- [x] `docs/privacy.html`을 GitHub Pages로 발행
- [ ] 옛 `/vollio/privacy` 페이지가 아직 살아 있다면 내린다 (새 주소가 뜬 뒤에)
- [ ] 문구는 코드와 일치해야 한다. **"업로드 없음"이라고 쓰지 말 것** — `PlaceLookup`이 영상의 GPS
      태그를 애플 지오코더로 보내 코트 이름을 받아온다. 올바른 표현은 "영상은 기기 밖으로 나가지 않는다"다.
      (앱 내 개인정보 화면·스토어 문구는 이미 이 표현으로 통일해 뒀다.)

### 개인정보 페이지 올리기 (GitHub Pages, 무료)

이 저장소는 원격이 없는 로컬 저장소다. 정책 페이지만 올리는 **공개 저장소를 따로 하나** 만드는 것이
가장 간단하고, 앱 소스는 계속 비공개로 둘 수 있다.

1. github.com → **New repository** → 이름 `ribatto` → **Public** → Create
2. 저장소 화면에서 **Add file ▸ Upload files** → `docs/privacy.html`을 끌어다 놓고,
   업로드 후 파일명을 **`index.html`로 바꾼다**(그래야 주소가 짧아진다) → Commit
3. **Settings ▸ Pages** → Source: **Deploy from a branch** → Branch: `main` / 폴더 `/ (root)` → Save
4. 1~2분 뒤 주소가 뜬다: `https://<깃허브아이디>.github.io/ribatto/`
5. 그 주소를 브라우저에서 직접 열어 **본문이 보이는지** 확인한다. App Store Connect의
   개인정보 URL 칸에는 이 주소를 넣는다.

> `github.com/<아이디>/<저장소>/blob/...` 형태의 주소는 깃허브 UI가 감싸진 페이지라 정책 URL로 쓰지 않는다.
> 반드시 `github.io` 주소를 쓴다.

파일 안의 `CONTACT@EXAMPLE.COM` 두 곳을 실제 연락 메일로 바꾼 뒤 올린다. 애플은 동작하는 연락 수단을 요구한다.

## 3. App Store Connect — 앱 레코드

[SUBMIT_GUIDE.md 단계 2](SUBMIT_GUIDE.md) 참고.

- [ ] 플랫폼 iOS · 이름 `Ribatto` · 기본 언어 **English (U.S.)** · 번들 ID `com.ribatto.app` · SKU `ribatto-001`
- [ ] **현지화 9개 언어 추가.** 이걸 해야 제품 페이지에 9개 언어가 표시된다.
      (앱 번들 쪽 선언은 `Ribatto-Info.plist`의 `CFBundleLocalizations`로 이미 처리돼 있다.)
- [ ] 카테고리: 스포츠 / 사진 및 비디오
- [ ] 연령 등급 설문 — 전 연령. 사용자 생성 콘텐츠·웹 접근 없음

## 4-2. AdMob — 무료 등급 광고

앱은 광고로만 운영한다(배너 + 렌더 완료 후 전면광고). 리워드 광고를 끝까지 보면 1시간 Pro 패스가 열리고, 그동안 광고도 사라진다.
인앱 구입은 2026-09-15에 코드에서 걷어냈다. 되살릴 때는 태그 `pro-iap-snapshot`에서 가져온다.
코드는 `Ribatto/Store/AdsManager.swift`. Debug 빌드는 구글의 공개 테스트 ID로 돌아가므로 아래는 **Release 제출 전에만** 필요하다.

- [ ] admob.google.com에서 앱 등록(iOS, 번들 `com.ribatto.app`) → 앱 ID `ca-app-pub-XXXX~YYYY`
- [ ] 광고 단위 3개 생성: **배너**(적응형 앵커) · **전면광고** · **리워드**(보상 = Pro 패스, 수량 1 — 앱은 서버 검증 없이 완료 콜백만 본다)
- [ ] `Ribatto.xcodeproj` Release 구성의 `GAD_APPLICATION_ID`에 앱 ID 입력 (Debug 쪽 테스트 ID는 그대로 둔다)
- [ ] `AdsManager.Unit`의 `#else` 분기에 배너·전면·리워드 단위 ID 입력
- [ ] Release 빌드에서 값이 비어 있으면 `AdsManager.configured`가 false라 **광고 없이 조용히 나간다.** 크래시는 아니지만 수익도 없다 — 제출 전 실기기 Release로 배너가 뜨는지 확인
- [ ] AdMob 결제 정보·세금 정보는 앱 심사와 무관하다. 나중에 채워도 된다
- [ ] App Store Connect ▸ 앱 개인정보: **"사용자를 추적하는 데 사용되는 데이터"에 기기 ID·광고 데이터**, "사용자와 연결되지 않는 데이터"에 대략적 위치(IP)·제품 상호작용. 광고 SDK 표준 항목이다
- [ ] 추적 허용 프롬프트(ATT)는 온보딩 직후 한 번 뜬다. 문구는 `INFOPLIST_KEY_NSUserTrackingUsageDescription`
- [ ] `docs/privacy.html`이 2026-09-18에 다시 바뀌었다(Pro = 보상형 광고 1시간). GitHub Pages의 `index.html`을 이 파일로 다시 올린다
- UMP 동의 폼은 2026-09-18에 연결했다(동의 → ATT → SDK). 폼이 실제로 뜨려면 AdMob ▸ 개인정보 보호 및 메시지에서 GDPR 메시지를 만들어 게시해야 한다. EU를 켜는 날 필요하다

## 4-1. 판매 지역 — EU는 1차 출시에서 제외

EU 27개국에 팔려면 DSA 30·31조에 따라 **거래자(trader) 신원 확인**을 받아야 하고, 확인이
끝나면 **입력한 주소·전화·이메일이 EU 제품 페이지에 공개된다**. 개인 개발자의 집 주소가
공개되는 문제라 1차 출시에서는 EU를 빼기로 했다.

- [ ] **가격 및 사용 가능 여부 → 국가 또는 지역**에서 EU 27개국 해제
- 영국·스위스·노르웨이는 EU가 아니므로 그대로 둔다
- 나중에 사업자 주소가 생기면 거래자 확인을 받고 EU를 켜면 된다
- 제출 단계에서 거래자 상태를 요구하면 EU 배포가 아직 켜져 있다는 뜻이다

## 5. 메타데이터 · 스크린샷

- [ ] 설명·프로모션 문구·키워드: [../marketing/app-store-copy.md](../marketing/app-store-copy.md)
- [ ] **키워드에 `VLLO`·`블로`를 넣지 말 것.** 상표 분쟁은 대개 여기서 시작된다.
- [ ] 스크린샷 5장 업로드 (`marketing/01_hero.png` … `05_s4_clips.png`)
- [ ] 개인정보 URL: 2번에서 만든 새 주소 (원문은 저장소의 `docs/privacy.html`)
- [ ] App Privacy 설문: 4-2의 광고 항목대로. 번들의 `PrivacyInfo.xcprivacy`와 답이 일치해야 한다.

## 6. 빌드 업로드 · 제출

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project ios/Ribatto.xcodeproj -scheme Ribatto -destination 'platform=iOS Simulator,name=iPhone 17' build
```
시뮬레이터 빌드는 위 명령으로 확인하고, 제출용은 Xcode에서 **Any iOS Device → Product ▸ Archive → Distribute**.

- [ ] Archive 업로드 후 App Store Connect에서 빌드 선택
- [ ] **TestFlight로 자기 기기에서 한 번 실행해 본다.** 시뮬레이터에서 안 잡히는 것(실제 촬영 영상의
      타구음 감지 품질, 긴 영상 렌더 시간, 저장 공간)은 여기서만 보인다. [DEVICE_TESTING.md](DEVICE_TESTING.md)
- [ ] 심사 정보 메모: [APP_STORE.md 4-1](APP_STORE.md) 문단을 그대로 복사.
      영상 없이는 앱이 비어 보이므로 **심사자용 샘플 영상 링크를 반드시 넣는다.**

---

## 제출 전 최종 점검

### 이미 검증된 것 (2026-09-07, 이 저장소 기준)

- Debug·Release 빌드 통과, 시뮬레이터 설치·실행·전 탭 이동 확인
- 번들 검증: `com.ribatto.app` / 표시명 `Ribatto` / `PrivacyInfo.xcprivacy` 포함 / 폰트·아이콘 포함
- `CFBundleLocalizations` 9개 언어가 **빌드된** Info.plist에 실제로 들어감
- 개인정보 매니페스트: `UserDefaults(CA92.1)` + `FileTimestamp(C617.1)` 선언 — 코드의 실제 API 사용과 일치
- 9개 언어 × 373키 전수 대조: 누락 0 · 자리표시자 불일치 0
- 접근성 최대 글씨(AX5) + 소형 화면(iPhone SE)에서 4개 탭 레이아웃 확인
- 시즌 공유 카드·클립 워터마크·파일명까지 새 이름으로 렌더되는 것 확인

### 사람만 할 수 있는 것

- [ ] 실기기에서 실제 경기 영상 1개 전체 흐름 (가져오기 → 감지 → 클립 → 릴스 → 사진 앱 저장)
- [ ] 실기기 Release 빌드에서 리워드 광고 → Pro 패스가 열리고 1시간 뒤 닫히는지
- [ ] 스크린샷 속 문구가 실제 화면과 어긋나지 않는지 눈으로 대조

---

## 거절 위험과 대비

| 사유 | 상태 | 대비 |
|---|---|---|
| **2.3.1 숨은 기능** | 대응됨 | Pro 강제 스위치(`DebugProSheet`)는 파일 전체가 `#if DEBUG`. 제출 전 릴리스 바이너리에 `rc_debug_pro` 문자열이 없는지 확인 |
| **ITMS-91053 API 선언 누락** | 대응됨 | `FileTimestamp` 카테고리를 매니페스트에 추가함 (누락 상태였음) |
| **5.1.1 / 2.1 콘텐츠 없음** | 대비 필요 | 심사자는 영상이 없어 빈 앱을 본다. 심사 노트에 샘플 영상 링크 필수 |
| **2.3.10 부정확한 메타데이터** | 대응됨 | "업로드 없음" 류의 포괄 주장을 영상 기준 표현으로 교체함 |
| **3.1.1 결제 우회** | 해당 없음 | 결제 자체가 없음. Pro는 리워드 광고로만 열린다 |

## Pro 테스트 방법

- **Debug 빌드**: 등급 알약을 1.2초 길게 누르면 `DebugProSheet`가 열린다. "Force Pro"로 광고 없이 Pro를 켜고,
  "Grant a pass" / "End pass"로 패스 시작·종료를 확인한다.
- **리워드 광고 흐름**: Debug 빌드는 구글 테스트 단위라 시뮬레이터에서도 끝까지 보면 패스가 열린다.
- TestFlight·App Store 빌드는 Release라 디버그 스위치가 없다. 실기기에서는 실제 리워드 광고로만 Pro가 열린다.

## 알아둘 것

- **기존에 만들어 둔 클립·릴스에는 옛 워터마크(`VOLLIO`)가 픽셀로 박혀 있다.** 마케팅에 쓸 영상은
  새 빌드로 다시 렌더해야 `RIBATTO`가 나온다.
- **시뮬레이터·기기에 남아 있던 데모 데이터는 새 앱에서 안 보인다.** 번들 ID가 바뀌면 데이터 컨테이너가
  달라지기 때문이다. 실제 사용자에게는 해당 없는 문제다(출시 전이라 기존 사용자가 없다).
- 스크린샷 원본 캡처(`hero.jpg`, `s1_library.png` …)는 남아 있지 않다. 완성본만 있으므로,
  화면을 다시 찍어야 할 일이 생기면 시뮬레이터에 데모 데이터를 채우고 `Tools/make_screenshots.swift`를
  다시 돌려야 한다.
