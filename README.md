# mac-subtitles

Mac용 앱 모음입니다. 각 앱은 `apps/` 아래의 독립된 Swift 패키지입니다.

| 앱 | 설명 |
|---|---|
| [Live Subtitles](apps/live-subtitles) | 재생 중인 모든 소리를 실시간으로 번역해 화면 하단 자막으로 표시 |
| [Hey Mac](apps/hey-mac) | "헤이 맥"으로 불러서 음량·밝기·잠자기·미디어 등을 음성으로 제어 |

빌드: 각 앱 폴더에서 `./scripts/build-app.sh` (macOS 15 이상, Xcode 16 이상).
GitHub Actions의 Build 워크플로 아티팩트에서 빌드된 앱을 내려받을 수도 있습니다.
