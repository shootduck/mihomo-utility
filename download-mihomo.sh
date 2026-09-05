#!/usr/bin/env bash
set -euo pipefail

DESTINATION=""
VERSION="latest"
VARIANT=""

usage() {
  cat <<'EOF'
Usage:
  download-mihomo.sh DESTINATION [--version VERSION] [--variant VARIANT]

Download a stable Mihomo release from the official MetaCubeX repository.
The operating system and CPU architecture are detected automatically.

Argument:
  DESTINATION        Required directory in which to install the mihomo binary.

Options:
  --version VERSION  Install a specific release, such as 1.19.0 or v1.19.0.
                     The default is the latest stable release.
  --variant VARIANT  Select a CPU build such as compatible, v1, v2, or v3.
                     By default, amd64 uses the broadly compatible v1 build;
                     other CPUs use the release's generic build.
  -h, --help         Show this help.

Environment:
  GITHUB_TOKEN       Optional token for a higher GitHub API rate limit.

Examples:
  ./download-mihomo.sh ~/mihomo
  ./download-mihomo.sh ~/mihomo --version 1.19.0
  ./download-mihomo.sh ~/mihomo --variant v3
  ./download-mihomo.sh /usr/local/bin
EOF
}

while (($#)); do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || { echo "Missing value after --version" >&2; exit 2; }
      VERSION="$2"
      shift 2
      ;;
    --variant)
      [[ $# -ge 2 ]] || { echo "Missing value after --variant" >&2; exit 2; }
      VARIANT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      [[ $# -eq 1 ]] || {
        echo "Expected exactly one destination after --" >&2
        exit 2
      }
      [[ -z "$DESTINATION" ]] || {
        echo "The destination was provided more than once." >&2
        exit 2
      }
      DESTINATION="$1"
      shift
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      [[ -z "$DESTINATION" ]] || {
        echo "The destination was provided more than once." >&2
        exit 2
      }
      DESTINATION="$1"
      shift
      ;;
  esac
done

if [[ -z "$DESTINATION" ]]; then
  echo "A destination directory is required." >&2
  usage >&2
  exit 2
fi
if [[ -e "$DESTINATION" && ! -d "$DESTINATION" ]]; then
  echo "The destination is not a directory: $DESTINATION" >&2
  exit 2
fi
OUTPUT="${DESTINATION%/}/mihomo"

if [[ "$VERSION" != "latest" ]]; then
  VERSION="${VERSION#v}"
  if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([._-][0-9A-Za-z.-]+)?$ ]]; then
    echo "Invalid version: $VERSION (expected a value such as 1.19.0)" >&2
    exit 2
  fi
fi

if [[ -n "$VARIANT" && ! "$VARIANT" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]]; then
  echo "Invalid variant: $VARIANT" >&2
  exit 2
fi

for command in curl gzip python3 uname mktemp tr; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Required command is missing: $command" >&2
    exit 1
  }
done

case "$(uname -s)" in
  Linux)   PLATFORM="linux" ;;
  Darwin)  PLATFORM="darwin" ;;
  FreeBSD) PLATFORM="freebsd" ;;
  *)
    echo "Unsupported operating system: $(uname -s)" >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  x86_64|amd64)          ARCH="amd64" ;;
  i386|i486|i586|i686)   ARCH="386" ;;
  aarch64|arm64|armv8*)  ARCH="arm64" ;;
  armv7*|armhf)          ARCH="armv7" ;;
  armv6*)                ARCH="armv6" ;;
  armv5*)                ARCH="armv5" ;;
  riscv64)               ARCH="riscv64" ;;
  loongarch64|loong64)   ARCH="loong64" ;;
  s390x)                 ARCH="s390x" ;;
  ppc64le)               ARCH="ppc64le" ;;
  mips64el|mips64le)     ARCH="mips64le" ;;
  mips64)                ARCH="mips64" ;;
  mipsel|mipsle)         ARCH="mipsle" ;;
  mips)                  ARCH="mips" ;;
  *)
    echo "Unsupported CPU architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mihomo-download.XXXXXX")"
INSTALL_TEMP=""
cleanup() {
  rm -rf -- "$TEMP_DIR"
  if [[ -n "$INSTALL_TEMP" ]]; then
    rm -f -- "$INSTALL_TEMP"
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

METADATA="$TEMP_DIR/release.json"
ARCHIVE="$TEMP_DIR/mihomo.gz"
API_URL="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
if [[ "$VERSION" != "latest" ]]; then
  API_URL="https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/v$VERSION"
fi

CURL_ARGS=(
  --fail
  --location
  --silent
  --show-error
  --retry 3
  --connect-timeout 10
  --proto '=https'
  --tlsv1.2
  --header 'User-Agent: mihomo-utility-downloader'
)
API_CURL_ARGS=(
  "${CURL_ARGS[@]}"
  --header 'Accept: application/vnd.github+json'
  --header 'X-GitHub-Api-Version: 2022-11-28'
)

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  API_CURL_ARGS+=(--header "Authorization: Bearer $GITHUB_TOKEN")
fi

echo "Looking up Mihomo ${VERSION} for ${PLATFORM}/${ARCH}..."
if ! curl "${API_CURL_ARGS[@]}" --output "$METADATA" "$API_URL"; then
  echo "GitHub API lookup failed; trying the public release page..." >&2

  if [[ "$VERSION" == "latest" ]]; then
    if ! LATEST_URL="$(curl "${CURL_ARGS[@]}" --output /dev/null \
      --write-out '%{url_effective}' \
      'https://github.com/MetaCubeX/mihomo/releases/latest')"; then
      echo "Failed to resolve the latest Mihomo release." >&2
      echo "Set GITHUB_TOKEN if GitHub's API rate limit is the cause." >&2
      exit 1
    fi
    FALLBACK_TAG="${LATEST_URL##*/}"
  else
    FALLBACK_TAG="v$VERSION"
  fi

  if [[ ! "$FALLBACK_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([._-][0-9A-Za-z.-]+)?$ ]]; then
    echo "Could not determine a valid Mihomo release tag from GitHub." >&2
    exit 1
  fi

  RELEASE_PAGE="$TEMP_DIR/release-assets.html"
  RELEASE_PAGE_URL="https://github.com/MetaCubeX/mihomo/releases/expanded_assets/$FALLBACK_TAG"
  if ! curl "${CURL_ARGS[@]}" --output "$RELEASE_PAGE" "$RELEASE_PAGE_URL"; then
    echo "Failed to read the Mihomo $FALLBACK_TAG release page." >&2
    exit 1
  fi

  if ! python3 - "$RELEASE_PAGE" "$METADATA" "$FALLBACK_TAG" <<'PYRELEASEPAGE'
from html.parser import HTMLParser
import json
from pathlib import Path
import sys
from urllib.parse import unquote, urljoin, urlsplit

page_path, metadata_path, tag = sys.argv[1:]
download_prefix = f"/MetaCubeX/mihomo/releases/download/{tag}/"


class ReleaseAssetParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.assets = []
        self.digests = {}
        self.seen = set()

    def handle_starttag(self, element, attributes):
        attributes = dict(attributes)
        if element == "clipboard-copy":
            label = attributes.get("aria-label", "")
            label_prefix = "Copy to clipboard digest for "
            digest = attributes.get("value")
            if label.startswith(label_prefix) and digest:
                self.digests[label[len(label_prefix) :]] = digest
            return
        if element != "a":
            return
        href = attributes.get("href")
        if not href:
            return
        path = urlsplit(href).path
        if not path.startswith(download_prefix):
            return
        name = unquote(path[len(download_prefix) :])
        if not name or "/" in name or name in self.seen:
            return
        self.seen.add(name)
        self.assets.append(
            {
                "name": name,
                "browser_download_url": urljoin("https://github.com", href),
            }
        )


try:
    page = Path(page_path).read_text(encoding="utf-8")
except OSError as exc:
    raise SystemExit(f"Cannot read GitHub release page: {exc}")

parser = ReleaseAssetParser()
parser.feed(page)
if not parser.assets:
    raise SystemExit("No downloadable assets were found on the GitHub release page")
for asset in parser.assets:
    digest = parser.digests.get(asset["name"])
    if digest:
        asset["digest"] = digest

try:
    Path(metadata_path).write_text(
        json.dumps({"tag_name": tag, "assets": parser.assets}),
        encoding="utf-8",
    )
except OSError as exc:
    raise SystemExit(f"Cannot store release metadata: {exc}")
PYRELEASEPAGE
  then
    exit 1
  fi
fi

if ! RELEASE_INFO="$(python3 - "$METADATA" "$PLATFORM" "$ARCH" "$VARIANT" <<'PYSELECT'
import json
from pathlib import Path
import sys

metadata_path, platform, architecture, requested_variant = sys.argv[1:]

try:
    release = json.loads(Path(metadata_path).read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"Cannot parse GitHub release metadata: {exc}")

tag = release.get("tag_name")
assets = release.get("assets")
if not isinstance(tag, str) or not isinstance(assets, list):
    message = release.get("message", "response did not describe a release")
    raise SystemExit(f"GitHub API error: {message}")

prefix = f"mihomo-{platform}-{architecture}-"
candidates = [
    asset
    for asset in assets
    if isinstance(asset, dict)
    and isinstance(asset.get("name"), str)
    and asset["name"].startswith(prefix)
    and asset["name"].endswith(".gz")
    and isinstance(asset.get("browser_download_url"), str)
]

if requested_variant:
    variant_prefix = f"{prefix}{requested_variant}-"
    candidates = [
        asset for asset in candidates if asset["name"].startswith(variant_prefix)
    ]

if not candidates:
    available = sorted(
        asset["name"]
        for asset in assets
        if isinstance(asset, dict)
        and isinstance(asset.get("name"), str)
        and asset["name"].startswith(f"mihomo-{platform}-")
        and asset["name"].endswith(".gz")
    )
    suffix = "\nAvailable compressed builds:\n  " + "\n  ".join(available) if available else ""
    requested = f" with variant {requested_variant!r}" if requested_variant else ""
    raise SystemExit(
        f"No Mihomo {platform}/{architecture} compressed build{requested} was found."
        + suffix
    )


def preference(asset):
    name = asset["name"]
    generic = f"{prefix}{tag}.gz"
    compatible = f"{prefix}compatible-{tag}.gz"
    v1 = f"{prefix}v1-{tag}.gz"

    if requested_variant:
        exact_variant = f"{prefix}{requested_variant}-{tag}.gz"
        return (name != exact_variant, name)
    if architecture == "amd64":
        if name == v1:
            return (0, name)
        if name == compatible:
            return (1, name)
        if name.startswith(f"{prefix}v1-"):
            return (2, name)
        if name.startswith(f"{prefix}compatible-"):
            return (3, name)
        if name == generic:
            return (4, name)
        return (5, name)
    if architecture == "loong64":
        abi2 = f"{prefix}abi2-{tag}.gz"
        if name == abi2:
            return (0, name)
        return (4, name)
    return (name != generic, name)


asset = min(candidates, key=preference)
digest = asset.get("digest") or "-"
checksums_url = next(
    (
        item["browser_download_url"]
        for item in assets
        if isinstance(item, dict)
        and item.get("name") == "checksums.txt"
        and isinstance(item.get("browser_download_url"), str)
    ),
    "-",
)
values = (
    tag,
    asset["name"],
    asset["browser_download_url"],
    digest,
    checksums_url,
)
if any("\t" in value or "\n" in value for value in values):
    raise SystemExit("Release metadata contains an invalid asset field")
print("\t".join(values))
PYSELECT
)"; then
  exit 1
fi

IFS=$'\t' read -r RELEASE_TAG ASSET_NAME ASSET_URL ASSET_DIGEST CHECKSUMS_URL <<<"$RELEASE_INFO"
if [[ -z "$RELEASE_TAG" || -z "$ASSET_NAME" || -z "$ASSET_URL" ]]; then
  echo "Release metadata did not contain a usable asset." >&2
  exit 1
fi

echo "Downloading $ASSET_NAME..."
if ! curl "${CURL_ARGS[@]}" --output "$ARCHIVE" "$ASSET_URL"; then
  echo "Failed to download $ASSET_NAME." >&2
  exit 1
fi

if [[ "$ASSET_DIGEST" == "-" && "$CHECKSUMS_URL" != "-" ]]; then
  CHECKSUMS_FILE="$TEMP_DIR/checksums.txt"
  echo "Downloading checksums.txt..."
  if ! curl "${CURL_ARGS[@]}" --output "$CHECKSUMS_FILE" "$CHECKSUMS_URL"; then
    echo "Failed to download checksums.txt." >&2
    exit 1
  fi

  if ! EXPECTED_SHA256="$(python3 - "$CHECKSUMS_FILE" "$ASSET_NAME" <<'PYCHECKSUM'
from pathlib import Path
import re
import sys

checksums_path, wanted_name = sys.argv[1:]
try:
    lines = Path(checksums_path).read_text(encoding="utf-8").splitlines()
except OSError as exc:
    raise SystemExit(f"Cannot read checksums.txt: {exc}")

for line in lines:
    fields = line.split(None, 1)
    if len(fields) != 2:
        continue
    digest, name = fields
    name = name.strip().lstrip("*")
    while name.startswith("./"):
        name = name[2:]
    if name == wanted_name:
        if not re.fullmatch(r"[0-9a-fA-F]{64}", digest):
            raise SystemExit(f"Invalid SHA-256 entry for {wanted_name}")
        print(digest)
        break
else:
    raise SystemExit(f"No SHA-256 entry for {wanted_name} in checksums.txt")
PYCHECKSUM
)"; then
    exit 1
  fi
  ASSET_DIGEST="sha256:$EXPECTED_SHA256"
fi

if [[ "$ASSET_DIGEST" == sha256:* ]]; then
  EXPECTED_SHA256="${ASSET_DIGEST#sha256:}"
  case "$EXPECTED_SHA256" in
    *[!0-9A-Fa-f]*|'')
      echo "GitHub returned an invalid SHA-256 digest for $ASSET_NAME." >&2
      exit 1
      ;;
  esac
  if ((${#EXPECTED_SHA256} != 64)); then
    echo "GitHub returned an invalid SHA-256 digest for $ASSET_NAME." >&2
    exit 1
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL_SHA256="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
  elif command -v sha256 >/dev/null 2>&1; then
    ACTUAL_SHA256="$(sha256 -q "$ARCHIVE")"
  else
    echo "Cannot verify the download: install sha256sum, shasum, or sha256." >&2
    exit 1
  fi

  ACTUAL_SHA256="$(printf '%s' "$ACTUAL_SHA256" | tr 'A-F' 'a-f')"
  EXPECTED_SHA256="$(printf '%s' "$EXPECTED_SHA256" | tr 'A-F' 'a-f')"
  if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
    echo "SHA-256 verification failed for $ASSET_NAME." >&2
    exit 1
  fi
  echo "SHA-256 verified."
elif [[ "$ASSET_DIGEST" != "-" ]]; then
  echo "Warning: GitHub supplied an unsupported digest: $ASSET_DIGEST" >&2
else
  echo "Warning: this release has no SHA-256 digest in its GitHub metadata." >&2
fi

mkdir -p -- "$DESTINATION"
INSTALL_TEMP="$(mktemp "$DESTINATION/.mihomo.XXXXXX")"

if ! gzip -dc "$ARCHIVE" >"$INSTALL_TEMP"; then
  echo "Failed to decompress $ASSET_NAME." >&2
  exit 1
fi
chmod 0755 "$INSTALL_TEMP"

if ! INSTALLED_VERSION="$("$INSTALL_TEMP" -v 2>&1)"; then
  echo "The downloaded file is not a working Mihomo executable." >&2
  exit 1
fi

mv -f -- "$INSTALL_TEMP" "$OUTPUT"
INSTALL_TEMP=""

echo "Installed: $OUTPUT"
echo "Release:   $RELEASE_TAG"
printf '%s\n' "$INSTALLED_VERSION" | sed -n '1p'
echo "Run with:  $OUTPUT -d $DESTINATION"
