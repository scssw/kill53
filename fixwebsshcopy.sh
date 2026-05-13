#!/usr/bin/env bash
set -euo pipefail

IMAGE_MATCH="${IMAGE_MATCH:-beibeizi/websshgateway}"
CONTAINER="${1:-}"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker command not found" >&2
  exit 1
fi

if [ -z "$CONTAINER" ]; then
  CONTAINER="$(docker ps --format '{{.Names}} {{.Image}}' \
    | awk -v img="$IMAGE_MATCH" '$2 ~ img {print $1; exit}')"
fi

if [ -z "$CONTAINER" ]; then
  echo "ERROR: no running container found for image matching: $IMAGE_MATCH" >&2
  echo "Usage: $0 [container_name]" >&2
  exit 1
fi

echo "Target container: $CONTAINER"

JS_PATH="$(docker exec -u root "$CONTAINER" sh -lc \
  'find /app/backend/frontend/dist/assets -maxdepth 1 -type f -name "index-*.js" 2>/dev/null | head -1')"

if [ -z "$JS_PATH" ]; then
  echo "ERROR: frontend JS bundle not found in container" >&2
  exit 1
fi

echo "Frontend bundle: $JS_PATH"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

LOCAL_JS="$TMPDIR/index.js"
PATCHED_JS="$TMPDIR/index.patched.js"

docker cp "$CONTAINER:$JS_PATH" "$LOCAL_JS"

python3 - "$LOCAL_JS" "$PATCHED_JS" <<'PY'
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
s = src.read_text(encoding="utf-8")

marker = "getSelectionPosition&&J.getSelectionPosition"
if marker in s:
    dst.write_text(s, encoding="utf-8")
    print("Already patched")
    raise SystemExit(0)

old = '''h=A.useCallback(async()=>{var T,j,I;const v=((T=S.terminalInstance.current)==null?void 0:T.getSelection())??"",k=((j=window.getSelection())==null?void 0:j.toString())??"",P=v||k;if(!P){t(d("没有可复制内容","No selection to copy"));return}const B=()=>{const z=document.createElement("textarea");z.value=P,z.setAttribute("readonly",""),z.style.position="fixed",z.style.left="-9999px",z.style.opacity="0",document.body.appendChild(z),z.select();const K=document.execCommand("copy");return document.body.removeChild(z),K};try{if((I=navigator.clipboard)!=null&&I.writeText){await navigator.clipboard.writeText(P),t(d("已复制选中内容","Copied selection"));return}}catch{}if(B()){t(d("已复制选中内容","Copied selection"));return}t(d("复制失败，请使用右键菜单","Copy failed, use context menu"))},[t,d,S.terminalInstance])'''

new = '''h=A.useCallback(async()=>{var T,j,I;const v=((T=S.terminalInstance.current)==null?void 0:T.getSelection())??"",k=((j=window.getSelection())==null?void 0:j.toString())??"";let P=v||k;const B=((J,Le)=>{try{const Ke=/(?:ssr|ss|vmess|vless|trojan|hysteria2|hy2):\\/\\/[^\\s"'<>]+/ig,ve=Ce=>{if(!Ce)return"";let Te="",qe;for(;qe=Ke.exec(Ce);)Te=qe[0];return Te.replace(/[\\])}>,.;，。；]+$/g,"")},Ee=Ce=>Ce?Ce.replace(/\\s+/g,""):"",rt=J.buffer&&J.buffer.active;if(!rt)return"";const Ft=Ee(Le),Dt=(Ce,Te)=>{let qe="";for(let nt=Ce;nt<=Te;nt++){const at=rt.getLine(nt);at&&(qe+=at.translateToString(!1))}return ve(qe)},Rt=J.getSelectionPosition&&J.getSelectionPosition();if(Rt){let Ce=Rt.start.y,Te=Rt.end.y;for(;Ce>0;){const qe=rt.getLine(Ce);if(!(qe&&qe.isWrapped))break;Ce--}for(;Te<rt.length-1;){const qe=rt.getLine(Te+1);if(!(qe&&qe.isWrapped))break;Te++}const qe=Dt(Ce,Te);if(qe&&(!Ft||Ee(qe).includes(Ft)||qe.length>Le.length))return qe}let Ce="";for(let Te=0;Te<rt.length;Te++){const qe=rt.getLine(Te);if(!qe)continue;if(qe.isWrapped)continue;let nt=Te;for(;nt<rt.length-1;){const at=rt.getLine(nt+1);if(!(at&&at.isWrapped))break;nt++}const at=Dt(Te,nt);at&&(!Ft||Ee(at).includes(Ft)||Ee(Ft).includes(Ee(at)))&&(Ce=at),Te=nt}return Ce&&(!Le||Ce.length>Le.length)?Ce:""}catch{return""}})(S.terminalInstance.current,P);B&&(P=B);if(!P){t(d("没有可复制内容","No selection to copy"));return}const z=()=>{const K=document.createElement("textarea");K.value=P,K.setAttribute("readonly",""),K.style.position="fixed",K.style.left="-9999px",K.style.opacity="0",document.body.appendChild(K),K.select();const q=document.execCommand("copy");return document.body.removeChild(K),q};try{if((I=navigator.clipboard)!=null&&I.writeText){await navigator.clipboard.writeText(P),t(d("已复制选中内容","Copied selection"));return}}catch{}if(z()){t(d("已复制选中内容","Copied selection"));return}t(d("复制失败，请使用右键菜单","Copy failed, use context menu"))},[t,d,S.terminalInstance])'''

if old not in s:
    print("ERROR: copy handler signature not found. This image version may differ.", file=sys.stderr)
    raise SystemExit(2)

s = s.replace(old, new, 1)
dst.write_text(s, encoding="utf-8")
print("Patched")
PY

if cmp -s "$LOCAL_JS" "$PATCHED_JS"; then
  echo "No changes needed."
  exit 0
fi

if command -v node >/dev/null 2>&1; then
  node --check "$PATCHED_JS"
else
  echo "WARN: node not found on host, skipped JS syntax check"
fi

STAMP="$(date +%Y%m%d%H%M%S)"
BAK_PATH="$JS_PATH.bak.$STAMP"

docker exec -u root "$CONTAINER" sh -lc "cp '$JS_PATH' '$BAK_PATH'"
docker cp "$PATCHED_JS" "$CONTAINER:$JS_PATH"

docker exec -u root "$CONTAINER" sh -lc "ls -l '$JS_PATH' '$BAK_PATH'"

echo "Done."
echo "Backup: $BAK_PATH"
echo "Refresh the WebSSH page on mobile. Clear site cache if the old bundle is still loaded."
