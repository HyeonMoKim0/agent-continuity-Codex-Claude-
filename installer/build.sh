#!/usr/bin/env bash
# build.sh — AgentContinuity-Setup.exe 빌드 (CI/로컬 공용, linux/mac 호스트에서 교차 컴파일)
# 사용: installer/build.sh <version>   예) installer/build.sh v0.4.0
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-dev}"

# 1) payload.zip: 저장소 내용(개발·빌드 산출물 제외)을 내장용으로 압축
rm -f payload.zip
( cd .. && zip -rq installer/payload.zip . \
    -x '.git/*' -x '.github/*' -x 'installer/*' -x 'dist/*' )

# 2) 아이콘·매니페스트 리소스 (.syso)
go run github.com/tc-hib/go-winres@v0.3.3 make --in winres/winres.json --arch amd64

# 3) GUI 서브시스템으로 빌드
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 \
  go build -trimpath -ldflags "-s -w -H windowsgui -X main.version=${VERSION}" \
  -o "AgentContinuity-Setup-${VERSION}.exe" .
echo "built: installer/AgentContinuity-Setup-${VERSION}.exe"
