# Ribatto 1.1.0 출시 계획 (의장 최종안)

## 1. 결론 한 줄
삭제·초기화 확인 창 7곳과 재감지·패스 종료 확인을 모두 가운데 `.alert`로 바꿔 (B)를 끝냅니다. (A)는 두 갈래로 갑니다. 다시 만들기(적용) 직전에는 횟수 제한이 걸린 패스 제안 시트를 띄우고, 가져오기 감지 중에는 조용한 한 줄 안내를 둡니다. 그 밖에는 광고와 패스 쪽 버그 수정과 스토어 문구 정리만 넣고, 1.1.0 / 빌드 21로 냅니다.

---

## 2. 필수

### M1. (B) 삭제·초기화 확인 7곳을 가운데 `.alert`로 — C1
- **표결**: keep 11 / modify 4 / cut 0
- **파일**: `ios/Ribatto/Views/SessionDetailView.swift`(:294, :313, :323), `ClipViews.swift`(:547), `LibraryView.swift`(:281), `ReelsView.swift`(:74, :250)
- **방법**:
  - `.confirmationDialog(title, isPresented:, titleVisibility: .visible) {…} message: {…}`를 `.alert(title, isPresented:) {…} message: {…}`로 1:1 교체합니다.
  - 제목, destructive 버튼, message 클로저는 그대로 둡니다. ReelsView:74의 `Binding(get:set:)`도 그대로 씁니다.
  - `.alert`는 취소 버튼을 자동으로 넣어 주지 않습니다. 그래서 취소가 없는 곳에만 `Button(L.s("cancel", lang), role: .cancel) {}`를 추가합니다.
    - 추가할 곳: SessionDetailView:313, ClipViews:547, LibraryView:281, ReelsView:74, ReelsView:250
    - 이미 있는 곳(:294, :323)에는 중복으로 넣지 않습니다.
  - SessionDetailView:313에는 `message: { Text(L.s("delete_sessions_note", lang)) }`를 추가해 라이브러리 삭제와 맞춥니다.
  - 새 문자열은 없습니다.
  - 병합 전에 네 파일에서 `.alert(`를 grep해, 파괴적 alert마다 cancel 역할 버튼이 있는지 확인합니다.
- **반영한 수정 의견**:
  - 트리거에 붙이는 변형은 철회됐습니다(MAB#1, UID#2). 트리거 셋이 Menu·contextMenu 항목이라 창이 뜰 때 이미 사라지고, deleteBtn은 ViewThatFits가 두 번 만들기 때문입니다.
  - AX5 확인은 모든 경로가 아니라 가장 긴 제목 두 개에만 de·it로 합니다(CR#1).
  - LibraryView:565(복구 폐기)는 자기 카드에 붙어 있어 위치가 이미 맞습니다. 손대지 않습니다.

### M2. (B) 재감지 확인을 `.alert`로 — C2
- **표결**: keep 1 / modify 14 / cut 0
- **파일**: `SessionDetailView.swift:228`
- **방법**: `confirmRedetect`만 `.alert`로 바꿉니다. 버튼(취소 포함)과 메시지는 그대로입니다. LibraryView:565는 제외합니다(14명 의견).

### M3. (A/B) "패스가 끝났습니다" 3버튼 창을 없애고 제안 시트로 바로 연결 — C3
- **표결**: keep 1 / modify 13 / cut 1
- **파일**: `SessionDetailView.swift`(:54, :343-357, :1066-1068), `PassOfferSheet.swift`, `L10n.swift`
- **방법**:
  - runApply의 `confirmFreeRender = true`를 다음 호출로 바꿉니다.
    `offer(session, title: "pro_expired_title", declineKey: "offer_later_free", granted: apply, declined: apply)`
  - 진입 조건은 지금 그대로 둡니다: `renderedPro == true && !isPro && 완성 클립 있음`.
  - 이 제안은 명시적 관문입니다. 횟수 제한에 걸리지 않고 recordShown도 하지 않습니다. 스와이프는 예전 취소와 같습니다.
  - `confirmFreeRender` @State와 다이얼로그를 삭제합니다.
  - `pro_expired_watch`와 `pro_expired_free`는 9개 언어에서 지웁니다. grep으로 다른 독자가 없는지 먼저 확인합니다.
  - **다운그레이드 경고는 남깁니다.** `PassOfferRequest`에 `var messageKey: String? = nil`을 추가하고, PassOfferSheet:136을 `Text(L.s(request.messageKey ?? "offer_sub", lang))`로 바꿉니다. 이 호출만 `messageKey: "pro_expired_msg"`를 넘깁니다. 대략 3줄입니다.
- **반영한 수정 의견**:
  - 같은 질문을 두 번 묻는 흐름과 떠다니는 다이얼로그 제거는 11명의 의견입니다.
  - 경고 문장 유지는 UID#2, ASO#2·#3, RC#1·#2, CR#2·#3의 의견입니다. CLAUDE.md도 "패스 만료 후 무료 화질 재생성 확인"을 요구합니다.
  - de·it AX3에서 하프시트 안에 들어가는지 확인합니다.

### M4. (A) 공용 수동 제안 판정 + 광고 로드 조건 — C5
- **표결**: keep 15
- **파일**: `PassOfferSheet.swift`(PassOfferGate), `ReelSheet.swift:793-798`
- **방법**:
  - PassOfferGate에 다음 함수를 추가합니다.
    `static func allowsPassive(pass: ProPass, ads: AdsManager) -> Bool { !pass.isPro && ads.showing && ads.rewardedReady && allowsPassive && Date().timeIntervalSince(ads.lastInterstitialAt) > 60 }`
  - `ReelSheet.offersPass`에는 자기 조건만 남기고 이 함수를 호출합니다.
  - 문서 주석에 규칙을 적습니다: "요청 없이 뜨는 시트는 이 판정 → recordShown → passive: true. 모달이 아닌 줄은 제한도 집계도 하지 않는다."

### M5. (A) 무료 다시 만들기(적용) 직전 수동 제안 — C4
- **표결**: keep 0 / modify 15 / cut 0
- **파일**: `SessionDetailView.swift`(offer :436, finishOffer :450-466, runApply :1058-1072)
- **방법**:
  1. `offer()`에 `passive: Bool = false`를 추가해 PassOfferRequest로 넘깁니다. offerActions 옆에도 보관합니다.
  2. `finishOffer`에서 `case nil:` 결과는 **passive일 때만 declined()를 실행**합니다. 스와이프해도 사용자가 누른 적용은 반드시 렌더돼야 합니다(AdMob 정책).
  3. 조건은 runApply의 **마지막 else 분기에서만** 봅니다. 재감지 분기와 패스 종료 분기 뒤라야 하고, recordShown도 이 분기 안에서만 부릅니다(MAB#3 지적).
     - `PassOfferGate.allowsPassive(pass:ads:)`
     - 완성 클립 있음
     - `!store.isBusy(session.id)`
     - `!session.needsRedetect`
     - `session.renderGap == nil`
  4. 조건이 맞으면 `PassOfferGate.recordShown()`을 부른 뒤 다음을 호출합니다. 조건이 안 맞으면 지금처럼 바로 apply합니다.
     `offer(session, declineKey: "offer_later_free", title: <M7 규칙>, passive: true, granted: apply, declined: apply)`
  - 새 문자열은 없습니다.
- **반영한 수정 의견**:
  - 재감지 질문 직후 모달을 겹치지 않습니다. 11명이 재감지 쪽 제외를 요구했고, `needsRedetect`가 `!confirmed`를 포함합니다.
  - "이어서 만들기"는 한 번 탭으로 유지합니다. renderGap 제외는 9명 의견이고 반대는 5명이었습니다. 패스를 받으면 RenderStamp.pro가 바뀌어 전부 다시 만드는 staged 경로로 빠지기 때문입니다.
  - 렌더 중에 4K 미리보기를 디코딩하지 않도록 isBusy를 제외 조건에 넣었습니다(9명).
  - hasPendingChanges와 settingsShown 제외는 한 명만 제안해 기각했습니다. 설정 시트 경로는 시트가 닫힌 뒤(onDismiss :400-403) runApply가 돌기 때문에 문제가 없다는 것이 검증됐습니다(MAB#1, CR#2).

### M6. (A) 가져오기 감지 중 조용한 패스 한 줄 — C6
- **표결**: keep 0 / modify 12 / cut 3
- **파일**: `SessionDetailView.swift`(progressCard :1074-1110), `LibraryView.swift`(목록 위)
- **방법**:
  - 기존 `ReelSheet.passLine` 모양(:447-463)을 그대로 복사합니다. 누를 수 있으므로 tint를 쓰고, `.fixedSize(horizontal:false, vertical:true)`를 주고, 글리프는 `.xxxLarge`로 상한을 둡니다.
  - 문구는 기존 `reel_pass_line`을 재사용합니다. 9개 언어가 이미 있어 새 문자열이 필요 없습니다.
  - 표시 조건: `!pass.isPro && ads.showing`이고 단계가 `.queued / .audio / .detect`일 때. `.render`부터는 숨깁니다. 이때는 등급이 이미 굳어 업그레이드를 약속할 수 없기 때문입니다.
  - 표시 위치는 두 곳입니다.
    - 라이브러리: 해당 단계의 세션이 하나라도 있으면 목록 위에 **한 번만** 보입니다. 카드마다 넣지 않습니다.
    - 세션 화면: progressCard의 keep_awake 아래.
  - 탭하면 **ProPassView**가 열립니다. 라이브러리는 기존 `showPro`, 세션은 `open(.pro)`를 씁니다. PassOfferSheet는 열지 않습니다. 가져오기 디코딩 옆에서 passPreview 디코딩이 돌면 -11819 메모리 문제가 날 수 있기 때문입니다.
  - LibraryView에 `@EnvironmentObject var ads: AdsManager`를 추가합니다. M14와 같이 씁니다.
  - 모달이 아니라 사용자가 직접 누르는 것이므로 횟수 제한과 recordShown이 없습니다.
- **반영한 수정 의견**: 탭 대상을 ProPassView로 한 것은 11명 의견입니다. 라이브러리 줄은 사용자가 가져오기 뒤 라이브러리에 머물기 때문에 넣었습니다(LibraryView는 화면 이동을 하지 않습니다).

### M7. 가로 세션에 9:16 비교와 "선수 크게" 금지 — C10
- **표결**: keep 11 / modify 4
- **파일**: `PassOfferSheet.swift`(body의 comparison·`.task { loadFrames }`), `SessionDetailView.swift`(offer)
- **방법**:
  - `OutputFrame(request.session.effectiveOrientation).isPortrait`가 아니면 comparison을 그리지 않고 loadFrames도 돌리지 않습니다.
  - offer()에서 기본 제목(`offer_title`)이고 세로가 아니면 `offer_title_quality`를 씁니다. M5의 제목도 이 규칙을 따릅니다.
  - 새 문자열은 없습니다.

### M8. 전면광고 표시 실패 시 리워드 광고까지 버리는 버그 — C9
- **표결**: keep 15
- **파일**: `ios/Ribatto/Store/AdsManager.swift:510-520`
- **방법**: `interstitial = nil`, `rewarded = nil`, `rewardedReady = false` 세 줄을 삭제하고 두 load 호출은 남깁니다.

### M9. 패스 중 재실행해도 SDK를 시작해 연장 광고를 불러오기 — C14
- **표결**: keep 13 / modify 2
- **파일**: `AdsManager.swift`(:168, :200, :163 주석)
- **방법**:
  - :168의 `!isPro,`와 :200의 `, !isPro`를 삭제합니다.
  - :163의 IAP 시절 주석("Pro 사용자는 프롬프트를 안 본다")을 고칩니다.
  - 배너와 전면광고는 `refreshShowing()`이 이미 막고 있습니다.
- **반영한 수정 의견**: 패스 중 재실행하면 UMP·ATT 프롬프트가 뜰 수 있습니다. 이는 정상 동작으로 받아들이고, IntroView 뒤에 뜨는지 기기에서 확인합니다.

### M10. 리워드 광고 만료(약 1시간) 대비 — C15
- **표결**: keep 5 / modify 6 / cut 4
- **파일**: `AdsManager.swift`
- **방법**:
  - 리워드 광고에만 적용합니다. 광고를 할당할 때(:369) `rewardedAt`을 기록합니다.
  - `showRewarded`에서 55분이 지났으면 광고를 버리고 다시 불러온 뒤 false를 반환합니다. 버튼은 로딩 상태가 됩니다.
  - 대략 4줄입니다.
- **반영한 수정 의견**: 전면광고는 M8 이후 실패하면 스스로 다시 불러오므로 제외했습니다(MAB#1·#2, ASO#2·#3).

### M11. 감지 중 경기를 지우면 남는 유령 busy 상태 — C11
- **표결**: keep 9 / modify 6
- **파일**: `ios/Ribatto/Store/SessionStore.swift`
- **방법**:
  - 근본 수정은 한 곳입니다. `isBusy`(:1229) 첫 줄에 `guard !deleted.contains(id), let stage = progress[id] else { return false }`를 넣습니다. busyCount, 화면 꺼짐 방지, 가짜 "일시정지" 알림이 모두 이 함수를 거칩니다.
  - 추가로 process()의 AudioLoader await 직후에 `if wasDeleted(sessionID) { progress[sessionID] = nil; return }` 한 줄을 넣어 FFT 낭비를 막습니다.
  - 나머지 산발적인 가드는 넣지 않습니다.
- **반영한 수정 의견**: 바쁜 세션의 삭제는 막지 않습니다. 삭제가 곧 가져오기를 취소하는 방법이기 때문입니다.

### M12. 원본이 없으면 되돌리기 숨김 — C16 (첫 절반만)
- **표결**: keep 0 / modify 15
- **파일**: `SessionDetailView.swift:1564-1567`
- **방법**: `undo = store.sourceMissing(session) ? nil : (text, rallies)`. 삭제 확인 창은 모두 유지합니다(M1의 alert).

### M13. 되돌리기 막대 타이머와 단수 문구 — C17
- **표결**: keep 12 / modify 3
- **파일**: `SessionDetailView.swift`(:1567, :1593 주석, :1621), `L10n.swift`
- **방법**:
  - task id를 `undo.rallies.map(\.start)`로 바꿉니다.
  - "five seconds" 주석을 "eight seconds"로 고칩니다.
  - `deleted_one` 키를 9개 언어에 추가합니다. 자리표시자는 없습니다. :294의 `delete_one_clip`·`delete_n_clips`처럼 개수가 1이면 이 키를 고릅니다.
  - 예: en "1 clip deleted", ko "클립 1개 삭제됨".

### M14. 고정 삭제·되돌리기 바와 배너 사이 간격 — C20
- **표결**: keep 1 / modify 13 / cut 1
- **파일**: `SessionDetailView.swift:216`, `LibraryView.swift`(선택 바 :194 부근)
- **방법**: `.padding(.bottom, ads.bannerLoaded && ads.showing ? 20 : 8)`. 구분선(hairline)은 넣지 않습니다(13명).

### M15. 클립 삭제의 busy 사전 확인 — C19
- **표결**: keep 7 / modify 5 / cut 3
- **파일**: `ClipViews.swift`(툴바 휴지통 :511-515)
- **방법**:
  - 휴지통을 탭할 때 `store.isBusy(clip.sessionID)`면 확인 창을 열지 않고 busy_wait를 보여 줍니다. 그렇지 않으면 `confirmDelete = true`입니다. 버튼 안의 거절 처리는 대비책으로 남깁니다.
  - SessionDetailView의 deleteBtn은 selectionBar가 `.disabled(busy)`(:1252)라 이미 막혀 있습니다. 손대지 않습니다.
  - **세션 삭제에는 절대 적용하지 않습니다**(MAB#1, RC#3, CR#3).

### M16. 결과 시트를 닫을 때 되돌리기 위로 전면광고가 덮이는 문제 — 누락 이슈(RC#2), 코드 확인함
- **파일**: `SessionDetailView.swift:396`
- **방법**: `if destination == nil, onScreen, watched, undo == nil {`로 바꿉니다. 플레이어에서 클립을 지운 직후 빚진 전면광고가 8초짜리 되돌리기를 덮어 버리던 문제입니다. 광고 빚은 다음 결과 시트를 닫을 때로 미뤄집니다.

### M17. 제안 시트를 스와이프로 닫아도 미룬 전면광고 해제 — 누락 이슈(ASO#3), 코드 확인함
- **파일**: `PassOfferSheet.swift:164-166`
- **방법**:
  - 현재 "나중에" 버튼(:288)만 `ads.declinePassOffer()`를 부릅니다.
  - onDisappear를 `if outcome == nil { ads.declinePassOffer(); if request.passive { PassOfferGate.record(.declined) } }`로 바꿉니다.
  - "광고 하나를 거절했는데 다른 광고를 봤다"는 상황을 막습니다. 수동 제안(M5)이 늘어나므로 필요합니다.

### M18. 색 규칙 위반 두 곳 — C22, C21
- **C22** (keep 15): `SessionDetailView.swift:823-827`의 apply_hint를 `.tint`에서 `.secondary`로 바꾸고 `.fixedSize(horizontal:false, vertical:true)`를 줍니다.
- **C21** (keep 8 / modify 4 / cut 3): `upgradeBanner`(:1189-1210)
  - 아이콘을 `.secondary`로 바꾸고 `.dynamicTypeSize(...DynamicTypeSize.xxxLarge)` 상한을 둡니다.
  - 접근성 크기에서는 `AnyLayout(VStackLayout(alignment: .leading, spacing: 10))`로 쌓고 버튼을 전체 폭으로 둡니다.
  - 패스가 렌더 도중 열린 경우의 안내라 1.1.0에서 더 자주 보입니다.

### M19. 죽은 코드와 문자열 삭제 — C25, C26, C27
- **C25** (keep 13): `LibraryView.swift`의 `.sample` 케이스(:49, :486), `sampleURL`(:54), 버튼 블록(:351-361), `importSample()`(:518-532), 그리고 9개 언어의 `try_sample`·`sample_name` 키를 삭제합니다. 번들에 sample_match.mp4가 없어 도달할 수 없는 경로입니다.
- **C26** (keep 15): `offer_sub_fmt`의 9개 항목을 삭제합니다.
- **C27** (keep 15): `SessionDetailView.swift:1333-1334`의 옛 "All Clips" 주석을 삭제합니다.

### M20. 한국어 온보딩 ob3_d — C24 (문구만)
- **표결**: modify 12 / cut 3
- **파일**: `L10n.swift:532`
- **방법**:
  - ko를 `"세로 클립과 하이라이트 릴스를 폰에서 바로 만듭니다."`로 바꿉니다.
  - 다른 언어는 "reel·resumen·Highlight-Video" 등이라 실제 기능과 맞습니다. pt의 "compilação"는 릴스 자체를 가리키므로 그대로 둡니다.
  - IntroView 동작은 바꾸지 않습니다.

### M21. 평점 요청을 버전당 1회로 — C31
- **표결**: keep 15
- **파일**: `ReelSheet.swift`(:49, :227, :931)
- **방법**:
  - `@AppStorage("rc_review_asked_ver") var reviewAskedVersion = ""`로 바꿉니다.
  - :931에서 `CFBundleShortVersionString`과 비교하고, :227에서 현재 버전을 저장합니다.
  - 묻는 시점은 그대로입니다.

### M22. 권한 문구 현지화 (ATT 포함) — C36
- **표결**: keep 12 / modify 2 / cut 1
- **파일**: `ios/Ribatto/InfoPlist.xcstrings`(신규)
- **방법**:
  - 사용 설명 5개 키를 9개 언어로 만듭니다. 현재 의미를 유지하고 "추적하지 않음"은 약속하지 않습니다.
  - synchronized root group이 pbxproj 수술 없이 파일을 집어 가는지 확인합니다.
  - 빌드된 .app 안에 `ko.lproj/InfoPlist.strings`가 생겼는지 확인합니다.
- **반영한 수정 의견**: 수동 pbxproj 편집이 필요하면 1.1.1로 미룹니다(MAB#3, RC#1). 이 프로젝트는 Info.plist 생성기가 키를 조용히 버린 전례가 있습니다.

### M23. 버전·스토어·심사 문구 — C32, C33, C34, C35(키워드만) + 누락 이슈(RC#3)
- **C32** (keep 15): `ios/Ribatto.xcodeproj/project.pbxproj`
  - Debug와 Release 모두 `MARKETING_VERSION = 1.1.0`, `CURRENT_PROJECT_VERSION = 21`로 올립니다.
  - `ios/APP_STORE.md:241`의 버전 줄을 고칩니다. iPad는 추가하지 않고 PrivacyInfo는 바꾸지 않습니다.
- **C33**: `marketing/app-store-copy.md`
  - 9개 언어 모두 1.1.0 What's New를 씁니다.
  - **한국어 섹션(:69-122)에는 1.0 블록조차 없습니다(확인함). 새로 만들어야 합니다.**
  - 범위가 확정된 뒤 실제로 나간 기능만 적습니다. 각 언어의 패스 용어를 쓰고 "Pro"·"광고 없음"은 쓰지 않습니다.
- **C34** (keep 15): 설명의 "가운데를 자르는 대신" 문구를 9개 언어에서 고칩니다. 무료 출력은 블러 배경 위 전체 화면입니다(문구는 C34 안 그대로).
- **C35**: 영어 키워드만 고칩니다.
  - `clip`(이름과 중복)을 빼고 `tennis`를 넣습니다.
  - 상표는 넣지 않습니다(ASO#3). `shorts`·`reels`·`tiktok`·`instagram` 모두 제외입니다.
  - :23-25의 틀린 메모를 고칩니다.
  - 이름과 부제 변경은 5절에서 오너가 결정합니다.
- **심사 노트**: `ios/APP_STORE.md`(:98-102, :173-179)에 한 문장을 추가합니다. "가져오기 중이나 적용 전에 선택형 패스 제안이 뜰 수 있으며, '나중에 · 무료로 만들기'를 누르면 무료 흐름이 그대로 이어진다." 심사 빌드는 테스트 광고가 항상 채워지므로 M5 시트를 만나게 됩니다.

---

## 3. 권장 (시간이 되면)
- **C18 한 줄**: `onChange(of: session.segments)`(:223)에서 `selection.removeAll()` 옆에 `confirmDeleteClips = false`를 넣습니다. 표결은 keep 2 / modify 5 / cut 8로 필수 기준에 못 미쳤습니다. 다만 alert는 더 눈에 띄어서 "클립 0개 삭제" 불일치가 보일 수 있습니다(CR#1).
- **ask_sport(LibraryView:251)를 `.alert`로**(UID#1): 같은 컨테이너에 붙어 있고 Menu에서 열립니다. iOS 26 기기에서 떠다니는 것이 확인되면 종목 버튼 4개, 기존 취소, ask_sport_msg로 바꿉니다. 450ms 대기는 유지합니다.
- **recordShown을 PassOfferSheet.onAppear로 옮기기**(ASO#1): 시트가 실제로 화면에 보였을 때만 횟수를 셉니다.
- **restoreRallies 실패 반환**(RC#2): 뒤따른 렌더가 `.failed`로 끝나면 false를 돌려 undo_failed를 보여 줍니다. M12로 주된 경우는 이미 막혀 있습니다.
- **ko·ja·zh 키워드 칸 채우기**(ASO#2): 각각 60·67·45자를 쓰고 있습니다. 키워드는 버전을 제출할 때만 바꿀 수 있습니다.

---

## 4. 기각

| 항목 | 표결 | 기각 이유 |
|---|---|---|
| C7 가져오기마다 제안 시트 | cut 11 | 첫 동작 앞에 모달을 끼워 넣고, BG 작업 제출을 광고 뒤로 밀며(기기에서만 확인 가능), 하루 1회 슬롯을 M5·릴스 저장과 나눠 먹습니다. 비차단 변형은 "광고를 봤는데 무료로 나왔다" 경합을 되살립니다. M6이 같은 순간을 모달 없이 맡습니다. |
| C8 가져오기 후 세션 화면 자동 이동 | cut 15 | 아무도 요청하지 않은 흐름 변경이고 다중 가져오기에서 모호합니다. M6의 라이브러리 줄로 필요가 없어졌습니다. |
| C12 다시 자르기에 beginBackgroundTask | keep 2 / mod 10 / cut 3 | **전제가 틀렸습니다.** SessionStore:97-103(확인함)과 CLAUDE.md에 따르면 iOS는 백그라운드 앱에 GPU를 주지 않습니다. 인코딩이 GPU라 배경 작업 시간을 받아도 실패하고, 트림은 깔끔하게 롤백됩니다(의도된 동작). 표수와 달리 근거가 반박돼 기각합니다. setClipTarget 병합도 출시 직전 리팩터라 제외합니다. |
| C13 복귀 시 BG 작업 재제출 | cut 11 | 사용자 탭이 아닌 시점의 제출은 정책상 불확실합니다. 시뮬레이터로 검증할 수 없고 CPU 전용 다중 가져오기의 경계 사례일 뿐입니다. |
| C23 빈 라이브러리에서 종목을 바로 묻기 | cut 15 | M 규모이고 심사자가 처음 보는 화면을 바꿉니다. |
| C28 Stabilizer 삭제 | cut 10 | 오너가 핸드헬드 영상이 생길 때를 대비해 의도적으로 보관 중이고, 사용자 가치가 없습니다. |
| C29 PersonDetector 삭제 | cut 15 | M 규모이고 추적 재검증(97.7%)이 필요합니다. 사용자 가치가 없습니다. |
| C30 ReelPreset 삭제 | cut 14 | 옛 릴스 재렌더 경로(SessionStore:2059)에 위험이 있습니다. 죽은 프리셋 문자열 약 80개(CR#3)도 함께 다음으로 미룹니다. |
| C24 인트로 첫 실행 때만 | — | 브랜드 결정이고 광고 시작 순서와 묶여 있습니다. 문구 수정(M20)만 채택했습니다. |
| C15의 전면광고 쪽 | — | M8 이후 실패하면 스스로 다시 불러옵니다. |
| C3의 단순 alert 변환안(RC#1·#2, CR#3) | 소수 | 같은 질문을 두 번 묻는 흐름이 그대로 남습니다. 경고 문장은 messageKey로 살렸습니다. |

---

## 5. 남은 이견
1. **M3 경고 표시 방식**: "messageKey를 추가하지 말고 `offer_later_free`로 충분하다"는 쪽(MAB#1~3, UID#1·#3, ASO#1)과 "경고 문장이 꼭 필요하다"는 쪽(7명)이 맞섰습니다. 의장이 3줄짜리 messageKey로 절충했습니다. 오너가 더 단순한 쪽을 원하면 messageKey를 빼고 `pro_expired_msg`까지 삭제하면 됩니다.
2. **M5 제외 조건**: renderGap에서 제외할지 다툼이 있었습니다. MAB#1, ASO#1·#3, RC#3, CR#2는 "패스를 받았으면 전체 재렌더가 맞다"고 봤습니다. needsRedetect 대신 `!confirmed`만 쓰자는 의견도 있었습니다(CR#1, RC#1·#2).
3. **M6 노출 조건**: `ads.rewardedReady`를 조건에 넣을지(MAB#3, ASO#3) 결론이 나지 않았습니다. ASO#3은 라이브러리 줄 자체를 군더더기로 봅니다.
4. **ask_sport 변환**: UID#1은 필수라고 보고, 나머지는 제외하자는 입장입니다. 기기 확인 결과로 정합니다(3절).
5. **C12**: 표수는 수정 의견이 우세했지만 의장이 사실 근거로 기각했습니다. 반대하는 사람은 기기에서 재현 근거를 가져와야 합니다.
6. **C35 앱 이름**: "Ribatto: Tennis Rally Clips"와 부제 "Pickleball, padel & badminton"으로 바꾸는 안은 **오너가 결정**합니다. ASO 측은 1.1.0이 기회라고 보고, RC·CR 측은 데이터 없이 이름을 바꾸는 것은 투기라고 봅니다.
7. **수동 슬롯 공유**: 하루 1회 슬롯을 M5와 릴스 저장 제안이 함께 씁니다. 먼저 뜬 쪽이 슬롯을 가져가는 것을 의도된 동작으로 받아들입니다. 릴리스 노트나 테스트에서 "두 순간 모두 제안이 뜬다"고 약속하지 않습니다.

---

## 6. 기기에서 직접 확인해야 할 것 (TestFlight, `ios/DEVICE_TESTING.md`에 추가)
1. **확인 창**: alert로 바꾼 9곳(M1, M2, M3의 남은 흐름 포함)을 iOS 26과 iOS 17/18 각각, 기본 크기와 AX5(de·it, 긴 제목 2개)에서 확인합니다. 모든 곳에서 취소가 데이터를 건드리지 않아야 합니다.
2. **M5 적용 전 제안**:
   - "나중에"와 스와이프 모두 렌더가 시작되고 720p·워터마크로 나와야 합니다.
   - 광고를 끝까지 보면 1080p/4K, 워터마크 없음, `renderedPro == true`가 돼야 합니다.
   - 재감지 alert 직후와 renderGap 세션에서는 제안이 뜨지 않아야 합니다.
   - 설정 시트 안에서 적용을 눌러도 finishOffer가 실행돼야 합니다.
3. **긴 4K 세션(랠리 40개 이상)**: 패스를 받은 직후 다시 만들 때 staged 전체 재렌더가 통과하는지 봅니다(MAB#2).
4. **횟수 제한**: 한 실행에서 두 번째 제안이 없어야 하고, 3번 거절하면 7일 쉬어야 합니다. 광고 no-fill 상태에서는 수동 제안이 뜨지 않고 횟수도 소모되지 않아야 합니다(M4).
5. **ProPassView 경유 보상**: 제안 시트 안에서 전체 패스 화면을 열어 보상을 받았을 때 거절이 아니라 `.granted`로 기록되는지 봅니다(MAB#3, RC#1).
6. **M6 줄**:
   - 감지 중 탭 → 광고 → 이번 가져오기의 첫 클립이 패스 화질로 나와야 합니다.
   - `.render` 단계에 들어가면 줄이 사라져야 합니다.
   - 라이브러리와 세션 화면 양쪽 모두, de·it AX5에서 줄바꿈이 괜찮은지 봅니다.
7. **M7**: 가로 세션에서 "원본 화질" 제목이 나오고 9:16 비교가 없어야 합니다.
8. **M11**: 감지 중 경기를 삭제하면 화면이 다시 꺼지고 "일시정지" 알림이 오지 않아야 합니다.
9. **M9**: 패스 중 앱을 종료했다 다시 열면 연장 버튼이 보여야 합니다. 동의·ATT가 IntroView 뒤에 뜨고 배너는 없어야 합니다.
10. **M12·M13·M16**:
    - 원본이 없는 세션에서 삭제하면 되돌리기가 없어야 합니다.
    - 8초 안에 두 번 삭제하면 타이머가 다시 시작돼야 합니다.
    - "1 clip deleted" 문구가 맞아야 합니다.
    - 전면광고를 빚진 상태에서 플레이어로 삭제해도 광고가 되돌리기를 덮지 않아야 합니다.
11. **M14·M17**: 배너가 실린 상태에서 고정 바 간격을 봅니다. 제안을 스와이프로 닫은 뒤 60초 안에 전면광고가 없어야 합니다.
12. **M22**: 한국어·일본어 기기에서 ATT와 사진 권한 문구가 현지어로 나와야 합니다.
13. **TestFlight 설치**: 테스트 광고 단위가 쓰이는지(distribution == testflight) 확인합니다.

---

## 7. 1.1.0 새로운 기능 문구 초안

**한국어**
> - 경기 영상을 분석하는 동안과 클립을 다시 만들기 전에, 패스로 무엇이 좋아지는지(원본 화질·워터마크 없음) 바로 알려 드려요. 원하지 않으면 무료로 그대로 진행됩니다.
> - 클립·경기·릴스 삭제 확인 창이 화면 가운데에 깔끔하게 뜹니다.
> - 되돌리기, 패스, 광고 관련 안정성을 개선했어요.

**English**
> - See what a PASS adds (original quality, no watermark) while your match is analysed and before you rebuild clips. Not interested? Everything carries on for free.
> - Delete confirmations for clips, matches and reels now appear centred.
> - Fixes for Undo, the PASS and ads.

(다른 7개 언어는 각 언어의 패스 용어(PASE·PASSE·PASS·パス·通行证)로 같은 3줄을 씁니다. "Pro"와 "광고 없음"은 쓰지 않습니다.)

---

읽기 전용으로만 작업했고, 빌드나 기기 검증은 하지 않았습니다. 코드에서 직접 확인한 것은 다음 여섯 가지입니다: SessionDetailView:396 광고 가드, PassOfferSheet onDisappear와 "나중에" 버튼, ask_sport, 한국어 What's New 누락, SessionStore의 GPU 주석, isBusy. 나머지 줄 번호는 위원 보고를 그대로 따랐습니다.

위험 요소:
- M5는 심사 빌드에서 거의 항상 뜹니다. 그래서 APP_STORE.md 심사 노트 수정(M23)을 빼먹으면 안 됩니다.
- M22는 pbxproj 수정이 필요하면 1.1.1로 미룹니다.