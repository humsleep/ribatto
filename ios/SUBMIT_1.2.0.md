# Ribatto 1.2.0 심사 제출 가이드 (App Store Connect)

제출할 빌드: **1.2.0 (31)** — 새 클립 편집기(타임라인·자막·줌 키프레임·슬로모션), 클립별 보정, 앱 전체 새 색 체계, 전면광고 직전 패스 제안.

이번 버전에서 바뀌는 메타데이터: **앱 이름 · 부제 · 키워드 · 설명 · 프로모션 텍스트 · 새로운 기능 · 스크린샷(6장)**.
이름·부제·키워드는 새 버전을 제출할 때만 바꿀 수 있으니 이번에 꼭 함께 넣으세요.

준비물 위치
- 문구 9개 언어: [`marketing/app-store-copy.md`](../marketing/app-store-copy.md) — 언어별 App Name / Subtitle / Keywords / Promotional text / Description / What's New (1.2.0). 맨 위 "ASO rationale"에 키워드를 고른 이유가 있다.
- 스크린샷 6장(1320×2868): `marketing/screenshots/<폴더>/01~06.png` — 폴더와 스토어 언어의 대응은 5절 표
- 스크린샷 설계와 문구 근거: [`marketing/screenshot-plan.md`](../marketing/screenshot-plan.md)
- 심사 메모(영문): 이 문서 6절

---

## 0. 빌드 올리기 (2026-10-31)

빌드 **1.2.0 (31)**을 올립니다. 아카이브: `~/Library/Developer/Xcode/Archives/2026-10-31/Ribatto-1.2.0-31.xcarchive`
29와 다른 점: 결과 화면을 닫아 전면광고가 나올 차례면 "1시간 동안 광고 없이" 패스 제안이 먼저 뜹니다(거절하면 원래 광고).
빌드 30은 이미 쓰인 번호라 App Store Connect가 거절해서 31로 올렸습니다. 28·29·30은 제출하지 않습니다.

## 1. TestFlight에서 먼저 확인 (업로드 후 10~30분)

1. App Store Connect → **앱 → Ribatto → TestFlight** → 빌드 **31**이 "테스트 가능"이 될 때까지 대기.
   - "수출 규정 관련 문서 누락"이 뜨면 **아니요(암호화 사용 안 함)**.
2. 내부 테스트 그룹에 31 추가 → 아이폰 TestFlight 앱에서 설치.
3. 꼭 볼 것 (10분)
   - [ ] 영상 가져오기 → 감지 → 클립 생성
   - [ ] 클립 → **편집** → 타임라인이 손가락을 따라 부드럽게 움직이는지(실기기 4K에서 처음 보는 것)
   - [ ] **텍스트**: 글자 입력(한글 포함) → 미리보기에서 끌어 옮기기·두 손가락으로 크기 → 완료 → 클립에 그대로 구워지는지
   - [ ] **줌**: 미리보기 핀치로 키프레임 → 완료 → 클립이 부드럽게 당겨지는지
   - [ ] **속도 0.5×**, **보정** 하나 적용 → 완료
   - [ ] 30초 하이라이트 릴스 → 저장·공유
   - [ ] 패스 받기 → 테스트 광고 끝까지 → 1시간 패스
   - [ ] (패스 없이) 클립 하나를 만들고 결과를 닫기 → 3분 뒤 다른 결과를 닫으면 "1시간 동안 광고 없이" 제안 → "괜찮아요 · 광고 보기"를 누르면 전면광고가 나오는지
   - [ ] VoiceOver를 켜고 편집기 타임라인을 한 번 조작해 보기(시뮬레이터에서는 확인 못 함)
   - 이상하면 여기서 멈추고 알려 주세요. 고쳐서 다음 빌드로 올립니다.

## 2. 새 버전 만들기

**앱 → Ribatto → 배포(App Store)** → 왼쪽 "iOS 앱" 옆 **＋** → **1.2.0** → 만들기.

- 1.1.1이 아직 **"심사 대기 중"**이면: 1.1.1 페이지에서 **심사에서 제거** → 버전 번호를 **1.2.0**으로 바꿔 그 버전을 그대로 씁니다(빌드만 31로 교체).
- 1.1.1이 **"제출 준비 중"**이면: 그 버전의 번호를 1.2.0으로 바꿔 씁니다.
- 1.1.1이 이미 **출시됨**이면: 위의 ＋로 새로 만듭니다.

## 3. 앱 정보 (버전과 별도 화면) — 이름·부제

**먼저 언어 추가(이번에 새로):** 앱 정보 화면 오른쪽 위 언어 메뉴 → **언어 추가**로 6개를 넣습니다:
English (U.K.) · English (Australia) · English (Canada) · Spanish (Mexico) · Portuguese (Portugal) · French (Canada).
앱 화면 언어가 늘어나는 것이 아니라 스토어 목록만 생깁니다. 문구는 `app-store-copy.md`의 "국가별 추가 현지화" 절에 있습니다.

**앱 → Ribatto → 일반 → 앱 정보**에서 언어를 바꿔 가며 15개 모두:
- **이름**, **부제**: `app-store-copy.md` 해당 언어의 App Name / Subtitle 그대로.
  - 영어 이름이 `Ribatto: Rally Clips` → **`Ribatto: Tennis Highlights`**로 바뀝니다. 이름이 이미 다른 앱에 쓰이고 있으면 저장할 때 막힙니다 — 그때 알려 주세요(대안: `Ribatto: Tennis Video Clips`).
- 카테고리는 그대로(스포츠 / 사진 및 비디오).

> 이름·부제는 "앱 정보"에 있지만 실제 반영은 이 버전이 승인될 때 함께 됩니다.

## 4. 버전 정보 (언어별 9개)

오른쪽 위 언어 메뉴: English(기본) · 한국어 · 日本語 · Español · Português(Brasil) · Deutsch · Français · Italiano · 简体中文
+ 이번에 추가한 English (U.K./Australia/Canada) · Español (México) · Português (Portugal) · Français (Canada)

각 언어마다 `app-store-copy.md`에서 복사:
1. **프로모션 텍스트**
2. **설명**
3. **키워드** — 쉼표 뒤에 공백 없이 그대로. 한국어·일본어·중국어는 "100자 초과"로 거절되면 **뒤에서부터 키워드 1~2개를 지우세요**(글자 수로 셌는데 바이트로 세는 경우가 있습니다).
4. **이 버전의 새로운 기능**: "What's New (1.2.0)" / "새로운 기능 (1.2.0)" 블록.
5. 지원 URL·마케팅 URL은 그대로.

## 5. 스크린샷 (언어별 9개)

**iPhone 6.9" 디스플레이** 칸에서:
1. 기존 스크린샷 **5장을 모두 삭제**(각 사진 위 ⊖). 이번엔 장 수와 순서가 바뀌어서 남겨 두면 섞입니다.
2. `marketing/screenshots/<언어>/`의 **01 → 06 순서**로 끌어다 놓기.
   - 01 하이라이트 결과 · 02 새 편집기(자막, "NEW") · 03 소리로 랠리 찾기 · 04 줌 키프레임 · 05 30초 릴스 · 06 시즌 기록
   - 폴더 ↔ 스토어 언어

     | 폴더 | 스토어 언어 |
     |---|---|
     | `en` | English (U.S.) — 기본 |
     | `en-GB` | English (U.K.) · English (Australia) · English (Canada) — 같은 폴더를 세 번 씁니다 |
     | `es` | Español (España) |
     | `es-MX` | Español (México) |
     | `pt` | Português (Brasil) |
     | `pt-PT` | Português (Portugal) |
     | `fr` | Français · Français (Canada) — 같은 폴더 |
     | `de` `it` `ja` `ko` `zh-Hans` | 각 언어 |

   - pt-PT·es-MX 스크린샷의 앱 화면은 앱에 있는 pt(브라질)·es(스페인) 그대로이고, 헤드라인만 현지 표기입니다.
3. 6.5"·5.5" 칸은 비워 두면 6.9"가 자동 축소 사용됩니다.

참고: 영상 위 "MATCH POINT" 글자는 모든 언어에서 영어 그대로입니다(영상에 구운 예시 자막이라 의도한 것).

## 6. 앱 심사 정보

**로그인 필요**: 체크 해제. **연락처** 확인. **메모**에 아래를 그대로 붙여넣기:

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
4. NEW in 1.2.0 - the clip editor: open a clip and tap "Edit". The timeline
   scrolls under a fixed playhead. "Text" adds a caption that can be dragged and
   pinched on the preview; "Zoom" sets zoom keyframes by pinching the preview;
   "Speed", "Look", "Sound" and "Trim" are below. "Done" re-renders only that clip.
   All editing is free.
5. "30-second highlight reel" on the match screen builds a vertical reel at once;
   it can be saved, shared or edited from the result screen.
6. The pass: tap "PASS" under the "My Matches" title, then "Watch an ad".
   An optional PASS offer may appear while importing or before Apply; tapping
   "Later · make it free" continues the free flow unchanged.

About step 6: review builds request Google's public test ad units (a sandbox
receipt is treated as a pre-release install), so the rewarded ad plays as a
Google test ad labelled "Test mode". Watching it to the end opens the one-hour
pass. App Store installs use live ad units.

There are no in-app purchases and no accounts. Videos are processed on the
device and never uploaded.
```

**첨부 파일**: 비워 둠.

## 7. 빌드 선택 · 출시 방식 · 제출

1. **빌드** 섹션 → ＋ → **1.2.0 (31)** → 완료. 수출 규정은 **아니요**.
2. **버전 출시**: "이 버전을 수동으로 출시"(추천) — 바뀐 이름·스크린샷을 스토어에서 한 번 보고 내보낼 수 있습니다.
3. **단계적 출시(7일)**: 켜기 추천.
4. **저장 → 심사에 추가 → 심사 제출**.
5. 광고 식별자(IDFA) 질문: **예** → "앱 내에서 광고 제공" → ATT 사용 확인. 개인정보 "수집하는 데이터"는 그대로(이번 버전에서 수집 항목 변화 없음 — 편집은 전부 기기 안에서 처리).

## 8. 심사 결과별 대응

- **승인**: 배포 탭 → **이 버전 출시**.
- **메타데이터 거절**(이름·키워드·스크린샷): 빌드 재제출 없이 고쳐 다시 제출. 거절 문구를 그대로 주시면 수정안을 드립니다.
  - 가능성이 있는 곳: 05번 스크린샷의 릴스 화면 제목·버튼에 앱 UI 그대로 "Instagram"이 보입니다(이전 버전 스크린샷에도 있던 화면). 2.3.7로 지적받으면 해당 프레임만 다른 캡처로 바꿉니다.
- **2.1 추가 정보 요청**: 메시지를 주시면 회신 문안을 만듭니다. 화면 녹화가 필요하면 `APP_STORE.md` 4-2 순서.

## 9. 출시 후

- 검색 순위 확인: 1~2주 뒤 각 스토어에서 "tennis highlights", "pickleball video", "테니스 영상" 등으로 검색해 위치를 기록 → 다음 버전 키워드 조정에 씁니다.
- AdMob: 스토어 연결·app-ads.txt 상태 유지 확인.
- 다음 버전에서 할 일: 02번 스크린샷의 "NEW" 칩 떼기, es-MX(미국 스페인어) 현지화 추가 검토.
