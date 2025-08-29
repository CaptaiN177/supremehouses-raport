# plik: deploy_netlify.sh
#!/usr/bin/env bash
# Generuje XML + MD5 (2 warianty), archiwizuje i deployuje na Netlify (Linux/macOS)
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXCEL_FILE="${1:-$PROJECT_DIR/DaneSH.xlsx}"
OUT_DIR="$PROJECT_DIR/netlify_site"
OUT_XML="$OUT_DIR/raport_ofert_dewelopera.xml"
ARCHIVE_DIR="$OUT_DIR/archiwum"

mkdir -p "$OUT_DIR" "$ARCHIVE_DIR"

echo "ℹ️  Używam pliku Excela: $EXCEL_FILE"
export OUT_XML EXCEL_FILE

# ========= PYTHON: generacja XML z walidacją i mapowaniem kolumn =========
python3 - <<'PYCODE'
import pandas as pd, os, sys, datetime as dt

infile = os.environ['EXCEL_FILE']
df = pd.read_excel(infile)

# MAPOWANIE nagłówków Excela -> pola XML (dopasowane do Twojego pliku)
COL = {
    "id": "Nr lokalu lub domu jednorodzinnego nadany przez dewelopera",
    "cena_brutto_prefer": "Cena lokalu mieszkalnego lub domu jednorodzinnego uwzględniająca cenę lokalu stanowiącą iloczyn powierzchni oraz metrażu i innych składowych ceny, o których mowa w art. 19a ust. 1 pkt 1), 2) lub 3) [zł]",
    "cena_brutto_fallback": "Cena lokalu mieszkalnego lub domu jednorodzinnego będących przedmiotem umowy stanowiąca iloczyn ceny m2 oraz powierzchni [zł]",
    "cena_m2": "Cena m 2 powierzchni użytkowej lokalu mieszkalnego / domu jednorodzinnego [zł]",
    "typ": "Rodzaj nieruchomości: lokal mieszkalny, dom jednorodzinny ",
    "woj": "Województwo lokalizacji przedsięwzięcia deweloperskiego lub zadania inwestycyjnego",
    "powiat": "Powiat lokalizacji przedsięwzięcia deweloperskiego lub zadania inwestycyjnego",
    "gmina": "Gmina lokalizacji przedsięwzięcia deweloperskiego lub zadania inwestycyjnego",
    "miejsc": "Miejscowość lokalizacji przedsięwzięcia deweloperskiego lub zadania inwestycyjnego",
    "ulica": "Ulica lokalizacji przedsięwzięcia deweloperskiego lub zadania inwestycyjnego",
    "nr": "Nr nieruchomości lokalizacji przedsięwzięcia deweloperskiego lub zadania inwestycyjnego",
    "kod": "Kod pocztowy lokalizacji przedsięwzięcia deweloperskiego lub zadania inwestycyjnego",
    "data_cena_m2": "Data od której cena obowiązuje cena m 2 powierzchni użytkowej lokalu mieszkalnego / domu jednorodzinnego",
    "data_cena_full": "Data od której obowiązuje cena lokalu mieszkalnego lub domu jednorodzinnego uwzględniająca cenę lokalu stanowiącą iloczyn powierzchni oraz metrażu i innych składowych ceny, o których mowa w art. 19a ust. 1 pkt 1), 2) lub 3)",
}

missing_cols = [v for v in [COL["id"], COL["typ"], COL["cena_m2"]] if v not in df.columns]
if missing_cols:
    sys.exit(f"❌ Brakuje kolumn w Excelu: {missing_cols}")

def get(r, key):
    col = COL[key]
    if col not in df.columns: return ""
    val = r.get(col, "")
    if pd.isna(val): return ""
    return str(val).strip()

def cena_brutto(r):
    for key in ("cena_brutto_prefer", "cena_brutto_fallback"):
        c = COL[key]
        if c in df.columns:
            v = r.get(c, "")
            if pd.notna(v) and str(v).strip():
                return str(v).strip()
    return ""

def join_addr(r):
    parts = []
    for k in ("ulica","nr","kod","miejsc","gmina","powiat","woj"):
        v = get(r, k)
        if v: parts.append(v)
    return " ".join(parts)

rows, errors = [], []
today = dt.date.today().isoformat()

for idx, r in df.iterrows():
    _id = get(r, "id")
    _typ = get(r, "typ") or "Dom jednorodzinny"
    _addr = join_addr(r)
    _cbr = cena_brutto(r)
    _cm2 = get(r, "cena_m2")
    _d1 = get(r, "data_cena_full")
    _d2 = get(r, "data_cena_m2")
    _data = (_d1 or _d2 or today)

    if not _id or (not _addr and not _typ):
        errors.append(f"Wiersz {idx+2}: brak ID lub adresu/typu (ID='{_id}', adres='{_addr}', typ='{_typ}')"); continue
    if not (_cbr or _cm2):
        errors.append(f"Wiersz {idx+2}: brak ceny (ani cena_brutto, ani cena_m2) dla ID='{_id}'"); continue

    rows.append({
        "id": _id, "adres": _addr, "cenaBrutto": _cbr, "cenaZaM2": _cm2,
        "status": "dostępny", "dataAktualizacji": _data,
        "liczbaPokoi": "", "typ": _typ,
        "powierzchnia_domu": "", "powierzchnia_dzialki": "", "informacjeDodatkowe": ""
    })

if errors and len(errors)==len(df.index):
    sys.exit("❌ Żaden wiersz nie przeszedł walidacji:\n- " + "\n- ".join(errors))
elif errors:
    sys.stderr.write("⚠️  Ostrzeżenia (pominięte wiersze):\n- " + "\n- ".join(errors) + "\n")

xml = ["<?xml version='1.0' encoding='UTF-8'?>", "<oferty>"]
for r in rows:
    xml.append("  <lokal>")
    xml.append(f"    <id>{r['id']}</id>")
    xml.append(f"    <adres>{r['adres']}</adres>")
    xml.append(f"    <powierzchnia_domu>{r['powierzchnia_domu']}</powierzchnia_domu>")
    xml.append(f"    <powierzchnia_dzialki>{r['powierzchnia_dzialki']}</powierzchnia_dzialki>")
    xml.append(f"    <cenaBrutto>{r['cenaBrutto']}</cenaBrutto>")
    xml.append(f"    <cenaZaM2>{r['cenaZaM2']}</cenaZaM2>")
    xml.append(f"    <status>{r['status']}</status>")
    xml.append(f"    <dataAktualizacji>{r['dataAktualizacji']}</dataAktualizacji>")
    xml.append(f"    <liczbaPokoi>{r['liczbaPokoi']}</liczbaPokoi>")
    xml.append(f"    <typ>{r['typ']}</typ>")
    xml.append(f"    <informacjeDodatkowe>{r['informacjeDodatkowe']}</informacjeDodatkowe>")
    xml.append("  </lokal>")
xml.append("</oferty>")

with open(os.environ['OUT_XML'], "w", encoding="utf-8") as f:
    f.write("\n".join(xml))

print(f"✅ Rekordów wygenerowanych: {len(rows)} / {len(df.index)}")
PYCODE
# ========= KONIEC BLOKU PYTHON =========

[[ -s "$OUT_XML" ]] || { echo "❌ Błąd generowania XML"; exit 1; }
echo "✅ Zapisano: $OUT_XML"

# MD5 (krzyżowo Linux/macOS)
MD5_FILE="$OUT_XML.md5"
if command -v md5 >/dev/null 2>&1; then
  md5 -q "$OUT_XML" > "$MD5_FILE"
elif command -v md5sum >/dev/null 2>&1; then
  md5sum "$OUT_XML" | awk '{print $1}' > "$MD5_FILE"
else
  python3 - <<'PYMD5' > "$MD5_FILE"
import hashlib, sys
with open(sys.argv[1], 'rb') as f:
    print(hashlib.md5(f.read()).hexdigest())
PYMD5
fi

cp "$MD5_FILE" "$OUT_DIR/raport_ofert_dewelopera.md5"
echo "✅ MD5: $(cat "$MD5_FILE")"

# Archiwum + lista
DATE=$(date +%F)
cp "$OUT_XML" "$ARCHIVE_DIR/raport_${DATE}.xml"
ls -1t "$ARCHIVE_DIR"/raport_*.xml | sed 's#.*/##' > "$ARCHIVE_DIR/index.html"
echo "Archiwum: $ARCHIVE_DIR/raport_${DATE}.xml"
echo "Wygenerowano listę archiwum: $ARCHIVE_DIR/index.html"

# Netlify: trim + deploy z retry
NETLIFY_AUTH_TOKEN="${NETLIFY_AUTH_TOKEN:-}"; NETLIFY_SITE_ID="${NETLIFY_SITE_ID:-}"
NETLIFY_AUTH_TOKEN="$(printf '%s' "$NETLIFY_AUTH_TOKEN" | tr -d '\r' | xargs || true)"
NETLIFY_SITE_ID="$(printf '%s' "$NETLIFY_SITE_ID" | tr -d '\r' | xargs || true)"
export NETLIFY_AUTH_TOKEN NETLIFY_SITE_ID

NETLIFY_ARGS=(--dir="$OUT_DIR" --prod)
[[ -n "$NETLIFY_AUTH_TOKEN" ]] && NETLIFY_ARGS+=(--auth "$NETLIFY_AUTH_TOKEN")
[[ -n "$NETLIFY_SITE_ID"    ]] && NETLIFY_ARGS+=(--site "$NETLIFY_SITE_ID")

DEPLOY_OK=0
for attempt in 1 2 3; do
  if netlify deploy "${NETLIFY_ARGS[@]}"; then DEPLOY_OK=1; break; fi
  echo "WARN: netlify deploy attempt $attempt failed; retrying..."
  sleep $((attempt*15))
done
[[ $DEPLOY_OK -eq 1 ]] || { echo "ERROR: netlify deploy failed after retries"; exit 9; }

echo "🚀 Deploy complete"
