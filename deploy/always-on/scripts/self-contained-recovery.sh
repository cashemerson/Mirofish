#!/usr/bin/env bash
set -euo pipefail

DEPLOY_ROOT="/root/mirofish-deploy"
DEPLOY_DIR="${DEPLOY_ROOT}/deploy/always-on"

fail() { echo "FATAL: $*" >&2; exit 1; }
step() { echo ""; echo "===> $*"; }

step "Checking prerequisites"
command -v docker >/dev/null 2>&1 || fail "docker not found"
docker compose version >/dev/null 2>&1 || fail "docker compose plugin not available"
command -v curl >/dev/null 2>&1 || fail "curl not found"
echo "  docker, docker compose, curl: OK"

step "Stopping any running mirofish containers"
docker stop mirofish-caddy mirofish-portal mirofish 2>/dev/null || true
docker rm mirofish-caddy mirofish-portal mirofish 2>/dev/null || true
echo "  Containers stopped"

step "Creating directory structure"
mkdir -p "${DEPLOY_DIR}/scripts"
mkdir -p "${DEPLOY_DIR}/uploads"
mkdir -p "${DEPLOY_DIR}/portal"
echo "  Directories created"

step "Writing docker-compose.yml"
cat > "${DEPLOY_DIR}/docker-compose.yml" << 'COMPOSE_EOF'
services:
  portal:
    image: nginx:1.27-alpine
    container_name: mirofish-portal
    depends_on:
      mirofish:
        condition: service_healthy
    volumes:
      - ./portal:/usr/share/nginx/html:ro
      - ./portal-nginx.conf:/etc/nginx/conf.d/default.conf:ro
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:8080/ || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 8
      start_period: 20s

  mirofish:
    image: ghcr.io/666ghj/mirofish:latest
    container_name: mirofish
    restart: unless-stopped
    env_file:
      - .env
    environment:
      - __VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS=${MIROFISH_DOMAIN:-localhost},${PORTAL_DOMAIN:-localhost},localhost,127.0.0.1
    ports:
      - "3000:3000"
      - "5001:5001"
    volumes:
      - ./uploads:/app/backend/uploads
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:5001/api/simulation/history?limit=1 || exit 1"]
      interval: 20s
      timeout: 8s
      retries: 10
      start_period: 45s
COMPOSE_EOF
echo "  docker-compose.yml written"

step "Writing docker-compose.tls.yml"
cat > "${DEPLOY_DIR}/docker-compose.tls.yml" << 'TLS_EOF'
services:
  caddy:
    image: caddy:2.8-alpine
    container_name: mirofish-caddy
    init: true
    depends_on:
      portal:
        condition: service_healthy
      mirofish:
        condition: service_healthy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    command: ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:2019/config/ || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 8
      start_period: 20s

volumes:
  caddy_data:
  caddy_config:
TLS_EOF
echo "  docker-compose.tls.yml written"

step "Writing Caddyfile.template"
cat > "${DEPLOY_DIR}/Caddyfile.template" << 'CADDY_TPL_EOF'
__APP_HOSTS__ {
  encode zstd gzip
  tls __ACME_EMAIL__

  @api path /api/*
  handle @api {
    request_body {
      max_size __API_MAX_UPLOAD_SIZE__
    }
    reverse_proxy mirofish:5001 {
      header_up Host localhost
      flush_interval -1
      transport http {
        dial_timeout 10s
        response_header_timeout __API_RESPONSE_HEADER_TIMEOUT__
        read_timeout __API_READ_TIMEOUT__
        write_timeout __API_WRITE_TIMEOUT__
      }
    }
  }

  reverse_proxy mirofish:3000 {
    header_up Host localhost
    transport http {
      dial_timeout 10s
      response_header_timeout 120s
    }
  }
}

__PORTAL_HOSTS__ {
  encode zstd gzip
  tls __ACME_EMAIL__
  reverse_proxy portal:8080
}
CADDY_TPL_EOF
echo "  Caddyfile.template written"

step "Writing portal-nginx.conf"
cat > "${DEPLOY_DIR}/portal-nginx.conf" << 'NGINX_EOF'
server {
  listen 8080;
  server_name _;
  root /usr/share/nginx/html;
  index index.html;
  location / {
    try_files $uri /index.html;
  }
}
NGINX_EOF
echo "  portal-nginx.conf written"

step "Writing portal/index.html (minimal recovery version)"
cat > "${DEPLOY_DIR}/portal/index.html" << 'PORTAL_EOF'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>MiroFish Portal</title>
    <style>
      :root {
        --bg: #0f172a;
        --panel: #111827;
        --panel-2: #1f2937;
        --text: #e5e7eb;
        --muted: #94a3b8;
      }
      * { box-sizing: border-box; }
      body {
        margin: 0;
        font-family: Inter, ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif;
        background: radial-gradient(1200px 500px at 20% -10%, #1e293b 0%, var(--bg) 55%);
        color: var(--text);
        min-height: 100vh;
      }
      .wrap { max-width: 860px; margin: 48px auto; padding: 0 16px; }
      .card {
        background: linear-gradient(180deg, rgba(255,255,255,0.02), rgba(255,255,255,0.01));
        border: 1px solid #334155;
        border-radius: 14px;
        padding: 20px;
        margin-bottom: 16px;
      }
      .top { display: flex; justify-content: space-between; align-items: flex-start; gap: 12px; }
      .lang-switch { display: flex; gap: 8px; }
      .lang-btn {
        border: 1px solid #334155;
        background: var(--panel);
        color: var(--text);
        padding: 6px 10px;
        border-radius: 8px;
        cursor: pointer;
        font-size: 13px;
      }
      .lang-btn.active { border-color: #60a5fa; background: #1e3a8a; }
      h1 { margin: 0 0 8px; font-size: 30px; }
      p.sub { margin: 0 0 20px; color: var(--muted); }
      label { display: block; font-size: 14px; margin: 10px 0 6px; color: #cbd5e1; }
      input {
        width: 100%;
        padding: 12px 14px;
        border-radius: 10px;
        border: 1px solid #334155;
        background: var(--panel);
        color: var(--text);
        outline: none;
      }
      input:focus { border-color: #60a5fa; }
      .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
      .actions { margin-top: 16px; display: flex; gap: 10px; flex-wrap: wrap; }
      button, a.btn {
        border: 1px solid #334155;
        background: var(--panel-2);
        color: var(--text);
        padding: 10px 14px;
        border-radius: 10px;
        cursor: pointer;
        text-decoration: none;
        font-size: 14px;
      }
      button.primary, a.btn.primary { border-color: #15803d; background: #166534; }
      .status {
        margin-top: 14px;
        padding: 10px 12px;
        border-radius: 10px;
        border: 1px solid #334155;
        color: #cbd5e1;
        font-size: 14px;
      }
      .ok { color: #86efac; border-color: #14532d; }
      .bad { color: #fca5a5; border-color: #7f1d1d; }
      .hint { color: var(--muted); font-size: 13px; margin-top: 10px; }
      .links { display: flex; gap: 10px; margin-top: 6px; flex-wrap: wrap; }
      @media (max-width: 640px) { .grid { grid-template-columns: 1fr; } }
    </style>
  </head>
  <body>
    <div class="wrap">
      <div class="card">
        <div class="top">
          <div>
            <h1 data-i18n="title">MiroFish Portal</h1>
            <p class="sub" data-i18n="subtitle">Save your deployment URL and launch MiroFish from any browser.</p>
          </div>
          <div class="lang-switch">
            <button id="langEn" class="lang-btn" type="button">English</button>
            <button id="langZh" class="lang-btn" type="button">中文</button>
          </div>
        </div>
        <div class="grid">
          <div>
            <label for="frontendUrl" data-i18n="frontendLabel">Frontend URL</label>
            <input id="frontendUrl" data-i18n-placeholder="frontendPlaceholder" placeholder="https://your-mirofish.example.com" />
          </div>
          <div>
            <label for="apiUrl" data-i18n="apiLabel">API URL</label>
            <input id="apiUrl" data-i18n-placeholder="apiPlaceholder" placeholder="https://your-mirofish.example.com/api or :5001" />
          </div>
        </div>
        <div class="actions">
          <button id="saveBtn" class="primary" data-i18n="saveBtn">Save URLs</button>
          <a id="openBtn" class="btn primary" href="#" target="_blank" rel="noopener noreferrer" data-i18n="openBtn">Open MiroFish</a>
          <button id="healthBtn" data-i18n="healthBtn">Check API Health</button>
          <button id="clearBtn" data-i18n="clearBtn">Clear Saved URLs</button>
        </div>
        <div id="status" class="status" data-i18n="statusNoCheck">No health check run yet.</div>
        <div class="hint" data-i18n="hint">Tip: After first save, this page remembers your URLs in your browser (localStorage).</div>
      </div>
      <div class="card">
        <h2 style="margin-top:0;font-size:20px;" data-i18n="quickLinks">Quick links</h2>
        <div class="links">
          <a class="btn" href="https://github.com/cashemerson/Mirofish" target="_blank" rel="noopener noreferrer" data-i18n="deployGuide">Deployment Guide</a>
          <a class="btn" href="https://github.com/666ghj/MiroFish" target="_blank" rel="noopener noreferrer" data-i18n="upstream">MiroFish Upstream</a>
        </div>
      </div>
    </div>
    <script>
      const frontendInput=document.getElementById("frontendUrl"),apiInput=document.getElementById("apiUrl"),statusEl=document.getElementById("status"),openBtn=document.getElementById("openBtn"),langEnBtn=document.getElementById("langEn"),langZhBtn=document.getElementById("langZh"),CFG_KEY="mirofish_portal_config_v1",LANG_KEY="mirofish_portal_lang_v1",I18N={en:{title:"MiroFish Portal",subtitle:"Save your deployment URL and launch MiroFish from any browser.",frontendLabel:"Frontend URL",frontendPlaceholder:"https://your-mirofish.example.com",apiLabel:"API URL",apiPlaceholder:"https://your-mirofish.example.com/api or :5001",saveBtn:"Save URLs",openBtn:"Open MiroFish",healthBtn:"Check API Health",clearBtn:"Clear Saved URLs",statusNoCheck:"No health check run yet.",hint:"Tip: After first save, this page remembers your URLs in your browser (localStorage).",quickLinks:"Quick links",deployGuide:"Deployment Guide",upstream:"MiroFish Upstream",statusSaved:"Saved. You can now open MiroFish directly.",statusSetApi:"Set API URL first.",statusChecking:"Checking API health...",statusApiFail:"API check failed: HTTP {code}",statusApiHealthy:"API is healthy and responding.",statusApiSuccessFalse:"API responded but success flag was false.",statusApiError:"API check error: {message}",statusCleared:"Cleared saved URLs."},zh:{title:"MiroFish \u5165\u53e3",subtitle:"\u4fdd\u5b58\u4f60\u7684\u90e8\u7f72\u5730\u5740\uff0c\u5e76\u4ece\u4efb\u610f\u6d4f\u89c8\u5668\u5feb\u901f\u542f\u52a8 MiroFish\u3002",frontendLabel:"\u524d\u7aef\u5730\u5740",frontendPlaceholder:"https://\u4f60\u7684-mirofish-\u57df\u540d",apiLabel:"API \u5730\u5740",apiPlaceholder:"https://\u4f60\u7684-mirofish-\u57df\u540d/api \u6216 :5001",saveBtn:"\u4fdd\u5b58\u5730\u5740",openBtn:"\u6253\u5f00 MiroFish",healthBtn:"\u68c0\u67e5 API \u5065\u5eb7\u72b6\u6001",clearBtn:"\u6e05\u9664\u5df2\u4fdd\u5b58\u5730\u5740",statusNoCheck:"\u5c1a\u672a\u6267\u884c\u5065\u5eb7\u68c0\u67e5\u3002",hint:"\u63d0\u793a\uff1a\u9996\u6b21\u4fdd\u5b58\u540e\uff0c\u672c\u9875\u9762\u4f1a\u5728\u6d4f\u89c8\u5668\u672c\u5730\u5b58\u50a8\u8fd9\u4e9b\u5730\u5740\uff08localStorage\uff09\u3002",quickLinks:"\u5feb\u901f\u94fe\u63a5",deployGuide:"\u90e8\u7f72\u6307\u5357",upstream:"MiroFish \u4e0a\u6e38\u4ed3\u5e93",statusSaved:"\u4fdd\u5b58\u6210\u529f\u3002\u73b0\u5728\u53ef\u4ee5\u76f4\u63a5\u6253\u5f00 MiroFish\u3002",statusSetApi:"\u8bf7\u5148\u586b\u5199 API \u5730\u5740\u3002",statusChecking:"\u6b63\u5728\u68c0\u67e5 API \u5065\u5eb7\u72b6\u6001...",statusApiFail:"API \u68c0\u67e5\u5931\u8d25\uff1aHTTP {code}",statusApiHealthy:"API \u54cd\u5e94\u6b63\u5e38\u3002",statusApiSuccessFalse:"API \u6709\u54cd\u5e94\uff0c\u4f46 success \u6807\u8bb0\u4e3a false\u3002",statusApiError:"API \u68c0\u67e5\u9519\u8bef\uff1a{message}",statusCleared:"\u5df2\u6e05\u9664\u4fdd\u5b58\u7684\u5730\u5740\u3002"}};let currentLang="en",statusState={key:"statusNoCheck",type:"",params:{}};function normalize(e){return e?e.replace(/\/+$/,""):""}function tr(e,t={}){const n=(I18N[currentLang]||I18N.en)[e]||I18N.en[e]||e;return n.replace(/\{(\w+)\}/g,(e,n)=>Object.prototype.hasOwnProperty.call(t,n)?String(t[n]):`{${n}}`)}function applyTranslations(){document.documentElement.lang=currentLang,document.querySelectorAll("[data-i18n]").forEach(e=>{e.textContent=tr(e.getAttribute("data-i18n"))}),document.querySelectorAll("[data-i18n-placeholder]").forEach(e=>{e.setAttribute("placeholder",tr(e.getAttribute("data-i18n-placeholder")))}),langEnBtn.classList.toggle("active","en"===currentLang),langZhBtn.classList.toggle("active","zh"===currentLang),renderStatus()}function renderStatus(){statusEl.textContent=tr(statusState.key,statusState.params),statusEl.className="status","ok"===statusState.type&&statusEl.classList.add("ok"),"bad"===statusState.type&&statusEl.classList.add("bad")}function setStatus(e,t="",n={}){statusState={key:e,type:t,params:n},renderStatus()}function loadConfig(){const e=localStorage.getItem(CFG_KEY);if(!e)return;try{const t=JSON.parse(e);frontendInput.value=t.frontendUrl||"",apiInput.value=t.apiUrl||"",openBtn.href=normalize(t.frontendUrl)||"#"}catch(e){}}function saveConfig(){const e={frontendUrl:normalize(frontendInput.value),apiUrl:normalize(apiInput.value)};localStorage.setItem(CFG_KEY,JSON.stringify(e)),openBtn.href=e.frontendUrl||"#",setStatus("statusSaved","ok")}async function healthCheck(){const e=normalize(apiInput.value);if(!e)return void setStatus("statusSetApi","bad");const t=e.includes("/api")?`${e}/simulation/history?limit=1`:`${e}/api/simulation/history?limit=1`;setStatus("statusChecking");try{const e=await fetch(t,{method:"GET"});if(!e.ok)return void setStatus("statusApiFail","bad",{code:e.status});(await e.json())&&(await e.clone().json()).success?setStatus("statusApiHealthy","ok"):setStatus("statusApiSuccessFalse","bad")}catch(e){setStatus("statusApiError","bad",{message:e.message})}}function detectDefaultLang(){const e=localStorage.getItem(LANG_KEY);return"en"===e||"zh"===e?e:navigator.language&&navigator.language.toLowerCase().startsWith("zh")?"zh":"en"}function setLanguage(e){currentLang="zh"===e?"zh":"en",localStorage.setItem(LANG_KEY,currentLang),applyTranslations()}document.getElementById("saveBtn").addEventListener("click",saveConfig),document.getElementById("healthBtn").addEventListener("click",healthCheck),document.getElementById("clearBtn").addEventListener("click",()=>{localStorage.removeItem(CFG_KEY),frontendInput.value="",apiInput.value="",openBtn.href="#",setStatus("statusCleared")}),langEnBtn.addEventListener("click",()=>setLanguage("en")),langZhBtn.addEventListener("click",()=>setLanguage("zh")),loadConfig(),currentLang=detectDefaultLang(),applyTranslations();
    </script>
  </body>
</html>
PORTAL_EOF
echo "  portal/index.html written"

step "Writing .env"
if [ -f "${DEPLOY_DIR}/.env" ]; then
  echo "  .env already exists, preserving it"
else
  cat > "${DEPLOY_DIR}/.env" << 'ENV_EOF'
LLM_API_KEY=replace_with_openai_or_compatible_key
LLM_BASE_URL=https://api.openai.com/v1
LLM_MODEL_NAME=gpt-4o-mini
ZEP_API_KEY=replace_with_zep_key
VITE_API_BASE_URL=/api
MIROFISH_DOMAIN=app.cesimulation.it.com,cesimulation.it.com
PORTAL_DOMAIN=portal.cesimulation.it.com
ACME_EMAIL=you@example.com
API_MAX_UPLOAD_SIZE=100MB
API_RESPONSE_HEADER_TIMEOUT=600s
API_READ_TIMEOUT=600s
API_WRITE_TIMEOUT=600s
ENV_EOF
  echo "  .env written (EDIT API KEYS BEFORE STARTING)"
fi

step "Rendering Caddyfile"
ENV_FILE="${DEPLOY_DIR}/.env"
TEMPLATE="${DEPLOY_DIR}/Caddyfile.template"
TARGET="${DEPLOY_DIR}/Caddyfile"

read_val() {
  grep -E "^${1}=" "${ENV_FILE}" | tail -n1 | sed -E "s/^${1}=//"
}
read_val_default() {
  local v
  v="$(grep -E "^${1}=" "${ENV_FILE}" | tail -n1 | sed -E "s/^${1}=//" || true)"
  printf "%s" "${v:-$2}"
}

APP_RAW="$(read_val MIROFISH_DOMAIN)"
PORTAL_RAW="$(read_val PORTAL_DOMAIN)"
ACME="$(read_val ACME_EMAIL)"
MAX_UP="$(read_val_default API_MAX_UPLOAD_SIZE 100MB)"
RESP_T="$(read_val_default API_RESPONSE_HEADER_TIMEOUT 600s)"
READ_T="$(read_val_default API_READ_TIMEOUT 600s)"
WRITE_T="$(read_val_default API_WRITE_TIMEOUT 600s)"

APP_HOSTS="${APP_RAW//,/ }"
PORTAL_HOSTS="${PORTAL_RAW//,/ }"

awk -v app_hosts="${APP_HOSTS}" \
    -v portal_hosts="${PORTAL_HOSTS}" \
    -v acme_email="${ACME}" \
    -v max_upload="${MAX_UP}" \
    -v resp_timeout="${RESP_T}" \
    -v read_timeout="${READ_T}" \
    -v write_timeout="${WRITE_T}" \
    '{
      gsub(/__APP_HOSTS__/, app_hosts)
      gsub(/__PORTAL_HOSTS__/, portal_hosts)
      gsub(/__ACME_EMAIL__/, acme_email)
      gsub(/__API_MAX_UPLOAD_SIZE__/, max_upload)
      gsub(/__API_RESPONSE_HEADER_TIMEOUT__/, resp_timeout)
      gsub(/__API_READ_TIMEOUT__/, read_timeout)
      gsub(/__API_WRITE_TIMEOUT__/, write_timeout)
      print
    }' "${TEMPLATE}" > "${TARGET}"
echo "  Caddyfile rendered"

step "Validating compose config"
cd "${DEPLOY_DIR}"
docker compose -f docker-compose.yml -f docker-compose.tls.yml config > /dev/null
echo "  Compose config valid"

step "Pulling latest images"
docker compose -f docker-compose.yml -f docker-compose.tls.yml pull
echo "  Images pulled"

step "Starting stack"
docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d --force-recreate
echo "  Containers started"

step "Waiting for containers (up to 120s)"
WAITED=0
while [ "${WAITED}" -lt 120 ]; do
  sleep 10
  WAITED=$((WAITED + 10))
  echo "  ${WAITED}s elapsed..."
  HEALTHY="$(docker ps --filter "health=healthy" --format "{{.Names}}" | grep -c mirofish || true)"
  if [ "${HEALTHY}" -ge 3 ]; then
    echo "  All 3 containers healthy"
    break
  fi
done

step "Container status"
docker compose -f docker-compose.yml -f docker-compose.tls.yml ps

step "Quick endpoint checks"
for URL in "https://cesimulation.it.com/" "https://app.cesimulation.it.com/" "https://portal.cesimulation.it.com/"; do
  CODE="$(curl -sk -o /dev/null -w "%{http_code}" "${URL}" 2>/dev/null || echo "ERR")"
  echo "  ${URL} -> HTTP ${CODE}"
done
API_CODE="$(curl -sk -o /dev/null -w "%{http_code}" "https://cesimulation.it.com/api/simulation/history?limit=1" 2>/dev/null || echo "ERR")"
echo "  API history -> HTTP ${API_CODE}"

echo ""
echo "==========================================="
echo "  Recovery complete."
echo "  Deploy dir: ${DEPLOY_DIR}"
echo ""
echo "  If .env still has placeholder keys, edit:"
echo "    vi ${DEPLOY_DIR}/.env"
echo "  Then restart:"
echo "    cd ${DEPLOY_DIR}"
echo "    docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d --force-recreate"
echo "==========================================="
