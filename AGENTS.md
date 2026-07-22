# TokenMeter

Swift로 만든 일반 macOS 앱입니다.

## 프로젝트 계약

- 앱 표시명, Swift target, 릴리스 산출물 이름은 `TokenMeter`를 사용합니다.
- 릴리스 ZIP에는 인앱 설치가 기대하는 `TokenMeter.app`을 포함합니다.
- 메뉴 막대 전용 앱으로 바꾸지 않습니다.
- 토큰 데이터는 로컬에 보관하며 GitHub 통신은 업데이트 확인과 다운로드에만 사용합니다.
- 설정은 영향을 주는 UI 가까이에 둡니다.

## 검증

- 일반 변경: `./scripts/verify.sh`
- 좁은 Swift/UI 변경도 최소 `swift build`를 실행합니다.
- 앱 이름이나 패키징 변경은 `dist/`, `Info.plist`, `/Applications` 설치 상태까지 확인합니다.
