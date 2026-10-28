# Ribatto 1.1.1 심사 제출 가이드 (App Store Connect)

제출할 빌드: **1.1.1 (26)** — 새 아이콘·리디자인·버그 수정이 모두 들어간 마지막 빌드입니다.
빌드 21~25는 고르지 마세요.

준비물 위치
- 새로운 기능 문구(9개 언어): `marketing/app-store-copy.md` 각 언어의 "What's New (1.1.1)" / "새로운 기능 (1.1.1)"
- 스크린샷(9개 언어 × 5장, 1320×2868): `marketing/screenshots/<언어>/01~05.png`
- 심사 메모(영문): 이 문서 5절

---

## 1. TestFlight에서 먼저 확인 (10~20분)

1. App Store Connect → **앱 → Ribatto → TestFlight** 탭.
2. 빌드 **26**이 "처리 중"에서 "테스트 가능"으로 바뀔 때까지 기다립니다(보통 10~30분).
   - "수출 규정 관련 문서 누락"이 뜨면: **"아니요(암호화 사용 안 함)"** 선택. Info.plist에 이미 `ITSAppUsesNonExemptEncryption = NO`가 있어 대부분 자동 처리됩니다.
3. **내부 테스트** 그룹에 빌드 26을 추가 → 아이폰의 TestFlight 앱에서 설치.
4. 꼭 볼 것 (5분 체크)
   - [ ] 홈 화면 아이콘이 새 아이콘(볼트 공 + 소리 호)인지
   - [ ] 처음 실행: 온보딩 1장 → 시작하기 → 광고 동의 → 추적 허용 창 순서
   - [ ] 영상 하나 가져오기 → 그 경기 화면으로 바로 이동 → 감지·클립 생성
   - [ ] 클립 열기 → **편집** → 속도 0.5× 적용 → 클립이 느리게 나오는지
   - [ ] 30초 하이라이트 릴스 → 결과 화면 **저장 · 공유 · 편집** 버튼
   - [ ] "패스 받기" → 광고(테스트 광고) 끝까지 → 1시간 패스 열림
   - [ ] 클립 삭제·경기 삭제 확인창이 화면 가운데 뜨는지
   - 이상하면 여기서 멈추고 알려 주세요. 고쳐서 빌드 27로 올립니다.

## 2. 새 버전 만들기

1. **앱 → Ribatto → 배포(App Store)** 탭 → 왼쪽 "iOS 앱" 옆 **＋** → 버전 번호 **1.1.1** 입력 → 만들기.
   - 이미 1.1.0 버전이 "제출 준비 중"으로 만들어져 있다면, 그 버전을 열어 **버전 번호를 1.1.1로 바꿔** 쓰세요(새로 만들지 않아도 됨).

## 3. 버전 정보 입력 (언어별)

오른쪽 위 언어 메뉴에서 언어를 바꿔 가며 9개 모두 입력합니다:
English(기본) · 한국어 · 日本語 · Español · Português(Brasil) · Deutsch · Français · Italiano · 简体中文

각 언어마다:
1. **이 버전의 새로운 기능**: `marketing/app-store-copy.md`의 해당 언어 1.1.1 블록 붙여넣기.
2. **스크린샷 → iPhone 6.9" 디스플레이**:
   - 기존 스크린샷을 모두 삭제(각 사진 위 ⊖) → `marketing/screenshots/<언어>/` 의 **01 → 05 순서**로 끌어다 놓기.
   - 폴더 대응: en=English, ko=한국어, ja=日本語, es=Español, pt=Português, de=Deutsch, fr=Français, it=Italiano, zh-Hans=简体中文
   - 6.5"·5.5" 칸은 비워 두면 6.9"가 자동으로 축소 사용됩니다.
3. 프로모션 텍스트·설명·키워드: 바꾸고 싶을 때만 `app-store-copy.md`에서 복사(선택). 키워드는 새 버전을 낼 때만 바꿀 수 있습니다.

> 앱 아이콘은 빌드에 들어 있어서 따로 올리지 않습니다. 스토어에는 빌드 26의 아이콘이 자동으로 표시됩니다.

## 4. 빌드 선택

1. 같은 페이지 아래 **빌드** 섹션 → **빌드 추가(＋)** → **1.1.1 (26)** 선택 → 완료.
2. 수출 규정 질문이 나오면 **아니요**.

## 5. 앱 심사 정보

**로그인 필요**: 체크 해제(계정 없음).
**연락처**: 이름·전화·이메일 확인.
**메모**: 아래를 그대로 붙여넣기.

```
Ribatto analyses a racket-sport match video that the user imports from Photos.
The reviewer's device is unlikely to have suitable footage, so please use this
sample: https://humsleep.github.io/apps/ribatto/review/

Steps:
1. Save the sample video to the device's Photos library.
2. Open Ribatto. On the welcome screen choose Tennis and tap "Get started".
3. Tap + at the top of "My Matches", then "From Photos", and pick the sample.
   The app opens the match and detection runs automatically; the best rally
   plays at the top as soon as it is found, and clips follow within about a minute.
4. Open a clip to play it. "Edit" changes its speed and length.
   "30-second highlight reel" builds a vertical reel at once; it can be saved,
   shared or edited (colour, sound, background) from the result screen.
5. The pass: tap "Get PASS" under the "My Matches" title, then "Watch an ad".
   An optional PASS offer may appear while importing or before Apply; tapping
   "Later · make it free" continues the free flow unchanged.

About step 5: review builds request Google's public test ad units (a sandbox
receipt is treated as a pre-release install), so the rewarded ad plays as a
Google test ad labelled "Test mode". Watching it to the end opens the one-hour
pass. App Store installs use live ad units.

There are no in-app purchases and no accounts. Videos are processed on the
device and never uploaded.
```

**첨부 파일**: 비워 둠(지난 심사에서 요청받은 화면 녹화가 다시 필요하면 `APP_STORE.md` 4-2의 녹화 순서를 따르세요).

## 6. 출시 방식

**버전 출시** 섹션에서 하나 선택:
- **이 버전을 수동으로 출시** (추천): 승인 뒤 직접 "출시" 버튼을 누름. 아이콘·스크린샷을 스토어에서 한 번 더 보고 내보낼 수 있습니다.
- 자동 출시: 승인 즉시 공개.

**단계적 출시(7일)**: 켜기를 추천합니다. 문제가 생기면 일시 정지할 수 있습니다(새로 받는 사용자는 바로 받을 수 있고, 자동 업데이트만 7일에 걸쳐 퍼집니다).

## 7. 제출

1. 페이지 오른쪽 위 **저장** → **심사에 추가** → **심사 제출**.
2. 광고 식별자(IDFA) 질문이 나오면: **예, 광고 식별자를 사용함** → "앱 내에서 광고 제공" 체크 → 추적 투명성(ATT) 사용 확인 체크. (개인정보 "앱이 수집하는 데이터"는 1.0 때 입력한 그대로 둡니다 — 이번 버전에서 바뀐 수집 항목은 없습니다.)
3. 상태가 **"심사 대기 중"**이 되면 끝. 보통 24~48시간 안에 결과가 옵니다.

## 8. 심사 결과별 대응

- **승인됨**: 수동 출시를 골랐다면 배포 탭 → **이 버전 출시**.
- **거절 / 추가 정보 요청(Guideline 2.1)**: 메시지 전문을 복사해서 주세요. 회신 문안을 만들어 드립니다. 화면 녹화를 요구하면 `APP_STORE.md` 4-2 녹화 순서대로 찍어 첨부하면 됩니다.
- **메타데이터 거절**(스크린샷·문구): 빌드 재제출 없이 문구·이미지만 고쳐 다시 제출할 수 있습니다.

## 9. 출시 후

- AdMob 콘솔: 앱 → **스토어 연결 상태**와 **app-ads.txt 확인됨**인지 확인.
- App Store Connect → 평가 및 리뷰: 1.1.1 이후 평점 요청이 버전마다 한 번 뜨므로 평점 수 변화를 지켜보세요.
- 홈 화면 아이콘이 다크·틴트 모드에서 어떻게 보이는지 확인 — 어색하면 다크·틴트 전용 아이콘을 다음 업데이트에 추가합니다.
