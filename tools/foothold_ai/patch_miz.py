#!/usr/bin/env python3
"""Embed the Foothold AI scripts into a .miz and add a trigger that loads them.

The trigger ("Foothold AI", type ONCE, TIME MORE) runs a few seconds after the
last existing DO SCRIPT FILE trigger, so zoneCommanderv2.lua, the setup file,
Foothold CTLD and AIEN are already loaded. Running the tool again on a patched
mission only refreshes the script files.

The original .miz is never modified unless --in-place is given (a .bak copy is
made first). After writing, the output is re-read and checked: every original
mission value must be unchanged apart from the added trigger.

Usage:
    python patch_miz.py "Foothold_PG_5.3.5_....miz"
    python patch_miz.py in.miz -o out.miz
    python patch_miz.py in.miz --in-place
"""

from __future__ import annotations

import argparse
import copy
import pathlib
import re
import shutil
import sys
import zipfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import miz_lua  # noqa: E402

REPO = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_SCRIPTS = ["Foothold_AI_Core.lua", "Foothold_AI_Wingman.lua"]
TRIGGER_COMMENT = "Foothold AI"
MISSION = "mission"
MAP_RESOURCE = "l10n/DEFAULT/mapResource"
RESOURCE_DIR = "l10n/DEFAULT/"


def read_lua(zf: zipfile.ZipFile, name: str):
    text = zf.read(name).decode("utf-8", "surrogateescape")
    return miz_lua.loads(text)


def encode_lua(name: str, value) -> bytes:
    return miz_lua.dumps(name, value).encode("utf-8", "surrogateescape")


def int_keys(table: dict) -> list[int]:
    return [k for k in table if isinstance(k, int)]


def script_trigger_delay(mission: dict) -> int:
    """Seconds after the latest existing TIME MORE trigger that loads scripts."""
    latest = 0
    for rule in mission.get("trigrules", {}).values():
        actions = rule.get("actions", {}).values()
        if not any(a.get("predicate") == "a_do_script_file" for a in actions):
            continue
        for cond in rule.get("rules", {}).values():
            if cond.get("predicate") == "c_time_after":
                latest = max(latest, int(float(cond.get("seconds", 0))))
    return max(20, latest + 5)


def find_time_rule_template(mission: dict) -> dict | None:
    for rule in mission.get("trigrules", {}).values():
        for cond in rule.get("rules", {}).values():
            if cond.get("predicate") == "c_time_after":
                return copy.deepcopy(cond)
    return None


def patch(mission: dict, map_resource: dict, scripts: list[str]) -> tuple[int, list[str]]:
    """Add or refresh the Foothold AI trigger. Returns (trigger index, resource keys)."""
    trig = mission["trig"]
    trigrules = mission.setdefault("trigrules", {})

    # Resource keys: reuse an existing key for the same file name.
    by_file = {v: k for k, v in map_resource.items()}
    max_dict = int(float(mission.get("maxDictId", 0)))
    keys = []
    for script in scripts:
        key = by_file.get(script)
        if not key:
            max_dict += 1
            key = f"ResKey_Action_{max_dict}"
            map_resource[key] = script
        keys.append(key)
    mission["maxDictId"] = max_dict

    existing = [i for i, r in trigrules.items() if r.get("comment") == TRIGGER_COMMENT]
    index = existing[0] if existing else max(int_keys(trigrules) + int_keys(trig["actions"]) + [0]) + 1
    delay = script_trigger_delay({"trigrules": {k: v for k, v in trigrules.items() if k != index}})

    actions_code = "".join(f'a_do_script_file(getValueResourceByKey("{k}"));' for k in keys)
    trig["actions"][index] = f"{actions_code} mission.trig.func[{index}]=nil;"
    trig["func"][index] = f"if mission.trig.conditions[{index}]() then mission.trig.actions[{index}]() end"
    trig["conditions"][index] = f"return(c_time_after({delay}) )"
    trig["flag"][index] = True

    rule = find_time_rule_template({"trigrules": {k: v for k, v in trigrules.items() if k != index}}) \
        or {"predicate": "c_time_after"}
    rule["seconds"] = delay
    trigrules[index] = {
        "rules": {1: rule},
        "comment": TRIGGER_COMMENT,
        "eventlist": "",
        "predicate": "triggerOnce",
        "actions": {i + 1: {"predicate": "a_do_script_file", "file": k} for i, k in enumerate(keys)},
        "colorItem": "0x00ff00ff",
    }
    return index, keys


def verify(original_mission: dict, original_map: dict, out_path: pathlib.Path,
           index: int, keys: list[str], scripts: dict[str, bytes]) -> None:
    with zipfile.ZipFile(out_path) as zf:
        _, mission = read_lua(zf, MISSION)
        _, map_resource = read_lua(zf, MAP_RESOURCE)
        for name, data in scripts.items():
            if zf.read(RESOURCE_DIR + name) != data:
                raise AssertionError(f"embedded {name} differs from source")
    for key in keys:
        if map_resource.get(key) not in scripts:
            raise AssertionError(f"mapResource {key} missing")

    stripped = copy.deepcopy(mission)
    expected = copy.deepcopy(original_mission)
    for part in ("actions", "func", "conditions", "flag"):
        stripped["trig"][part].pop(index, None)
        expected["trig"][part].pop(index, None)
    stripped["trigrules"].pop(index, None)
    expected["trigrules"].pop(index, None)
    stripped.pop("maxDictId", None)
    expected.pop("maxDictId", None)
    if miz_lua.normalized(stripped) != miz_lua.normalized(expected):
        raise AssertionError("mission content changed outside the Foothold AI trigger")
    extra = {k: v for k, v in map_resource.items() if k not in original_map}
    if any(v not in scripts for v in extra.values()):
        raise AssertionError("unexpected mapResource entries")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Embed Foothold AI scripts into a .miz")
    parser.add_argument("miz", type=pathlib.Path)
    parser.add_argument("-o", "--output", type=pathlib.Path)
    parser.add_argument("--in-place", action="store_true", help="overwrite the input (keeps a .bak)")
    parser.add_argument("--scripts-dir", type=pathlib.Path, default=REPO / "Common Scripts")
    parser.add_argument("--script", action="append", dest="scripts",
                        help="script file name to embed (repeatable, in load order)")
    args = parser.parse_args(argv)

    scripts = args.scripts or DEFAULT_SCRIPTS
    script_data = {name: (args.scripts_dir / name).read_bytes() for name in scripts}

    if args.in_place:
        out_path = args.miz
        backup = args.miz.with_suffix(args.miz.suffix + ".bak")
        shutil.copy2(args.miz, backup)
        print(f"backup: {backup}")
    else:
        out_path = args.output or args.miz.with_name(args.miz.stem + "_AI" + args.miz.suffix)
    tmp_path = out_path.with_name(out_path.name + ".tmp")

    with zipfile.ZipFile(args.miz) as zin:
        name, mission = read_lua(zin, MISSION)
        map_name, map_resource = read_lua(zin, MAP_RESOURCE)
        original_mission = copy.deepcopy(mission)
        original_map = copy.deepcopy(map_resource)
        index, keys = patch(mission, map_resource, scripts)
        replaced = {
            MISSION: encode_lua(name, mission),
            MAP_RESOURCE: encode_lua(map_name, map_resource),
        }
        for script, data in script_data.items():
            replaced[RESOURCE_DIR + script] = data
        with zipfile.ZipFile(tmp_path, "w") as zout:
            written = set()
            for info in zin.infolist():
                data = replaced.get(info.filename)
                zout.writestr(info, data if data is not None else zin.read(info.filename),
                              compress_type=info.compress_type)
                written.add(info.filename)
            for filename, data in replaced.items():
                if filename not in written:
                    zout.writestr(filename, data, compress_type=zipfile.ZIP_DEFLATED)

    verify(original_mission, original_map, tmp_path, index, keys, script_data)
    tmp_path.replace(out_path)
    delay = re.search(r"c_time_after\((\d+)\)", mission["trig"]["conditions"][index]).group(1)
    print(f"wrote {out_path}")
    print(f"trigger #{index} '{TRIGGER_COMMENT}' (ONCE, TIME MORE {delay}s) loads: {', '.join(scripts)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
