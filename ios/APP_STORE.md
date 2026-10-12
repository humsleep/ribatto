# App Store 출시 체크리스트

> 순서표는 [RELEASE.md](RELEASE.md)에 있다. 이 문서는 그 안의 단계를 자세히 푼 것이다.

## 0. 준비물

| 항목 | 상태 | 비고 |
|---|---|---|
| Apple Developer Program | ✅ 가입 완료 | 2026-09-01 결제 완료 |
| 앱 아이콘 1024px | ✅ 포함됨 | `Ribatto/Assets.xcassets/AppIcon.appiconset` |
| 스크린샷 6.9" | ✅ 완료 | `marketing/01~05` (2026-09-22 광고 전용 기준으로 다시 만듦) |
| 개인정보 처리방침 URL | ⬜ 필요 | 아래 초안 참고. GitHub Pages/노션 공개 페이지면 충분 |
| 유료 계약(Paid Apps) | 필요 없음 | 인앱 구입이 없다(2026-09-15 광고 전용 전환). 광고 수익은 AdMob 콘솔에서 따로 정산 |
| AdMob 앱·광고 단위 ID | ⬜ 필요 | Release 빌드 설정에 입력([RELEASE.md](RELEASE.md) 4-2). 비면 광고도 패스도 없다 |

## 1. App Store Connect 앱 생성

1. https://appstoreconnect.apple.com → **나의 앱 → +**
2. 플랫폼 iOS, 이름 `Ribatto`, 기본 언어 **English (U.S.)**, 번들 ID 선택, SKU `ribatto-001`

## 2. 인앱 구입 — 없음

2026-09-15에 구매를 코드에서 걷어냈다. **인앱 구입을 등록하지 않는다.**
패스는 리워드 광고를 끝까지 보면 1시간 열린다(`Store/ProPass.swift`).
구매를 되살릴 때의 절차는 git 태그 `pro-iap-snapshot` 시점의 이 문서에 있다.

## 3. 스토어 메타데이터 초안 — ⚠️ 사용하지 말 것 (옛 초안)

> **실제 제출 문안은 [`../marketing/app-store-copy.md`](../marketing/app-store-copy.md) 한 군데다.**
> 아래 초안은 이름·부제·키워드가 그것과 전부 어긋난다(이름 `Ribatto` vs `Ribatto: Rally Clips` 등).
> 두 곳을 다 남겨 두면 제출할 때 어느 쪽을 붙여넣었는지 알 수 없다. 참고용으로만 남긴다.

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
  > Build a vertical reel from your best rallies in a few taps.
  >
  > • Tennis, badminton, pickleball and padel presets
  > • Wide 16:9 and vertical 9:16 output
  > • Sensitivity control for noisy or quiet courts
  > • Everything runs on your iPhone — your video never leaves it, no account
  >
  > Free with ads, nothing to buy. Watch one video ad for a one-hour pass — original quality, no watermark,
  > smart vertical framing — for an hour. Nothing to buy, no subscription.

**한국어**
- 이름: `Ribatto`
- 부제: `라켓 스포츠 랠리 자동 편집`
- 설명:
  > 테니스·배드민턴·피클볼·파델 — 30분 경기 영상에서 볼 만한 랠리만 남깁니다.
  > 타구음을 분석해 랠리를 찾아내고, 앞뒤 여유와 페이드까지 넣어 깔끔한 클립으로 잘라줍니다.
  > 유튜브용 가로, 릴스·쇼츠용 세로를 모두 지원하며, 베스트 랠리를 골라 세로 릴스까지 만듭니다.
  >
  > • 테니스·배드민턴·피클볼·파델 전용 설정
  > • 가로 16:9 / 세로 9:16 자동 전환
  > • 코트 환경에 맞춘 민감도 3단계
  > • 모든 처리는 아이폰 안에서 — 영상은 기기 밖으로 나가지 않고, 계정도 구독도 없습니다
  >
  > 광고와 함께 무료로 쓰세요. 광고 한 편을 끝까지 보면 원본 화질·워터마크 없음·스마트 세로 크롭이 1시간 열립니다.

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
- **구매 없음**: 복원 버튼 요건(3.1.1)이 해당하지 않는다. 패스 시트는 "구매할 것 없음 · 광고 1편 = 1시간"을 적는다.
- **리워드 광고 = 기능 해제**: 광고 시청으로 앱 기능을 여는 것은 3.2.2(x)에서 허용된다(보상형 광고). 3.1.1이 아니다. 결제를 우회하는
  구조가 아니라 판매 자체가 없다는 점을 메모에 적는다.
- **ATT**: 온보딩이 끝난 뒤, 첫 광고 요청 전에 묻는다. 거부해도 비맞춤 광고와 패스 열기가 그대로 동작한다.


### 4-1. 심사 정보 메모 (그대로 복사)

```
Ribatto analyses a racket-sport match video that the user imports from Photos.
The reviewer's device is unlikely to have suitable footage, so please use this
sample: https://humsleep.github.io/apps/ribatto/review/

Steps:
1. Save the sample video to the device's Photos library.
2. Open Ribatto, tap + at the top of "My Matches", then "From Photos".
   On the first import the app asks which sport you play: choose Tennis.
3. Pick the sample. Detection runs automatically with live progress; the best
   rally starts playing as soon as it is found, and clips follow within about a minute.
4. Open a clip to play it, or tap "30-second highlight reel": the vertical reel
   is built at once and can be saved or shared from the result screen.
5. The pass: tap "Get PASS" under the title, then "Watch an ad".

Please note about step 5: review builds request Google's public test ad
units (a sandbox receipt is treated as a pre-release install), so the rewarded
ad plays as a Google test ad labelled "Test mode". Watching it to the end opens
the one-hour pass. App Store installs use live ad units. For reference, the
page above also has the same rally exported both ways: rally-pass.mp4 (full
quality, no watermark, re-framed vertically) and rally-free.mp4 (720p,
watermarked). The pass changes only export quality and framing; every
detection and editing feature is available without it. There are no in-app
purchases of any kind.

No account or sign-in is required.

Photos access: the app uses PhotosPicker to select a match video, and also
requests Photos permission so it can read the selected video in place (via
PHImageManager) rather than duplicating a multi-gigabyte file into app
storage, and so it can save exported clips back to the library. If access is
denied, import still works through the picker using a local copy.

All video analysis and rendering happen entirely on-device, and the video
itself never leaves the device. There is no server of ours and no analytics.
Network use: Google AdMob for ads in the free tier (it receives the
advertising identifier only if the tracking prompt is accepted, plus IP
address and basic device data), and CLGeocoder to turn a video's own GPS tag
into a court name.

There are no in-app purchases. A one-hour pass (original-quality export, no
watermark, no ads, smart vertical crop, player tracking, batch save, clip
merge) opens after watching a rewarded video ad to the end. Without it the app
still runs the whole flow at 720p with a watermark, watching nothing.

Detection works from the sound of racket impacts, so footage without racket
strikes will correctly report that no rallies were found.
```

### 4-2. 2.1 Information Needed 회신 (2026-10-01 요청, 그대로 복사)

신규 개발자 계정이라 받은 정보 요청. **App Store Connect 회신**과 **심사 정보 메모** 두 곳 모두에 붙인다
(메모는 4-1 문안 뒤에 이어 붙인다). 화면 녹화는 실기기에서 찍어 회신에 첨부한다.

```
Thank you for reviewing Ribatto. Answers to each point follow.

1. SCREEN RECORDING
Attached: a screen recording on a physical iPhone running the latest iOS. It
starts by launching the app and shows the typical flow: onboarding, the ad
consent and tracking prompts, importing a match video from Photos, choosing a
sport, automatic rally detection, playing a clip, trimming it, making a
vertical reel and saving it to Photos, then opening the one-hour pass by
watching a rewarded ad from the pass sheet (it shows the user's own clip free
vs. with the pass, with an equal "Not now" that keeps the free export). The app has no accounts (no registration, login or
deletion), no user-generated content shared with other users, and no paid
content: the only gated features open for one hour after a rewarded video ad,
and there are no in-app purchases.

2. PURPOSE AND AUDIENCE
Ribatto is for amateur tennis and other racket-sport players who film their
own matches on a phone. A match recording is mostly dead time: walking,
picking up balls, changing ends. Finding the few rallies worth sharing means
scrubbing through 30-90 minutes of video by hand. Ribatto listens for the
sound of the ball being struck, finds every rally automatically, and cuts each
one into a clip ready for Instagram Reels, YouTube Shorts or TikTok, entirely
on the device. It also keeps a simple season record (rallies, courts, longest
point).

3. SETUP AND MAIN FEATURES
No login is required and there is nothing to configure.
- Sample file: https://humsleep.github.io/apps/ribatto/review/ (save the video
  to Photos).
- Matches tab: tap + > "From Photos" and pick the sample. On first import the
  app asks for the sport: choose Tennis. Detection starts automatically and
  clips appear in about a minute.
- Match screen: the best rally plays at the top; open a clip to play it; the Trim
  button adjusts its length; "30-second highlight reel" builds a vertical reel at
  once (Edit changes rallies, length and aspect); clips can be saved to Photos.
- Reels tab: finished reels. Season tab: statistics.
- Pass: tap "Get PASS" under the "My Matches" title, then "Watch an ad". After the
  rewarded ad ends, export quality, framing and ad-free use are unlocked for
  one hour. Review builds use Google's test ad units, labelled "Test mode".

4. EXTERNAL SERVICES
- Google AdMob (Google Mobile Ads SDK) for banner, interstitial and rewarded
  ads in the free tier, and Google's User Messaging Platform for the consent
  form required in the EEA, UK and Switzerland.
- Apple CLGeocoder, only to turn a video's own GPS tag into a court name.
Everything else uses Apple's on-device frameworks (AVFoundation, Accelerate,
SoundAnalysis, Vision, Photos). There is no server of ours, no account or
authentication service, no payment processor, no analytics service and no
cloud AI service. Videos never leave the device.

5. REGIONAL DIFFERENCES
The app works the same in every region where it is offered. The only
differences are legal ones around ads: users in the EEA, UK and Switzerland see
Google's consent form before any ad is requested, and the tracking prompt
appears where iOS shows it. The interface is available in English, Korean,
Japanese, Spanish, Portuguese, German, French, Italian and Simplified Chinese.
The app is not offered in mainland China.

6. REGULATED INDUSTRY / THIRD-PARTY MATERIAL
Not applicable. The app is not in a regulated industry and contains no
protected third-party content. It only processes videos the user recorded.
Bundled fonts (Anton, Bebas Neue) are under the SIL Open Font License and the
Pow library under MIT; their licenses are shown in the app (gear button at the
top of "My Matches" > Open-source licences).
```

#### 화면 녹화 순서 (실기기, 최신 iOS, 2~4분)

1. 앱을 지웠다가 TestFlight에서 다시 설치한다 — 온보딩·동의·추적 창이 처음부터 나오게
2. 제어 센터 → 화면 기록 시작 → **홈 화면에서 앱 아이콘을 누르는 것부터** 찍는다
3. 인트로 → 온보딩 → (동의 창) → 추적 허용 창
4. + → 사진 보관함에서 → 샘플 영상 → 종목 Tennis → 감지 완료까지 (기다리는 구간은 그대로 둬도 된다)
5. 클립 하나 재생 → 트림 버튼(구간 선택 아이콘)으로 길이 조정 → 닫기 → "30초 하이라이트 릴스" → 결과 화면에서 사진에 저장
6. 무료 상태에서 "사진 앱에 저장" → 패스 제안 시트(무료/패스 비교) → "광고 보고 1시간 패스" → 끝까지 시청
   → "패스가 열렸어요" 토스트 → 릴스가 패스 화질로 다시 만들어지고 저장되는 것까지
7. 릴스 탭·시즌 탭을 잠깐 보여주고 기록 종료

얼굴이 나오지 않는 샘플 영상만 쓴다. 알림이 녹화에 찍히지 않게 방해 금지 모드를 켠다.

## 5. 개인정보 처리방침

공개 문서는 https://humsleep.github.io/apps/ribatto/privacy/ 다(한/영, 원본은 `~/workspace/apps/ribatto/privacy/index.html`). 앱 안의 PrivacyView와 문구를 맞춘다.

App Store Connect **앱 개인정보 보호** 설문은 더 이상 "데이터를 수집하지 않음"이 아니다.
`Ribatto/PrivacyInfo.xcprivacy`와 같게 답한다(모두 **사용자와 연결되지 않음**):

| 데이터 | 추적에 사용 | 목적 |
|---|---|---|
| 식별자 › 기기 ID | 예 | 제3자 광고, 분석 |
| 사용 데이터 › 광고 데이터 | 예 | 제3자 광고, 분석 |
| 사용 데이터 › 제품 상호작용 | 아니요 | 제3자 광고, 분석 |
| 위치 › 대략적 위치 | 아니요 | 제3자 광고 |
| 진단 › 충돌·성능·기타 진단 데이터 | 아니요 | 앱 기능 |

AdMob의 최신 공개 안내(Google "Prepare for Apple's App Store data disclosure")와 다르면 그쪽을 따르고 매니페스트도 같이 고친다.

## 6. 제출 전 최종 점검

- [ ] `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 확인 (현재 1.0 / 1)
- [ ] Release 구성으로 Archive (`Product → Archive`) → Validate → Distribute
- [ ] 실기기에서 최소 3개 이상의 실제 경기 영상으로 감지 품질 확인 ([DEVICE_TESTING.md](DEVICE_TESTING.md))
- [ ] 번들 ID가 App Store Connect와 일치하는지
- [ ] 스크린샷에 실제 UI가 아닌 요소(디바이스 프레임 위조 등)가 없는지 — 2026-09-22 다시 만든 5장
- [ ] Release 빌드에서 리워드 광고가 뜨고 패스가 열리는지(TestFlight — 테스트 기기 등록 후에만 가능)
- [ ] AdMob 콘솔에 GDPR 메시지(EU/UK/스위스)를 게시 — UMP 동의 폼은 코드에 연결돼 있다(AdsManager `gatherConsent`). 메시지가 없으면 폼이 안 뜬다
