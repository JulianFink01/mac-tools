"""Optional real-engine regression: python3 Tests/SecurityLargeArchive.py."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import zipfile

root = Path(__file__).resolve().parents[1]
engine = root / "Vendor/ClamAV/bin/clamscan"
database = Path.home() / "Library/Application Support/MacTools/ClamAV/database"
environment = dict(os.environ, CVD_CERTS_DIR=str(root / "Vendor/ClamAV/etc/certs"))
with tempfile.TemporaryDirectory(prefix="MacTools-archive-check-") as temporary:
    archive = Path(temporary) / "large-fixture.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=1) as bundle:
        with bundle.open("padding.bin", "w") as output:
            for _ in range(450):
                output.write(bytes(1024 * 1024))
    common = [str(engine), "--database=" + str(database), "--alert-exceeds-max=yes", "--max-filesize=2G", "--infected"]
    results = []
    for name, arguments in [
        ("previous", ["--max-scansize=400M", "--max-scantime=30000"]),
        ("fixed", ["--max-scansize=4G", "--max-scantime=120000", "--max-files=100000", "--max-recursion=64"]),
    ]:
        if name == "fixed":
            with zipfile.ZipFile(archive, "a", compression=zipfile.ZIP_DEFLATED) as bundle:
                # Detection takes precedence over a limit alert, so the baseline
                # checks the large clean entry before adding the harmless test.
                eicar = "X5O!P%@AP[4" + "\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"
                bundle.writestr("eicar.txt", eicar)
        started = time.monotonic()
        result = subprocess.run(common + arguments + [str(archive)], env=environment, capture_output=True, text=True, timeout=180)
        text = result.stdout + result.stderr
        print(name, "exit", result.returncode, "seconds", round(time.monotonic() - started, 2), flush=True)
        print(text, flush=True)
        results.append((result.returncode, text))
    assert "Heuristics.Limits.Exceeded" in results[0][1], results[0]
    assert results[1][0] == 1 and "eicar" in results[1][1].lower() and "Heuristics.Limits.Exceeded" not in results[1][1], results[1]
    print("PASS: bundled engine scans a 450 MiB archive entry and detects EICAR; previous 400 MiB budget limited the archive", flush=True)
