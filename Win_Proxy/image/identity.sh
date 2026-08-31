#!/usr/bin/env bash
#=============================================================================
#  identity.sh — Windows device identity engine (deterministic per proxy)
#-----------------------------------------------------------------------------
#  Sinh ra "hồ sơ máy Windows" hoàn toàn giả lập nhưng KHỚP VỚI PROXY:
#    - MachineGuid, ComputerName, ProductName/Id/Build, InstallDate, Owner
#    - BIOS/OEM/BaseBoard (registry + WMI-ish)
#    - TimeZone (Windows bias + IANA TZ), Locale/LCID/Keyboard theo country
#    - MAC address (OUI thật của hãng NIC phổ biến)
#  Mọi thứ đều SUY RA TỪ (seed + geo) nên: 1 proxy = 1 danh tính ổn định,
#  đổi proxy = đổi danh tính (đúng luật "1 device / 1 IP" của các nền tảng).
#
#  KHÔNG gọi bất kỳ request nào QUA proxy để sinh identity -> không thể lộ IP VPS
#  hoặc làm "bẩn" proxy IP-auth. Geo lookup (nếu bật) chạy phía HOST, direct.
#
#  Cách dùng:
#    identity.sh gen <seed> <proxy_ip> [country] [city] [tz] -o <outdir>
#    identity.sh show <dir>                                  # in lại hồ sơ
#    identity.sh apply <dir> [wineprefix]                    # chạy TRONG container
#=============================================================================
set -uo pipefail

#------------------------------------------------------------ colors (auto-off)
if [[ -t 1 ]]; then C_=$'\033[1;36m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; R=$'\033[1;31m'; N=$'\033[0m'; else C_=''; G=''; Y=''; R=''; N=''; fi
say(){ printf '%s[*]%s %s\n' "$C_" "$N" "$*"; }
warn(){ printf '%s[!]%s %s\n' "$Y" "$N" "$*" >&2; }

#------------------------------------------------------------ utils
H(){ printf '%s' "$1" | sha256sum | awk '{print $1}'; }
# rnd <seed> <key> <mod>  -> 0..mod-1, deterministic
rnd(){ local s k m; s="$1"; k="$2"; m="$3"; printf '%d' $(( 16#$(H "${s}:${k}" | cut -c1-8) % m )); }
# hex <seed> <key> <bytes> -> lowercase hex string (2*bytes chars)
hexn(){ local s k n i out=""; s="$1"; k="$2"; n="$3";
  for ((i=0;i<n;i++)); do out+=$(H "${s}:${k}:${i}" | cut -c1-2); done; printf '%s' "$out"; }
uuid(){
  local p q r s t w vn
  p=$(hexn "$1" u0 4); q=$(hexn "$1" u1 2); r=$(hexn "$1" u2 2)
  s="4${r:1}"
  t=$(hexn "$1" u3 2); vn=$((8 + 16#${t:0:1} % 4)); vn=$(printf '%x' "$vn")
  w=$(hexn "$1" u4 6)
  printf '%s-%s-%s-%s%s-%s' "$p" "$q" "$s" "$vn" "${t:1}" "$w"
}

#------------------------------------------------------------ country DB (best-effort, có thể override)
# key: cc ; value: locale|lcid|language|sLanguage|sCountry|iCountry|tz
declare -A CTRY=(
 [US]="en-US|0409|English|ENU|United States|1|America/New_York"
 [GB]="en-GB|0809|English|ENG|United Kingdom|44|Europe/London"
 [DE]="de-DE|0407|German|DEU|Germany|49|Europe/Berlin"
 [FR]="fr-FR|040C|French|FRA|France|33|Europe/Paris"
 [IT]="it-IT|0410|Italian|ITA|Italy|39|Europe/Rome"
 [ES]="es-ES|0C0A|Spanish|ESP|Spain|34|Europe/Madrid"
 [NL]="nl-NL|0413|Dutch|NLD|Netherlands|31|Europe/Amsterdam"
 [BE]="nl-BE|0813|Dutch|NLB|Belgium|32|Europe/Brussels"
 [CH]="de-CH|0807|German|DES|Switzerland|41|Europe/Zurich"
 [AT]="de-AT|0C07|German|DEA|Austria|43|Europe/Vienna"
 [PL]="pl-PL|0415|Polish|PLK|Poland|48|Europe/Warsaw"
 [GR]="el-GR|0408|Greek|ELL|Greece|30|Europe/Athens"
 [RS]="sr-Latn-RS|241A|Serbian|SRL|Serbia|381|Europe/Belgrade"
 [PT]="pt-PT|0816|Portuguese|PTG|Portugal|351|Europe/Lisbon"
 [RO]="ro-RO|0418|Romanian|ROM|Romania|40|Europe/Bucharest"
 [TR]="tr-TR|041F|Turkish|TRK|Türkiye|90|Europe/Istanbul"
 [TW]="zh-TW|0404|Chinese|CHT|Taiwan|886|Asia/Taipei"
 [JP]="ja-JP|0411|Japanese|JPN|Japan|81|Asia/Tokyo"
 [SG]="en-SG|1004|English|ENI|Singapore|65|Asia/Singapore"
 [KR]="ko-KR|0412|Korean|KOR|Korea|82|Asia/Seoul"
 [HK]="zh-HK|0C04|Chinese|ZHH|Hong Kong S.A.R.|852|Asia/Hong_Kong"
 [AU]="en-AU|0C09|English|ENA|Australia|61|Australia/Sydney"
 [CA]="en-CA|1009|English|ENC|Canada|2|America/Toronto"
 [MX]="es-MX|080A|Spanish|ESM|Mexico|52|America/Mexico_City"
 [BR]="pt-BR|0416|Portuguese|PTB|Brazil|55|America/Sao_Paulo"
 [VN]="vi-VN|042A|Vietnamese|VIT|Vietnam|84|Asia/Ho_Chi_Minh"
 [TH]="th-TH|041E|Thai|THA|Thailand|66|Asia/Bangkok"
 [ID]="id-ID|0421|Indonesian|IND|Indonesia|62|Asia/Jakarta"
 [PH]="en-PH|3409|English|ENU|Philippines|63|Asia/Manila"
 [AR]="es-AR|2C0A|Spanish|ESS|Argentina|54|America/Argentina/Buenos_Aires"
 [FI]="fi-FI|040B|Finnish|FIN|Finland|358|Europe/Helsinki"
 [DK]="da-DK|0406|Danish|DAN|Denmark|45|Europe/Copenhagen"
 [SE]="sv-SE|041D|Swedish|SVE|Sweden|46|Europe/Stockholm"
 [LU]="fr-LU|140C|French|FRL|Luxembourg|352|Europe/Luxembourg"
 [IN]="en-IN|4009|English|ENU|India|91|Asia/Kolkata"
)

#------------------------------------------------------------ names per geo (dùng chung, khan hiếm thì fallback)
NAMES_FIRST="John Michael David James Robert Daniel William Richard Thomas Mark Steven Paul Andrew Kenneth George Brian Kevin Jason Jeff Eric Scott Larry Frank Steve Justin Brandon Ryan"
NAMES_LAST="Smith Johnson Williams Brown Jones Miller Davis Wilson Moore Taylor Anderson Thomas Jackson White Harris Martin Thompson Garcia Martinez Robinson Clark Lewis Lee Walker Hall Allen Young King Wright Scott"

#------------------------------------------------------------ OEM / BIOS pools
BIOS_VENDORS="Dell Inc.|American Megatrends Inc.|Insyde Corp.|Phoenix Technologies LTD|AMI"
# OEM khớp model thật (cặp)
OEM_MODELS=(
 "Dell Inc.|Inspiron 15 3511"
 "Dell Inc.|OptiPlex 3050"
 "HP|Pavilion 15"
 "HP|ProBook 450 G8"
 "LENOVO|ThinkPad T14 Gen 2"
 "LENOVO|IdeaPad 3 15"
 "ASUSTeK COMPUTER INC.|VivoBook 15"
 "ASUSTeK COMPUTER INC.|ROG Strix G15"
 "Acer|Aspire 5"
 "MSI|Katana GF66"
)
BOARDS="0K2RCD|0P8T5R|LNVNB161216|87C3|B1M51LA|0X6B07|Z8B14LA|PT315-52"

# CPU desktop thật (máy nhà dùng — tránh Xeon/QEMU lộ VPS). vendor|name|identifier|mhz
CPUS=(
 "GenuineIntel|Intel(R) Core(TM) i5-8400 CPU @ 2.80GHz|Intel64 Family 6 Model 158 Stepping 10|2808"
 "GenuineIntel|Intel(R) Core(TM) i7-8700 CPU @ 3.20GHz|Intel64 Family 6 Model 158 Stepping 10|3192"
 "GenuineIntel|Intel(R) Core(TM) i3-10100 CPU @ 3.60GHz|Intel64 Family 6 Model 165 Stepping 3|3600"
 "GenuineIntel|Intel(R) Core(TM) i5-10400 CPU @ 2.90GHz|Intel64 Family 6 Model 165 Stepping 3|2904"
 "AuthenticAMD|AMD Ryzen 5 3600 6-Core Processor|AuthenticAMD Family 23 Model 113 Stepping 0|3593"
 "AuthenticAMD|AMD Ryzen 7 3700X 8-Core Processor|AuthenticAMD Family 23 Model 113 Stepping 0|3593"
)

#------------------------------------------------------------ Windows SKU pool
# name|editionid|build|displayver|releaseid|ubr_min|ubr_max
SKUS=(
 "Windows 10 Pro|Professional|19045|22H2|2009|3000|5000"
 "Windows 11 Pro|Professional|22631|23H2|2009|2500|4500"
 "Windows 10 Home|Core|19045|22H2|2009|3000|5000"
 "Windows 10 Pro|Professional|19045|22H2|2009|3000|5000"
 "Windows 11 Pro|Professional|22631|23H2|2009|2500|4500"
 "Windows 11 Home|Core|22631|23H2|2009|2500|4500"
)

#------------------------------------------------------------ keyboard layout theo quốc gia (HKCU\Keyboard Layout\Preload)
declare -A KBD=(
 [US]=00000409 [GB]=00000809 [DE]=00000407 [FR]=0000040C [IT]=00000410 [ES]=0000040A
 [NL]=00000413 [BE]=00000813 [CH]=00000807 [AT]=00000C07 [PL]=00000415 [GR]=00000408
 [RS]=00000C1A [PT]=00000816 [RO]=00000418 [TR]=0000041F [TW]=00000404 [JP]=00000411
 [SG]=00000409 [KR]=00000412 [HK]=00000C04 [AU]=00000409 [CA]=00001009 [MX]=0000080A
 [BR]=00000416 [VN]=0000042A [TH]=0000041E [ID]=00000421 [PH]=00000409 [AR]=00002C0A
 [FI]=0000040B [DK]=00000406 [SE]=0000041D [LU]=0000040C [IN]=00004009
)

#------------------------------------------------------------ độ phân giải laptop thật (ưu tiên 1920x1080)
RESOLUTIONS=("1920x1080" "1366x768" "1920x1080" "1536x864" "2560x1440" "1920x1080" "1440x900" "1280x800")

#------------------------------------------------------------ timezone helpers
tz_offset_min(){ # <tz> <date> -> minutes east of UTC (+420)
  local z; z=$(TZ="$1" date -d "$2" +%z 2>/dev/null) || { echo 0; return; }
  local sign=${z:0:1} hh=$((10#${z:1:2})) mm=$((10#${z:3:2}))
  local v=$(( hh*60+mm )); [[ "$sign" == "-" ]] && v=$((-v)); echo "$v"
}
# Windows Bias = số phút CỘNG vào UTC để ra local? Không: local = UTC - Bias => Bias = -offset
win_bias_dword(){ # <minutes_east> -> 8-hex dword
  local b=$(( -$1 )); printf '%08x' $(( b & 0xffffffff ))
}
std_dst_names(){ # <tz> -> "STD|DST"
  case "$1" in
    America/New_York)        echo "Eastern Standard Time|Eastern Daylight Time";;
    America/Los_Angeles)     echo "Pacific Standard Time|Pacific Daylight Time";;
    America/Chicago)         echo "Central Standard Time|Central Daylight Time";;
    America/Toronto)         echo "Eastern Standard Time|Eastern Daylight Time";;
    America/Mexico_City)     echo "Central Standard Time (Mexico)|Central Daylight Time (Mexico)";;
    America/Sao_Paulo)       echo "E. South America Standard Time|E. South America Daylight Time";;
    America/Argentina/Buenos_Aires) echo "Argentina Standard Time|Argentina Daylight Time";;
    Europe/London)           echo "GMT Standard Time|GMT Daylight Time";;
    Europe/Berlin|Europe/Rome|Europe/Paris|Europe/Amsterdam|Europe/Brussels|Europe/Zurich|Europe/Vienna|Europe/Warsaw|Europe/Stockholm|Europe/Copenhagen|Europe/Luxembourg|Europe/Madrid|Europe/Lisbon|Europe/Belgrade|Europe/Bucharest|Europe/Athens)
                             echo "W. Europe Standard Time|W. Europe Daylight Time";;
    Europe/Helsinki)         echo "FLE Standard Time|FLE Daylight Time";;
    Europe/Istanbul)         echo "Türkiye Standard Time|Türkiye Daylight Time";;
    Asia/Taipei)             echo "Taipei Standard Time|Taipei Daylight Time";;
    Asia/Tokyo)              echo "Tokyo Standard Time|Tokyo Daylight Time";;
    Asia/Seoul)              echo "Korea Standard Time|Korea Daylight Time";;
    Asia/Singapore)          echo "Singapore Standard Time|Singapore Daylight Time";;
    Asia/Hong_Kong)          echo "China Standard Time|China Daylight Time";;
    Asia/Ho_Chi_Minh)        echo "SE Asia Standard Time|SE Asia Daylight Time";;
    Asia/Bangkok)            echo "SE Asia Standard Time|SE Asia Daylight Time";;
    Asia/Jakarta)            echo "SE Asia Standard Time|SE Asia Daylight Time";;
    Asia/Manila)             echo "Singapore Standard Time|Singapore Daylight Time";;
    Asia/Kolkata)            echo "India Standard Time|India Daylight Time";;
    Australia/Sydney)        echo "AUS Eastern Standard Time|AUS Eastern Daylight Time";;
    *)                       echo "$1|$1";;
  esac
}

#------------------------------------------------------------ geo resolve (HOST-side, direct, KHÔNG qua proxy)
resolve_geo(){ # <ip> -> "CC|country|city|tz"
  local ip="$1" cc="" country="" city="" tz="" line
  if command -v geoiplookup >/dev/null 2>&1; then
    line=$(geoiplookup "$ip" 2>/dev/null | head -1)
    cc=$(echo "$line" | grep -oE 'Country: [A-Z]{2}' | awk '{print $2}')
  fi
  if [[ -z "$cc" && "${ALLOW_GEO_LOOKUP:-true}" == "true" ]] && command -v curl >/dev/null 2>&1; then
    line=$(curl -4 -s --max-time 6 "http://ip-api.com/line/${ip}?fields=status,countryCode,country,city,timezone" 2>/dev/null)
    # status,CC,country,city,tz
    if [[ "$line" == success* ]]; then
      cc=$(echo "$line" | sed -n 2p); country=$(echo "$line" | sed -n 3p); city=$(echo "$line" | sed -n 4p); tz=$(echo "$line" | sed -n 5p)
    fi
  fi
  cc=${cc:-XX}; country=${country:-Unknown}; city=${city:-Unknown}; tz=${tz:-UTC}
  printf '%s|%s|%s|%s' "$cc" "$country" "$city" "$tz"
}

#------------------------------------------------------------ reg writer
REG_OUT=""
reg_hdr(){ REG_OUT=$'Windows Registry Editor Version 5.00\r\n'; }
reg_key(){ REG_OUT+=$'\r\n'"[$1]"$'\r\n'; }
reg_sz(){ # name value
  local v="${2//\\/\\\\}"; v="${v//\"/\\\"}"
  REG_OUT+="\"$1\"=\"$v\""$'\r\n'; }
reg_dw(){ REG_OUT+="\"$1\"=dword:${2,,}"$'\r\n'; }

#------------------------------------------------------------ generate
gen(){
  local seed="$1" ip="$2" cc="${3:-}" city="${4:-}" tz="${5:-}" outdir="${OUTDIR:-.}" country=""
  [[ -z "$seed" ]] && { warn "thiếu seed"; exit 1; }
  ip=${ip:-0.0.0.0}

  # --- geo
  if [[ -z "$cc" ]]; then
    IFS='|' read -r cc country city tz <<< "$(resolve_geo "$ip")"
  else
    country=${country:-${CTRY[$cc]}} ; [[ -z "$country" ]] && country="Unknown"
  fi
  cc=${cc^^}; country=${country//|/ }
  local row="${CTRY[$cc]:-}"
  if [[ -z "$row" ]]; then
    warn "country $cc không có trong DB -> dùng fallback en-US/UTC (khuyên ghi hint '#CC:City:TZ' trong proxies.txt)"
    row="en-US|0409|English|ENU|United States|1|UTC"; cc_fallback=1
  fi
  local locale lcid lang slang scountry icount deftz
  IFS='|' read -r locale lcid lang slang scountry icount deftz <<< "$row"
  tz=${tz:-$deftz}
  [[ "$city" == "Unknown" || -z "$city" ]] && city="${scountry}"

  # --- SKU
  local sku sku_row name edid build disp rel ubr_min ubr_max ubr
  sku=$(rnd "$seed" sku 100)
  (( sku<45 )) && sku_row="${SKUS[0]}"
  (( sku>=45 && sku<80 )) && sku_row="${SKUS[1]}"
  (( sku>=80 && sku<95 )) && sku_row="${SKUS[2]}"
  (( sku>=95 )) && sku_row="${SKUS[3]}"
  IFS='|' read -r name edid build disp rel ubr_min ubr_max <<< "$sku_row"
  ubr=$(( ubr_min + $(rnd "$seed" ubr $((ubr_max-ubr_min))) ))

  # --- machine guid, computer name, product id
  local mguid cname pid owner org
  mguid=$(uuid "$seed")
  cname="DESKTOP-$(H "$seed" | tr 'a-f' 'A-F' | tr -d '01OI' | cut -c1-7)"
  pid=$(printf '%05d-%05d-%05d-%05d' \
    $(( 10000 + $(rnd "$seed" p0 89999) )) $(( 10000 + $(rnd "$seed" p1 89999) )) \
    $(( 10000 + $(rnd "$seed" p2 89999) )) $(( 10000 + $(rnd "$seed" p3 89999) )))
  local fns=( $NAMES_FIRST ) lns=( $NAMES_LAST )
  owner="${fns[$(rnd "$seed" n0 ${#fns[@]})]} ${lns[$(rnd "$seed" n1 ${#lns[@]})]}"
  org="${lns[$(rnd "$seed" n2 ${#lns[@]})]} Family"

  # --- install date (epoch, trong 1-4 năm trước)
  local now inst
  now=$(date +%s); inst=$(( now - 86400 * (30 + $(rnd "$seed" days $((365*3))) ) ))

  # --- OEM / BIOS
  local bvs oem model bv boards bbprod
  IFS='|' read -r -a bvs <<< "$BIOS_VENDORS"
  IFS='|' read -r oem model <<< "${OEM_MODELS[$(rnd "$seed" o0 ${#OEM_MODELS[@]})]}"
  bv=${bvs[$(rnd "$seed" b0 ${#bvs[@]})]}
  IFS='|' read -r -a boards <<< "$BOARDS"
  bbprod=${boards[$(rnd "$seed" m0 ${#boards[@]})]}
  local biosv biosrel
  biosv="1.$(rnd "$seed" b1 30).$(rnd "$seed" b2 99)"
  biosrel=$(printf '20%02d/%02d/%02d' $((15+$(rnd "$seed" b3 10))) $((1+$(rnd "$seed" b4 12))) $((1+$(rnd "$seed" b5 28))))

  # --- CPU (desktop thật, tránh lộ Xeon/QEMU của VPS)
  local cpuv cpum cpid cpumhz buildlab buildguid
  IFS='|' read -r cpuv cpum cpid cpumhz <<< "${CPUS[$(rnd "$seed" c0 ${#CPUS[@]})]}"
  buildlab="${build}.1.amd64fre.vb_release.19h1_release.190318-1202"
  buildguid=$(uuid "${seed}-bg")

  # --- MAC (OUI thật + 3 octet theo seed)
  local ouis=( "3C:7C:3F" "B4:2E:99" "00:E0:4C" "A4:5E:60" "D8:BB:C1" "E8:6F:38" "00:1B:21" "F8:FF:C2" )
  local oui=${ouis[$(rnd "$seed" mac0 ${#ouis[@]})]}
  local mac=$(printf '%s:%s:%s:%s' "$oui" "$(hexn "$seed" mac1 1)" "$(hexn "$seed" mac2 1)" "$(hexn "$seed" mac3 1)")
  mac=$(echo "$mac" | tr '[:lower:]' '[:upper:]')

  # --- timezone (bias chuẩn + bias hiện tại theo DST)
  local bias_std bias_cur stdname dstname
  bias_std=$(tz_offset_min "$tz" '2026-01-15')
  bias_cur=$(tz_offset_min "$tz" 'now')
  IFS='|' read -r stdname dstname <<< "$(std_dst_names "$tz")"
  local bias_std_dw=$(win_bias_dword "$bias_std") bias_cur_dw=$(win_bias_dword "$bias_cur")

  # --- keyboard layout + màn hình (riêng từng "máy" như laptop thật)
  local kbd="${KBD[$cc]:-00000409}"
  local res="${RESOLUTIONS[$(rnd "$seed" r0 ${#RESOLUTIONS[@]})]}"

  # --- build .reg
  reg_hdr
  reg_key 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography'
  reg_sz 'MachineGuid' "$mguid"
  reg_key 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  reg_sz 'ProductName' "$name"; reg_sz 'EditionID' "$edid"; reg_sz 'InstallationType' 'Client'
  reg_sz 'ProductId' "$pid"; reg_sz 'CurrentBuild' "$build"; reg_sz 'CurrentBuildNumber' "$build"
  reg_sz 'DisplayVersion' "$disp"; reg_sz 'ReleaseId' "$rel"; reg_sz 'UBR' "$ubr"
  reg_sz 'BuildLabEx' "$buildlab"; reg_sz 'BuildBranch' 'vb_release'
  reg_sz 'RegisteredOwner' "$owner"; reg_sz 'RegisteredOrganization' "$org"
  reg_sz 'SystemRoot' 'C:\Windows'; reg_sz 'PathName' 'C:\Windows'
  reg_sz 'CSDVersion' ''; reg_sz 'CurrentType' 'Multiprocessor Free'
  reg_dw 'InstallDate' "$inst"
  reg_key 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
  reg_sz 'DefaultUserName' "$owner"
  reg_key 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName'
  reg_sz 'ComputerName' "$cname"
  reg_key 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName'
  reg_sz 'ComputerName' "$cname"
  reg_key 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
  reg_sz 'Hostname' "$cname"; reg_sz 'NV Hostname' "$cname"
  reg_key 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\TimeZoneInformation'
  reg_sz 'TimeZoneKeyName' "$stdname"; reg_sz 'StandardName' "$stdname"; reg_sz 'DaylightName' "$dstname"
  reg_dw 'Bias' "$bias_std_dw"; reg_dw 'ActiveTimeBias' "$bias_cur_dw"
  reg_key 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Nls\Language'
  reg_sz 'Default' "$lcid"; reg_sz 'InstallLanguage' "$lcid"
  reg_key 'HKEY_CURRENT_USER\Control Panel\International'
  reg_sz 'LocaleName' "$locale"; reg_sz 'sCountry' "$scountry"; reg_sz 'sLanguage' "$slang"
  reg_sz 'sLongDate' 'dddd, MMMM d, yyyy'; reg_sz 'sShortDate' 'M/d/yyyy'; reg_sz 'sTimeFormat' 'h:mm:ss tt'
  reg_sz 'iDate' '0'; reg_sz 'iTime' '0'; reg_sz 'iTLZero' '1'; reg_sz 'iLZero' '1'
  reg_sz 'iNegNumber' '1'; reg_sz 'iDigits' '2'; reg_sz 'iFirstDayOfWeek' '6'
  reg_dw 'iCountry' "$icount"; reg_dw 'iMeasure' 1
  reg_key 'HKEY_CURRENT_USER\Control Panel\International\Geo'
  reg_sz 'Nation' "$cc"
  reg_key 'HKEY_CURRENT_USER\Keyboard Layout\Preload'
  reg_sz '1' "$kbd"
  reg_key 'HKEY_CURRENT_USER\Control Panel\Desktop'
  reg_dw 'LogPixels' 96
  reg_key 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation'
  reg_sz 'Manufacturer' "$oem"; reg_sz 'Model' "$model"
  reg_key 'HKEY_LOCAL_MACHINE\HARDWARE\DESCRIPTION\System\BIOS'
  reg_sz 'BIOSVendor' "$bv"; reg_sz 'BIOSVersion' "$biosv"; reg_sz 'BIOSReleaseDate' "$biosrel"
  reg_sz 'SystemManufacturer' "$oem"; reg_sz 'SystemProductName' "$model"
  reg_sz 'BaseBoardManufacturer' "$oem"; reg_sz 'BaseBoardProduct' "$bbprod"
  reg_key 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\SystemInformation'
  reg_sz 'SystemManufacturer' "$oem"; reg_sz 'SystemProductName' "$model"
  reg_sz 'BIOSVersion' "$biosv"; reg_sz 'BIOSReleaseDate' "$biosrel"
  reg_key 'HKEY_LOCAL_MACHINE\HARDWARE\DESCRIPTION\System\CentralProcessor\0'
  reg_sz 'Identifier' "$cpid"; reg_sz 'ProcessorNameString' "$cpum"
  reg_sz 'VendorIdentifier' "$cpuv"
  reg_dw '~MHz' "$cpumhz"

  mkdir -p "$outdir"
  printf '%s' "$REG_OUT" > "$outdir/identity.reg"

  # --- env.sh cho orchestrator
  cat > "$outdir/env.sh" <<EOF
WIN_COMPUTER_NAME='$cname'
WIN_TZ='$tz'
WIN_MAC='$mac'
WIN_LOCALE='$locale'
WIN_COUNTRY='$cc'
WIN_SCREEN='${res}x24'
WIN_KBD='$kbd'
EOF

  # --- identity.json (để debug/show)
  cat > "$outdir/identity.json" <<EOF
{
  "seed": "$seed",
  "proxy_ip": "$ip",
  "country": "$cc",
  "city": "$city",
  "timezone": "$tz",
  "machine_guid": "$mguid",
  "computer_name": "$cname",
  "product_name": "$name",
  "edition": "$edid",
  "build": "$build",
  "display_version": "$disp",
  "product_id": "$pid",
  "registered_owner": "$owner",
  "oem": "$oem",
  "model": "$model",
  "bios_vendor": "$bv",
  "bios_version": "$biosv",
  "cpu_vendor": "$cpuv",
  "cpu_model": "$cpum",
  "cpu_mhz": $cpumhz,
  "mac": "$mac",
  "locale": "$locale",
  "lcid": "$lcid",
  "language": "$lang",
  "keyboard_layout": "$kbd",
  "screen": "${res}x24",
  "bias_minutes": $bias_std,
  "bias_active_minutes": $bias_cur
}
EOF
  say "Đã tạo identity: $cname | $cc/$city | $tz | $oem $model | $mguid"
}

show(){
  local d="$1"
  [[ -f "$d/identity.json" ]] || { warn "không thấy $d/identity.json"; exit 1; }
  cat "$d/identity.json"
}

# apply — chạy TRONG container (wine đã có sẵn)
apply(){
  local d="${1:-/identity}" wp="${2:-$WINEPREFIX}"
  export WINEPREFIX="${wp:-$HOME/.wine}" WINEARCH="${WINEARCH:-win64}"
  export WINEDEBUG=-all
  # bỏ Z: drive -> chặn app đọc filesystem host (chống lộ VPS)
  rm -f "$WINEPREFIX/dosdevices/z:" 2>/dev/null || true
  wineboot -u >/dev/null 2>&1 || true
  wine regedit /S "$d/identity.reg" 2>/dev/null || warn "import registry thất bại (đã có thể chạy)"
  # tắt dialog crash (giữ container sống)
  wine reg add 'HKCU\Software\Wine\WineDbg' /v ShowCrashDialog /t REG_DWORD /d 0 /f >/dev/null 2>&1 || true
  say "Đã áp identity vào prefix $WINEPREFIX"
}

usage(){ cat <<EOF
Cách dùng:
  identity.sh gen <seed> <proxy_ip> [cc] [city] [tz]  -o <outdir>   # host
  identity.sh show <dir>                                            # in hồ sơ
  identity.sh apply <dir> [wineprefix]                              # trong container
Env: ALLOW_GEO_LOOKUP=true|false (mặc định true, chạy host direct)
EOF
}

main(){
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    gen)
      local outdir="${OUTDIR:-.}" args=()
      while [[ $# -gt 0 ]]; do
        case "$1" in
          -o) outdir="$2"; shift 2 ;;
          *)  args+=("$1"); shift ;;
        esac
      done
      OUTDIR="$outdir" gen "${args[@]}" ;;
    show)   show "$@" ;;
    apply)  apply "$@" ;;
    *)      usage ;;
  esac
}
main "$@"
