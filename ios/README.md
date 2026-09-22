# Ribatto — iOS 앱

라켓 스포츠 경기 영상에서 랠리를 자동으로 찾아 클립·하이라이트로 만들어주는 앱.
사진 앱에서 영상을 가져오면 감지부터 렌더링까지 **전부 아이폰 안에서** 처리된다
(서버 없음, 계정 없음, 구독 없음).

## 실행

```bash
open ios/Ribatto.xcodeproj
```

Xcode에서 시뮬레이터나 본인 아이폰을 선택하고 ⌘R. 터미널 빌드는:

```bash
cd ios && xcodebuild -project Ribatto.xcodeproj -scheme Ribatto -destination 'platform=iOS Simulator,name=iPhone 17' build
```

> 이 Mac은 `xcode-select`가 Command Line Tools를 가리키고 있어서, 터미널에서 빌드할 땐
> `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`를 앞에 붙이면 확실하다.

## 구조

(파일 지도는 저장소 루트의 `CLAUDE.md`가 최신이다. 여기에 두 벌을 두면 한쪽이 낡는다.)

## 수익 모델 (무료 / Pro) — 광고 전용, 구매 없음

| | 무료 | Pro (리워드 광고 1편 = 1시간) |
|---|---|---|
| 광고 | 배너 + 렌더 완료 뒤 전면광고(3분 간격) | **없음** |
| 내보내기 화질 | 720p | **원본 화질 — 가로 최대 4K / 세로 1080p** |
| 워터마크 | `Ribatto` | **없음** |
| 사진 앱 일괄 저장(2개 이상) | — | **가능** |
| 클립 병합 | — | **가능** |
| 스마트 세로 크롭 · 특정 인물 추적 | 중앙 고정 크롭 | **가능** |
| 종목·방향·민감도·캡션·릴스 | 전부 사용 가능 | 동일 |

렌더는 시작 시점의 등급을 굽는다 — 패스 중 만든 클립은 패스가 끝나도 그대로다.
인앱 구입은 2026-09-15에 걷어냈고, 되살릴 때는 태그 `pro-iap-snapshot`에서 가져온다.

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
