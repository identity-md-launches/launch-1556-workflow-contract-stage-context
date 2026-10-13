#!/usr/bin/env python3
"""Export the exact built Solidity ABIs, or verify the checked-in copies. No network is used."""

import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
CONTRACTS = {
    "LaunchToken": "src/LaunchToken.sol:LaunchToken",
    "MoonRewards": "src/MoonRewards.sol:MoonRewards",
    "MoonShop": "src/MoonShop.sol:MoonShop",
    "CourierCompanions": "src/CourierCompanions.sol:CourierCompanions",
    "IPostOffice": "src/interfaces/IPostOffice.sol:IPostOffice",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if any exported ABI differs")
    args = parser.parse_args()
    failed = False
    for name, artifact in CONTRACTS.items():
        result = subprocess.run(
            ["forge", "inspect", artifact, "abi", "--json"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        abi = json.loads(result.stdout)
        output = json.dumps(abi, indent=2) + "\n"
        path = ROOT / "docs" / "abi" / f"{name}.json"
        if args.check:
            if not path.is_file() or path.read_text() != output:
                print(f"ABI is missing or stale: {path.relative_to(ROOT)}", file=sys.stderr)
                failed = True
            else:
                print(f"Verified {path.relative_to(ROOT)}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(output)
            print(f"Exported {path.relative_to(ROOT)}")
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
