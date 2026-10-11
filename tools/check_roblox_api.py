#!/usr/bin/env python3
"""
Static Roblox API check for the Iron Throne source tree.

Validates engine API usage against Roblox's machine-generated API dump (the same reflection data
Studio uses), catching mistakes a Luau type checker cannot see through our UI.create() helper:

  * Instance.new("X") / UI.create("X", { ... })  class exists and is creatable
  * keys of UI.create property tables             writable, scriptable properties of that class
  * Enum.A.B                                      enum and item exist
  * game:GetService("X")                          X is a service
  * :GetPropertyChangedSignal("X")                X is a property of some class
  * .Event:Connect(  (PascalCase)                 event exists on some class
  * :Method(  (PascalCase)                        method exists on some class or datatype

Usage:
  curl -o API-Dump.json https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/roblox/API-Dump.json
  python3 tools/check_roblox_api.py --dump API-Dump.json [src]

Exit code 1 when problems are found.
"""

import argparse
import json
import os
import re
import sys

# Methods of Roblox datatypes and signals (not part of the class API dump), plus methods defined
# by this project's own PascalCase APIs (Signal).
EXTRA_METHODS = {
    "Connect", "Once", "Wait", "ConnectParallel", "Disconnect",  # RBXScriptSignal / Connection
    "Lerp", "Dot", "Cross", "FuzzyEq", "Max", "Min", "Abs", "Floor", "Ceil", "Sign",  # vectors
    "ToHSV", "ToHex",  # Color3
    "Fire", "DisconnectAll",  # project Signal
}


def load_api(path):
    with open(path, encoding="utf-8") as handle:
        dump = json.load(handle)
    classes = {c["Name"]: c for c in dump["Classes"]}
    enums = {e["Name"]: {i["Name"] for i in e["Items"]} for e in dump["Enums"]}

    def chain(name):
        while name and name in classes:
            yield classes[name]
            name = classes[name].get("Superclass")

    def members(name, member_type):
        found = {}
        for cls in chain(name):
            for member in cls["Members"]:
                if member["MemberType"] == member_type and member["Name"] not in found:
                    found[member["Name"]] = member
        return found

    all_props, all_events, all_methods = set(), set(), set(EXTRA_METHODS)
    for cls in dump["Classes"]:
        for member in cls["Members"]:
            kind = member["MemberType"]
            if kind == "Property":
                all_props.add(member["Name"])
            elif kind == "Event":
                all_events.add(member["Name"])
            elif kind in ("Function", "Callback"):
                all_methods.add(member["Name"])
    return classes, enums, members, all_props, all_events, all_methods


def table_keys(source, start):
    """Returns top-level `Key =` names of the table literal starting at source[start] == '{'."""
    depth, i, keys = 0, start, []
    key_pattern = re.compile(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)")
    at_entry_start = True
    while i < len(source):
        ch = source[i]
        if ch in "\"'":
            quote = ch
            i += 1
            while i < len(source) and source[i] != quote:
                i += 2 if source[i] == "\\" else 1
        elif ch == "`":
            i += 1
            while i < len(source) and source[i] != "`":
                i += 1
        elif source.startswith("--", i):
            while i < len(source) and source[i] != "\n":
                i += 1
            continue
        elif ch in "{([":
            depth += 1
            if depth == 1:
                at_entry_start = True
                i += 1
                continue
        elif ch in "})]":
            depth -= 1
            if depth == 0:
                return keys
        elif ch == "," and depth == 1:
            at_entry_start = True
            i += 1
            continue
        if depth == 1 and at_entry_start and not ch.isspace():
            match = key_pattern.match(source, i)
            if match:
                keys.append(match.group(1))
            at_entry_start = False
        i += 1
    return keys


def check_file(path, source, api):
    classes, enums, members, all_props, all_events, all_methods = api
    problems = []

    def line_of(index):
        return source.count("\n", 0, index) + 1

    def report(index, message):
        problems.append(f"{path}:{line_of(index)}: {message}")

    for match in re.finditer(r'(?:Instance\.new|UI\.create)\(\s*"([A-Za-z0-9]+)"', source):
        class_name = match.group(1)
        cls = classes.get(class_name)
        if cls is None:
            report(match.start(), f'unknown class "{class_name}"')
            continue
        if "NotCreatable" in (cls.get("Tags") or []):
            report(match.start(), f'class "{class_name}" cannot be created with Instance.new')
        rest = source[match.end():]
        brace = re.match(r"\s*,\s*\{", rest)
        if match.group(0).startswith("UI.create") and brace:
            start = match.end() + brace.end() - 1
            props = members(class_name, "Property")
            for key in table_keys(source, start):
                if key == "Parent":
                    continue
                prop = props.get(key)
                if prop is None:
                    report(match.start(), f'"{class_name}" has no property "{key}"')
                    continue
                tags = prop.get("Tags") or []
                if "ReadOnly" in tags or "NotScriptable" in tags:
                    report(match.start(), f'"{class_name}.{key}" is not writable from scripts')
                if "Deprecated" in tags:
                    report(match.start(), f'"{class_name}.{key}" is deprecated')

    for match in re.finditer(r"\bEnum\.([A-Za-z0-9]+)\.([A-Za-z0-9]+)", source):
        enum_name, item = match.groups()
        if enum_name not in enums:
            report(match.start(), f"unknown enum Enum.{enum_name}")
        elif item not in enums[enum_name]:
            report(match.start(), f"Enum.{enum_name} has no item {item}")

    for match in re.finditer(r'GetService\(\s*"([A-Za-z0-9]+)"\s*\)', source):
        cls = classes.get(match.group(1))
        if cls is None or "Service" not in (cls.get("Tags") or []):
            report(match.start(), f'"{match.group(1)}" is not a service')

    for match in re.finditer(r'GetPropertyChangedSignal\(\s*"([A-Za-z0-9]+)"\s*\)', source):
        if match.group(1) not in all_props:
            report(match.start(), f'no class has a property "{match.group(1)}"')

    for match in re.finditer(r"\.([A-Z][A-Za-z0-9]+):(?:Connect|Once|Wait)\(", source):
        if match.group(1) not in all_events:
            report(match.start(), f'no class has an event "{match.group(1)}"')

    defined = set(re.findall(r"function\s+[A-Za-z_][A-Za-z0-9_]*[.:]([A-Za-z_][A-Za-z0-9_]*)\s*\(", source))
    for match in re.finditer(r":([A-Z][A-Za-z0-9]+)\(", source):
        name = match.group(1)
        if name not in all_methods and name not in defined:
            report(match.start(), f'no class or datatype has a method "{name}"')

    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dump", required=True, help="path to API-Dump.json")
    parser.add_argument("root", nargs="?", default="src")
    args = parser.parse_args()
    if not os.path.exists(args.dump):
        print(f"API dump not found at {args.dump}; download it as described in the header.", file=sys.stderr)
        return 2
    api = load_api(args.dump)

    problems, checked = [], 0
    for directory, _, files in os.walk(args.root):
        for name in sorted(files):
            if name.endswith(".luau"):
                path = os.path.join(directory, name)
                with open(path, encoding="utf-8") as handle:
                    problems.extend(check_file(path, handle.read(), api))
                checked += 1

    for problem in problems:
        print(problem)
    print(f"checked {checked} files against the Roblox API dump: {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
