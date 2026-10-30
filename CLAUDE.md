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
  RibattoApp.swift        진입점 · 온보딩 분기 · 3탭(라이브러리/릴스/시즌). "모든 클립" 탭은 2026-10-11 삭제(세션 격자와 겹쳤다)
  Models.swift             Sport·Sensitivity·AspectSetting·Session·RallySegment·CaptionSettings
  L10n.swift               인앱 다국어 9종 (en 기본 / ko ja es pt de fr it zh-Hans) — 문자열은 9곳 모두 추가
                           s()는 없는 키를 영어로 폴백한다. 키 누락 검사는 세션 기록의 파서 스크립트 참고
  CaptionText.swift        캡션 토큰 {rank} {shots} {tempo} {duration} {rally} {place} {date} {sport} → 렌더 직전 클립별 문구로 치환(SessionStore)
                           없앤 토큰 {score} {opponent}는 옛 캡션에 남아 있을 수 있어 빈 문자열로 지운다(`retired`)
  Engine/                  ★ 핵심 로직, 실측 검증됨
    AudioLoader.swift      영상 → 16kHz 모노 샘플. 선택적 progress 콜백(진행률 + 300칸 음량 엔벨로프, 1%·0.25초 단위).
                           길이가 NaN·0·1초 미만이면 엔벨로프를 만들지 않는다 — 칸 크기가 1이 되어 샘플 배열만큼 커진다
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
                           2026-10-12 H.264 0.12 → 0.22 bit/px(인스타 재압축에 뭉갬). 시뮬레이터 무료 릴스 4.5 Mbps. HEVC(패스·기기)는 그대로
                           편집(1.2, 전부 무료): `ClipEdit`(Session.edit) = 색감 프리셋(`graded`, 오버레이 아래) · 세로 배경 블러/검정(`blackFilled`) ·
                           경기 소리 1/0.4/0. RenderStamp·needsRerender가 비교한다. 클립별 속도(RallySegment.speed, TrimSheet 0.5–2×)는
                           완성 파일을 한 번 더 인코딩하는 `retime`(피치 유지). 릴스는 속도를 무시하고 세션의 ClipEdit만 따른다
                           클립별 보정(2026-10-30): `RallySegment.edit`(nil = 경기 것을 따름)가 세션 ClipEdit보다 우선한다. 렌더 루프·`rerenderClip` 둘 다.
                           RenderStamp에는 넣지 않는다(속도처럼 그 클립만 다시 만든다). "모든 클립에 적용"(`useLookForAll`)은 세션 edit을 바꾸고
                           클립별 값을 지운 뒤, 적용이 전체 재렌더를 할 거면 맡기고 아니면 덮어썼던 클립만 다시 만든다
                           편집 시트(TrimSheet)는 원본 미리보기에 `graded`를 videoComposition으로 입혀 색감을 바로 보여 준다
                           자막·키프레임(2026-10-30, 무료): `RallySegment.subtitles`(구간별 CaptionSettings, CaptionEditorView `tokens: false`로 편집)·
                           `zoomKeys`(줌·중심, smoothstep 보간 `ZoomKey.at`). 시간은 **원본 초** — 트림해도 그 순간에 남고 나누기는 양쪽에 복사.
                           export가 segment에서 직접 읽는다(배관 없음). 줌은 채움·색감 뒤·워터마크/자막 앞(`move`), 자막은 훅과 같은 `timed`.
                           릴스는 새 RallySegment를 만들므로 둘 다 안 따른다. 미리보기 줌은 원본 프레임 기준이라 세로 클립에선 근사치
    Stabilizer.swift       Vision 영상 정합으로 카메라 흔들림 보정. **연결 안 함** — 가진 녹화가 전부 고정 거치라
                           랠리 안 프레임 간 이동이 0이었다. 핸드헬드 영상이 생기면 그때 붙일 것(파일 주석 참고)
                           워터마크(무료)는 Bebas 대문자 + 얇은 검정 외곽선. 흰 글자만으로는 밝은 하늘에서 사라진다
                           크롭은 `transform(window:)` 하나로 통일 — 소스의 사각 영역을 출력 프레임에 매핑
                           `reframed(...)`: 추적 박스가 있으면 피사체에 맞춰 축소·이동(최대 2배 줌), 없으면 기존 전체높이 창
                           세로(9:16·4:5) 출력에 스마트 크롭을 안 쓰면 `blurFilled`: 원본 전체를 폭에 맞춰 가운데 두고
                           위아래는 같은 프레임을 1/4 크기로 블러·25% 어둡게 깔아 채운다(2026-10-11). 중앙 크롭은 선수가
                           가장자리에서 잘리고 화면 절반이 하늘이라 그대로 올릴 수 없었다. Mac 18초 1080p 2.84→2.89초, 기기 미측정
    ReelBuilder.swift      여러 랠리를 하나의 세로 릴스로 (길이캡: reels 90s/shorts 60s/tiktok 180s — UI는 reels 고정)
                           배경 음악은 2026-10-28에 넣었다가 뺐다(인스타가 라이선스 없는 음원을 음소거·노출 축소). 되살리려면 fdf656d의 `addMusic`
                           ReelPace: full/impact(마지막 6초)/hook(위닝샷 0.8초 + 전체, 티저는 마지막 타구에서 끝)
                           릴스의 랠리는 `RallySegment.playTrimmed`로 첫 타구 0.5초 전~마지막 타구 1.5초 뒤만 쓴다(타구 2개 미만은 그대로).
                           클립 원본은 자르지 않는다. 사이드카 `sources`에는 실제로 쓴 구간을 적어 자막만 다시 만들기가 같은 릴스를 낸다
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
    AdsManager.swift       AdMob(SPM 12.x). 무료 등급의 배너 + 전면광고(3분 간격). 전면은 완료 직후가 아니라 "빚"으로 미룬다:
                           렌더·릴스가 끝나면 `markInterstitialDue()`, 사용자가 결과를 보고 시트를 닫을 때 `showPendingInterstitial()`.
                           10분 만료·패스 시작 시 해제·다음 런루프에 세로일 때만(2026-10-11). 결과(클립·병합·릴스) 시트를 닫을 때만 띄운다 —
                           설정·캡션·패스 시트를 닫자마자 뜨면 AdMob이 말하는 "예상치 못한 전면광고"다(2026-10-12)
                           배너는 하나(`banner`)를 세 탭이 나눠 쓴다. 슬롯은 `bannerLoaded`(광고가 **실제로 실림**) 뒤에만 열린다 —
                           SDK 시작 시점에 높이를 예약하면 no-fill 동안 탭 바 밑에 빈 띠가 남는다(2026-09-23 TestFlight에서 확인)
                           `.adBanner()`는 각 탭의 **NavigationStack 안쪽** 루트 VStack에 단다(+ 푸시되는 SessionDetailView에도).
                           NavigationStack 바깥이나 TabView에 달면 안쪽 스크롤뷰까지 인셋이 닿지 않아 광고가 목록 마지막
                           63pt를 **덮고** 고정 선택 바를 잘라 먹는다(2026-09-23 실측). 고정 바의 하단 여백은 8pt다 —
                           safeAreaInset은 탭 바 안전영역을 이미 받으므로 62pt를 또 주면 두 번 띄운다
                           `AdBannerHost`가 창에 들어온 컨테이너로 뷰를 옮긴다(선택 안 된 탭은 창에서 빠진다)
                           로드 실패는 30초→5분 백오프로 재요청. 한 번이라도 실린 뒤의 갱신 실패로는 슬롯을 닫지 않는다(`bannerFilled`) —
                           닫으면 보던 화면이 63pt 튄다. 패스가 시작되면 `banner`를 **해제**한다. 창 없는 뷰가 계속 갱신되면
                           아무도 못 본 노출이 잡힌다(무효 트래픽)
                           `refreshShowing()`이 showing 전이를 한 곳에서 처리한다 — false→true면 배너·전면을 다시 요청하고,
                           true→false면 배너를 버린다. 로드 호출을 refreshShowing보다 **먼저** 두면 showing이 낡아 전부 조용히 반환한다
                           + 리워드 영상(ProPassView의 "광고 보기") → ProPass.grant()로 1시간 Pro 패스
                           동의 → ATT 프롬프트 → SDK 시작 순서. 온보딩이 끝난 뒤에만 시작한다
                           `started`는 SDK가 **실제로 올라간 뒤에만** 켠다(진행 중 중복 방지는 `starting`). 동의 관문 앞에서 켜면
                           첫 실행 때 동의 조회가 한 번 실패하는 것만으로 배너·전면·리워드가 모두 죽고, 리워드가 유일한 Pro 입구라
                           강제 종료 전까지 복구가 없다. 포그라운드 복귀 때 `retryIfNeverStarted()`로 다시 시도한다
                           전면광고는 `interstitial`이 비면 그 자리에서 다시 불러온다. 첫 로드 실패로 세션 내내 전면이 사라졌었다
                           단위 ID는 `Unit.Test`(구글 공개 테스트)와 `Unit.Live`(실제)로 나뉘고, **런타임에** 고른다(`distribution`).
                           App Store 설치만 Live를 쓴다. TestFlight·Xcode 설치·Ad-hoc은 전부 Test로 떨어진다.
                           `#if DEBUG`만 봐서는 안 된다 — TestFlight도 Release 빌드라 실제 단위를 요청하게 되고,
                           AdMob은 미게시 앱에 광고를 주지 않아 아무것도 안 뜬다(2026-09-26 확인). 게시된 뒤에는 더 나쁘다:
                           개발자가 테스트하며 누른 광고가 무효 트래픽으로 잡혀 계정이 정지될 수 있다.
                           판별: 시뮬레이터·DEBUG → debug · `embedded.mobileprovision` 있으면 → debug ·
                           영수증이 `sandboxReceipt`면 → testflight · 그 외 → appstore.
                           FC Scope(`~/workspace/fcscope-ios/FCScope/Core/Config.swift`)가 같은 계정에서 쓰는 방식을 가져왔다.
                           개발 설치(debug)에서만 패스 화면에 주황색 "TEST ADS — debug install"이 뜬다. TestFlight에서는 숨긴다 —
                           심사 설치도 sandboxReceipt라 심사자에게 디버그 문구가 보였을 것이다(2026-09-28). 심사자는 구글 테스트 광고로 패스를 연다
                           앱 ID는 빌드 설정 GAD_APPLICATION_ID(Debug=구글 테스트 ID, Release=실제 ID, 2026-09-22 아카이브에서 확인)
                           단위 ID는 Unit(Debug만 테스트값)
                           `configured`가 false면 SDK를 아예 시작하지 않는다 — Release에 ID를 안 넣으면 광고 없이 나가고 크래시는 없다
  Views/                   IntroView(2026-10-28 재작성, 약 1.6초·탭하면 건너뜀): 브랜드 바탕(#091100) 위에 마크(`AppMark`, 아이콘에서 뽑은 투명 공+호)가
                           튀어나오고 → 공이 맞는 순간 rigid 햅틱과 소리 링 3개 → "RIBATTO" 워드마크 → 페이드. Reduce Motion이면 정지 화면+페이드.
                           시작 화면(UILaunchScreen)은 색만 둔다 — 이미지는 시스템 스냅샷 캐시 때문에 비어 보였다.
                           광고 시작은 `.task(id: onboarded && !showIntro)` + 앱 .active 대기 — 동의·ATT가 인트로 위에 뜨지 않게
                           OnboardingView: 1페이지(설명 + 종목 칩 + 시작하기)
                           SessionDetailView(위에서부터 전체 폭 히어로(베스트 랠리 무음 루프 + 큰 길이 숫자) → "30초 하이라이트 릴스"(유일한 주 버튼) → 요약(일반 텍스트) → 클립 격자.
                           설정은 ⋯ → 설정 시트에서만. 히어로는 완성 클립만 재생하고 없으면 포스터 — 렌더 중 원본(4K)을 같이 디코딩하면
                           인코더와 메모리를 다툰다(-11819 계열). iCloud 원본도 끌어오지 않는다)
                           ReelSheet(열자마자 만들고 결과 화면에 착지: 인스타·저장·공유·편집. 버튼 경로는 30초 예산·랠리당 15초 상한·
                           최고 랠리 먼저·hook. 다시 만들기는 성공한 뒤에만 이 시트가 만든 이전 릴스를 지운다) · ClipViews
                           TrimSheet = 클립 편집기(2026-10-30, Instagram Edits 구성, 전체 화면 `fullScreenCover`). Views/Editor/:
                           EditorModel(초안 `EditDraft` + 되돌리기 50단계, 제스처가 **끝날 때** `checkpoint`) · EditorPreview(출력 모양 그대로:
                           컴포지션 핸들러가 블러/검정 채움→`graded`→`zoomed`, 워터마크·자막은 `ClipExporter.captionImage/watermarkImage` 픽셀을 겹침,
                           자막 끌기·핀치, 줌 도구일 땐 핀치·끌기가 재생 위치 키프레임을 만든다) · EditorTimeline(가운데 고정 재생헤드, 끌어 스크럽·핀치 배율,
                           자막 막대·키프레임 마름모·트림 핸들·타구 눈금) · EditorPanels(도구별 패널, VoiceOver용 스테퍼·목록 포함).
                           완료는 `trimClip` 한 번, 나누기는 확인 후 `splitRally`. 추적 크롭(Pass)은 미리보기에서 가운데 크롭 근사.
                           TrimmerBar/PryntTrimmerView는 더는 쓰이지 않는다 · TargetPlayerSheet(추적 대상 선택)
                           LibraryView(헤더는 + 메뉴(사진·파일·촬영)와 톱니(AppSettingsView: 언어·개인정보·라이선스·광고 동의)뿐.
                           선택은 세션 카드 길게 누르기. 검색·종목 칩은 세션 8개 이상일 때만)
                           AnalysisStrip(감지 중 포스터·파형·진행·남은 시간, 감지 후 랠리 구간 표시. 상태는 Store/AnalysisFeed — 비영속·세션별)
                           StatsView · CaptionEditorView · ProPassView(Pro 안내 + 리워드 광고 버튼) 등
                           SortMenu.swift: ClipSort(3종: 베스트·시간·즐겨찾기, 2026-10-11에 8종에서 줄임) + 정렬 메뉴
                           60초 넘는 구간은 `RallySegment.looksMerged`(여러 랠리가 붙은 것) — "긴 구간" 배지, 히어로·베스트·30초 릴스 후보에서 제외(전부 길면 예외)
                           AddRallySheet(놓친 랠리 수동 추가) · PrivacyView(앱 내 개인정보 설명 — 코드 동작과 항상 일치시킬 것)
                           ReelsView: 완성된 릴스 보관함. 파일은 sessions/reels/ 에 id.mp4 + id.jpg + id.json(ReelInfo)
                           OrientationGate.swift: 세로 고정 + 재생 화면만 가로 허용
```

## 디자인 시스템 (2026-10-28 리디자인, ios/REDESIGN_DIRECTIONS.md)

- 2026-10-30 중립 회색으로 교체(올리브 빛 회색 + 볼트 채움이 "촌스럽다"는 오너 피드백). 바닥 #0A0A0B · surface #141416 · surfaceHigh #1E1E21 ·
  raised2 #2A2A2E · letterbox #050506. 글자 primaryText #F5F5F7 / secondaryText #A1A1A6 / tertiaryText #8E8E93(raised2 위 금지, 4.38:1).
  주 버튼·선택 칩은 **흰 채움**(`primaryFill`/`onPrimary`). 볼트 `accent` #D4FF3F는 현재 선택·활성 토글/도구·PASS 테두리·브랜드 순간(인트로·워터마크·영상 자막색)에만.
  탭 안쪽 기본 tint는 흰색(RibattoApp, 탭 바 선택만 볼트). 데이터 `court` #5CC8DE(파형·타구 눈금), 상태 warning/danger #FF5A4F.
  볼트를 바꾸면 영상에 굽는 `CaptionColor.volt`·AccentColor 에셋·스크린샷 도구 볼트도 같이 바꾼다.
- 서체: UI는 전부 SF. 탭 제목 `.largeTitle.heavy.condensed`, 큰 숫자 `.heavy.compressed.monospacedDigit()`(숫자에만 compressed), 버튼 `.body.semibold` 최소 50·2줄.
- 영상 위 글자는 흰색만, 아래 55% 스크림. 카드 반경 16, 히어로 22.
- 앱 아이콘(2026-10-28 오너 제공): 볼트 공 + 소리 호 3개("타구음"). 원본 `marketing/icon/ribatto-icon-source.webp`, 브랜드 시트 `ribatto-brand-sheet.webp`.
  1024 sRGB 불투명으로 변환해 AppIcon icon-1024에 넣는다(알파 없음 확인). `ios/Tools/make_icon.swift`는 이전 생성기라 더는 쓰지 않는다. 시작 화면 로고 AppLogo는 그 아이콘을 둥글게 자른 것이고 LaunchBackground는 아이콘 바탕과 같은 #091100.
- 클립 플레이어: 왼쪽 X, 오른쪽 공유·⋯(즐겨찾기·다시 지정·삭제), 하단 '편집'·'릴스 만들기'. 릴스 결과와 릴스 탭 상세는 `ReelResultActions` 하나를 쓴다.
- 라이브러리: '선택' 버튼 없음(카드 길게 누르기 → 선택·삭제). 영상 하나를 가져오면 그 세션으로 바로 간다(NavigationPath).

## 랠리 번호와 되돌리기 (2026-10-13)

- 화면에 보이는 "#N"은 `RallySegment.number`(고정 번호)다. 위치(index)가 아니다. #2를 지우면 #1 #3 #4가 남는다.
  감지(재감지 포함) 때 시간순 1…n, 추가는 최댓값+1, 분할은 앞 조각이 번호 유지·뒤 조각 새 번호, 트림은 유지.
  옛 세션은 로드 때 한 번 매기고 저장한다. 파일 이름(clip_NN)·clipTargets 키·ReelSource.clipIndex는 여전히 위치다.
  예전엔 index+1로 그려서 삭제하면 다음 클립이 당겨와 같은 번호가 남았다(TestFlight 사용자 제보).
- 삭제 뒤 8초 "클립 N개 삭제됨 · 되돌리기"(`restoreRallies`): 같은 번호·별표로 되돌리고 그 클립만 다시 만든다.
  막대는 선택 바와 같은 고정 inset 안 — 오버레이로 두면 떠 있는 탭 바 밑에 깔려 탭이 먹힌다.
- 재감지는 편집(별표·트림·추가·분할·삭제·클립별 선수)이 있으면 먼저 묻고, 50% 이상 겹치는 새 랠리에 별표를 옮긴다.
- 선택은 랠리가 바뀌면 풀린다(선택 id가 위치 기반). 정렬은 `rc_clip_sort`로 기억한다.

## 패스 제안 흐름 (next-update, 2026-10-12)

- `PassOfferSheet`(하프시트): 패스 게이트 7곳 + 무료 릴스의 저장/인스타 버튼. 사용자 영상 한 프레임을 무료/패스로 나란히
  (`ClipExporter.passPreview`, 포스터로 먼저 보이고 진짜 쌍으로 교체, 로컬 원본만 — iCloud는 끌어오지 않는다).
  "나중에"는 광고 버튼과 같은 크기이고 원래 동작을 무료로 실행한다(AdMob 정책: 거절해도 기능을 막지 않는다).
  보상 후엔 다시 묻지 않고 원래 동작을 패스로 이어 한다(릴스 재생성 → 저장/인스타, 토글 켜기 등) + "패스가 열렸어요 · HH:mm까지" 토스트.
  시트는 광고가 닫힌 뒤(`ads.rewardedClosed`)에 내린다 — 광고가 덮인 채 시트를 내리면 광고 정리 콜백이 빠질 수 있다.
- 저장 시 수동 제안 상한: 실행당 1회 · 하루 2회 · 연속 3번 거절(스와이프 포함)이면 7일 쉼. 명시적 게이트는 상한 없음.
- 1.1.0(2026-10-28): 무료 적용(다시 만들기) 직전에도 수동 제안을 띄운다 — 슬롯은 릴스 저장과 공유, 판정은 `PassOfferGate.allowsPassive(pass:ads:)`
  (리워드 광고가 실려 있어야 함). 재감지·이어서 만들기·렌더 중에는 안 띄운다. 스와이프해도 적용은 무료로 진행된다.
  가져오기 감지 중(.queued/.audio/.detect)에는 모달 대신 `PassLine` 한 줄(라이브러리 1곳 + 진행 카드) → ProPassView.
  패스 만료 뒤 적용은 3버튼 창 대신 제안 시트(`messageKey: pro_expired_msg`)로 바로 간다.
- 첫 무료 릴스에만 결과 화면 카드 B. 카드가 보이는 동안 조용한 패스 줄과 저장 시 제안은 숨긴다(한 화면에 제안 하나).
- 리워드 광고를 열면(보상 여부 무관) 미룬 전면광고를 버리고 간격을 재시작, "나중에"도 버린다. 패스로 만든 렌더는
  패스가 중간에 끝나도 전면광고를 빚지지 않고, 패스 만료 뒤 3분은 전면광고를 안 띄운다(재실행에도 유지).
- 릴스 훅 문구(첫 1.8초): 타구 5~40일 때만 "{n}구 랠리", 아니면 "오늘의 베스트 랠리" — 타구 수는 옆 코트 소리로 틀릴 수 있다.
  위닝샷 슬로우 리플레이는 원본 50fps 이상일 때만, 마지막 랠리의 진짜 마지막 타구가 남아 있을 때만.
- 무료 세로 출력은 블러 배경 위 약한 줌(≤1.35×, SmartCrop 표본 재사용, 앱이 앞에 있을 때만 분석). RenderStamp에 화면 구성 버전.

## 패스 경계 (isPro 로 게이팅)

**UI 용어는 "Pro"가 아니라 "패스"다**(2026-09-25). 구입이 없는데 "Pro 해제"라고 쓰면 영구 등급을 약속하는 셈이고,
App Store 제품 페이지의 "앱 내 구입 없음" 표시와 어긋난다. 코드의 `isPro`·`ProPass`·`ProBadge`는 그대로 두되
사용자에게 보이는 문구는 전부 이용권으로 말한다(en PASS · ko 패스 · ja パス · es PASE · pt PASSE · de/fr/it PASS · zh 通行证).
배지는 짧게 유지할 것 — 긴 문구로 바꾸면 독일어·이탈리아어에서 잘린다.

**인앱 구입은 없다.** 2026-09-15에 StoreKit·페이월·복원·오너 패스프레이즈를 코드에서 걷어냈다(광고 전용 운영).
나중에 구매를 되살릴 때는 git 태그 `pro-iap-snapshot`의 `PurchaseManager.swift`·`PaywallView.swift`·`Ribatto.storekit`에서 가져온다.

무료: 광고(배너+전면) · 720p · 워터마크 · 세로는 블러 배경 위 원본 전체(`blurFilled`, 2026-10-11 전에는 중앙 고정 크롭).
     그 전에 만든 클립은 다시 만들기 전까지 중앙 크롭 그대로다.
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
2026-10-12에 D1–D4 화면 기준으로 다시 만들었다: 히어로(Pro 9:16 클립) · 내 경기(라이브러리) · 세션 화면 · 릴스 결과 · 시즌.
데모 장소명은 앱 데이터의 meta.json `placeName`을 직접 고쳐 넣었다.
캡처는 영어 UI + Debug Pro(테스트 광고 배너가 안 찍히게) + `simctl status_bar override --time 9:41`. 히어로는 `hero.jpg`로 넣는다.
2026-10-28부터 9개 언어 세트가 `marketing/screenshots/<locale>/`에 있다(`make_screenshots.swift <캡처> <출력> <locale>`).
데모 데이터: sample2.mov에서 자른 5분짜리 3개를 앱 Documents/seed에 넣고 Debug 빌드를 `-seedDemo`로 띄우면 가져와 감지한다.
언어는 `-rc_lang <code>` 실행 인자로 바꾸고, 코트 이름은 meta.json `placeName`을 언어별로 고쳐 찍었다.

## Pro 테스트

Debug 빌드에서 등급 알약을 1.2초 길게 누르면 `DebugProSheet`(Force Pro · 패스 부여/종료)가 열린다.
리워드 광고는 Debug에서 구글 테스트 단위라 시뮬레이터에서도 끝까지 보면 실제로 패스가 열린다.

## 빌드 / 실행

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project ios/Ribatto.xcodeproj -scheme Ribatto -destination 'platform=iOS Simulator,name=iPhone 17' build
```

이 Mac은 `xcode-select`가 Command Line Tools를 가리켜서 `DEVELOPER_DIR` 접두가 필요하다.

## 감지 평가 (ios/Eval, 2026-10-29)

```bash
./Eval/eval.sh --baseline Eval/baseline.json   # ios/ 에서 실행. Eval/labels/*.json 전부 채점
./Eval/eval.sh --draft <영상> <종목> > Eval/drafts/<이름>.json   # 지금 감지기 결과로 라벨 초안
```

- 앱과 같은 순서(RallyDetector → SoundCheck, normal)로 돌리고 정밀도·재현율·F1·경계 오차 중앙값·영상 1분당 처리 초를 낸다.
  매칭은 IoU ≥ 0.5, 1:1. 감지는 패딩 뺀 플레이 구간(첫 타구 → 마지막 타구+1초)으로 비교한다.
- 라벨은 서브부터 공이 죽을 때까지. `Eval/drafts/`는 **사람이 확인하기 전의 초안**이다 — 감지기 자기 출력이라 그대로 labels에 넣으면 F1 1.0이 나오는 순환이다.
  영상과 대조해 고친 것만 `Eval/labels/`로 옮긴다. 영상은 저장소 밖, 경로만 적는다. 디코딩한 음성은 `.build/eval-cache/`에 캐시된다.
- **규칙**: RallyDetector·SoundCheck·Sport·Sensitivity 값을 바꾸면 eval 전후 숫자를 함께 보고한다. 기준선보다 떨어지면 되돌린다.
  `Eval/baseline.json`(`--json`으로 만든다)은 사용자 승인 후에만 갱신한다. 녹화가 한 종류뿐이면 숫자도 그 녹화만 대표한다.

## 작업 규칙

- 코드 삭제·수정 전에 **반드시 사용자에게 확인**받는다.
- git 저장소다(main). 커밋은 사용자가 요청할 때만 한다.
- 문자열 추가 시 L10n.swift의 9개 언어 모두. %d·%@ 자리표시자는 원문과 개수·순서가 같아야 한다.
- `DebugProSheet`는 파일 전체가 `#if DEBUG`. 릴리스에 숨은 기능이 있으면 심사 2.3.1 거절 사유다.
- 긴 렌더는 `beginBackgroundTask`로 보호된다. `.failed`는 진행 중이 아니라 메시지이므로 busy 판정은 `isBusy`를 쓴다.
- 재렌더는 원본을 먼저 확보한 뒤 기존 클립을 지운다. 순서를 되돌리면 원본이 사라진 세션의 클립이 전부 날아간다.
- **긴 랠리 실패의 진짜 원인은 메모리였다**(2026-10-02 기기 실측). `ClipExporter.pump`의 프레임 루프에 autoreleasepool이 없어
  프레임마다 3.5MB(720p 버퍼 하나)가 클립 끝까지 쌓였다. 인코더가 4K 디코드보다 빨라 콜백 한 번이 클립 전체를 돌기 때문이다.
  iPhone 14 Pro에서 42초 랠리가 가용 메모리를 3,013→969MB로 떨어뜨리자 iOS가 미디어 서버를 죽였고(-11819),
  붙잡고 있던 AVAsset이 죽어 이후 클립이 짧은 것까지 전부 즉시 실패했다. Mac은 한도가 넉넉해 재현되지 않는다.
  수정: 프레임마다 `autoreleasepool` · CIContext를 클립마다(`cacheIntermediates: false`) · 실패 시 1초 쉬고 `loadAsset`으로 새 자산을 받아 재시도.
  수정 후 같은 기기에서 가용 메모리가 클립 길이와 무관하게 약 3,005MB로 평평하고 114초 랠리도 16초에 통과한다.
  기본 경로가 실패하면 `legacyEncode`로 떨어지는데, 화면에 뜨던 오류는 그 두 번째 경로의 것이었다 — 1차 오류를 보려면 DEBUG 로그를 볼 것.
  기기 진단: Debug 빌드를 `devicectl device process launch ... com.ribatto.app -diagRender`로 띄우면 클립 10–13·마지막을 만들며
  Documents/debug.log에 96프레임마다 가용 메모리와 오류를 남긴다(`SessionStore.runDiagnostics`).
  **규칙: 프레임/샘플 루프에는 반드시 `autoreleasepool`.** encode 펌프·FrameSequence(순차·시크)·SmartCrop·loudnessGain 모두 넣었다(2026-10-02).
  새 루프를 추가할 때 빠뜨리면 Mac에서는 멀쩡하고 기기에서만 긴 랠리가 죽는다.
  -11819(미디어 서버 리셋)·-11847은 `legacyEncode`로 떨어지지 않고 바로 던진다 — 죽은 자산으로 두 번째 전체 내보내기를 하면 같은 오류로 진짜 원인만 가린다.
  호출자가 새 자산으로 재시도한다: 세션 렌더 루프와 `ReelBuilder.build(reload:)` 모두. `export(session:)`(프리셋 경로·병합)에도 워치독이 있다.
  FrameSequence는 리더가 중간에 죽으면 부분 프레임을 성공으로 넘기지 않고 던진다.
- 확인 창은 `.alert`로 쓴다. iOS 26의 `confirmationDialog`는 붙은 뷰(대개 화면 전체)에 popover로 떠서 엉뚱한 곳에 보인다(1.1.0에서 삭제·재감지 확인 전부 교체).
  `.alert`는 취소를 자동으로 넣지 않으니 `role: .cancel` 버튼을 직접 둔다.
- 백그라운드 진입도 별도로 막는다: iOS는 백그라운드 앱의 GPU 사용을 막는다.
  그래서 렌더 루프는 클립 사이에서 `waitForForeground()`로 멈추고, 실패한 클립은 한 번 다시 시도한다.
  첫 렌더는 실패한 클립을 건너뛰고 끝까지 간 뒤 "클립 N개를 만들지 못함"을 띄운다. `Session.partialRender`(RenderStamp)가
  설정과 같으면 다음 적용은 빠진 클립만 만든다. 재렌더(staged)는 여전히 전부 아니면 전무다.
  스탬프 비교는 `RenderStamp.matches`로 한다 — 픽셀에 영향을 주는 것(구간 start/end·화면비·등급·크롭·캡션·언어)만 본다.
  즐겨찾기·타구 수·클립별 대상까지 비교하면 별 하나에 재개가 풀려 전체 재렌더가 됐다. 미완성 렌더 중 트림·나누기는
  스탬프 설정으로 굽고(`rerenderClip`) 스탬프를 새 구간으로 맞춘다. 실패한 클립을 지워 남은 게 전부 있으면 렌더 완료로 기록한다.
  백그라운드 GPU가 없어 렌더가 대기에 들어가면 연속 처리 작업을 끝낸다(`BackgroundWork.pause`) — 잠금 화면 진행률이 멈춘 채 남았다.
  시스템 오류의 localizedDescription을 그대로 띄우지 말 것 — `failureText`가 원인별 문구(+코드)로 바꾼다.
- **엔타이틀먼트 파일이 없다**(2026-10-12 확인, CODE_SIGN_ENTITLEMENTS 미설정). 아래 GPU 권한은 실제로 켜진 적이 없어
  기기에서는 항상 "GPU 거절 → CPU 전용 재제출 → 렌더는 클립 사이에서 대기" 경로다. 켜려면 .entitlements를 만들고 서명 설정에 연결할 것.
- 백그라운드 이어하기(`Store/BackgroundWork.swift`, 2026-10-02): iOS 26의 `BGContinuedProcessingTask`로 감지·렌더를 앱 밖에서도
  계속한다. 사용자가 누른 순간(앱이 앞에 있을 때)에만 제출할 수 있어서 다중 가져오기는 큐 전체를 작업 하나로 감싼다(`processQueued`).
  식별자는 `<bundle>.process.<uuid>` — Info.plist `BGTaskSchedulerPermittedIdentifiers`의 와일드카드와 맞아야 한다.
  클립 인코딩은 GPU라서 `com.apple.developer.background-tasks.continued-processing.gpu` 권한과 기기 지원
  (`BGTaskScheduler.supportedResources`)이 둘 다 있어야 백그라운드에서 돈다. 없으면 GPU 요청이 거절되고 CPU 전용으로 다시 제출한다 —
  그때 감지는 계속되고 렌더는 클립 사이에서 멈춘다. 시뮬레이터는 제출 자체가 BGTaskSchedulerErrorDomain 1로 실패한다.
  완료·실패·일시정지 알림은 로컬 알림이고 앱이 앞에 있으면 보내지 않는다. 권한은 첫 처리 시작 때 묻는다.
  알림 트리거는 nil이 아니라 1초다 — nil로 백그라운드 진입 순간 보내면 오류 없이 사라졌다(시뮬레이터 실측).
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
- 세로(9:16·4:5) 워터마크는 왼쪽, 바닥에서 24% 위치다(2026-10-28). 오른쪽 아래는 인스타·틱톡의 캡션·버튼 밑에 깔렸다.
  새 세로 캡션의 기본 y도 0.70(가로는 0.88). 첫 설치 24시간은 전면광고를 빚지지 않는다(`AdsManager.firstSeen`, 기존 설치는 제외).
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
- 세션 설정은 감지 전·감지 0개·미적용 변경·원본 없음일 때만 화면에 펼친다(`settingsForced`). 그 외에는 ⋯ → 설정 시트.
  설정을 바꾸면 `hasPendingChanges`로 곧바로 펼쳐져야 한다(시트 안에서 바꿔도 적용 버튼이 보이게).
  단 렌더가 중단됐거나 클립 파일을 비운 것은 "변경"이 아니다 — `Session.renderGap`(.unfinished/.cleared)이 있으면
  설정 폼 대신 "클립 N개를 아직 못 만들었어요 · 이어서 만들기"/"클립 파일을 비웠어요 · 다시 만들기" 배너를 띄운다.
  예전엔 `renderedOrientation == nil`을 변경으로 봐서 아무것도 안 바꾼 사용자에게 "설정이 변경되었습니다"가 떴다.
  비우기는 마지막 렌더 설정을 `partialRender`(cleared: true)로 남겨 다시 만들기가 재개 경로를 탄다.
- Pow(MIT, SPM)는 작은 반응 효과에만 쓴다. 라이선스 전문은 `Pow-MIT.txt`로 번들되어 LicensesView에 나온다 — 빼면 MIT 고지 의무 위반이다.
- 장식 요소(정렬 칩, 썸네일 배지, 차트 축 라벨)는 `dynamicTypeSize(...)`로 상한을 둔다. 두면 한 글자씩 줄바꿈되어 화면을 삼킨다.
  클립 카드의 시각·타구수도 같다. 격자가 폭을 고정하므로 상한이 없으면 "00:02–0…"으로 잘린다.
  행 앞의 SF Symbol도 마찬가지다. 글리프는 Dynamic Type을 따라 커지는데 `frame(width:)` 칸은 안 커져서,
  상한이 없으면 칸 밖으로 그려져 옆 글자를 덮는다(`StatsView.record`/`statRow`).
- 볼트(액센트)는 **누를 수 있는 것과 현재 선택**에만 쓴다. 값·상태 라벨·목록 장식 아이콘은 흰색이나 보조색이다.
  수치와 글리프까지 액센트로 칠하면 정작 눌러야 할 버튼을 구분할 방법이 없어진다. 같은 이유로 `ProBadge`는
  채우지 않고 테두리+연한 배경이다 — 솔리드 볼트 캡슐은 주 버튼의 모양이라 라벨이 버튼처럼 읽힌다.
- 탭 헤더는 접근성 크기에서 제목과 동작을 세로로 쌓는다(`TabHeader`). 한 줄을 나눠 가지면 긴 제목에 남는 폭이 없어
  독일어 "Meine Matches"가 "Mein…"이 되고 버튼이 "Auswä…"가 된다. 같은 이유로 세션 화면의 클립 개수 라벨도 정렬 칩과
  줄을 나누지 않는다 — 나누면 "Clips"가 "Clip / s"로 끊긴다(옛 "모든 클립" 탭에서 확인).
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
  "외부 SDK 없음·광고 없음"도 더는 사실이 아니다. AdMob이 광고 식별자·IP를 보낸다. PrivacyView의 p_ads_d와 공개 방침(`~/workspace/apps/ribatto/privacy/`, 게시 https://humsleep.github.io/apps/ribatto/privacy/)이 이를 적는다.
- 전면광고는 렌더·릴스가 끝났을 때 "빚"으로만 기록하고(`markInterstitialDue`), 사용자가 결과를 본 시트를 닫을 때 띄운다.
  완료 순간에 띄우면 처음 결과를 보는 순간을 가린다(2026-10-11 UX 테스트). 플레이어·편집 시트·가져오기 도중에는 넣지 않는다.
  `.failed`는 결과가 아니라 메시지이므로 광고를 얹지 않는다.
- 리워드 광고를 못 불러오는 빌드(Release에 광고 ID 없음)에서는 ProPassView가 버튼 대신 "지금은 광고를 불러올 수 없음"을 보여준다.
  불러오기에 실패하면 10초·30초 뒤 두 번 자동 재시도하고, 그래도 안 되면 "다시 시도" 버튼을 준다. 영원히 도는 스피너 금지 —
  리워드 광고가 Pro로 가는 유일한 입구다. 패스 중에도 리워드는 계속 로드한다(광고 한 편 더 = 1시간 연장).
- 패스가 끝난 뒤 Pro로 만든 세션에 적용을 누르면 "무료 화질로 다시 만듭니다" 확인을 먼저 띄운다(SessionDetailView).
- EEA 동의는 UMP(`UserMessagingPlatform`, GoogleMobileAds가 끌고 오는 패키지)로 받는다. 동의 → ATT → SDK 시작 순서이고,
  `canRequestAds`가 false면 SDK를 시작하지 않는다. 동의 재설정 진입점은 라이브러리 톱니 → AppSettingsView에 있다(필요한 지역에서만 보인다).
  설정이 시트라서 폼은 최상위 presented VC에서 띄워야 한다 — 루트에서 띄우면 조용히 실패한다.
  AdMob 콘솔에 GDPR 메시지를 만들어 두지 않으면 폼이 뜨지 않는다.
- `PrivacyInfo.xcprivacy`에는 **"추적"이 어디에도 없어야 한다** — 최상위 NSPrivacyTracking false, 항목별 Tracking도 전부 false.
  도메인 없이 추적을 한 군데라도 true로 두면 업로드가 ITMS-91064로 거절된다. 2026-09-30에 세 번 거절됐다:
  빌드 11(true+빈 배열) · 12(true, 키 삭제) · 13(false인데 기기ID·광고 데이터 항목이 Tracking true).
  그래서 기기ID·광고 데이터 항목은 앱 매니페스트에서 뺐다 — 구글 SDK 매니페스트가 직접 선언한다. 같은 계정의 FC Scope도 이 모양으로 통과했다.
  도메인을 적는 해법은 금지: ATT 거부 시 그 도메인이 차단돼 비맞춤 광고와 리워드까지 끊긴다.
  App Store Connect 설문은 그대로 "추적에 사용"이다(APP_STORE.md §5 표) — 설문은 SDK를 포함한 앱 전체 기준이다.
