#!/usr/bin/env python3
"""Translation tooling for Sources/Murmur/Localizable.xcstrings.

  l10n.py export            write l10n/source.json (what translators work from)
  l10n.py merge  [lang...]  fold l10n/translations/<lang>.json into the catalog
  l10n.py check  [lang...]  validate shards (and the catalog) without writing

A shard is a JSON object: key -> string, or for plural keys key -> {category: string}.
Placeholders (%@, %lld, %%, %1$@) must survive translation; `check` enforces that.
"""
import json, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Sources/Murmur/Localizable.xcstrings"
L10N = ROOT / "l10n"
SOURCE = L10N / "source.json"
SHARDS = L10N / "translations"

# Target languages (Parakeet v3) and the CLDR plural categories each one needs.
LANGUAGES = {
    "bg": ["one", "other"], "hr": ["one", "few", "other"], "cs": ["one", "few", "many", "other"],
    "da": ["one", "other"], "nl": ["one", "other"], "et": ["one", "other"], "fi": ["one", "other"],
    "fr": ["one", "many", "other"], "de": ["one", "other"], "el": ["one", "other"], "hu": ["one", "other"],
    "it": ["one", "many", "other"], "lv": ["zero", "one", "other"], "lt": ["one", "few", "many", "other"],
    "mt": ["one", "two", "few", "many", "other"], "pl": ["one", "few", "many", "other"],
    "pt-PT": ["one", "many", "other"], "ro": ["one", "few", "other"], "sk": ["one", "few", "many", "other"],
    "sl": ["one", "two", "few", "other"], "es": ["one", "many", "other"], "sv": ["one", "other"],
    "ru": ["one", "few", "many", "other"], "uk": ["one", "few", "many", "other"],
}

PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:ll?d|@|d|f|%)")


def load_catalog():
    return json.loads(CATALOG.read_text(encoding="utf-8"))


def english_forms(entry):
    plural = entry.get("localizations", {}).get("en", {}).get("variations", {}).get("plural")
    return {c: u["stringUnit"]["value"] for c, u in plural.items()} if plural else None


def placeholders(text):
    """Placeholder types, ignoring position numbers: `%1$@` and `%@` are the same kind."""
    return sorted(re.sub(r"%\d+\$", "%", p) for p in PLACEHOLDER.findall(text))


def export():
    catalog = load_catalog()
    items = []
    for key, entry in catalog["strings"].items():
        if entry.get("shouldTranslate") is False:
            continue
        item = {"key": key, "comment": entry.get("comment", "")}
        forms = english_forms(entry)
        if forms:
            item["plural"] = forms
        items.append(item)
    L10N.mkdir(exist_ok=True)
    SOURCE.write_text(json.dumps({"languages": LANGUAGES, "strings": items}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"exported {len(items)} strings to {SOURCE.relative_to(ROOT)}")


def shard_problems(lang, shard, source):
    problems = []
    keys = {item["key"]: item for item in source["strings"]}
    for key in keys.keys() - shard.keys():
        problems.append(f"missing: {key!r}")
    for key in shard.keys() - keys.keys():
        problems.append(f"unknown key: {key!r}")
    for key, item in keys.items():
        if key not in shard:
            continue
        value = shard[key]
        if "plural" in item:
            if not isinstance(value, dict):
                problems.append(f"{key!r}: expected plural forms {LANGUAGES[lang]}")
                continue
            if sorted(value) != sorted(LANGUAGES[lang]):
                problems.append(f"{key!r}: plural categories {sorted(value)} != {sorted(LANGUAGES[lang])}")
            texts = list(value.values())
            expected = placeholders(item["plural"]["other"])
        else:
            if not isinstance(value, str):
                problems.append(f"{key!r}: expected a string")
                continue
            texts, expected = [value], placeholders(key)
        for text in texts:
            if not isinstance(text, str) or not text.strip():
                problems.append(f"{key!r}: empty translation")
            elif placeholders(text) != expected:
                problems.append(f"{key!r}: placeholders {placeholders(text)} != {expected} in {text!r}")
    return problems


def selected(args):
    langs = args or sorted(LANGUAGES)
    bad = [lang for lang in langs if lang not in LANGUAGES]
    if bad:
        sys.exit(f"unknown language(s): {bad}")
    return langs


def read_shard(lang):
    path = SHARDS / f"{lang}.json"
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else None


def check(langs):
    source = json.loads(SOURCE.read_text(encoding="utf-8"))
    failed = False
    for lang in langs:
        shard = read_shard(lang)
        if shard is None:
            print(f"{lang}: no shard"); failed = True; continue
        problems = shard_problems(lang, shard, source)
        print(f"{lang}: {'ok' if not problems else str(len(problems)) + ' problem(s)'}")
        for problem in problems[:40]:
            print(f"   {problem}")
        failed = failed or bool(problems)
    return not failed


def merge(langs):
    if not check(langs):
        sys.exit("refusing to merge: fix the problems above first")
    catalog = load_catalog()
    for lang in langs:
        shard = read_shard(lang)
        for key, value in shard.items():
            entry = catalog["strings"][key]
            localizations = entry.setdefault("localizations", {})
            if isinstance(value, dict):
                localizations[lang] = {"variations": {"plural": {c: {"stringUnit": {"state": "translated", "value": v}} for c, v in value.items()}}}
            else:
                localizations[lang] = {"stringUnit": {"state": "translated", "value": value}}
    CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"merged {len(langs)} language(s) into {CATALOG.relative_to(ROOT)}")


if __name__ == "__main__":
    command, rest = (sys.argv[1] if len(sys.argv) > 1 else ""), sys.argv[2:]
    if command == "export": export()
    elif command == "merge": merge(selected(rest))
    elif command == "check": sys.exit(0 if check(selected(rest)) else 1)
    else: sys.exit(__doc__)
