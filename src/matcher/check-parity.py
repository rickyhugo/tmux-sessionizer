#!/usr/bin/env python3
"""Compare the native oracle with the locked Rust oracle. No golden writes."""

import argparse
import json
from pathlib import Path
import random
import subprocess


ROOT = Path(__file__).resolve().parents[2]


def corpus():
    rng = random.Random(0x4E55434C454F)
    alphabet = "aabcABC012/,:;|_- .!^'$\\"
    for index in range(2400):
        items = [
            "".join(rng.choices(alphabet, k=rng.randrange(0, 65)))
            for _ in range(rng.randrange(4, 24))
        ]
        source = rng.choice(items)
        if source:
            positions = sorted(
                rng.sample(range(len(source)), min(len(source), rng.randrange(1, 9)))
            )
            query = "".join(source[i] for i in positions)
        else:
            query = rng.choice(["a", "", "!", "'"])
        if index % 3 == 0:
            query = query.lower()
        if index % 5 == 0:
            query = query.replace(" ", "\\ ")
        query = rng.choice(["", "", "", "^", "'", "!", "!^", "!'", "\\^"]) + query
        if index % 7 == 0:
            query += rng.choice(["$", "\\$", " a", " !b", " ^A", " 'c"])
        items += [query, query.lower(), source, source]
        yield f"ascii-{index}", query, items

    unicode_groups = [
        ["café", "cafe", "cafe\u0301", "Café", "caféteria", "caffè", "caf\u0301e"],
        ["ä", "Ä", "a", "Å", "bär", "bar", "a\u0308", "xÄ"],
        ["Σ", "σ", "ς", "µ", "μ", "Μ", "ſ", "s", "S", "İ", "i", "ı"],
        ["👩", "👩‍💻", "👩‍🔬", "👩🏽‍💻", "🧑‍💻", "👨‍👩‍👧", "🙂", "🏳️‍🌈"],
        ["🇸🇪", "🇸🇪🇩🇪", "🇸", "🇪", "🇩🇪", "🇸🇩", "🇸🇪🇩"],
        ["क्ष", "क्", "क", "ष", "क्‍ष", "क्षि", "ক্ক", "क्क", "कष", "ക്ഷ"],
        ["가", "가", "각", "각", "ᄀ", "ᅡ", "ᆨ", "ᄀ가"],
        [
            "a\u0301",
            "a",
            "a\u200d",
            "a\u0301b",
            "\u0600a",
            "\u0600b",
            "\r\né",
            "\u0301a",
        ],
        ["ᴀ", "ᴁ", "Ḁ", "ḁ", "ₐ", "ⁿ", "ɑ", "Æ", "æ", "ß", "ẞ", "K", "K", "k"],
        ["𐐀", "𐐨", "𐓘", "𐒰", "中文", "中", "１２", "12", "Ⅳ", "四", "\u00a0", "é"],
    ]
    for group_index, group in enumerate(unicode_groups):
        items = group + ["x" + item for item in group] + [item + "x" for item in group]
        items += [" " + item + " " for item in group] + [group[0], group[0]]
        for query_index, query in enumerate(group):
            for mode in ["", "^", "'", "!", "!^", "!'"]:
                yield f"unicode-{group_index}-{query_index}-{mode}", mode + query, items
            yield f"unicode-suffix-{group_index}-{query_index}", query + "$", items
            yield f"unicode-exact-{group_index}-{query_index}", "^" + query + "$", items
            yield f"unicode-atoms-{group_index}-{query_index}", query + " !z", items
            yield f"unicode-escape-{group_index}-{query_index}", query + "\\ x", items

    for index in range(600):
        alphabet = rng.choice(unicode_groups) + [
            "a",
            "B",
            " ",
            "/",
            "\\",
            "'",
            "!",
            "^",
            "$",
        ]
        items = [
            "".join(rng.choices(alphabet, k=rng.randrange(0, 20))) for _ in range(15)
        ]
        source = rng.choice(items)
        query = "".join(rng.choices(alphabet, k=rng.randrange(1, 5)))
        if index % 2 == 0 and source:
            query = source[: rng.randrange(1, len(source) + 1)]
        query = rng.choice(["", "", "'", "!", "^"]) + query
        if index % 5 == 0:
            query += "$"
        yield f"unicode-random-{index}", query, items + [source, source]

    for size in [63, 128, 256, 1024, 2048, 2049]:
        query = "a" * size
        items = [
            query,
            query.upper(),
            "z" + query,
            "a_" * size,
            "a/" * size,
            "a" * (size + 1),
        ]
        yield f"long-needle-{size}", query, items
    for size in [4096, 16384, 65535, 65536, 70000]:
        for query in ["ab", "abc", "aB", "'ab"]:
            items = [
                "a" + "x" * size + "babc",
                "ab" + "x" * size + "c",
                "a" + "x" * size + "bc",
                "ab/c",
                "éa" + "x" * size + "babc",
                "a" + "x" * size + "bcé",
            ]
            yield f"long-haystack-{size}-{query}", query, items

    for size in [100, 10000, 12000, 20000, 51200, 65536]:
        for prefix in ["", "é"]:
            items = [prefix + "a" + "x" * size + "b ab", "a/b", "ab", "a___b"]
            yield f"slab-budget-{size}-{prefix}", "ab", items
    query = "a" * 127 + "b"
    for gap in [543, 544]:
        items = ["a" * 127 + "x" * gap + "b " + query, query, "_" + query]
        yield f"matrix-cell-limit-{gap}", query, items

    items = [
        "foo",
        "Foo",
        " foo ",
        "\tfoo\t",
        "\vfoo\v",
        "éfoo",
        "fooé",
        "\r\nfoo",
        "\r\néfoo",
    ]
    for query in [
        "^foo",
        "^Foo",
        "foo$",
        "Foo$",
        "^foo$",
        "^Foo$",
        "\tfoo",
        "\vfoo",
        "\r\nfoo",
    ]:
        yield f"whitespace-{query!r}", query, items


def run(binary, query, items):
    completed = subprocess.run(
        [binary, "rank", query, *items], stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    if completed.returncode:
        raise RuntimeError(
            f"{binary} exited {completed.returncode}\n{completed.stderr.decode()}"
        )
    return completed.stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--oracle", required=True)
    parser.add_argument("--rust-oracle", required=True)
    parser.add_argument("--random-only", action="store_true")
    args = parser.parse_args()
    count = 0
    if not args.random_only:
        for case in json.loads((ROOT / "tests/compat/ranking.json").read_text()):
            actual = run(args.oracle, case["query"], case["items"])
            expected = "".join(item + "\n" for item in case["ranked"]).encode()
            if actual != expected:
                raise AssertionError(
                    f"Stored fixture mismatch: {case['name']}\n{actual!r}\n{expected!r}"
                )
            count += 1
        print(f"{count} stored ranking vectors passed", flush=True)
    differential = 0
    for name, query, items in corpus():
        expected = run(args.rust_oracle, query, items)
        actual = run(args.oracle, query, items)
        if actual != expected:
            raise AssertionError(
                f"{name}\nquery={query!r}\nitems={items!r}\n"
                f"Rust={expected!r}\nZig={actual!r}"
            )
        differential += 1
    print(f"{differential} independent differential vectors passed")


if __name__ == "__main__":
    main()
