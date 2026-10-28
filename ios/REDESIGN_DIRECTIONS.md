# Ribatto 리디자인 결정안 (2026-10-28)

## 1. 추천

**A(Evolve)를 뼈대로 하고 C의 화면 정리안과 B의 툴바 처리를 가져와 붙이는 안을 추천합니다.**

- **점수:** 비평가 3명 중 2명이 A를 골랐습니다. 네 항목 평균은 A 6.75, B 6.50, C 5.75입니다. A는 UX(7.33)와 아이콘(7.0)이 고르게 높고 치명적 약점이 없습니다.
- **B를 고르지 않은 이유:** B는 아이콘 점수가 가장 높지만(7.33) 갈색 바닥이 영상 썸네일을 탁하게 만듭니다. 또 브랜드색 클레이가 앱 안에는 없고 아이콘에만 있습니다. 지금 청록 아이콘이 앱 어디에도 안 쓰이는 문제를 그대로 되풀이하는 셈입니다.
- **C를 고르지 않은 이유:** C는 강조색을 흰색으로 바꿉니다. 그러면 스포츠 앱다운 느낌이 사라지고 토글 7곳과 tint 34곳을 하나씩 다시 칠해야 합니다. 아이콘도 60px에서 배터리나 카드처럼 보입니다.
- **A의 약점:** 색 변화가 미세해서 "색감이 별로"라는 지적에 덜 답한다는 평이 있었습니다. 그래서 데이터 전용 코트 시안(#5CC8DE)을 새로 넣고, 아래 7번에서 스토어 배경을 바꿀지 따로 묻습니다.

## 2. 방향별 비교

| 방향 | 한 줄 요약 | 아이콘 | 색 | UX | 실현성 | 평균 | 치명적 약점 |
|---|---|---|---|---|---|---|---|
| **A · Evolve** | 어두운 스포츠 톤 유지. 바닥을 따뜻한 흑연색으로, 볼트는 누를 것에만, 데이터는 시안 | 7.0 | 6.3 | 7.3 | 6.3 | **6.75** | 없음. 크롭 모서리가 QR·스캐너 아이콘과 닮았고, 색 변화가 미세함 |
| **B · Court** | 밤의 클레이 코트. 분필 선과 옐로 공 하나만 누르는 색 | 7.3 | 5.3 | 6.3 | 7.0 | 6.50 | 갈색 바닥이 영상을 탁하게 함. 클레이가 앱 밖에만 있음. 아이콘에 그림자가 구워져 있음 |
| **C · Clip-first** | 앱 화면은 흑백, 색은 사용자 영상만. 탭·스플래시·온보딩을 크게 줄임 | 5.0 | 5.7 | 7.3 | 5.0 | 5.75 | 흰 강조색이 스포츠 느낌을 지우고 토글이 안 보일 위험. 아이콘이 60px에서 안 읽힘 |

## 3. 최종 팔레트 (A + 비평 반영)

대비는 WCAG 2.x 기준입니다. 숫자는 순서대로 background / surface / surfaceHigh 위에서 잰 값입니다.

| 토큰 | hex | 용도 | 대비 |
|---|---|---|---|
| background | #0B0C0A | 앱 바닥. 옛 #0A0B0F는 푸른 기가 있어 볼트와 부딪쳤음 | 기본 글자 17.99 |
| surface | #171915 | 카드·시트·세션 카드 (rcCard) | 기본 글자 16.25 |
| surfaceHigh | #23261F | 선택 안 된 칩, 보조 버튼, 검색창, 진행 막대 트랙 | 기본 글자 14.09. 바닥과는 1.28이라 hairline이 필수 |
| hairline | #FFFFFF @ 9% | 카드·칩 테두리 | 장식용 |
| accent | #D4FF3F | 주 버튼 채움, 선택 칩, tint. **누를 수 있는 것과 현재 선택에만** | 글자로 쓰면 16.97 / 15.32 / 13.28 |
| onAccent | #0D1500 | accent 위 글자·글리프 | 16.16 (옛 조합 14.71). accent 위 흰 글자는 1.16이라 금지 |
| secondaryText (신규) | #A6AC9D | 날짜·힌트·단위·섹션 헤더. 정보를 담은 .secondary/.tertiary를 대체 | 8.41 / 7.59 / 6.58 (옛 .tertiary는 2.4로 불합격) |
| court (신규) | #5CC8DE | **데이터 전용, 누르지 않음**: 분석 파형, 시즌 차트 막대, 트림 스트립의 구간 표시 | 10.06 / 9.08 / 7.87 |
| warning | #FFB547 | 긴 구간 배지, 패스 만료, 부분 렌더 배너. 시스템 .orange를 대체 | 11.16 / 10.08 / 8.73 |
| danger | #FF6B5E | 삭제·폐기. 시스템 .red를 대체 | 7.02 / 6.34 / 5.49 |
| 기본 글자 | 시스템 label (약 #F4F6EF) | 본문. 비평대로 chalk 같은 별도 토큰은 만들지 않음 | 위 첫 칸 |

**함께 지킬 규칙**

- **영상 위 글자 (C에서 가져옴):** 흰색만 씁니다. 아래쪽 스크림을 55% 이상 깔고, secondaryText는 영상 위에 쓰지 않습니다(2.24로 불합격).
- **볼트 변경은 한 번에:** #C8F63E를 #D4FF3F로 바꾸면 영상에 굽는 `.volt`(ReelBuilder.swift:135), 워터마크·훅 색, 시즌 공유 카드, 마케팅 글로우도 같은 변경에서 바꿉니다. 아니면 이미 올린 릴스와 UI의 볼트가 어긋납니다.
- **순수 검정 금지:** 순수 검정이 필요해 보이는 곳에는 #050506을 씁니다(OLED 스미어 방지).
- **색은 셋만:** 브랜드(볼트), 데이터(시안), 상태(warning/danger)입니다. B의 클레이를 앱 안에 들이지 않습니다.

## 4. 서체 규칙

- **원칙:** UI는 전부 SF입니다. 개성은 Font.width와 굵은 숫자로 냅니다. Bebas·Anton은 Dynamic Type과 한중일 글리프가 없어서 영상에 굽는 글자에만 씁니다.
- **탭 제목(TabHeader.titleText):** `.largeTitle.weight(.heavy).width(.condensed)`. `lineLimit(1)`과 `minimumScaleFactor(0.6)`은 유지합니다.
- **시트·내비 제목:** `.headline.weight(.bold)`.
- **섹션 헤더 (C에서 가져옴):** `.subheadline.weight(.semibold)`, secondaryText, 문장형 대소문자입니다. uppercase와 tracking은 쓰지 않아 9개 언어가 같은 모양이 됩니다. A의 대문자·자간 안은 버립니다.
- **큰 숫자**(히어로 길이, 시즌 합계, 랠리 수): `.system(.largeTitle, weight: .heavy).width(.compressed).monospacedDigit()`. 단위는 `.subheadline.weight(.semibold)` secondaryText로 쓰고 `HStack(alignment: .firstTextBaseline)`에 둡니다.
- **행 값**("42s", "12.8"): `.title3.weight(.bold).width(.condensed).monospacedDigit()`.
- **영상 위 숫자:** `.title3.weight(.heavy).width(.condensed).monospacedDigit()` 흰색, `...DynamicTypeSize.xxLarge` 상한.
- **메타**(날짜·시간): `.footnote.monospacedDigit()` secondaryText.
- **버튼 (C에서 가져옴):** RCPrimaryButton과 RCSecondaryButton을 `.body.weight(.semibold)`, 최소 높이 50, `lineLimit(2)`, 가운데 정렬로 바꿉니다. 독일어·이탈리아어 문구가 잘리지 않고 두 줄로 내려갑니다.
- **배지:** ProBadge는 `.caption2.weight(.heavy)`에 `.xLarge` 상한을 그대로 둡니다.
- **한중일:** width 축이 조용히 무시되고 같은 굵기의 보통 폭으로 나옵니다. 숫자는 SF라 압축 숫자가 유지됩니다. 실제로 렌더해 보지는 않았습니다.
- **압축(compressed):** 숫자에만 씁니다. 단어에 쓰면 AX 크기의 독일어가 읽기 어려워집니다.

## 5. UX 변경 (구현 순서)

| # | 화면 | 변경 | 파일 | 작업량 |
|---|---|---|---|---|
| 1 | 앱 전체 | 토큰 교체. StatsView:282 `.tint`→secondaryText, StatsView:200과 분석 파형→court, lime #D6ED6B→Theme.accent, `.red`/`.orange`→danger/warning. 볼트를 영상 굽기(ReelBuilder.swift:135)·워터마크·공유 카드까지 함께 바꿈. 반경 토큰 6/12/16/Capsule, TabHeader 좌우 여백 16 | Theme.swift, StatsView.swift, AnalysisStrip.swift, LibraryView.swift, ReelBuilder.swift | S |
| 2 | 클립 플레이어 | 툴바를 중립 tint로 바꿈(B). 왼쪽 X, 오른쪽 공유와 ⋯(즐겨찾기·트림·다른 사람 추적·삭제) (C). "릴스 만들기"만 주 버튼으로 남김 | ClipViews.swift | S–M |
| 3 | 세션 상세 | 히어로를 전체 폭으로. 영상 위 55% 스크림에 베스트 랠리 길이를 큰 숫자로. 바로 아래 "30초 릴스"가 유일한 주 버튼. 요약 줄은 일반 텍스트로 바꾸고 설정은 ⋯에서만 진입. 공백 카드 버튼은 rcSecondary. 히어로 반경 22 | SessionDetailView.swift | S–M |
| 4 | 릴스 결과·릴스 탭 상세 | 주 버튼 "저장하고 인스타 열기" 하나 아래에 저장·공유·편집 아이콘 버튼 한 줄. 하나의 뷰로 만들어 릴스 탭 상세도 같이 씀(지금은 그 화면에 인스타 버튼이 없음) | ReelSheet.swift, ReelsView.swift | S |
| 5 | 라이브러리 | 헤더의 "선택" 버튼을 없애고 길게 누르기로만 선택. 메뉴에 바로 삭제 추가. PASS 알약은 테두리 스타일. 카드는 포스터 타일로(C): 흰 메타 "9 rallies · best 0:42 · 릴스 ✓" + 55% 스크림 | LibraryView.swift | S |
| 6 | 라이브러리→세션 | 영상 한 개를 가져오면 그 세션으로 바로 이동(NavigationStack path). 여러 개는 지금처럼 큐 | LibraryView.swift | S |
| 7 | 실행·온보딩 | 1.6초 IntroView 삭제. 온보딩 3페이지를 1페이지(종목 칩 + "경기 영상 고르기")로. 광고 시작 조건 `.task(id:)`·scenePhase를 `onboarded` 기준으로 바꿈. 동의→ATT→SDK 순서와 `retryIfNeverStarted`를 다시 검증. lastSport가 nil인 기존 사용자용 종목 다이얼로그는 남김 | IntroView.swift, OnboardingView.swift, RibattoApp.swift, LibraryView.swift | S–M |
| 8 | 작은 빈틈 | 첫 릴스에는 전면광고 없음. 빈 릴스 탭에 "경기 가져오기" 버튼. 워터마크·기본 자막을 인스타 하단 UI 띠 밖으로(워터마크 좌하단 0.24H, 자막 y 0.70) | AdsManager.swift, ReelsView.swift, ClipExporter.swift | S 각각 |
| 9 | (오너 선택) 탭 바 | 시즌 탭을 라이브러리 맨 위 한 줄("10월 · 4경기 · 14랠리")로 접음. 누르면 StatsView로 이동. 탭 3개→2개, 배너 노출면 하나 감소 | RibattoApp.swift, LibraryView.swift, StatsView.swift | M |
| 보류 | 세션 상세 | 클립이 다 만들어지기 전에 릴스 열기(렌더 큐 일시정지). 비평가 2명이 이번 범위에서 빼라고 했습니다. SessionStore의 -11819 메모리·staging·waitForForeground 규칙을 건드리고, 긴 랠리로 기기에서만 검증할 수 있습니다 | SessionStore.swift, SessionDetailView.swift | M 이상, 별도 라운드 |

## 6. 아이콘

- **추천 파일:** `/private/tmp/claude-501/-Users-hyukahn-workspace-tennis-video/1904d62b-415a-4fb0-86bd-ed4587a1bcd3/scratchpad/redesign/A/icon-1024.png`
- **180px 미리보기:** `/private/tmp/claude-501/-Users-hyukahn-workspace-tennis-video/1904d62b-415a-4fb0-86bd-ed4587a1bcd3/scratchpad/redesign/A/icon-180.png`
- **생성기:** `/private/tmp/claude-501/-Users-hyukahn-workspace-tennis-video/1904d62b-415a-4fb0-86bd-ed4587a1bcd3/scratchpad/redesign/A/make_icon.swift`
- **팔레트:** `/private/tmp/claude-501/-Users-hyukahn-workspace-tennis-video/1904d62b-415a-4fb0-86bd-ed4587a1bcd3/scratchpad/redesign/A/palette.png`
- **콘셉트:** 볼트 테니스공(#D4FF3F, 솔기 두 줄, -36°)이 9:16 비율의 흰 크롭 모서리 네 개를 뚫고 오른쪽 위로 날아갑니다. 왼쪽 아래로 볼트 잔상 세 줄이 남습니다. 바닥은 앱과 같은 흑연색 그라데이션(#1E221A→#0B0C0A)이라 아이콘·앱·스토어가 한 바닥색을 씁니다. "세로 릴스로 잘라낸 랠리"라는 뜻이고, 재생 삼각형 같은 상투적 기호를 쓰지 않습니다.
- **확정 전 수정할 점 (비평 반영):**
  - 공이 9:16 틀 밖으로 확실히 벗어나게 오른쪽 위 모서리 너머로 더 밀고, 공을 틀 안으로 묶어 보이게 하는 바닥색 링을 없앱니다. 스캐너·QR 아이콘처럼 읽히는 문제를 줄이기 위해서입니다.
  - 잔상은 60px에서도 살아남게 더 굵게 하거나, 아예 빼고 공이 틀을 넘는 모양만으로 움직임을 표현합니다.
  - 최종 PNG는 알파 채널이 없어야 합니다.
- **iOS 26 변형 계획:** 그림자를 굽지 않고 Icon Composer `.icon`의 2그룹(바닥 / 모서리 / 공+잔상)으로 넣습니다.
  - 다크: 같은 그림을 순수 #000 위에 두고 글로우를 뺍니다.
  - 틴트: 모서리 100%, 공 70% 휘도, 솔기는 투명하게 뚫습니다. 아직 렌더하지 않았으니 확정 전에 틴트 미리보기로 공과 모서리가 겹치는 부분을 꼭 확인해야 합니다.
  - 클리어: 모서리는 글래스, 공은 반사광 레이어로 둡니다.
- **대안 (B, 그리드에서 가장 눈에 띔):** `/private/tmp/claude-501/-Users-hyukahn-workspace-tennis-video/1904d62b-415a-4fb0-86bd-ed4587a1bcd3/scratchpad/redesign/B/icon-1024.png`, 180px는 `/private/tmp/claude-501/-Users-hyukahn-workspace-tennis-video/1904d62b-415a-4fb0-86bd-ed4587a1bcd3/scratchpad/redesign/B/icon-180.png`. 클레이 코트의 T자 선과 옐로 공입니다. 쓴다면 공 아래 구운 그림자를 없애고, 흐린 스키드 자국은 선명하게 하거나 지워야 합니다.

## 7. 오너가 고를 것

1. **방향:** A 기반 혼합안(추천), B(클레이), C(흑백) 중 하나.
2. **아이콘:** A 수정판(추천)과 B 클레이 코트 중 하나.
3. **볼트 색:** #D4FF3F로 바꾸고 영상에 굽는 색까지 한 번에 갱신(추천), 또는 #C8F63E 유지(변경 범위 최소).
4. **시즌 탭:** 라이브러리 한 줄로 접기(탭 2개)와 지금처럼 유지(탭 3개) 중 하나.
5. **클립보다 릴스 먼저(보류 항목):** 다음 라운드로 따로 진행(추천)과 이번에 포함 중 하나. 이번에 넣으면 긴 랠리로 기기 실측을 해야 합니다.
6. **스토어 스크린샷 배경:** 앱과 같은 흑연색(추천, 일관성)과 클레이 배경(첫 번째 비평가 제안, 경쟁작과의 차별화) 중 하나.
7. **밝은 배경(라이트 모드):** 세 안 모두 다크 전용입니다. 영상 앱이라 다크 유지를 추천하고, 라이트 모드는 따로 디자인해야 합니다.

---
안 한 것: 빌드, 시뮬레이터, 9개 언어 렌더는 하지 않았습니다. 대비 수치는 각 제안서의 계산을 그대로 옮겼고 다시 재지 않았습니다. 아이콘 PNG는 파일이 있는지만 확인했고 직접 열어 보지 않았습니다.
위험: 5번 7행(인트로 삭제)은 광고 동의→ATT→SDK 순서를 건드립니다. 1행(볼트 변경)을 영상 쪽과 따로 내보내면 이미 올린 릴스의 색이 UI와 달라집니다. CLAUDE.md 규칙대로 코드를 고치기 전에 오너 확인이 필요합니다.