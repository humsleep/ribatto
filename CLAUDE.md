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
                           ReelsView: 완성된 릴스 보관함. 파일은 sessions/reels/ 에 id.mp4 + id.jpg + id.json(ReelInfo)
                           OrientationGate.swift: 세로 고정 + 재생 화면만 가로 허용
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

## Pro 결제 테스트

`ios/Ribatto.storekit`(상품 `com.ribatto.pro`, 비소모성)이 공유 스킴에 연결돼 있다.
**Xcode에서 Run하면** 이 설정이 적용돼 결제가 로컬에서 무료로 완결된다. Debug ▸ StoreKit ▸ Manage Transactions에서
거래를 지우면 다시 무료 등급으로 돌아온다. `xcrun simctl launch`로 띄우면 스킴을 거치지 않아 적용되지 않는다 —
페이월이 "가격 불러오는 중"에 머무는 건 이 경우다.
실기기·TestFlight에서는 OwnerSheet(등급 알약 길게 누르기 + 패스프레이즈)로 등급을 바꾼다. 진짜 결제·복원 흐름은
App Store Connect의 샌드박스 테스터 계정으로만 확인할 수 있다.

## 빌드 / 실행

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project ios/Ribatto.xcodeproj -scheme Ribatto -destination 'platform=iOS Simulator,name=iPhone 17' build
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
- 무료 횟수 환불은 세션당 1회(`importRefunded`). `process`는 재감지에서도 실행되므로 조건 없이 돌려주면 무료가 무제한이 된다.
- 지원 언어는 `ios/Ribatto-Info.plist`의 `CFBundleLocalizations`에 선언한다. 빌드 설정
  `INFOPLIST_KEY_CFBundleLocalizations`로는 안 된다 — 생성기가 아는 키만 반영해서 조용히 사라진다.
  실제로 두 configuration 모두 선언돼 있었는데 빌드된 Info.plist에는 없었다. 선언이 빠지면 App Store
  제품 페이지에 영어 하나만 표시된다. 기기 언어 시드는 `Locale.preferredLanguages` 대신
  `AppleLanguages` 원본을 읽어 이 선언과 무관하게 동작한다(`seedLanguageFromDevice`).
  이 파일은 그 키 하나 때문에 존재하고, 나머지 키는 여전히 생성된 뒤 여기에 병합된다.
- 오버레이 번인 결과를 원본 자리로 옮기는 데 실패하면 던진다. 삼키면 워터마크 없는 무료 클립이 나간다.
- 세로 고정이다(OrientationGate + AppDelegate). 가로는 클립·하이라이트 재생 화면만, 그것도 가로 영상일 때만 허용한다.
  하이라이트·병합 재생도 세션의 `renderedOrientation`을 받아 같은 판정을 한다. 무조건 허용하면 세로 하이라이트가 옆으로 눕는다.
  `.allowsLandscape()`는 시트 최상위에 붙인다. 세로/가로 레이아웃 분기 안쪽에 붙이면 전환 순간 사라지는 쪽의 onDisappear가 권한을 도로 거둔다.
  시트가 떠 있을 때는 최상위 presented VC에 setNeedsUpdateOfSupportedInterfaceOrientations를 보내야 한다. 루트만 갱신하면 반영되지 않는다.
- 페이월 가격 블록은 접근성 크기에서 하단 고정을 풀고 스크롤에 넣는다. 고정하면 바가 화면을 통째로 먹어 기능 목록에 닿지 못한다.
- 접근성 큰 글씨에서는 설정 행이 세로로 쌓인다(`settingRows`). 가로 배치를 강제하면 AX5에서 종목명이 한 글자로 잘린다.
  같은 규칙이 시즌 기록·상대·코트 행에도 적용된다(`statRow`). 좌우 배치를 고집하면 아이콘이 글자를 덮거나 이름이 두 글자로 잘린다.
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
