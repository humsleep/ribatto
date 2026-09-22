# Ribatto — repo guide

라켓 스포츠 영상에서 랠리를 자동 감지해 릴스/쇼츠 클립을 만드는 온디바이스 앱.

## 이 저장소는 iOS 앱 하나다

`ios/` 가 유일한 제품이다. 예전에 있던 웹 프로토타입(`app/` — Python 서버 + 웹 UI)과
그 생성물(`output/`)은 Swift 포팅이 끝나 2026-09-02에 삭제했다. **웹 서비스 계획 없음.**
로드맵은 iOS 출시 → Android 순.

## 읽지 말 것 (토큰/사고 방지)

- `sample.mov` — **6.6GB**. 절대 Read 금지. 메타데이터가 필요하면 `ios/Tools`의 검증 도구 사용.
- `ios/.build/`, `*.xcuserstate` — 빌드 산출물.

`.claude/settings.json`에서 위 경로 Read를 deny 처리해 뒀다.

## iOS 앱 지도

```
ios/Ribatto/
  RibattoApp.swift        진입점 · 온보딩 분기 · 4탭(라이브러리/모든 클립/릴스/시즌)
  Models.swift             Sport·Sensitivity·AspectSetting·Session·RallySegment·CaptionSettings
  L10n.swift               인앱 다국어 9종 (en 기본 / ko ja es pt de fr it zh-Hans) — 문자열은 9곳 모두 추가
                           s()는 없는 키를 영어로 폴백한다. 키 누락 검사는 세션 기록의 파서 스크립트 참고
  CaptionText.swift        캡션 토큰 {rank} {shots} {tempo} {duration} {rally} {place} {date} {sport} → 렌더 직전 클립별 문구로 치환(SessionStore)
                           없앤 토큰 {score} {opponent}는 옛 캡션에 남아 있을 수 있어 빈 문자열로 지운다(`retired`)
  Engine/                  ★ 핵심 로직, 실측 검증됨
    AudioLoader.swift      영상 → 16kHz 모노 샘플
    RallyDetector.swift    타구음 감지 (vDSP FFT + 2단 임계값)
                           + 랠리 점수화: 타구수 0.40 / 환호(voiceE 급등) 0.35 / 길이 0.25
                           RallySegment.hitTimes(타구 시각)·cheer(환호 비율, 3.5↑이면 🔥 배지·"환호 큰 순" 정렬)도 보존
                           즐겨찾기는 감지가 아니라 사용자 입력(RallySegment.favourite)
    SoundCheck.swift       감지 직후 iOS 내장 소리 분류기(SoundAnalysis .version1, 3초 창·겹침 0.9 — 0.5는 창 위치에 따라 판정이 뒤집혔다)로 랠리마다 두 번째 판정
                           racketConf < 0.15 && 타구 ≤ 5 → 버림(전부 버려지면 적용 안 함) · < 0.35 → 점수 절반
                           crowdConf(마지막 타 뒤 0.5~4초의 환호·박수·웃음)가 환호 점수와 🔥 배지(≥0.3)를 대신한다
                           옛 세션은 `reaction`이 cheer 비율을 같은 눈금으로 환산해 폴백. 분류기가 못 돌면 감지 결과 그대로
                           기준값은 sample.mov 한 녹화(박수·볼머신·실내 없음)로 잡았다 — 그런 녹화가 생기면 다시 잴 것
    SmartCrop.swift        세로 크롭용 관심영역 추적 — 모션 기반(사람 인식 아님). 설계 이유는 파일 주석 참고
    PlayerTracker.swift    특정 인물 추적 — Vision 시드 추적 + 재획득 + SmartCrop 모션 폴백. Session.targetPlayer 있을 때 사용
                           Keyframe.box(디스플레이 좌표)를 채워 ClipExporter의 재프레이밍 입력이 됨
    ClipExporter.swift     클립 컷 · 화면비 · 페이드 · 워터마크/캡션 번인
                           인코딩은 리더/라이터 한 패스(`encode`). 크롭 합성 프레임에 오버레이를 얹어 바로 쓴다
                           두 펌프는 `PumpGate`로 한 번만 재개된다. 한쪽이 실패하면 양쪽을 깨우고, 워치독이 0.5초마다
                           writer.status를 본다 — 라이터가 append 사이에 실패하면 두 입력 모두 영영 ready가 되지 않아
                           타임아웃도 없이 멈춘다(2026-09-18 시뮬레이터에서 재현). 한계 시간은 클립 길이×30(최소 120초)
                           비트레이트는 해상도·fps에서 계산(`bitrate`), Pro는 기기에서만 HEVC(시뮬레이터는 H.264)
                           실패하면 옛 2패스 경로(`legacyEncode`)로 떨어진다 — 조용히 떨어지므로 용량이 안 줄면 이걸 의심할 것
                           측정(2026-09-16, 18초 랠리): 무료 720p 9.50 → 2.84 Mbps · 22.0 → 6.4MB · 3.2초
    Stabilizer.swift       Vision 영상 정합으로 카메라 흔들림 보정. **연결 안 함** — 가진 녹화가 전부 고정 거치라
                           랠리 안 프레임 간 이동이 0이었다. 핸드헬드 영상이 생기면 그때 붙일 것(파일 주석 참고)
                           워터마크(무료)는 Bebas 대문자 + 얇은 검정 외곽선. 흰 글자만으로는 밝은 하늘에서 사라진다
                           크롭은 `transform(window:)` 하나로 통일 — 소스의 사각 영역을 출력 프레임에 매핑
                           `reframed(...)`: 추적 박스가 있으면 피사체에 맞춰 축소·이동(최대 2배 줌), 없으면 기존 전체높이 창
    ReelBuilder.swift      여러 랠리를 하나의 세로 릴스로 (길이캡: reels 90s/shorts 60s/tiktok 180s)
                           ReelPace: full/impact(마지막 6초)/hook(위닝샷 0.8초 + 전체)
    FrameSequence.swift    AVAssetReader 순차 디코드 (2.1ms/프레임, 시크는 45ms). PlayerTracker 전용
                           축소는 renderSize만으로 안 된다 — 레이어 transform에 배율을 곱해야 한다. 빠뜨리면 4K 프레임의
                           좌상단 1280×720(하늘·나무)만 넘어와 추적 전체가 엉뚱한 화면에서 돈다(2026-09-15 수정, 가까운 선수 유지율 89.8→97.7%)
    PersonDetector.swift   RF-DETR Nano(Apache-2.0, 6bit 20MB) 사람 검출. PlayerTracker 2단계 재획득용이지만 `useDetector = false`
                           이득이 작아(97.7→98.4%) 모델을 번들에서 뺐다. 다시 만들기: ios/Tools/rfdetr/make_model.py
                           켤 때는 모델을 Ribatto/Engine/에 넣고 LicensesView에 Apache-2.0 고지를 추가할 것
                           SmartCrop은 의도적으로 시크 유지 — 파일 주석 참고
    HighlightMerger.swift  무재인코딩 병합 우선. 클립 병합·릴스가 쓴다
                           (세션 전체 "하이라이트 합본"은 2026-09-15 삭제 — 릴스와 역할이 겹쳤다. 옛 highlight.mp4는 load가 지운다)
    VideoProbe.swift       메타데이터 + 포스터
  Store/
    SessionStore.swift     세션 영속화 + 처리 파이프라인 (process → render). 모든 상태의 소유자
                           클립이 이미 있으면 재렌더는 clips.staging에 만들고 전부 끝난 뒤에 바꿔치기한다(`swapInStaged`).
                           감지 결과도 그때 함께 기록된다 — 중간에 실패하면 옛 클립과 옛 랠리가 그대로 남는다
                           storage(of:)/clearClipFiles: 세션별 용량과 "클립 파일만 비우기"(기록은 남는다)
    ProPass.swift          isPro 판정. 리워드 광고를 끝까지 보면 grant()로 1시간 패스(passUntil 영속, 만료 타이머로 즉시 강등)
                           Debug 전용 debugPro 스위치(DebugProSheet). 구매는 없다
    AdsManager.swift       AdMob(SPM 12.x). 무료 등급의 배너(탭 바 아래, RibattoApp) + 전면광고(렌더·릴스 완료 직후, 3분 간격)
                           + 리워드 영상(ProPassView의 "광고 보기") → ProPass.grant()로 1시간 Pro 패스
                           ATT 프롬프트 → SDK 시작 순서. 온보딩이 끝난 뒤에만 시작한다
                           앱 ID는 빌드 설정 GAD_APPLICATION_ID(Debug=구글 테스트 ID, Release=빈값), 단위 ID는 Unit(Debug만 테스트값)
                           `configured`가 false면 SDK를 아예 시작하지 않는다 — Release에 ID를 안 넣으면 광고 없이 나가고 크래시는 없다
  Views/                   SessionDetailView(설정 카드는 클립이 생기면 한 줄 요약으로 접힌다) · ReelSheet(릴스 편집·순서·베스트N·pace) · ClipViews
                           TrimSheet(클립별 길이 조정 → 해당 클립만 재렌더. 썸네일 스트립은 TrimmerBar+PryntTrimmerView,
                           타구 위치를 눈금으로 찍고 VoiceOver용 스테퍼를 함께 둔다) · TargetPlayerSheet(추적 대상 선택)
                           LibraryView · StatsView · CaptionEditorView · ProPassView(Pro 안내 + 리워드 광고 버튼) 등
                           SortMenu.swift: ClipSort(6종 정렬) + 정렬 메뉴 — 세션 화면·모든클립 탭 공용
                           AddRallySheet(놓친 랠리 수동 추가) · PrivacyView(앱 내 개인정보 설명 — 코드 동작과 항상 일치시킬 것)
                           ReelsView: 완성된 릴스 보관함. 파일은 sessions/reels/ 에 id.mp4 + id.jpg + id.json(ReelInfo)
                           OrientationGate.swift: 세로 고정 + 재생 화면만 가로 허용
```

## Pro 티어 경계 (isPro 로 게이팅)

**인앱 구입은 없다.** 2026-09-15에 StoreKit·페이월·복원·오너 패스프레이즈를 코드에서 걷어냈다(광고 전용 운영).
나중에 구매를 되살릴 때는 git 태그 `pro-iap-snapshot`의 `PurchaseManager.swift`·`PaywallView.swift`·`Ribatto.storekit`에서 가져온다.

무료: 광고(배너+전면) · 720p · 워터마크 · 중앙 고정 크롭.
Pro: **리워드 광고를 끝까지 보면 `ProPass.duration`(1시간) 동안** 열린다. `isPro = pass.active`(Debug는 `debugPro`도).
     렌더는 시작 시점의 tier를 굽는다 — 패스 중 만든 클립은 끝난 뒤에도 원본화질·워터마크 없음 그대로다.
     광고 없음 · 원본화질(가로4K/세로1080p) · 워터마크 없음 · 일괄저장 · 클립병합 · **스마트 세로 크롭**(SmartCrop) · **특정 인물 추적**(PlayerTracker, TargetPlayerSheet에서 선택)
캡션 자동 문구(토큰)·환호 배지·즐겨찾기·랠리 추가/분할은 무료. 일괄저장은 2개 이상 선택 시 Pro.
점수 기능(스코어보드·승자 태깅·타구 카운터 번인·타구 수 보정·상대 태그/전적)은 2026-09-15에 UI 정리로 삭제했다.
옛 세션 JSON의 해당 키는 디코딩 때 무시된다.

## 마케팅 자산

`marketing/` — 앱스토어 스크린샷 5장(1320x2868, 6.9인치 규격)과 등록 문구(`app-store-copy.md`).
스크린샷은 `ios/Tools/make_screenshots.swift`가 만든다. 실기기 캡처를 헤드라인과 함께 합성하는 방식이며,
캡처를 갱신하려면 시뮬레이터 화면을 `xcrun simctl io <udid> screenshot`으로 다시 찍어 넣고 도구를 재실행한다.

```bash
swift Tools/make_screenshots.swift <캡처폴더> <출력폴더>   # ios/ 에서 실행
```

스크린샷 속 세션 이름·코트는 데모용으로 채운 값이다. 실제 사용자 데이터가 아니다.
2026-09-22에 광고 전용 기준으로 다시 만들었다: 히어로(Pro 9:16 클립) · 라이브러리 · 세션 · 릴스 만들기 · 시즌.
캡처는 영어 UI + Debug Pro(테스트 광고 배너가 안 찍히게) + `simctl status_bar override --time 9:41`. 히어로는 `hero.jpg`로 넣는다.

## Pro 테스트

Debug 빌드에서 등급 알약을 1.2초 길게 누르면 `DebugProSheet`(Force Pro · 패스 부여/종료)가 열린다.
리워드 광고는 Debug에서 구글 테스트 단위라 시뮬레이터에서도 끝까지 보면 실제로 패스가 열린다.

## 빌드 / 실행

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project ios/Ribatto.xcodeproj -scheme Ribatto -destination 'platform=iOS Simulator,name=iPhone 17' build
```

이 Mac은 `xcode-select`가 Command Line Tools를 가리켜서 `DEVELOPER_DIR` 접두가 필요하다.

## 작업 규칙

- 코드 삭제·수정 전에 **반드시 사용자에게 확인**받는다.
- git 저장소다(main). 커밋은 사용자가 요청할 때만 한다.
- 문자열 추가 시 L10n.swift의 9개 언어 모두. %d·%@ 자리표시자는 원문과 개수·순서가 같아야 한다.
- `DebugProSheet`는 파일 전체가 `#if DEBUG`. 릴리스에 숨은 기능이 있으면 심사 2.3.1 거절 사유다.
- 긴 렌더는 `beginBackgroundTask`로 보호된다. `.failed`는 진행 중이 아니라 메시지이므로 busy 판정은 `isBusy`를 쓴다.
- 재렌더는 원본을 먼저 확보한 뒤 기존 클립을 지운다. 순서를 되돌리면 원본이 사라진 세션의 클립이 전부 날아간다.
- 가져오기는 마지막에 고른 종목으로 감지한다(`SessionStore.lastSport`, 기본값 없음 → 첫 가져오기 전에 묻는다).
  사진·파일 다중 선택은 전부 등록한 뒤 `processQueued`가 한 건씩 감지한다. 동시에 돌리면 원본을 여러 개 디코딩한다.
- 앱에서 찍은 녹화는 먼저 사진 앱에 저장하고 그 자산을 참조한다. 권한이 없을 때만 앱 안에 복사본을 둔다.
- 감지 결과가 0개인 것은 "완료"가 아니다. `apply`는 빈 배열도 재감지 대상으로 본다. 빼면 재감지 버튼이 죽는다.
- 릴스 파일명은 UUID다. 설정 조합으로 이름을 만들면 같은 설정의 다음 릴스가 이전 것을 덮어쓴다.
- 릴스 사이드카는 자기 랠리의 출처(`ReelInfo.sources`)를 적어 둔다. 그래야 완성된 릴스를 자막만 바꿔 다시 만들 수 있다.
  자막은 픽셀에 구워지므로 바꾸려면 재렌더 외에 방법이 없다. 재렌더는 새 id로 만든 뒤 성공했을 때만 옛 릴스를 지운다 —
  실패가 완성된 영상을 가져가면 안 된다.
  이 필드가 없는 옛 릴스는 `recoverSources`가 되찾는다. 세션마다 같은 설정으로 다시 계획해 보고
  랠리 수와 길이가 밀리초까지 맞는 세션을 찾는 방식이다(`ReelBuilder.plan`은 파일을 건드리지 않는다).
  같은 모양의 세션은 같은 길이로 계획되므로 사이드카의 코트 이름으로 먼저 좁히고, 그래도 둘 이상이면 포기한다 —
  찍는 방식이 매번 같은 사용자에게는 같은 길이가 예외가 아니라 기본값이다.
- 탭 제목은 네비게이션 바가 아니라 내용 안에서 그린다(`TabHeader`). 큰 제목 바는 버튼에 한 줄, 제목에 또 한 줄을 쓰는데
  버튼이 없는 탭에서는 첫 줄이 순수한 공백이다. 검색창도 `.searchable`이 아니라 `SearchField`로 직접 그린다.
- 캡션은 프레임 폭에 맞춰 자동 축소된다(`captionImage`). 크기는 높이 기준이라 세로 크롭에서 폭이 넘칠 수 있다.
- 워터마크는 자막을 피해 위로 올라간다(`place(clearOf:)`). 고정 위치로 두면 기본 자막 위에 겹쳐 한 단어처럼 읽힌다.
  그래서 워터마크 검증은 고정 사각형이 아니라 OCR로 읽는다. 자막 높이에 따라 위치가 달라져 고정 사각형은 빈 곳을 재게 된다.
- PlayerTracker 2단계 재획득도 1단계와 같은 크기 검사를 거친다. 빼면 카메라 앞 다른 사람에게 붙잡혀 랠리 끝까지 못 돌아온다.
- 내보내기 구간은 실제 에셋 길이로 자른다. 영상 밖에서 시작하면 AVAssetExportSession이 실패가 아니라 무한 대기한다.
- 타구 수는 표시·정렬·통계·{shots} 자막용이다. 옆 코트 소리가 섞이면 틀릴 수 있어서 영상에 숫자를 굽는 기능(카운터)은 없앴다.
- 지원 언어는 `ios/Ribatto-Info.plist`의 `CFBundleLocalizations`에 선언한다. 빌드 설정
  `INFOPLIST_KEY_CFBundleLocalizations`로는 안 된다 — 생성기가 아는 키만 반영해서 조용히 사라진다.
  실제로 두 configuration 모두 선언돼 있었는데 빌드된 Info.plist에는 없었다. 선언이 빠지면 App Store
  제품 페이지에 영어 하나만 표시된다. 기기 언어 시드는 `Locale.preferredLanguages` 대신
  `AppleLanguages` 원본을 읽어 이 선언과 무관하게 동작한다(`seedLanguageFromDevice`).
  이 파일은 그 키 하나 때문에 존재하고, 나머지 키는 여전히 생성된 뒤 여기에 병합된다.
- 오버레이 번인 결과를 원본 자리로 옮기는 데 실패하면 던진다. 삼키면 워터마크 없는 무료 클립이 나간다.
- 하나의 `AVAssetReader`에 영상·오디오 출력을 달았으면 **동시에** 비운다. 영상을 끝까지 뽑고 오디오를 뽑으면
  오디오 큐가 차는 순간 리더가 영상 공급을 멈춰 영영 끝나지 않는다(타임아웃도 없다).
- NextLevelSessionExporter는 2026-09-16에 붙였다가 걷어냈다. 1.0.1에서 오디오 설정·구간·오버레이를 모두 빼도
  "AVAssetWriterInput ... status is 0"로 죽거나 콜백이 오지 않는다. 다시 붙이지 말 것.
- 전면광고는 세션 화면이 앞에 있고(`destination == nil`) 그 화면이 화면에 있을 때만 띄운다(`onScreen`).
  탭을 옮긴 뒤 렌더가 끝나면 다른 탭 위로 광고가 덮인다. 릴스 시트는 광고 전에 재생을 멈춘다. 트림·추적 재지정·랠리 나누기도 같은 렌더
  완료 신호를 내보내서, 확인 없이 띄우면 편집 시트 위로 광고가 덮인다.
- 세로 고정이다(OrientationGate + AppDelegate). 가로는 클립·하이라이트 재생 화면만, 그것도 가로 영상일 때만 허용한다.
  병합 재생(HighlightPlayerSheet)도 세션의 `renderedOrientation`을 받아 같은 판정을 한다. 무조건 허용하면 세로 영상이 옆으로 눕는다.
  `.allowsLandscape()`는 시트 최상위에 붙인다. 세로/가로 레이아웃 분기 안쪽에 붙이면 전환 순간 사라지는 쪽의 onDisappear가 권한을 도로 거둔다.
  시트가 떠 있을 때는 최상위 presented VC에 setNeedsUpdateOfSupportedInterfaceOrientations를 보내야 한다. 루트만 갱신하면 반영되지 않는다.
- Pro 시트(ProPassView)의 광고 버튼 블록은 접근성 크기에서 하단 고정을 풀고 스크롤에 넣는다. 고정하면 바가 화면을 통째로 먹어 기능 목록에 닿지 못한다.
- 접근성 큰 글씨에서는 설정 행이 세로로 쌓인다(`settingRows`). 가로 배치를 강제하면 AX5에서 종목명이 한 글자로 잘린다.
  같은 규칙이 시즌 기록·코트 행에도 적용된다(`statRow`). 좌우 배치를 고집하면 아이콘이 글자를 덮거나 이름이 두 글자로 잘린다.
- 세션 설정 카드는 감지 전·감지 0개·미적용 변경·원본 없음일 때 강제로 펼친다(`forced`). 그 외에는 접힌 요약에서 사용자가 연다.
  접힌 상태에서 적용 버튼이 숨으므로, 설정을 바꾸면 `hasPendingChanges`로 곧바로 펼쳐져야 한다.
- Pow(MIT, SPM)는 작은 반응 효과에만 쓴다. 라이선스 전문은 `Pow-MIT.txt`로 번들되어 LicensesView에 나온다 — 빼면 MIT 고지 의무 위반이다.
- 장식 요소(정렬 칩, 썸네일 배지, 차트 축 라벨)는 `dynamicTypeSize(...)`로 상한을 둔다. 두면 한 글자씩 줄바꿈되어 화면을 삼킨다.
  클립 카드의 시각·타구수도 같다. 격자가 폭을 고정하므로 상한이 없으면 "00:02–0…"으로 잘린다.
  행 앞의 SF Symbol도 마찬가지다. 글리프는 Dynamic Type을 따라 커지는데 `frame(width:)` 칸은 안 커져서,
  상한이 없으면 칸 밖으로 그려져 옆 글자를 덮는다(`StatsView.record`/`statRow`).
- 볼트(액센트)는 **누를 수 있는 것과 현재 선택**에만 쓴다. 값·상태 라벨·목록 장식 아이콘은 흰색이나 보조색이다.
  수치와 글리프까지 액센트로 칠하면 정작 눌러야 할 버튼을 구분할 방법이 없어진다. 같은 이유로 `ProBadge`는
  채우지 않고 테두리+연한 배경이다 — 솔리드 볼트 캡슐은 주 버튼의 모양이라 라벨이 버튼처럼 읽힌다.
- 탭 헤더는 접근성 크기에서 제목과 동작을 세로로 쌓는다(`TabHeader`). 한 줄을 나눠 가지면 긴 제목에 남는 폭이 없어
  독일어 "Meine Matches"가 "Mein…"이 되고 버튼이 "Auswä…"가 된다. 같은 이유로 "모든 클립"의 개수 라벨도 정렬 칩과
  줄을 나누지 않는다 — 나누면 "Clips"가 "Clip / s"로 끊긴다.
- 빈 화면은 `EmptyStateBox`로 감싼다. 공간을 채우게만 하면 콘텐츠가 화면보다 길어질 때 SwiftUI가 넘치는 대신
  글자를 잘라낸다. 새로 설치한 사용자가 처음 보는 화면이 "Ancora nessuna parti…"였다. 상자는 짧으면 가운데,
  길면 스크롤이고 떠 있는 탭 바만큼(62pt) 여백을 준다.
- 앞 아이콘과 뒤 글리프(연필·체크·화살표)가 한 줄을 나눠 가지면 접근성 크기에서 남는 폭이 한 단어보다 좁다.
  값이 폭을 갖도록 글리프를 글에 흘려넣거나(`editableRow`) 별도 줄로 올린다(`selectableRow`, 캡션 행).
  "Wednesday group"·"Instagram Reels"·"Caption"이 각각 단어 중간에서 끊겼다.
- 행 높이 상수는 `@ScaledMetric`으로 둔다. ReelSheet의 52pt 고정 때문에 큰 글씨에서 4개 중 1개만 보였다.
- 한 번만 보여줄 힌트는 `@State`가 아니라 `@AppStorage`에 둔다. 회전은 뷰를 새로 만들기 때문에 화면을 돌릴 때마다 힌트가 되살아난다.
- 시트는 스크롤 컨테이너 안에 둔다. TrimSheet은 고정 스택이라 큰 글씨에서 영상이 위로, 적용 버튼이 아래로 잘려 나갔다.
- 선택 동작 바는 스크롤 끝이 아니라 `safeAreaInset`으로 화면에 고정한다.
  목록 끝에 두면 위쪽 클립 두 개를 고른 사용자가 나머지를 다 지나야 무엇을 할 수 있는지 알게 된다.
- 온보딩 페이지 점은 TabView 기본 인디케이터(`.always`)가 아니라 직접 그려 페이지 아래에 둔다.
  기본 인디케이터는 스크롤 위에 떠서 큰 글씨일 때 문장 한가운데를 덮는다.
- 화면의 유일한 내용이 플레이어라면 `AVPlayer`를 `onAppear`가 아니라 init에서 만든다.
  첫 레이아웃에서 nil이면 NavigationStack이 배치할 것이 없어 시트가 제목까지 통째로 빈 채로 뜨고, 플레이어가 생겨도 그대로 남는다.
- "업로드 없음"이라고 쓰지 말 것. PlaceLookup이 좌표를 애플 지오코더로 보낸다. 문구는 "영상은 기기 밖으로 나가지 않는다"로.
  "외부 SDK 없음·광고 없음"도 더는 사실이 아니다. AdMob이 광고 식별자·IP를 보낸다. PrivacyView의 p_ads_d와 docs/privacy.html이 이를 적는다.
- 전면광고는 렌더가 **끝난 직후**만이다(SessionDetailView·ReelSheet의 onChange). 플레이어·편집 시트·가져오기 도중에는 넣지 않는다.
  `.failed`는 결과가 아니라 메시지이므로 광고를 얹지 않는다.
- 리워드 광고를 못 불러오는 빌드(Release에 광고 ID 없음)에서는 ProPassView가 버튼 대신 "지금은 광고를 불러올 수 없음"을 보여준다.
  불러오기에 실패하면 10초·30초 뒤 두 번 자동 재시도하고, 그래도 안 되면 "다시 시도" 버튼을 준다. 영원히 도는 스피너 금지 —
  리워드 광고가 Pro로 가는 유일한 입구다. 패스 중에도 리워드는 계속 로드한다(광고 한 편 더 = 1시간 연장).
- 패스가 끝난 뒤 Pro로 만든 세션에 적용을 누르면 "무료 화질로 다시 만듭니다" 확인을 먼저 띄운다(SessionDetailView).
- EEA 동의는 UMP(`UserMessagingPlatform`, GoogleMobileAds가 끌고 오는 패키지)로 받는다. 동의 → ATT → SDK 시작 순서이고,
  `canRequestAds`가 false면 SDK를 시작하지 않는다. 동의 재설정 진입점은 라이브러리 지구본 메뉴에 있다(필요한 지역에서만 보인다).
  AdMob 콘솔에 GDPR 메시지를 만들어 두지 않으면 폼이 뜨지 않는다.
- `PrivacyInfo.xcprivacy`는 NSPrivacyTracking true + AdMob이 모으는 항목을 적는다. NSPrivacyTrackingDomains는 비워 둔다 —
  여기에 도메인을 적으면 ATT 거부 시 그 도메인이 차단돼 비맞춤 광고와 리워드까지 끊긴다. App Store Connect 설문은 APP_STORE.md §5 표와 같게.
