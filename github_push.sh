#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO_NAME="${REPO_NAME:-lazyslide-histoplus-nextflow}"
VISIBILITY="${VISIBILITY:-public}"
GITHUB_OWNER="${GITHUB_OWNER:-}"
GIT_USER_NAME="${GIT_USER_NAME:-$(git config --global user.name 2>/dev/null || true)}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-$(git config --global user.email 2>/dev/null || true)}"
COMMIT_MESSAGE="${COMMIT_MESSAGE:-Add LazySlide HistoPLUS Nextflow Docker pipeline}"
REPLACE_REMOTE="${REPLACE_REMOTE:-false}"

usage() {
  cat <<USAGE
Usage:
  ./github_push.sh [options]

Options:
  --repo-dir PATH
  --repo-name NAME
  --owner OWNER
  --public
  --private
  --git-name NAME
  --git-email EMAIL
  --message TEXT
  --replace-remote
  -h, --help
USAGE
}

log() { printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"; }

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --repo-dir) REPO_DIR="${2:?Missing value for --repo-dir}"; shift 2 ;;
    --repo-name) REPO_NAME="${2:?Missing value for --repo-name}"; shift 2 ;;
    --owner) GITHUB_OWNER="${2:?Missing value for --owner}"; shift 2 ;;
    --public) VISIBILITY="public"; shift ;;
    --private) VISIBILITY="private"; shift ;;
    --git-name) GIT_USER_NAME="${2:?Missing value for --git-name}"; shift 2 ;;
    --git-email) GIT_USER_EMAIL="${2:?Missing value for --git-email}"; shift 2 ;;
    --message) COMMIT_MESSAGE="${2:?Missing value for --message}"; shift 2 ;;
    --replace-remote|--force-with-lease) REPLACE_REMOTE="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

need_cmd git
need_cmd gh

cd "${REPO_DIR}"

if [[ -d .git/rebase-merge || -d .git/rebase-apply ]]; then
  fail "A Git rebase is in progress. Run: git rebase --abort"
fi
if [[ -f .git/MERGE_HEAD ]]; then
  fail "A Git merge is in progress. Run: git merge --abort"
fi

if [[ ! -d .git ]]; then
  git init
fi

if ! gh auth status --hostname github.com >/dev/null 2>&1; then
  GH_BROWSER=echo BROWSER=echo gh auth login --hostname github.com --git-protocol https --web
fi

gh config set git_protocol https --host github.com >/dev/null
gh auth setup-git --hostname github.com >/dev/null

AUTH_USER="$(gh api user --jq .login)"
[[ -n "${AUTH_USER}" ]] || fail "Could not determine authenticated GitHub user"
[[ -n "${GITHUB_OWNER}" ]] || GITHUB_OWNER="${AUTH_USER}"
[[ -n "${GIT_USER_NAME}" ]] || GIT_USER_NAME="${AUTH_USER}"
[[ -n "${GIT_USER_EMAIL}" ]] || GIT_USER_EMAIL="${AUTH_USER}@users.noreply.github.com"

git config user.name "${GIT_USER_NAME}"
git config user.email "${GIT_USER_EMAIL}"
git branch -M main

repo_files=(
  README.md
  Dockerfile
  requirements.txt
  constraints.txt
  lazyslide_histoplus_wsi_celltype.py
  main.nf
  nextflow.config
  run.sh
  setup_server.sh
  build_and_push.sh
  github_push.sh
  commands.txt
  .gitignore
  .dockerignore
)

find . -type d -name '__pycache__' -prune -exec rm -rf {} +
git rm -r --cached . >/dev/null 2>&1 || true
git add "${repo_files[@]}"

if git diff --cached --quiet; then
  git log --oneline -1 >/dev/null 2>&1 || fail "No commit exists"
else
  git commit -m "${COMMIT_MESSAGE}"
fi

FULL_REPO="${GITHUB_OWNER}/${REPO_NAME}"
REMOTE_URL="https://github.com/${FULL_REPO}.git"

if gh repo view "${FULL_REPO}" >/dev/null 2>&1; then
  log "Repository exists: ${FULL_REPO}"
else
  if [[ "${VISIBILITY}" == "private" ]]; then
    gh repo create "${FULL_REPO}" --private --description "LazySlide HistoPLUS Nextflow Docker pipeline"
  else
    gh repo create "${FULL_REPO}" --public --description "LazySlide HistoPLUS Nextflow Docker pipeline"
  fi
fi

if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "${REMOTE_URL}"
else
  git remote add origin "${REMOTE_URL}"
fi

if [[ "${REPLACE_REMOTE}" == "true" ]]; then
  git fetch origin main >/dev/null 2>&1 || true
  git push -u --force-with-lease origin main
else
  git push -u origin main
fi

log "Pushed: https://github.com/${FULL_REPO}"
