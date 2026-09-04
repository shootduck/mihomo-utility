#!/usr/bin/env python3
"""
Generate ~/mihomo/config.yaml in either local-proxy or TUN mode.

Behavior:
- Never auto-detect SSH/RDP peers.
- Never create backups.
- Reuse the existing subscription URL and API secret when possible.
- Allow manual TUN exclusions through --exclude.
- Allow custom routing rules through repeatable --rule options.

No third-party Python modules are required.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import sys
import tempfile
from urllib.parse import urlsplit


TUN_ALIASES = {"tun", "true", "yes", "1", "on"}
PROXY_ALIASES = {"proxy", "notun", "no-tun", "false", "no", "0", "off"}

STATIC_TUN_EXCLUDES = (
    "0.0.0.0/8",
    "10.0.0.0/8",
    "100.64.0.0/10",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "224.0.0.0/4",
    "240.0.0.0/4",
    "::/128",
    "::1/128",
    "fc00::/7",
    "fe80::/10",
    "ff00::/8",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Generate a Mihomo config.yaml in proxy or TUN mode. "
            "When --subscription-url is omitted, reuse it from the existing config."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""Examples:
  %(prog)s proxy --subscription-url 'https://provider.example/sub?...'
  %(prog)s tun --subscription-url 'https://provider.example/sub?...'
  %(prog)s tun
  %(prog)s proxy
  %(prog)s tun --exclude 203.0.113.25
  %(prog)s tun --preserve-excludes
  %(prog)s tun --rule 'DOMAIN,example.com,DIRECT'
  %(prog)s tun --preserve-rules
  %(prog)s tun --rule 'DOMAIN,example.com,DIRECT' --rule 'DOMAIN-SUFFIX,example.org,DIRECT'
  read -rsp 'Subscription URL: ' URL; echo; %(prog)s tun -u "$URL"

Mode aliases:
  TUN:    tun, true, yes, 1, on
  Proxy:  proxy, notun, no-tun, false, no, 0, off
""",
    )
    parser.add_argument(
        "mode",
        help="Generate TUN mode or local-proxy mode.",
    )
    parser.add_argument(
        "-u",
        "--subscription-url",
        metavar="URL",
        help=(
            "Subscription URL. Use '-' to read it from standard input. "
            "If omitted, reuse the URL in the existing config."
        ),
    )
    parser.add_argument(
        "-c",
        "--config",
        type=Path,
        default=Path.home() / "mihomo" / "config.yaml",
        help="Output config path (default: ~/mihomo/config.yaml).",
    )
    parser.add_argument(
        "--exclude",
        action="append",
        default=[],
        metavar="IP_OR_CIDR",
        help=(
            "Additional destination to exclude from TUN routing. "
            "May be specified more than once."
        ),
    )
    parser.add_argument(
        "--preserve-excludes",
        action="store_true",
        help=(
            "Preserve route-exclude-address entries from the existing config, "
            "then append any addresses supplied with --exclude (TUN mode only)."
        ),
    )
    parser.add_argument(
        "--rule",
        action="append",
        default=[],
        metavar="RULE",
        help=(
            "Custom Mihomo routing rule to place before MATCH,MANUAL. "
            "May be specified more than once."
        ),
    )
    parser.add_argument(
        "--preserve-rules",
        action="store_true",
        help=(
            "Preserve custom rules from the existing config, then append any "
            "rules supplied with --rule."
        ),
    )
    return parser.parse_args()


def normalize_mode(value: str) -> str:
    normalized = value.strip().lower()
    if normalized in TUN_ALIASES:
        return "tun"
    if normalized in PROXY_ALIASES:
        return "proxy"
    accepted = ", ".join(sorted(TUN_ALIASES | PROXY_ALIASES))
    raise ValueError(f"invalid mode {value!r}; accepted values: {accepted}")


def yaml_scalar(value: str) -> str:
    """JSON double-quoted strings are valid YAML scalars."""
    return json.dumps(value, ensure_ascii=False)


def strip_yaml_comment(value: str) -> str:
    single = False
    double = False
    escaped = False

    for index, char in enumerate(value):
        if escaped:
            escaped = False
            continue
        if double and char == "\\":
            escaped = True
            continue
        if not double and char == "'":
            single = not single
            continue
        if not single and char == '"':
            double = not double
            continue
        if char == "#" and not single and not double:
            if index == 0 or value[index - 1].isspace():
                return value[:index].rstrip()
    return value.strip()


def decode_yaml_scalar(value: str) -> str:
    value = strip_yaml_comment(value.strip())
    if not value:
        return ""

    if value.startswith('"'):
        try:
            return json.loads(value)
        except json.JSONDecodeError as exc:
            raise ValueError(f"cannot parse double-quoted YAML scalar: {value}") from exc

    if value.startswith("'"):
        if len(value) < 2 or not value.endswith("'"):
            raise ValueError(f"cannot parse single-quoted YAML scalar: {value}")
        return value[1:-1].replace("''", "'")

    return value


def indentation(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def extract_existing_values(path: Path) -> tuple[str | None, str | None]:
    """
    Extract:
      1. proxy-providers.subscription.url, or the first HTTP provider URL
      2. the top-level API secret

    This handles the block-style configuration generated by this script and
    the earlier Mihomo configuration used in this conversation.
    """
    if not path.is_file():
        return None, None

    lines = path.read_text(encoding="utf-8").splitlines()
    secret: str | None = None

    for line in lines:
        if indentation(line) != 0:
            continue
        match = re.match(r"^secret\s*:\s*(.*?)\s*$", line)
        if match:
            secret = decode_yaml_scalar(match.group(1))
            break

    providers: list[dict[str, str]] = []
    in_providers = False
    current: dict[str, str] | None = None

    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        indent = indentation(line)

        if not in_providers:
            if indent == 0 and re.match(r"^proxy-providers\s*:\s*(?:#.*)?$", line):
                in_providers = True
            continue

        if indent == 0:
            break

        provider_match = re.match(r"^\s{2}([^:#][^:]*)\s*:\s*(?:#.*)?$", line)
        if provider_match:
            if current is not None:
                providers.append(current)
            current = {"name": provider_match.group(1).strip()}
            continue

        if current is None or indent != 4:
            continue

        field_match = re.match(r"^\s{4}([A-Za-z0-9_-]+)\s*:\s*(.*?)\s*$", line)
        if field_match:
            key, raw_value = field_match.groups()
            if key in {"type", "url"}:
                current[key] = decode_yaml_scalar(raw_value)

    if current is not None:
        providers.append(current)

    subscription_url = None

    for provider in providers:
        if provider.get("name") == "subscription" and provider.get("url"):
            subscription_url = provider["url"]
            break

    if subscription_url is None:
        for provider in providers:
            if provider.get("type") == "http" and provider.get("url"):
                subscription_url = provider["url"]
                break

    return subscription_url, secret


def extract_existing_rules(path: Path) -> list[str]:
    """Extract scalar entries from the top-level rules list."""
    if not path.is_file():
        return []

    rules: list[str] = []
    in_rules = False

    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        indent = indentation(line)

        if not in_rules:
            if indent == 0 and re.match(r"^rules\s*:\s*(?:#.*)?$", line):
                in_rules = True
            continue

        if stripped and not stripped.startswith("#") and indent == 0:
            break
        if not stripped or stripped.startswith("#"):
            continue

        item = re.match(r"^\s{2}-\s+(.+?)\s*$", line)
        if not item:
            raise ValueError(
                "cannot preserve non-scalar or unexpectedly formatted routing rule: "
                f"{line.strip()}"
            )

        rule = decode_yaml_scalar(item.group(1)).strip()
        if rule and rule.replace(" ", "").upper() != "MATCH,MANUAL":
            rules.append(rule)

    return rules


def extract_existing_exclusions(path: Path) -> list[str]:
    """Extract scalar entries from tun.route-exclude-address."""
    if not path.is_file():
        return []

    exclusions: list[str] = []
    in_tun = False
    in_exclusions = False

    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        indent = indentation(line)

        if not in_tun:
            if indent == 0 and re.match(r"^tun\s*:\s*(?:#.*)?$", line):
                in_tun = True
            continue

        if stripped and not stripped.startswith("#") and indent == 0:
            break

        if not in_exclusions:
            if indent == 2 and re.match(
                r"^\s{2}route-exclude-address\s*:\s*(?:#.*)?$", line
            ):
                in_exclusions = True
            continue

        if stripped and not stripped.startswith("#") and indent <= 2:
            break
        if not stripped or stripped.startswith("#"):
            continue

        item = re.match(r"^\s{4}-\s+(.+?)\s*$", line)
        if not item:
            raise ValueError(
                "cannot preserve non-scalar or unexpectedly formatted TUN exclusion: "
                f"{line.strip()}"
            )
        exclusions.append(decode_yaml_scalar(item.group(1)))

    return exclusions


def read_subscription_url(argument: str | None, config_path: Path) -> tuple[str, str]:
    if argument is None:
        existing_url, _ = extract_existing_values(config_path)
        if not existing_url:
            raise ValueError(
                "--subscription-url was not provided and no reusable HTTP "
                f"subscription URL was found in {config_path}"
            )
        url = existing_url
        source = "reused from existing config"
    elif argument == "-":
        if sys.stdin.isatty():
            import getpass
            url = getpass.getpass("Subscription URL: ")
        else:
            url = sys.stdin.readline().rstrip("\r\n")
        source = "read from standard input"
    else:
        url = argument
        source = "provided on command line"

    url = url.strip()
    if not url or url == "REPLACE_WITH_YOUR_SUBSCRIPTION_URL":
        raise ValueError("the subscription URL is empty or still a placeholder")

    parsed = urlsplit(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("the subscription URL must be a valid http:// or https:// URL")

    return url, source


def normalize_network(value: str) -> str:
    value = value.strip()
    try:
        return ipaddress.ip_network(value, strict=False).with_prefixlen
    except ValueError:
        try:
            address = ipaddress.ip_address(value)
        except ValueError as exc:
            raise ValueError(f"invalid IP address or CIDR: {value}") from exc
        suffix = 32 if address.version == 4 else 128
        return ipaddress.ip_network(f"{address}/{suffix}", strict=False).with_prefixlen


def build_exclusions(user_values: list[str]) -> list[str]:
    values = list(STATIC_TUN_EXCLUDES)
    values.extend(user_values)

    normalized: list[str] = []
    seen: set[str] = set()

    for value in values:
        network = normalize_network(value)
        if network not in seen:
            seen.add(network)
            normalized.append(network)

    return normalized


def build_rules(user_values: list[str]) -> list[str]:
    rules: list[str] = []
    seen: set[str] = set()

    for value in user_values:
        rule = value.strip()
        if not rule:
            raise ValueError("routing rules cannot be empty")
        if rule not in seen:
            seen.add(rule)
            rules.append(rule)

    return rules


def render_config(
    *,
    mode: str,
    subscription_url: str,
    api_secret: str,
    exclusions: list[str],
    rules: list[str],
) -> str:
    lines = [
        "# Generated by generate-config.py.",
        "# Keep this file private: it contains your subscription URL and API secret.",
        "",
        "mixed-port: 7890",
        "allow-lan: false",
        "mode: rule",
        "log-level: info",
        "ipv6: false",
        "unified-delay: true",
        "tcp-concurrent: true",
        "",
        "external-controller: 127.0.0.1:9090",
        f"secret: {yaml_scalar(api_secret)}",
        "",
        "profile:",
        "  store-selected: true",
    ]

    if mode == "tun":
        lines.append("  store-fake-ip: true")

    lines.extend(
        [
            "",
            "proxy-providers:",
            "  subscription:",
            "    type: http",
            f"    url: {yaml_scalar(subscription_url)}",
            "    path: ./providers/subscription.yaml",
            "    interval: 3600",
            "    header:",
            "      User-Agent:",
            '        - "mihomo"',
            "    health-check:",
            "      enable: true",
            "      url: https://www.gstatic.com/generate_204",
            "      interval: 300",
            "      timeout: 5000",
            "      lazy: true",
            "      expected-status: 204",
            "",
            "proxy-groups:",
            '  - name: "MANUAL"',
            "    type: select",
            "    use:",
            "      - subscription",
            "",
            "rules:",
        ]
    )
    lines.extend(f"  - {yaml_scalar(rule)}" for rule in rules)
    lines.append("  - MATCH,MANUAL")

    if mode == "tun":
        lines.extend(
            [
                "",
                "tun:",
                "  enable: true",
                "  stack: mixed",
                '  device: "mihomo"',
                "  auto-route: true",
                "  auto-redirect: false",
                "  auto-detect-interface: true",
                "  dns-hijack:",
                '    - "any:53"',
                '    - "tcp://any:53"',
                "  route-exclude-address:",
            ]
        )
        lines.extend(f'    - "{network}"' for network in exclusions)
        lines.extend(
            [
                "",
                "dns:",
                "  enable: true",
                "  ipv6: false",
                "  enhanced-mode: fake-ip",
                "  fake-ip-range: 198.18.0.1/16",
                "  use-hosts: true",
                "  use-system-hosts: true",
                "  default-nameserver:",
                "    - tls://223.5.5.5",
                "    - tls://223.6.6.6",
                "  nameserver:",
                "    - https://doh.pub/dns-query",
                "    - https://dns.alidns.com/dns-query",
            ]
        )

    return "\n".join(lines) + "\n"


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    (path.parent / "providers").mkdir(parents=True, exist_ok=True)

    file_descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=path.parent,
        text=True,
    )
    temporary_path = Path(temporary_name)

    try:
        with os.fdopen(file_descriptor, "w", encoding="utf-8", newline="\n") as file:
            file.write(content)
            file.flush()
            os.fsync(file.fileno())

        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def main() -> int:
    args = parse_args()

    try:
        mode = normalize_mode(args.mode)
        config_path = args.config.expanduser().resolve()
        subscription_url, url_source = read_subscription_url(
            args.subscription_url, config_path
        )

        _, existing_secret = extract_existing_values(config_path)
        api_secret = existing_secret or secrets.token_hex(24)

        exclusions: list[str] = []
        if mode == "tun":
            existing_exclusions = (
                extract_existing_exclusions(config_path)
                if args.preserve_excludes
                else []
            )
            exclusions = build_exclusions(existing_exclusions + args.exclude)
        existing_rules = extract_existing_rules(config_path) if args.preserve_rules else []
        rules = build_rules(existing_rules + args.rule)

        content = render_config(
            mode=mode,
            subscription_url=subscription_url,
            api_secret=api_secret,
            exclusions=exclusions,
            rules=rules,
        )

        atomic_write(config_path, content)

    except (OSError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    print(f"Generated: {config_path}")
    print(f"Mode:      {mode}")
    print(f"URL:       {url_source}")
    print(
        "API secret: "
        + ("preserved from existing config" if existing_secret else "newly generated")
    )

    if mode == "tun":
        if args.exclude:
            print("Manual TUN exclusion(s):")
            for value in args.exclude:
                print(f"  {normalize_network(value)}")
        elif not args.preserve_excludes:
            print("Remote peer auto-detection: disabled")
            print("Manual remote-client exclusion: not configured")
        if args.preserve_excludes:
            print("Existing TUN exclusions: preserved")

    if rules:
        label = "Preserved/custom routing rule(s):" if args.preserve_rules else "Custom routing rule(s):"
        print(label)
        for rule in rules:
            print(f"  {rule}")

    print()
    print("The existing config was replaced without creating a backup.")
    print("Stop any running Mihomo process before starting it with the new config.")
    print(f"Validate with: ~/mihomo/mihomo -t -d {config_path.parent}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
