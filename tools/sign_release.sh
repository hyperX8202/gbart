#!/bin/sh
# Signs the release app package for AppGallery with the release key, certificate and profile.
#   tools/sign_release.sh [signing dir]   (default: ../signing next to the project)
# Build first:  hvigorw --mode project -p product=release -p buildMode=release assembleApp
# The signing dir holds keyboard-release.p12, PASSWORT.txt, the AGC certificate (*.cer) and the
# AGC release profile (*.p7b); it is never part of the repository.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SIGN=${1:-$ROOT/../signing}
SDK=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/lib
JAVA=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home/bin/java
PW=$(sed -n 's/.*passwort: //p' "$SIGN/PASSWORT.txt")
CER=$(ls "$SIGN"/*.cer | head -1)
P7B=$(ls "$SIGN"/*.p7b | head -1)
IN="$ROOT/build/outputs/release/keyboard-release-unsigned.app"
OUT="$ROOT/build/outputs/release/gBart-release-signed.app"
"$JAVA" -jar "$SDK/hap-sign-tool.jar" sign-app -mode localSign -keyAlias keyboard-release \
  -keyPwd "$PW" -keystoreFile "$SIGN/keyboard-release.p12" -keystorePwd "$PW" \
  -signAlg SHA256withECDSA -appCertFile "$CER" -profileFile "$P7B" -inForm zip \
  -inFile "$IN" -outFile "$OUT"
"$JAVA" -jar "$SDK/hap-sign-tool.jar" verify-app -inFile "$OUT" -outCertChain "$ROOT/build/outputs/release/cert-chain.cer" \
  -outProfile "$ROOT/build/outputs/release/profile.p7b"
echo "signed: $OUT"
