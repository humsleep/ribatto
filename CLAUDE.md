# Vollio — repo guide

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
ios/Vollio/
  VollioApp.swift        진입점 · 온보딩 분기 · 3탭(라이브러리/모든 클립/시즌)
  Models.swift             Sport·Sensitivity·AspectSetting·Session·RallySegment·CaptionSettings
  L10n.swift               인앱 다국어 9종 (en 기본 / ko ja es pt de fr it zh-Hans) — 문자열은 9곳 모두 추가
                           s()는 없는 키를 영어로 폴백한다. 키 누락 검사는 세션 기록의 파서 스크립트 참고
  CaptionText.swift        캡션 토큰 {score} {rank} {shots} {tempo} {duration} {rally} {opponent} {place} {date} {sport} → 렌더 직전 클립별 문구로 치환(SessionStore)
  TennisScore.swift        태그된 승자 → 스코어라인. 테니스·파델은 15/30/40 + 게임/세트, 배드민턴·피클볼은 랠리포인트(21/11)
  Engine/                  ★ 핵심 로직, 실측 검증됨
    AudioLoader.swift      영상 → 16kHz 모노 샘플
    RallyDetector.swift    타구음 감지 (vDSP FFT + 2단 임계값)
                           + 랠리 점수화: 타구수 0.40 / 환호(voiceE 급등) 0.35 / 길이 0.25
                           RallySegment.hitTimes(타구 시각)·cheer(환호 비율, 3.5↑이면 🔥 배지·"환호 큰 순" 정렬)도 보존
                           승자·즐겨찾기는 감지가 아니라 사용자 입력(RallySegment.winner/favourite)
    SmartCrop.swift        세로 크롭용 관심영역 추적 — 모션 기반(사람 인식 아님). 설계 이유는 파일 주석 참고
    PlayerTracker.swift    특정 인물 추적 — Vision 시드 추적 + 재획득 + SmartCrop 모션 폴백. Session.targetPlayer 있을 때 사용
                           Keyframe.box(디스플레이 좌표)를 채워 ClipExporter의 재프레이밍 입력이 됨
    ClipExporter.swift     클립 컷 · 화면비 · 페이드 · 워터마크/캡션 번인
                           + 타구 카운터(ShotCounter, Pro): 프레임 시각별로 타구 수 픽셀 번인. 타구 시각은 RallySegment.hitTimes
                           + 스코어보드 번인(좌상단). 카운터와 겹치면 카운터가 아랫줄로 내려간다
                           워터마크(무료)는 Bebas 대문자 + 얇은 검정 외곽선. 흰 글자만으로는 밝은 하늘에서 사라진다
                           크롭은 `transform(window:)` 하나로 통일 — 소스의 사각 영역을 출력 프레임에 매핑
                           `reframed(...)`: 추적 박스가 있으면 피사체에 맞춰 축소·이동(최대 2배 줌), 없으면 기존 전체높이 창
    ReelBuilder.swift      여러 랠리를 하나의 세로 릴스로 (길이캡: reels 90s/shorts 60s/tiktok 180s)
                           ReelPace: full/impact(마지막 6초)/hook(위닝샷 0.8초 + 전체)
    FrameSequence.swift    AVAssetReader 순차 디코드 (2.1ms/프레임, 시크는 45ms). PlayerTracker 전용
                           SmartCrop은 의도적으로 시크 유지 — 파일 주석 참고
    HighlightMerger.swift  무재인코딩 병합 우선
    VideoProbe.swift       메타데이터 + 포스터
  Store/
    SessionStore.swift     세션 영속화 + 처리 파이프라인 (process → render). 모든 상태의 소유자
    PurchaseManager.swift  StoreKit 2. isPro 판정. OwnerSheet용 passphrase 게이트
                           소유권은 Apple ID에 있다(비소모성·가족공유). 기기변경·재설치는 자동 복원된다
                           rc_entitled에 마지막 응답을 캐시 — 스토어에 못 닿았을 때만 폴백하고, 닿았으면 그 답으로 덮는다
  Views/                   SessionDetailView(설정) · ReelSheet(릴스 편집·순서·베스트N·pace) · ClipViews
                           TrimSheet(클립별 길이 조정 → 해당 클립만 재렌더) · TargetPlayerSheet(추적 대상 선택)
                           LibraryView · StatsView · CaptionEditorView · PaywallView 등
                           SortMenu.swift: ClipSort(6종 정렬) + 정렬 메뉴 — 세션 화면·모든클립 탭 공용
                           AddRallySheet(놓친 랠리 수동 추가) · PrivacyView(앱 내 개인정보 설명 — 코드 동작과 항상 일치시킬 것)
```

## Pro 티어 경계 (isPro 로 게이팅)

무료: 가져오기 3개 · 720p · 워터마크 · 중앙 고정 크롭
Pro: 무제한 · 원본화질(가로4K/세로1080p) · 워터마크 없음 · 일괄저장 · 클립병합 · **스마트 세로 크롭**(SmartCrop) · **특정 인물 추적**(PlayerTracker, TargetPlayerSheet에서 선택) · **타구 카운터 번인**(Session.shotCounter) · **스코어보드 번인**(Session.scoreboard)
캡션 자동 문구(토큰)·환호 배지·즐겨찾기·포인트 태깅·상대 태그·랠리 추가/분할은 무료. 일괄저장은 2개 이상 선택 시 Pro.

## 마케팅 자산

`marketing/` — 앱스토어 스크린샷 5장(1320x2868, 6.9인치 규격)과 등록 문구(`app-store-copy.md`).
스크린샷은 `ios/Tools/make_screenshots.swift`가 만든다. 실기기 캡처를 헤드라인과 함께 합성하는 방식이며,
캡처를 갱신하려면 시뮬레이터 화면을 `xcrun simctl io <udid> screenshot`으로 다시 찍어 넣고 도구를 재실행한다.

```bash
swift Tools/make_screenshots.swift <캡처폴더> <출력폴더>   # ios/ 에서 실행
```

스크린샷 속 세션 이름·코트·상대는 데모용으로 채운 값이다. 실제 사용자 데이터가 아니다.

## 빌드 / 실행

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project ios/Vollio.xcodeproj -scheme Vollio -destination 'platform=iOS Simulator,name=iPhone 17' build
```

이 Mac은 `xcode-select`가 Command Line Tools를 가리켜서 `DEVELOPER_DIR` 접두가 필요하다.

## 작업 규칙

- 코드 삭제·수정 전에 **반드시 사용자에게 확인**받는다.
- git 저장소다(main). 커밋은 사용자가 요청할 때만 한다.
- 문자열 추가 시 L10n.swift의 9개 언어 모두. %d·%@ 자리표시자는 원문과 개수·순서가 같아야 한다.
- 오너 패널(OwnerSheet) 진입은 `#if DEBUG`. 릴리스에 숨은 기능이 있으면 심사 2.3.1 거절 사유다.
- 긴 렌더는 `beginBackgroundTask`로 보호된다. `.failed`는 진행 중이 아니라 메시지이므로 busy 판정은 `isBusy`를 쓴다.
- 재렌더는 원본을 먼저 확보한 뒤 기존 클립을 지운다. 순서를 되돌리면 원본이 사라진 세션의 클립이 전부 날아간다.
- 렌더는 `awaitEntitlement`로 소유권 판정을 기다린 뒤 tier를 확정한다. 먼저 시작하면 결제한 사용자 클립에 워터마크가 박힌다.
- 감지 결과가 0개인 것은 "완료"가 아니다. `apply`는 빈 배열도 재감지 대상으로 본다. 빼면 재감지 버튼이 죽는다.
- 접근성 큰 글씨에서는 설정 행이 세로로 쌓인다(`settingRows`). 가로 배치를 강제하면 AX5에서 종목명이 한 글자로 잘린다.
- "업로드 없음"이라고 쓰지 말 것. PlaceLookup이 좌표를 애플 지오코더로 보낸다. 문구는 "영상은 기기 밖으로 나가지 않는다"로.
