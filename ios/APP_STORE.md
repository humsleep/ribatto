# App Store 출시 체크리스트

## 0. 준비물

| 항목 | 상태 | 비고 |
|---|---|---|
| Apple Developer Program | ✅ 가입 완료 | 2026-09-01 결제 완료 |
| 앱 아이콘 1024px | ✅ 포함됨 | `Ribatto/Assets.xcassets/AppIcon.appiconset` |
| 스크린샷 6.9" | ✅ 초안 포함 | `Marketing/` (필요 시 실기기 영상으로 재촬영 권장) |
| 개인정보 처리방침 URL | ⬜ 필요 | 아래 초안 참고. GitHub Pages/노션 공개 페이지면 충분 |
| 유료 계약(Paid Apps) | ⬜ 필요 | IAP 판매를 위해 App Store Connect에서 은행·세금 정보 입력 |

## 1. App Store Connect 앱 생성

1. https://appstoreconnect.apple.com → **나의 앱 → +**
2. 플랫폼 iOS, 이름 `Ribatto`, 기본 언어 **English (U.S.)**, 번들 ID 선택, SKU `ribatto-001`

## 2. 인앱 구입 등록

- 유형: **비소모품(Non-Consumable)**
- 제품 ID: `com.ribatto.pro` ← 코드의 `PurchaseManager.productID` 와 반드시 일치
- 참조명: `Ribatto Pro`
- 가격: **US$2.99 (한국 약 ₩4,400) 티어 권장** — 아래 근거 참고. 자동 환산되는 각국 가격 확인
  - Pro 번들이 커져(무제한·4K·스마트 크롭·일괄 저장·병합) 최초 계획(₩3,300)보다 한 단계 위가 적정
  - 비소모품은 나중에 가격을 올려도 기존 구매자에게 영향이 없다 — 리뷰가 쌓이면 $3.99로 인상 검토
  - 앵커: SwingVision 월 $14.99 → 우리 평생가가 그 1/5
- 현지화(영/한/일) 표시명·설명 입력 → 심사용 스크린샷 1장 첨부 필요 (페이월 화면 사용)

## 3. 스토어 메타데이터 초안

> 이름은 30자, 부제는 30자 제한. "rally"는 테니스·배드민턴·피클볼·파델에서 모두 쓰는
> 공통 용어라 이름은 그대로 두고, 종목 범위는 부제와 키워드로 드러낸다.

**영어 (기본)**
- 이름: `Ribatto`
- 부제: `Rally clips for racket sports`
- 키워드: `tennis,badminton,pickleball,padel,rally,highlight,clips,video,editor,shorts`
- 설명:
  > Ribatto turns a 30-minute match — tennis, badminton, pickleball or padel — into the rallies worth watching.
  > Import a video and it listens for racket impacts to find every rally,
  > then cuts clean clips with smooth fades — wide for YouTube, vertical for Reels and Shorts.
  > Merge them into one highlight reel with a tap.
  >
  > • Tennis, badminton, pickleball and padel presets
  > • Wide 16:9 and vertical 9:16 output
  > • Sensitivity control for noisy or quiet courts
  > • Everything runs on your iPhone — no uploads, no account, no subscription
  >
  > Free to try. One-time purchase for unlimited imports.

**한국어**
- 이름: `Ribatto`
- 부제: `라켓 스포츠 랠리 자동 편집`
- 설명:
  > 테니스·배드민턴·피클볼·파델 — 30분 경기 영상에서 볼 만한 랠리만 남깁니다.
  > 타구음을 분석해 랠리를 찾아내고, 앞뒤 여유와 페이드까지 넣어 깔끔한 클립으로 잘라줍니다.
  > 유튜브용 가로, 릴스·쇼츠용 세로를 모두 지원하며, 한 번의 탭으로 하이라이트 합본까지 만듭니다.
  >
  > • 테니스·배드민턴·피클볼·파델 전용 설정
  > • 가로 16:9 / 세로 9:16 자동 전환
  > • 코트 환경에 맞춘 민감도 3단계
  > • 모든 처리는 아이폰 안에서 — 업로드도, 계정도, 구독도 없습니다
  >
  > 무료로 사용해 보고, 마음에 들면 한 번만 결제하세요.

**日本語**
- 이름: `Ribatto`
- 부제: `ラケット競技のラリー自動編集`

## 4. 심사 대응 메모

- **로그인 불필요**: 심사 계정 제공란은 비워도 된다.
- **사진 접근**: `PhotosPicker`로 영상을 고른 뒤, 그 영상을 복사하지 않고 제자리에서
  읽기 위해 `PHPhotoLibrary.requestAuthorization(for: .readWrite)`를 **실제로 호출한다**
  (`Store/SessionStore.swift`). 클립을 사진 앱에 저장할 때도 같은 권한을 쓴다.
  예전 문안("PHPicker only — no permission prompt")은 사실과 달라 5.1.1 반려를 부른다.
  아래 §4-1의 문안을 그대로 쓸 것.
- **IAP 복원 버튼**: 페이월 우상단 `Restore` — 필수 요건이며 이미 구현되어 있다.
- **가격 표기**: 페이월에 "구독 아님, 1회 결제"를 명시했다 (거절 사유 예방).


### 4-1. 심사 정보 메모 (그대로 복사)

```
No account or sign-in is required; the app is fully usable immediately.

Photos access: the app uses PhotosPicker to select a match video, and also
requests Photos permission so it can read the selected video in place (via
PHImageManager) rather than duplicating a multi-gigabyte file into app
storage, and so it can save exported clips back to the library. If access is
denied, import still works through the picker using a local copy.

All video analysis and rendering happen entirely on-device. There is no
server, no analytics, no tracking, and nothing is uploaded.

In-app purchase: "Ribatto Pro" (com.ribatto.pro) is a one-time
non-consumable. It removes the import limit, the watermark and the 720p
export cap, and unlocks player tracking. A Restore button is at the top
right of the paywall. The free tier is fully functional.
```

## 5. 개인정보 처리방침 초안

> **Ribatto Privacy Policy**
> Ribatto does not collect, transmit, or store any personal data.
> All video processing happens entirely on your device. Videos you import,
> the clips created from them, and your settings never leave your iPhone and
> are never sent to us or any third party. We do not use analytics or tracking.
> Purchases are handled by Apple; we never see your payment details.
> Contact: <이메일 주소>

App Store Connect의 **앱 개인정보 보호** 설문에서는 모두 "데이터를 수집하지 않음"을 선택하면 된다.

## 6. 제출 전 최종 점검

- [ ] `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 확인 (현재 1.0 / 1)
- [ ] Release 구성으로 Archive (`Product → Archive`) → Validate → Distribute
- [ ] 실기기에서 최소 3개 이상의 실제 경기 영상으로 감지 품질 확인 ([DEVICE_TESTING.md](DEVICE_TESTING.md))
- [ ] 번들 ID가 App Store Connect와 일치하는지
- [ ] 스크린샷에 실제 UI가 아닌 요소(디바이스 프레임 위조 등)가 없는지
