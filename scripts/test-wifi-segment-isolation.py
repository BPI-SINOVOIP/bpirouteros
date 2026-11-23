#!/usr/bin/env python3
"""Exercise the image's wireless config reader with legacy segment UCI input."""

import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("libnetifd", type=Path, help="staged rootfs lib/netifd")
    parser.add_argument("--ucode", default="ucode", help="host ucode with fs module")
    parser.add_argument("--module-path", help="host ucode module search pattern")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        shutil.copyfile(args.libnetifd / "wireless.uc", root / "wireless.uc")
        shutil.copyfile(args.libnetifd / "utils.uc", root / "parser.uc")
        # Register the radio without shelling out to a hardware driver.
        symbols = ("handler_attributes parse_attribute_list parse_bool parse_array "
                   "TYPE_ARRAY TYPE_STRING TYPE_INT TYPE_BOOL").split()
        (root / "utils.uc").write_text(
            'import * as parser from "./parser.uc";\n'
            + "".join(f"export const {name} = parser.{name};\n" for name in symbols)
            + 'export function handler_load(path, register) { register("driver", { name: "mac80211" }); };\n'
        )
        (root / "wireless-device.uc").write_text("export function new(data) { return { data }; };\n")
        (root / "ubus.uc").write_text(
            "export function publish() {}; export function listener() {}; export function call() {};\n"
        )
        (root / "wifi").mkdir()
        (root / "wifi/utils.uc").write_text("export function find_phy() {};\n")
        (root / "wireless").mkdir()
        (root / "test.uc").write_text("""
global.netifd = { main_path: "." };
let reader = loadfile("./wireless.uc")();
function addAP(input, segment, radio, options, name) {
    let device = "radio" + radio;
    input[device] = { ".type": "wifi-device", type: "mac80211" };
    input[name] = { ".type": "wifi-iface", mode: "ap", device,
                    ssid: "Shared", network: segment, bpir_managed: "1", ...options };
}
function readConfig(input) {
    netifd.wireless.devices = {};
    reader.config_init({ get_all: () => input });
    return netifd.wireless.devices;
}
function check(segment, radio, options, name, bridge, station) {
    let input = {};
    addAP(input, segment, radio, options, name);
    let vif = readConfig(input)["radio" + radio].data.vif[0];
    assert(vif.name == name && !!vif.config.bridge_isolate == bridge &&
           !!vif.config.isolate == station, sprintf("unexpected flags: %s %J", name, options));
}
for (let segment in ["bpir_guest", "bpir_iot"]) {
    for (let radio in [0, 1]) {
        let name = segment + "_radio" + radio;
        check(segment, radio, { isolate: "1" }, name, true, true);
        check(segment, radio, { isolate: "0" }, name, false, false);
        check(segment, radio, { network: [segment], isolate: "1" }, name, true, true);
        check(segment, radio, { network: [segment], isolate: "0" }, name, false, false);
        check(segment, radio, { network: [segment, "lan"], isolate: "1" }, name, false, true);
        check(segment, radio, { isolate: "1", bpir_managed: "0" }, name, false, true);
        check(segment, radio, { isolate: "1", mode: "sta" }, name, false, true);
        check(segment, radio, { isolate: "1" }, "custom", false, true);
    }
    for (let enabled in [0, 1]) {
        let input = {};
        for (let radio in [0, 1])
            addAP(input, segment, radio, { isolate: radio == enabled ? "1" : "0" },
                  segment + "_radio" + radio);
        let devices = readConfig(input);
        for (let radio in [0, 1]) {
            let cfg = devices["radio" + radio].data.vif[0].config;
            assert(!!cfg.bridge_isolate == (radio == enabled) && !!cfg.isolate == (radio == enabled),
                   sprintf("mixed isolation flags: %s radio%d", segment, radio));
        }
    }
}
check("lan", 0, { isolate: "1" }, "default_radio0", false, true);
check("lan", 0, { isolate: "0", bridge_isolate: "1" }, "custom", true, false);
""")
        command = [args.ucode, "-L", "./*.uc"]
        if args.module_path:
            command.extend(["-L", args.module_path])
        command.append("test.uc")
        subprocess.run(command, cwd=root, check=True)
    print("PASS: managed Guest/IoT bridge isolation and independent AP settings")


if __name__ == "__main__":
    main()
