#!/usr/bin/env python3
"""
Regenerate waterfall hardware support report artifacts from SUPPORTED_DEVICES.md.

Writes:
  reports/waterfall-hardware-support.json
  reports/waterfall-hardware-support.html
  ~/.cursor/projects/.../canvases/waterfall-hardware-support.canvas.tsx
    (if the managed canvases directory exists)

Run from the waterfall work-area root:
  python3 contrib/waterfall/tools/gen-hardware-support-report.py

Keep this in sync with contrib/waterfall package capability (ath9k / ath10k
spectral) and focus devices in waterfall.uc isFocusBoard().
"""
from __future__ import annotations

import json
import re
import html as html_lib
from collections import Counter
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]  # waterfall work area
SUPPORTED = ROOT / "SUPPORTED_DEVICES.md"
REPORTS = ROOT / "reports"
PKG_BUILD = ROOT / "contrib" / "waterfall" / "build.sh"
CANVAS_CANDIDATES = [
    Path.home() / ".cursor/projects/home-kirk-ai-projects-AREDN-waterfall/canvases/waterfall-hardware-support.canvas.tsx",
]


def package_version() -> str:
    text = PKG_BUILD.read_text(encoding="utf-8")
    m = re.search(r"-v\s+([0-9.]+)", text)
    ver = m.group(1) if m else "0.0.0"
    return f"{ver}-r0"


def clean_cell(s: str) -> str:
    s = re.sub(r"<br\s*/?>", " / ", s)
    s = re.sub(r"\*\*", "", s)
    return " ".join(s.split()).strip()


def parse_devices(text: str) -> list[dict]:
    lines = text.splitlines()
    current_vendor = None
    current_status_override = None
    devices: list[dict] = []
    for line in lines:
        m = re.match(r"^## (.+)$", line)
        if m:
            current_vendor = m.group(1).strip()
            current_status_override = None
            continue
        if line.startswith("**Sunset Devices**"):
            current_status_override = "sunset"
            continue
        if line.startswith("**Frozen Devices**"):
            current_status_override = "frozen"
            continue
        if not current_vendor or current_vendor.startswith("Footnotes"):
            continue
        if (
            line.startswith("Model")
            or line.startswith("Hypervisor")
            or line.startswith(":---")
            or not line.strip()
            or "|" not in line
        ):
            continue
        cells = [clean_cell(c) for c in line.split("|")]
        while cells and cells[0] == "":
            cells.pop(0)
        while cells and cells[-1] == "":
            cells.pop()
        if len(cells) < 6 or cells[0] in ("Model", "Hypervisor"):
            continue
        vendor = current_vendor
        if vendor.startswith("x86"):
            model, skus, band = cells[0], "", "none"
            target, subtarget, image = cells[1], cells[2], cells[3]
            ram, stability = cells[4], cells[5]
            status = cells[6] if len(cells) > 6 else ""
        else:
            model, skus, band = cells[0], cells[1], cells[2]
            target, subtarget, image = cells[3], cells[4], cells[5]
            ram = cells[6] if len(cells) > 6 else ""
            stability = cells[7] if len(cells) > 7 else ""
            status = cells[8] if len(cells) > 8 else ""
        if current_status_override == "sunset" and "sunset" not in status.lower():
            status = "sunset"
        elif current_status_override == "frozen" and "frozen" not in status.lower():
            status = "frozen"
        devices.append(
            dict(
                vendor=vendor,
                model=model,
                skus=skus,
                band=band,
                target=target,
                subtarget=subtarget,
                image=image,
                ram=ram,
                stability=stability,
                status=status,
            )
        )
    return devices


def is_ac(model: str, image: str) -> bool:
    blob = (model + " " + image).lower()
    keys = [
        "5ac",
        "5-ac",
        "ac-gen",
        "ac gen",
        "nanobeam-ac",
        "nanostation-ac",
        "litebeam-ac",
        "powerbeam-5ac",
        "rocket-5ac",
        "lap-120",
        "5hpac",
        "922uags",
        "lhgg-5ac",
        "ldf-5ac",
        "sxtsq-5-ac",
        "cpe710",
        "liteap 5ac",
        "hap ac",
        "nanobeam 5ac",
        "nanostation 5ac",
        "litebeam 5ac",
        "powerbeam 5ac",
        "rocket 5ac",
        "mantbox 15",
        "mantbox 19",
        "netmetal",
    ]
    return any(k in blob for k in keys)


def classify(d: dict) -> tuple[str, bool, str] | None:
    """Return (waterfall, focus, reason) or None to omit."""
    model = d["model"].lower()
    band = d["band"].lower()
    target = d["target"].lower()
    image = d["image"].lower()
    status = d["status"].lower()
    vendor = d["vendor"].lower()
    sub = d["subtarget"].lower()

    if "not supported" in status:
        return None
    if "x86" in vendor or target == "x86" or band == "none":
        return ("cannot", False, "No onboard mesh RF suitable for spectral waterfall")
    if "halow" in band or "morse" in vendor or "morse" in image:
        return ("cannot", False, "HaLow/Morse PHY — no ath9k/ath10k spectral FFT")
    if "mediatek" in target or "filogic" in sub or "ax" in band:
        return ("possible", False, "mt76/filogic AX — needs new spectral backend")
    if any(x in target or x in sub for x in ["ramips", "mt76", "mt7621", "mt76x8"]):
        return ("possible", False, "mt76 — spectral possible with package work")
    if "ipq40xx" in target:
        return ("possible", False, "ipq40xx/ath10k — spectral capture blocked until a safe path exists")

    if "hap ac lite" in model or "952ui-5ac2nd" in image:
        return (
            "possible",
            True,
            "Focus board — 5 GHz ath10k capture blocked (lockups); 2.4 GHz ath9k still usable",
        )
    if "powerbeam 5ac 500" in model or "powerbeam-5ac-500" in image:
        return (
            "possible",
            True,
            "Focus board — ath10k spectral capture blocked until a safe path exists",
        )
    if "rocket m5" in model:
        return ("now", True, "Focus — ath9k spectral FFT (primary)")
    if ("powerbeam" in model and "m5" in model and "ac" not in model) or "powerbeam-m5" in image:
        return ("now", True, "Focus — ath9k spectral FFT (primary)")

    if is_ac(model, image):
        return ("possible", False, "ath10k AC — spectral capture blocked (lockup risk) until a safe path exists")

    if "ath79" in target:
        if any(x in image or x in model for x in ["gl-ar750", "gl-e750", "creta", "slate", "mudi"]):
            return ("possible", False, "Dual-band GL — mixed chipsets; needs per-board validation")
        if "5" in band or "3" in band or "900" in band or "2 & 5" in band:
            return ("now", False, "ath9k spectral FFT path (current package)")
        if band.strip() in ("2",) or band.startswith("2"):
            return ("now", False, "ath9k 2.4 GHz spectral FFT works; 5 GHz preferred when dual-band")
        return ("possible", False, "ath79 — confirm spectral debugfs")
    return ("possible", False, f"Unclassified ({target}); investigate")


def build_rows(devices: list[dict]) -> list[dict]:
    rows = []
    for d in devices:
        c = classify(d)
        if not c:
            continue
        wf, focus, reason = c
        rows.append({**d, "waterfall": wf, "focus": focus, "reason": reason})
    order = {"now": 0, "possible": 1, "cannot": 2}
    rows.sort(key=lambda r: (order[r["waterfall"]], 0 if r["focus"] else 1, r["vendor"], r["model"]))
    return rows


def write_json(rows: list[dict], ver: str, generated: str) -> Path:
    REPORTS.mkdir(parents=True, exist_ok=True)
    payload = {
        "package_version": ver,
        "source": "SUPPORTED_DEVICES.md",
        "generated": generated,
        "definitions": {
            "now": "Current waterfall package can probe/capture spectral FFT on this hardware class",
            "possible": "Not reliable/complete yet; feasible with package and/or firmware updates",
            "cannot": "No viable spectral waterfall path on this platform",
        },
        "devices": rows,
    }
    path = REPORTS / "waterfall-hardware-support.json"
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return path


def write_html(rows: list[dict], ver: str, generated: str) -> Path:
    counts = Counter(r["waterfall"] for r in rows)
    label = {
        "now": "Supported now",
        "possible": "Possible with updates",
        "cannot": "Cannot support",
    }
    meaning = {
        "now": "Current waterfall package can probe/capture spectral FFT on this hardware class",
        "possible": "Not reliable/complete yet; feasible with package and/or firmware updates",
        "cannot": "No viable spectral waterfall path on this platform",
    }
    tone = {"now": "#81c995", "possible": "#fdd663", "cannot": "#f28b82"}

    def esc(s: object) -> str:
        return html_lib.escape(str(s or ""))

    summary_trs = []
    for key in ("now", "possible", "cannot"):
        summary_trs.append(
            "<tr>"
            f'<td><span style="color:{tone[key]};font-weight:600">{esc(label[key])}</span></td>'
            f"<td>{counts[key]}</td>"
            f"<td>{esc(meaning[key])}</td>"
            "</tr>"
        )

    # Full device list sorted by vendor then model for lookup
    detail_rows = sorted(rows, key=lambda r: (r["vendor"].lower(), r["model"].lower()))
    detail_trs = []
    for r in detail_rows:
        wf = r["waterfall"]
        focus = "Yes" if r["focus"] else ""
        detail_trs.append(
            "<tr>"
            f"<td>{esc(r['vendor'])}</td>"
            f"<td>{esc(r['model'])}</td>"
            f"<td>{esc(r['skus'])}</td>"
            f"<td>{esc(r['band'])}</td>"
            f"<td>{esc(r['target'])}</td>"
            f"<td>{esc(r['image'])}</td>"
            f"<td>{esc(r['status'])}</td>"
            f"<td>{focus}</td>"
            f'<td><span style="color:{tone[wf]};font-weight:600">{esc(label[wf])}</span></td>'
            f"<td>{esc(r['reason'])}</td>"
            "</tr>"
        )

    doc = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Waterfall hardware support — AREDN devices</title>
<style>
  :root {{
    --bg:#0f1115; --fg:#e8eaed; --muted:#9aa0a6; --card:#161a22; --border:#2a2f3a; --accent:#8ab4f8;
  }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; font:14px/1.45 system-ui,sans-serif; background:var(--bg); color:var(--fg); padding:24px; max-width:1400px; }}
  h1 {{ font-size:1.45rem; margin:0 0 6px; }}
  h2 {{ font-size:1.1rem; margin:28px 0 10px; border-bottom:1px solid var(--border); padding-bottom:6px; }}
  p, li {{ color:var(--muted); }}
  .meta {{ font-size:12px; color:var(--muted); margin-bottom:16px; }}
  .stats {{ display:flex; flex-wrap:wrap; gap:12px; margin:14px 0 20px; }}
  .stat {{ background:var(--card); border:1px solid var(--border); border-radius:8px; padding:12px 14px; min-width:140px; }}
  .stat b {{ display:block; font-size:1.4rem; color:var(--fg); }}
  .stat span {{ font-size:12px; color:var(--muted); }}
  table {{ width:100%; border-collapse:collapse; font-size:12.5px; margin:0 0 8px; }}
  th, td {{ border:1px solid var(--border); padding:6px 8px; text-align:left; vertical-align:top; }}
  th {{ background:var(--card); color:var(--fg); position:sticky; top:0; z-index:1; }}
  td {{ color:var(--muted); }}
  .count {{ font-weight:600; }}
  code {{ font-family:ui-monospace,Menlo,Consolas,monospace; font-size:0.9em; }}
  .note {{ border-left:3px solid var(--accent); background:var(--card); padding:8px 12px; border-radius:0 8px 8px 0; margin:12px 0; }}
  .scroll {{ max-height:70vh; overflow:auto; border:1px solid var(--border); border-radius:8px; }}
  .scroll table {{ margin:0; }}
</style>
</head>
<body>
  <h1>Waterfall hardware support</h1>
  <p class="meta">Package <code>{esc(ver)}</code> · Source <code>SUPPORTED_DEVICES.md</code> · Generated {esc(generated)} · Twin of canvas <code>waterfall-hardware-support</code></p>
  <div class="note">
    Classification is for the side-loaded <strong>waterfall</strong> APK spectral probe/capture path (ath9k / experimental ath10k).
    AREDN “officially supported” devices from <code>SUPPORTED_DEVICES.md</code> excluding status <em>not supported</em>.
    Focus devices: Rocket M5, PowerBeam M5 / 500 class, PowerBeam 5AC 500, hAP ac lite.
  </div>
  <div class="stats">
    <div class="stat"><b style="color:{tone['now']}">{counts['now']}</b><span>Supported now</span></div>
    <div class="stat"><b style="color:{tone['possible']}">{counts['possible']}</b><span>Possible with updates</span></div>
    <div class="stat"><b style="color:{tone['cannot']}">{counts['cannot']}</b><span>Cannot support</span></div>
    <div class="stat"><b>{len(rows)}</b><span>Devices listed</span></div>
  </div>

  <h2>Summary by category</h2>
  <table>
    <thead><tr><th>Category</th><th>Count</th><th>Meaning</th></tr></thead>
    <tbody>
    {''.join(summary_trs)}
    </tbody>
  </table>

  <h2>All hardware <span class="count">{len(detail_rows)}</span></h2>
  <p>Every official AREDN device with waterfall support status (sorted by vendor, then model).</p>
  <div class="scroll">
  <table>
    <thead><tr><th>Vendor</th><th>Model</th><th>SKUs</th><th>Band</th><th>Target</th><th>Image</th><th>AREDN status</th><th>Focus</th><th>Waterfall support</th><th>Notes</th></tr></thead>
    <tbody>
    {''.join(detail_trs)}
    </tbody>
  </table>
  </div>
</body>
</html>
"""
    path = REPORTS / "waterfall-hardware-support.html"
    path.write_text(doc, encoding="utf-8")
    return path


def short_vendor(v: str) -> str:
    return (
        v.replace("Mikrotik (7)", "Mikrotik")
        .replace("MorseMicro and partners", "MorseMicro")
        .replace("x86 / Virtual Machine", "x86/VM")
    )


def write_canvas(rows: list[dict], ver: str, generated: str) -> Path | None:
    counts = Counter(r["waterfall"] for r in rows)
    focus_n = sum(1 for r in rows if r["focus"])
    label = {
        "now": "Supported now",
        "possible": "Possible with updates",
        "cannot": "Cannot support",
    }
    meaning = {
        "now": "Current package can probe/capture spectral FFT on this hardware class",
        "possible": "Feasible with more package/firmware work",
        "cannot": "No viable spectral waterfall path",
    }
    tone_map = {"now": "success", "possible": "warning", "cannot": "danger"}

    summary_rows = [
        [label[k], str(counts[k]), meaning[k]] for k in ("now", "possible", "cannot")
    ]
    summary_tone = [tone_map[k] for k in ("now", "possible", "cannot")]

    detail_src = sorted(rows, key=lambda r: (r["vendor"].lower(), r["model"].lower()))
    detail_rows = []
    detail_tone = []
    for r in detail_src:
        detail_rows.append(
            [
                short_vendor(r["vendor"]),
                r["model"],
                r["skus"] or "",
                r["band"],
                r["target"],
                r["image"] or "",
                r["status"],
                "Yes" if r["focus"] else "",
                label[r["waterfall"]],
                r["reason"],
            ]
        )
        detail_tone.append(tone_map[r["waterfall"]])

    parts = [
        """import {
  Callout,
  Divider,
  H1,
  H2,
  Row,
  Stack,
  Stat,
  Table,
  Text,
} from "cursor/canvas";

""",
        f"const PACKAGE_VERSION = {json.dumps(ver)};\n",
        f"const GENERATED = {json.dumps(generated)};\n",
        'const SOURCE = "SUPPORTED_DEVICES.md";\n\n',
        f"""const COUNTS = {{
  now: {counts['now']},
  possible: {counts['possible']},
  cannot: {counts['cannot']},
  total: {len(rows)},
  focus: {focus_n},
}};

const SUMMARY_HEADERS = ["Category", "Count", "Meaning"];
const DETAIL_HEADERS = ["Vendor", "Model", "SKUs", "Band", "Target", "Image", "AREDN status", "Focus", "Waterfall support", "Notes"];

""",
        f"const SUMMARY_ROWS: string[][] = {json.dumps(summary_rows, ensure_ascii=False, indent=2)};\n",
        f"const SUMMARY_TONE = {json.dumps(summary_tone)} as const;\n",
        f"const DETAIL_ROWS: string[][] = {json.dumps(detail_rows, ensure_ascii=False, indent=2)};\n",
        f"const DETAIL_TONE = {json.dumps(detail_tone)} as const;\n\n",
        """export default function WaterfallHardwareSupport() {
  return (
    <Stack gap={20}>
      <Stack gap={6}>
        <H1>Waterfall hardware support</H1>
        <Text tone="secondary">
          Side-loaded waterfall APK {PACKAGE_VERSION} vs official AREDN devices from {SOURCE} (excluding “not supported”). Generated {GENERATED}.
        </Text>
      </Stack>

      <Callout tone="info" title="How to read this">
        Supported now = current package can probe/capture spectral FFT on this hardware class.
        Possible with updates = feasible with more package/firmware work.
        Cannot support = no viable spectral waterfall path.
        Focus devices: Rocket M5, PowerBeam M5 / 500, PowerBeam 5AC 500, hAP ac lite.
      </Callout>

      <Row gap={16} style={{ flexWrap: "wrap" }}>
        <Stat value={String(COUNTS.now)} label="Supported now" tone="success" />
        <Stat value={String(COUNTS.possible)} label="Possible with updates" tone="warning" />
        <Stat value={String(COUNTS.cannot)} label="Cannot support" tone="danger" />
        <Stat value={String(COUNTS.total)} label="Devices listed" />
        <Stat value={String(COUNTS.focus)} label="Focus devices" tone="info" />
      </Row>

      <Divider />

      <Stack gap={8}>
        <H2>Summary by category</H2>
        <Table
          headers={SUMMARY_HEADERS}
          rows={SUMMARY_ROWS}
          rowTone={[...SUMMARY_TONE]}
          striped
        />
      </Stack>

      <Stack gap={8}>
        <H2>All hardware ({COUNTS.total})</H2>
        <Text tone="secondary" size="small">
          Every official AREDN device with waterfall support status (sorted by vendor, then model).
        </Text>
        <Table
          headers={DETAIL_HEADERS}
          rows={DETAIL_ROWS}
          rowTone={[...DETAIL_TONE]}
          striped
          stickyHeader
          style={{ maxHeight: 560 }}
        />
      </Stack>

      <Text tone="tertiary" size="small">
        Keep in sync: reports/waterfall-hardware-support.html + .json · regenerate via contrib/waterfall/tools/gen-hardware-support-report.py when SUPPORTED_DEVICES.md or waterfall support logic changes.
      </Text>
    </Stack>
  );
}
""",
    ]
    body = "".join(parts)
    written = None
    for path in CANVAS_CANDIDATES:
        if path.parent.is_dir():
            path.write_text(body, encoding="utf-8")
            written = path
            break
    return written


def main() -> None:
    ver = package_version()
    generated = date.today().isoformat()
    devices = parse_devices(SUPPORTED.read_text(encoding="utf-8"))
    rows = build_rows(devices)
    j = write_json(rows, ver, generated)
    h = write_html(rows, ver, generated)
    c = write_canvas(rows, ver, generated)
    counts = Counter(r["waterfall"] for r in rows)
    print(f"package {ver}  devices {len(rows)}  now={counts['now']} possible={counts['possible']} cannot={counts['cannot']}")
    print(f"wrote {j}")
    print(f"wrote {h}")
    print(f"wrote {c}" if c else "canvas path not found (skipped)")


if __name__ == "__main__":
    main()
