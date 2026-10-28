# Ribatto 앱 아이콘 디자인 브리프 & 프롬프트

직접 만드실 때 쓰는 자료입니다. 이미지 생성 도구(ChatGPT 이미지, Midjourney, Ideogram, Firefly 등)에 넣는 프롬프트는
영어로 쓰는 편이 결과가 좋아서 프롬프트 본문은 영어, 설명은 한국어로 적었습니다.

---

## 1. 이 아이콘이 해야 할 일

- **한 장면으로 앱을 말한다:** "라켓 경기 영상 → 세로 하이라이트 릴스". 경기(공·코트)와 결과물(9:16 세로 영상)이 한 그림에 있어야 합니다.
- **홈 화면 60px, 스토어 검색 결과 썸네일에서 살아남는다:** 큰 형태 1~2개, 가는 선·작은 디테일·글자 없음.
- **유료·대형 개발사 앱 수준의 마감:** 평평한 클립아트나 "AI가 만든 느낌"이 아니라, 빛·재질·여백이 계산된 한 개의 오브젝트.
- **경쟁 앱과 구분된다:** SwingVision(청록·공), CapCut(흑백 기호), Strava(주황 로고)와 나란히 놓였을 때 먼저 눈에 띄어야 합니다.

## 2. 브랜드 고정값 (앱 안 색과 같아야 함)

| 역할 | 색 | 쓰는 곳 |
|---|---|---|
| 볼트(브랜드) | `#D4FF3F` | 공, 강조 한 곳 |
| 흑연 바닥 | `#0B0C0A` → `#1E221A` 그라데이션 | 배경 |
| 분필 흰색 | `#F4F6EF` | 틀·선 |
| 코트 시안(선택) | `#5CC8DE` | 아주 작은 포인트에만, 없어도 됨 |

- 바닥은 앱과 같은 어두운 흑연색이어야 아이콘 · 앱 · 스토어 스크린샷이 한 브랜드로 보입니다.
- 볼트는 한 오브젝트(공)에만. 여러 곳에 칠하면 싸 보입니다.

## 3. 형식 요건 (App Store 제출 기준)

- 1024 × 1024 PNG, **불투명(알파 채널 없음)**, sRGB 또는 Display P3
- **모서리를 둥글게 자르지 말 것** — iOS가 자동으로 마스크합니다. 정사각형 그대로.
- 글자·로고 문자·워터마크·그림자 구움 금지(그림자는 iOS 26이 레이어로 처리)
- 중요한 형태는 가운데 약 80% 안에(가장자리 10%는 마스크·글래스 효과로 잘리거나 흐려짐)
- iOS 26용 변형 3개를 함께 만들면 가장 좋습니다: **기본(Default) · 다크(Dark) · 틴트(Tinted/Clear)**
  → Xcode의 **Icon Composer**에 레이어(배경 / 틀 / 공)로 나눠 넣으면 시스템이 글래스·틴트를 자동 처리합니다.

---

## 4. 콘셉트 3안 + 프롬프트

각 안마다 메인 프롬프트를 그대로 붙여 넣으세요. 마음에 드는 결과가 나오면 5절의 "다듬기 프롬프트"로 이어서 고칩니다.

### 안 A — "틀을 뚫는 공" (현재 아이콘의 고급판, 추천)

볼트 테니스공이 9:16 세로 영상 틀의 모서리를 뚫고 튀어나옵니다. "경기에서 하이라이트가 튀어나온다".

```
A premium iOS app icon, 1024x1024, square canvas, no rounded corners, no text.
A single glossy optic-yellow tennis ball (#D4FF3F) with two clean dark seams bursting out
of the top-right corner of a vertical 9:16 video frame drawn as four thick rounded white
corner brackets (#F4F6EF). The ball overlaps and breaks the frame boundary, slightly larger
than the frame's width, with a short soft motion trail behind it.
Background: deep warm graphite gradient (#1E221A top-left to #0B0C0A bottom-right) with a
subtle radial volt glow behind the ball.
Style: Apple-quality, 3D-lit but restrained, soft studio lighting from top-left, subtle
specular highlight and felt texture on the ball, crisp geometric brackets, generous margins,
centered composition, high contrast, readable at 60 px.
Mood: fast, sporty, premium, confident. Like a flagship sports app by a major studio.
```

### 안 B — "코트 위의 세로 프레임"

위에서 내려다본 어두운 코트 라인 위에 세로 9:16 카드가 놓이고, 그 안에 공이 하나. "코트에서 잘라낸 장면".

```
A premium iOS app icon, 1024x1024, square, no rounded corners, no text.
Top-down view of a dark graphite tennis court (#0B0C0A to #1E221A) with two crisp chalk-white
court lines (#F4F6EF) meeting in a T. Floating above the court, a vertical 9:16 rounded card
made of frosted dark glass with a thin bright edge, slightly tilted (about 8 degrees),
casting a soft shadow onto the court. Inside the card, one optic-yellow tennis ball (#D4FF3F)
glowing softly. Minimal, geometric, calm luxury.
Style: Apple design language, glassmorphism, soft volumetric light, precise edges,
high readability at small size, centered, generous padding.
```

### 안 C — "공의 궤적 = 재생 버튼" (가장 기호적)

공이 지나간 궤적이 재생(▶) 삼각형 모양을 그립니다. 가장 단순하고 작은 크기에서 강합니다.

```
A premium minimalist iOS app icon, 1024x1024, square, no rounded corners, no text.
A single optic-yellow tennis ball (#D4FF3F) at the right point of a bold play-button triangle
whose two other edges are formed by the ball's own smooth motion trail, tapering and fading
toward the left. Deep warm graphite background (#0B0C0A to #1E221A) with a faint volt glow.
Style: bold, iconic, Apple-quality, one strong shape, subtle 3D shading on the ball only,
flat clean trail, perfectly balanced in the center, instantly readable at 60 px,
feels like a top-grossing paid app.
```

---

## 5. 공통 — 다듬기 프롬프트 & 금지어

**다듬기(결과가 나온 뒤 이어서 요청):**

```
Keep the same composition. Make the shapes simpler and bolder so it reads at 60 px.
Remove any small details, thin lines and noise. Increase contrast between the ball and the background.
Keep generous padding: all important shapes inside the central 80%.
No text, no letters, no watermark, no border, no rounded-corner mask, opaque square image.
```

**다크/틴트 변형용:**

```
Same icon, dark mode variant: pure near-black background (#050506), no glow,
ball and brackets keep their colors. Then a tinted variant: single-color white glyphs
on transparent background, ball rendered as a solid shape with seams cut out.
```

**금지(네거티브 프롬프트 칸이 있으면):**

```
text, letters, logo text, watermark, signature, photo-realistic people, racket strings close-up,
busy background, multiple balls, clutter, thin lines, noise, grain, gradient banding,
rounded corners, drop shadow outside the canvas, border, frame around the whole icon, low contrast
```

---

## 6. 결과물 고르는 기준 (체크리스트)

- [ ] 60px로 줄여도 "공 + 세로 영상"이 바로 보인다 (스마트폰 홈 화면에 띄워 확인)
- [ ] 흑연 바닥 + 볼트 공 — 앱 화면·스토어 스크린샷과 같은 브랜드로 보인다
- [ ] 글자·작은 디테일 없음, 형태 1~2개
- [ ] 흔한 기호(재생 삼각형만, 카메라, 필름 릴)로만 이뤄지지 않았다 — 안 C는 공이 핵심이어야 함
- [ ] SwingVision·CapCut·Strava 아이콘 옆에 놓고 봐도 먼저 눈에 띈다
- [ ] 가장자리 10% 안에 중요한 형태가 없다

## 7. 앱에 넣는 방법

완성 파일을 주시면 제가 넣어도 됩니다. 직접 하실 때는:

1. 1024×1024 PNG를 `ios/Ribatto/Assets.xcassets/AppIcon.appiconset/icon-1024.png`에 덮어쓰기
2. 알파 확인: `sips -g hasAlpha icon-1024.png` → `hasAlpha: no`여야 함 (yes면 업로드 거절)
3. 시작 화면 로고(`AppLogo.imageset`)도 같은 그림으로 교체 — 지금은 아이콘을 둥글게 자른 120/240/360px
4. Icon Composer를 쓰면 `.icon` 파일을 프로젝트에 넣고 AppIcon 대신 지정 (다크·틴트 자동)
