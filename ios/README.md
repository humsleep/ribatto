# Vollio — iOS 앱

라켓 스포츠 경기 영상에서 랠리를 자동으로 찾아 클립·하이라이트로 만들어주는 앱.
사진 앱에서 영상을 가져오면 감지부터 렌더링까지 **전부 아이폰 안에서** 처리된다
(서버 없음, 계정 없음, 구독 없음).

## 실행

```bash
open ios/Vollio.xcodeproj
```

Xcode에서 시뮬레이터나 본인 아이폰을 선택하고 ⌘R. 터미널 빌드는:

```bash
cd ios && xcodebuild -project Vollio.xcodeproj -scheme Vollio -destination 'platform=iOS Simulator,name=iPhone 17' build
```

> 이 Mac은 `xcode-select`가 Command Line Tools를 가리키고 있어서, 터미널에서 빌드할 땐
> `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`를 앞에 붙이면 확실하다.

## 구조

```
Vollio/
  VollioApp.swift          앱 진입점 · 온보딩 분기 · 탭(라이브러리/모든 클립)
  Models.swift               Sport(종목별 감지 파라미터) · Sensitivity · Aspect · Session
  L10n.swift                 인앱 다국어 (영어 기본, 한국어, 일본어)
  Engine/                    ★ 핵심 — macOS/iOS 공용, 실측 검증 완료
    AudioLoader.swift        영상 → 16kHz 모노 샘플 (AVAssetReader)
    RallyDetector.swift      타구음 감지 (Accelerate vDSP FFT + 2단 임계값)
    ClipExporter.swift       클립 컷 · 화면비 · 페이드 인/아웃
    HighlightMerger.swift    하이라이트 합본 (무재인코딩 우선)
    VideoProbe.swift         메타데이터 + 포스터
  Store/
    SessionStore.swift       세션 영속화 + 처리 파이프라인
    PurchaseManager.swift    StoreKit 2 · 무료 3회 후 1회 결제
  Views/
    OnboardingView.swift     첫 실행 3단계 소개
    StatsView.swift          시즌 기록 · 개인 기록 · 인스타용 공유 카드
    LibraryView.swift        세션 카드 · 가져오기 · 무료 잔여/PRO 배지
    SessionDetailView.swift  종목·방향·민감도 · 통계 · 정렬 · 하이라이트
    PaywallView.swift        결제 화면
    ClipViews.swift          클립 카드 · 플레이어 · 모든 클립 탭
Tools/
  make_icon.swift            1024px 앱 아이콘 생성
  make_shots.swift           App Store 마케팅 스크린샷 합성 (1320x2868)
  validate.sh + ValidateMain.swift   새 영상으로 감지 정확도 점검
Marketing/                   생성된 스토어 스크린샷 5종
Vollio.storekit            로컬 결제 테스트 설정 (스킴에 연결됨)
```

## 수익 모델 (무료 / Pro)

| | 무료 | Pro (US$2.99 · 약 ₩4,400, 1회) |
|---|---|---|
| 영상 가져오기 | 3개 | 무제한 |
| 내보내기 화질 | 720p | **원본 화질 — 가로 최대 4K / 세로 1080p** |
| 워터마크 | 우하단 `Vollio` | **없음** |
| 사진 앱 일괄 저장 | — | **세션 전체 한 번에** |
| 클립 병합 | — | **고른 클립을 한 영상으로** |
| 랠리 중심 잡기(스마트 세로 크롭) | 중앙 고정 크롭 | **랠리가 벌어진 위치로 클립마다 프레임 배치** |
| 종목·방향·민감도·하이라이트 | 전부 사용 가능 | 동일 |

비소모품 IAP `com.vollio.pro`, 구독 아님. 잔여 횟수는 라이브러리 상단에 표시된다.
Pro로 전환하면 기존 세션에 "원본 화질로 다시 만들기" 배너가 뜬다.

Xcode에서 ⌘R로 실행하면 `Vollio.storekit` 설정이 자동 적용되어 실제 결제 없이
구매 흐름을 테스트할 수 있다 (Debug → StoreKit → Manage Transactions에서 환불도 가능).

## 새 영상으로 감지 정확도 점검

```bash
./Tools/validate.sh ~/Movies/badminton.mov badminton
```

종목·민감도 조합별로 몇 개의 랠리가 잡히는지, 원본의 몇 %가 남는지 출력한다.
실내 코트·야간·복식·다른 종목 영상을 넣어 프리셋이 맞는지 확인할 때 쓴다.

## 검증 상태

- 감지 엔진: 26분 4K 영상 기준 **오디오 추출 1.1초 + 감지 0.08초**, 이전 Python 검증 구현과 동일 결과
- 시뮬레이터 E2E: 가져오기 → 감지 → 클립 4개 → 하이라이트 합본 → 재생/공유 확인
- 결제: 페이월 UI와 무료 횟수 게이팅 확인 (실제 구매는 Xcode ⌘R 또는 샌드박스에서)
- 실기기: 미확인 → [DEVICE_TESTING.md](DEVICE_TESTING.md)

## 다음 단계

- [SUBMIT_GUIDE.md](SUBMIT_GUIDE.md) — **앱스토어 등록 전체 절차 (첫 등록자용, 결제·정산 포함)**
- [TESTING.md](TESTING.md) — 출시 전 직접 해볼 최종 점검 목록
- [DEVICE_TESTING.md](DEVICE_TESTING.md) — 내 아이폰에서 돌려보기 (무료 Apple ID로 가능)
- [APP_STORE.md](APP_STORE.md) — 출시 체크리스트, 스토어 문구 초안, 심사 대응
- [LAUNCH.md](LAUNCH.md) — 홍보 전략 (ASO, 커뮤니티, 가격, 3개월 목표)

## 저장 방식

사진 앱에서 가져온 영상은 **복사하지 않고 참조**한다 (`Session.assetIdentifier` →
`PHImageManager.requestAVAsset`). 2분30초 세션 기준 798MB → **118MB**로 줄었다.
사진 접근이 거부되거나 인앱 촬영으로 만든 세션은 예전처럼 로컬 사본을 쓴다.
원본이 사진 앱에서 삭제되면 세션 상세에 경고가 뜨고 재감지가 막힌다.

렌더링 중에는 `isIdleTimerDisabled`로 화면이 꺼지지 않게 하고, 안내 문구도 함께 띄운다
(iOS가 앱을 정지시키면 내보내기가 멈추기 때문).
