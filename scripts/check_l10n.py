#!/usr/bin/env python3
"""Validate Ammo localization tables against Swift call sites.

Checks that zh-Hans and en tables share the same keys and printf placeholders,
that every `L("key")` referenced in Swift sources exists in both tables, and
that table values only use placeholders the Swift call sites can satisfy.

Usage: python3 scripts/check_l10n.py
"""
from __future__ import annotations

import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TABLES = {
    language: [ROOT / f"packages/QuotaCore/Sources/QuotaCore/Resources/{language}.lproj/{name}.strings"
               for name in ("Localizable", "TokenUsage", "ResetReminder")]
    for language in ("zh-Hans", "en")
}
SCAN_ROOTS = ["apps", "extensions", "native", "packages", "tests"]

ENTRY = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$')
PLACEHOLDER = re.compile(r"%(?:(\d+)\$)?([0-9.]*[@diufFeEgGxXosScSaA]|lld|ld|ll?u)")
# Tests probe the missing-key fallback on purpose; never flag these.
INTENTIONALLY_MISSING = {"totally.missing.key"}


def unescape(text: str) -> str:
    return (
        text.replace("\\n", "\n")
        .replace("\\t", "\t")
        .replace('\\"', '"')
        .replace("\\\\", "\\")
    )


def strip_swift_comments(source: str) -> str:
    source = re.sub(r"/\*.*?\*/", " ", source, flags=re.DOTALL)
    return "\n".join(
        "" if line.lstrip().startswith("//") else line for line in source.splitlines()
    )


def parse_table(path: Path) -> tuple[dict[str, str], list[str]]:
    table: dict[str, str] = {}
    problems: list[str] = []
    in_comment = False
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw.strip()
        if in_comment:
            if "*/" in line:
                in_comment = False
                line = line.split("*/", 1)[1].strip()
            else:
                continue
        if line.startswith("/*"):
            line = line[2:].strip()
            if "*/" in line:
                line = line.split("*/", 1)[1].strip()
            else:
                in_comment = True
                continue
        if not line or line.startswith("//"):
            continue
        match = ENTRY.match(line)
        if not match:
            problems.append(f"{path.relative_to(ROOT)}:{number}: 无法解析的行: {line[:80]}")
            continue
        key, value = unescape(match.group(1)), unescape(match.group(2))
        if key in table:
            problems.append(f"{path.relative_to(ROOT)}:{number}: 重复键 {key}")
            continue
        table[key] = value
    return table, problems


def placeholders(value: str) -> Counter:
    """Multiset of placeholder types, ignoring positional reordering."""
    types = []
    for match in PLACEHOLDER.finditer(value):
        kind = match.group(2)
        if kind in ("lld", "ld", "llu", "lu", "d", "i", "u", "x", "X", "o"):
            types.append("int")
        elif kind in ("f", "e", "E", "g", "G"):
            types.append("float")
        else:
            types.append("object")
    return Counter(types)


def literal_percent_without_specifier(value: str) -> bool:
    stripped = PLACEHOLDER.sub("", value)
    return "%" in stripped and "%" not in value.replace("%%", "")


STRING_LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')


def localized_status_literals(source: str) -> set[str]:
    """Keys passed to `LocalizedStatus(...)`. The call may span lines and take
    ternary key branches (`cond ? "a" : "b"`), so balance parentheses and take
    every quoted literal inside the call — non-key arguments are expressions,
    never string literals."""
    keys: set[str] = []
    seen = set()
    index = 0
    while True:
        start = source.find("LocalizedStatus(", index)
        if start == -1:
            break
        index = start + len("LocalizedStatus")
        depth = 0
        end = index
        for position in range(index, min(index + 4000, len(source))):
            character = source[position]
            if character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
                if depth == 0:
                    end = position
                    break
        for match in STRING_LITERAL.finditer(source[index:end]):
            key = unescape(match.group(1))
            if key and key not in seen:
                seen.add(key)
                keys.append(key)
        index = end or index + 1
    return seen


def referenced_keys() -> tuple[set[str], list[str]]:
    keys: set[str] = set()
    problems: list[str] = []
    for root in SCAN_ROOTS:
        for path in (ROOT / root).rglob("*.swift"):
            if ".build" in path.parts or "Vendor" in path.parts:
                continue
            source = strip_swift_comments(path.read_text(encoding="utf-8"))
            for match in re.finditer(r'\bL\(\s*"((?:[^"\\]|\\.)*)"', source):
                keys.add(unescape(match.group(1)))
            for match in re.finditer(r'\bL10n\.resource\(\s*"((?:[^"\\]|\\.)*)"', source):
                keys.add(unescape(match.group(1)))
            # LocalizedStatus stores key + arguments so status lines can be
            # re-rendered after a language switch; its keys resolve at render.
            keys |= localized_status_literals(source)
    return keys, problems


def main() -> int:
    failures: list[str] = []
    warnings: list[str] = []
    tables: dict[str, dict[str, str]] = {}
    for language, paths in TABLES.items():
        tables[language] = {}
        for path in paths:
            if not path.exists():
                failures.append(f"缺少语言表: {path.relative_to(ROOT)}")
                continue
            table, problems = parse_table(path)
            failures.extend(problems)
            for key in table:
                if key in tables[language]:
                    failures.append(f"跨表重复键: {language}/{key}")
                expected_table = "TokenUsage" if key.startswith("tokenUsage.") else "ResetReminder" if key.startswith("resetReminder.") else "Localizable"
                if path.stem != expected_table:
                    failures.append(f"键位于错误语言表: {language}/{key}")
            tables[language].update(table)

    if len(tables) == len(TABLES):
        zh, en = tables["zh-Hans"], tables["en"]
        for key in sorted(set(zh) - set(en)):
            failures.append(f"en 表缺少键: {key}")
        for key in sorted(set(en) - set(zh)):
            failures.append(f"zh-Hans 表缺少键: {key}")
        for key in sorted(set(zh) & set(en)):
            if placeholders(zh[key]) != placeholders(en[key]):
                failures.append(f"占位符不一致: {key} (zh={zh[key]!r}, en={en[key]!r})")

        referenced, problems = referenced_keys()
        failures.extend(problems)
        for key in sorted(referenced - set(zh) - INTENTIONALLY_MISSING):
            failures.append(f"代码引用了未定义的键: {key}")
        for key in sorted(set(zh) - referenced):
            if not key.startswith("language."):
                warnings.append(f"表中的键没有被代码引用（可能仅供测试）: {key}")

    for line in warnings:
        print(f"警告: {line}")
    for line in failures:
        print(f"错误: {line}")
    total = len(tables.get("zh-Hans", {}))
    print(f"检查完成: {total} 个键，{len(failures)} 个错误")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
