#Requires -Version 5.1
<#
.SYNOPSIS
    Yerel Sistem Sağlık Kontrolü ve Otomatik Temizlik Aracı (System Health Check & Auto-Cleaner)

.DESCRIPTION
    Bu betik, Windows sistemlerinde disk ve bellek durumunu analiz eder, Temp ve Prefetch
    klasörlerindeki gereksiz dosyaları güvenli bir şekilde temizler ve işlem sonucunu
    koyu temalı bir HTML raporu olarak masaüstüne kaydedip otomatik olarak açar.

    Script iki aşamalı çalışır: önce mevcut sistem durumu ölçülür (temizlik öncesi),
    ardından temizlik işlemi yapılır ve son durum tekrar ölçülür (temizlik sonrası).
    Bu sayede rapor, temizliğin gerçek etkisini sayısal olarak gösterebilir.

.PARAMETER MinimumFileAgeDays
    Temizlenecek dosyanın en az kaç gündür değiştirilmemiş olması gerektiğini belirler.
    Varsayılan değer 1'dir; böylece o an aktif kullanılan geçici dosyalara dokunulmaz.

.PARAMETER NoAutoOpen
    Belirtilirse, rapor oluşturulduktan sonra tarayıcıda otomatik açılmaz.

.EXAMPLE
    .\SystemHealthCheck.ps1
    Varsayılan ayarlarla çalıştırır, raporu oluşturup otomatik açar.

.EXAMPLE
    .\SystemHealthCheck.ps1 -MinimumFileAgeDays 3 -NoAutoOpen
    Sadece 3 günden eski dosyaları hedefler ve raporu otomatik açmaz.

.NOTES
    Versiyon : 1.0
    Not      : Prefetch klasörü temizliği için betiğin Yönetici (Administrator) olarak
               çalıştırılması gerekir. Yönetici izni yoksa bu adım otomatik olarak atlanır
               ve durum rapora "Atlandı" olarak yansıtılır.
#>

[CmdletBinding()]
param(
    [int]$MinimumFileAgeDays = 1,
    [switch]$NoAutoOpen
)

# ============================================================
# BÖLÜM 0 - ORTAM HAZIRLIĞI
# ============================================================

# Konsol çıktısında Türkçe karakterlerin (ş, ğ, ı, ö, ü, ç) düzgün görünmesi için
# çıktı kodlamasını UTF-8 olarak ayarlıyoruz. Bu satır olmadan Write-Host çıktıları
# bazı terminallerde bozuk karakter olarak görünebiliyor.
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Script'in Yönetici yetkisiyle çalışıp çalışmadığını kontrol ediyoruz.
# Prefetch klasörü Windows tarafından korunan bir sistem klasörü olduğundan,
# oraya dokunabilmek için bu bilgiye ihtiyacımız var.
$currentIdentity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host "`n=== Sistem Sağlık Kontrolü ve Otomatik Temizlik Aracı ===" -ForegroundColor Cyan
if (-not $isAdmin) {
    Write-Host "[Uyarı] Betik Yönetici olarak çalıştırılmadı. Prefetch temizliği atlanacak." -ForegroundColor Yellow
}

# ============================================================
# BÖLÜM 1 - DİSK DURUMU KONTROLÜ
# ============================================================

function Get-DiskStatus {
    <#
        C: sürücüsünün toplam, boş ve kullanılan alanını GB cinsinden hesaplar.
        Win32_LogicalDisk sınıfını doğrudan sorgulamak yerine Get-CimInstance kullanıyoruz;
        CIM, eski WMI çağrılarına göre daha hızlı çalışıyor ve güncel PowerShell sürümleriyle
        daha uyumlu.
    #>
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"

    $totalGB     = [math]::Round($disk.Size / 1GB, 2)
    $freeGB      = [math]::Round($disk.FreeSpace / 1GB, 2)
    $usedGB      = [math]::Round($totalGB - $freeGB, 2)
    $percentFree = [math]::Round(($freeGB / $totalGB) * 100, 1)

    return [PSCustomObject]@{
        TotalGB     = $totalGB
        FreeGB      = $freeGB
        UsedGB      = $usedGB
        PercentFree = $percentFree
    }
}

# ============================================================
# BÖLÜM 2 - RAM (BELLEK) DURUMU KONTROLÜ
# ============================================================

function Get-MemoryStatus {
    <#
        Toplam ve boş fiziksel belleği hesaplar. Win32_OperatingSystem sınıfı bu bilgiyi
        KB cinsinden döndürüyor, bu yüzden 1MB'a (1024 KB) bölerek GB'a çeviriyoruz.
    #>
    $os = Get-CimInstance Win32_OperatingSystem

    $totalGB     = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
    $freeGB      = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
    $usedGB      = [math]::Round($totalGB - $freeGB, 2)
    $percentFree = [math]::Round(($freeGB / $totalGB) * 100, 1)

    return [PSCustomObject]@{
        TotalGB     = $totalGB
        FreeGB      = $freeGB
        UsedGB      = $usedGB
        PercentFree = $percentFree
    }
}

# ============================================================
# BÖLÜM 3 - GÜVENLİ DOSYA TEMİZLİĞİ
# ============================================================

function Remove-JunkFiles {
    <#
        Belirtilen klasördeki dosyaları güvenli bir şekilde silmeye çalışır.

        "Güvenli" derken kastımız şu: o an başka bir process tarafından kullanılan
        (kilitli) bir dosyayla karşılaşınca script çökmesin, sadece o dosyayı atlayıp
        devam etsin. Bu yüzden her silme işlemini kendi try/catch bloğuna alıyoruz ve
        hataları tek tek ekrana basmak yerine sayaç olarak topluyoruz.

        MinimumAgeDays parametresiyle sadece belirli bir süredir değiştirilmemiş
        dosyaları hedefliyoruz; böylece hâlâ yazılmakta olan bir günlük (log) dosyasını
        ya da bir uygulamanın o an kullandığı geçici dosyayı yanlışlıkla silmiyoruz.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [int]$MinimumAgeDays = 1
    )

    $result = [PSCustomObject]@{
        DeletedCount  = 0
        DeletedSizeMB = 0.0
        SkippedCount  = 0
    }

    if (-not (Test-Path $Path)) {
        return $result
    }

    $cutoffDate = (Get-Date).AddDays(-$MinimumAgeDays)
    $totalBytes = 0

    # -Force ile gizli/sistem dosyalarını da kapsama alıyoruz, -ErrorAction ile de
    # erişim izni olmayan alt klasörlerde hata almadan taramaya devam ediyoruz.
    $items = Get-ChildItem -Path $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
             Where-Object { $_.LastWriteTime -lt $cutoffDate }

    foreach ($item in $items) {
        try {
            $sizeBytes = $item.Length
            Remove-Item -Path $item.FullName -Force -ErrorAction Stop
            $totalBytes += $sizeBytes
            $result.DeletedCount++
        }
        catch {
            # Dosya kilitli, izin yetersiz ya da bir process tarafından kullanılıyor
            # olabilir. Script'in akışını bozmadan devam etmek için sadece sayıyoruz.
            $result.SkippedCount++
        }
    }

    # Dosyalar silindikten sonra geride kalan boş alt klasörleri de temizleyelim.
    # En derindeki klasörden başlayarak yukarı doğru çıkıyoruz ki üst klasör de
    # boşaldıysa o da silinebilsin.
    Get-ChildItem -Path $Path -Recurse -Force -Directory -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending |
        ForEach-Object {
            if (-not (Get-ChildItem -Path $_.FullName -Force -ErrorAction SilentlyContinue)) {
                Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }

    $result.DeletedSizeMB = [math]::Round($totalBytes / 1MB, 2)
    return $result
}

# ============================================================
# BÖLÜM 4 - HTML RAPORU OLUŞTURMA
# ============================================================

function New-HealthReportHtml {
    <#
        Toplanan tüm verileri (temizlik öncesi/sonrası disk ve RAM durumu, silinen
        dosya istatistikleri) alıp koyu temalı, tek dosyalık bir HTML raporu üretir.

        Tüm CSS kodu dosyanın içine gömülü; harici bir stylesheet'e bağımlı değil.
        Bu sayede rapor tek başına taşınabilir, e-posta ile gönderilebilir ya da
        herhangi bir tarayıcıda internet bağlantısı olmadan açılabilir.
    #>
    param(
        [Parameter(Mandatory)] $DiskBefore,
        [Parameter(Mandatory)] $DiskAfter,
        [Parameter(Mandatory)] $MemBefore,
        [Parameter(Mandatory)] $MemAfter,
        [Parameter(Mandatory)] $TempResult,
        [Parameter(Mandatory)] $PrefetchResult,
        [Parameter(Mandatory)] [bool]$PrefetchRan
    )

    $reportDate        = Get-Date -Format "dd.MM.yyyy HH:mm"
    $totalDeletedFiles = $TempResult.DeletedCount + $PrefetchResult.DeletedCount
    $totalDeletedMB    = [math]::Round($TempResult.DeletedSizeMB + $PrefetchResult.DeletedSizeMB, 2)
    $spaceFreedGB      = [math]::Round($DiskAfter.FreeGB - $DiskBefore.FreeGB, 2)

    $prefetchNote = if ($PrefetchRan) {
        "<span class='badge ok'>Çalıştırıldı</span>"
    } else {
        "<span class='badge skip'>Atlandı (Yönetici izni gerekli)</span>"
    }

    # Disk ve RAM kullanım yüzdesine göre renk belirliyoruz: kritik seviyede
    # (%90 ve üzeri kullanım) kırmızı, orta seviyede sarı, normal durumda yeşil.
    $diskUsedPercent = [math]::Round(100 - $DiskAfter.PercentFree, 1)
    $diskBarColor = if ($diskUsedPercent -ge 90) { "#e05252" } elseif ($diskUsedPercent -ge 75) { "#e0a852" } else { "#4fd188" }

    $memUsedPercent = [math]::Round(100 - $MemAfter.PercentFree, 1)
    $memBarColor = if ($memUsedPercent -ge 90) { "#e05252" } elseif ($memUsedPercent -ge 75) { "#e0a852" } else { "#4fd188" }

    $diskBeforeUsedPercent = [math]::Round(100 - $DiskBefore.PercentFree, 1)
    $memBeforeUsedPercent  = [math]::Round(100 - $MemBefore.PercentFree, 1)

    $html = @"
<!DOCTYPE html>
<html lang="tr">
<head>
<meta charset="UTF-8">
<title>Sistem Sağlık Raporu - $reportDate</title>
<style>
    :root {
        --bg: #0d0d10;
        --card: #16161a;
        --border: #26262c;
        --text: #e8e8ea;
        --muted: #8a8a92;
        --accent: #6ea8fe;
    }
    * { box-sizing: border-box; }
    body {
        background: var(--bg);
        color: var(--text);
        font-family: 'Segoe UI', system-ui, -apple-system, sans-serif;
        margin: 0;
        padding: 40px 20px;
        line-height: 1.5;
    }
    .container { max-width: 860px; margin: 0 auto; }
    header { margin-bottom: 36px; }
    header h1 { font-size: 22px; font-weight: 600; margin: 0 0 4px 0; }
    header p { color: var(--muted); font-size: 13px; margin: 0; }
    .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-bottom: 16px; }
    .card {
        background: var(--card);
        border: 1px solid var(--border);
        border-radius: 10px;
        padding: 20px;
    }
    .card h2 {
        font-size: 12px;
        text-transform: uppercase;
        letter-spacing: 0.06em;
        color: var(--muted);
        margin: 0 0 14px 0;
        font-weight: 600;
    }
    .stat-row { display: flex; justify-content: space-between; font-size: 14px; margin-bottom: 8px; }
    .stat-row span:last-child { font-weight: 600; }
    .bar-track { background: #26262c; border-radius: 6px; height: 8px; overflow: hidden; margin-top: 10px; }
    .bar-fill { height: 100%; border-radius: 6px; }
    .summary-card {
        background: linear-gradient(135deg, #17181d, #131318);
        border: 1px solid var(--border);
        border-radius: 10px;
        padding: 24px;
        margin-bottom: 16px;
        text-align: center;
    }
    .summary-card .big-number { font-size: 34px; font-weight: 700; color: var(--accent); }
    .summary-card .label { color: var(--muted); font-size: 13px; margin-top: 4px; }
    table { width: 100%; border-collapse: collapse; font-size: 13px; }
    th, td { text-align: left; padding: 10px 8px; border-bottom: 1px solid var(--border); }
    th { color: var(--muted); font-weight: 500; }
    .badge { padding: 2px 9px; border-radius: 20px; font-size: 11px; font-weight: 600; }
    .badge.ok { background: rgba(79,209,136,0.15); color: #4fd188; }
    .badge.skip { background: rgba(224,168,82,0.15); color: #e0a852; }
    footer { text-align: center; color: var(--muted); font-size: 12px; margin-top: 32px; }
</style>
</head>
<body>
<div class="container">
    <header>
        <h1>Sistem Sağlık Raporu</h1>
        <p>Oluşturulma tarihi: $reportDate</p>
    </header>

    <div class="summary-card">
        <div class="big-number">$totalDeletedMB MB</div>
        <div class="label">$totalDeletedFiles dosya temizlendi &middot; disk üzerinde $spaceFreedGB GB alan açıldı</div>
    </div>

    <div class="grid">
        <div class="card">
            <h2>Disk (C:) - Temizlik Öncesi</h2>
            <div class="stat-row"><span>Toplam</span><span>$($DiskBefore.TotalGB) GB</span></div>
            <div class="stat-row"><span>Boş Alan</span><span>$($DiskBefore.FreeGB) GB</span></div>
            <div class="stat-row"><span>Kullanım</span><span>%$diskBeforeUsedPercent</span></div>
        </div>
        <div class="card">
            <h2>Disk (C:) - Temizlik Sonrası</h2>
            <div class="stat-row"><span>Toplam</span><span>$($DiskAfter.TotalGB) GB</span></div>
            <div class="stat-row"><span>Boş Alan</span><span>$($DiskAfter.FreeGB) GB</span></div>
            <div class="stat-row"><span>Kullanım</span><span>%$diskUsedPercent</span></div>
            <div class="bar-track"><div class="bar-fill" style="width:$diskUsedPercent%; background:$diskBarColor;"></div></div>
        </div>
    </div>

    <div class="grid">
        <div class="card">
            <h2>Bellek (RAM) - Temizlik Öncesi</h2>
            <div class="stat-row"><span>Toplam</span><span>$($MemBefore.TotalGB) GB</span></div>
            <div class="stat-row"><span>Boş</span><span>$($MemBefore.FreeGB) GB</span></div>
            <div class="stat-row"><span>Kullanım</span><span>%$memBeforeUsedPercent</span></div>
        </div>
        <div class="card">
            <h2>Bellek (RAM) - Anlık Durum</h2>
            <div class="stat-row"><span>Toplam</span><span>$($MemAfter.TotalGB) GB</span></div>
            <div class="stat-row"><span>Boş</span><span>$($MemAfter.FreeGB) GB</span></div>
            <div class="stat-row"><span>Kullanım</span><span>%$memUsedPercent</span></div>
            <div class="bar-track"><div class="bar-fill" style="width:$memUsedPercent%; background:$memBarColor;"></div></div>
        </div>
    </div>

    <div class="card">
        <h2>Temizlik Detayları</h2>
        <table>
            <tr><th>Konum</th><th>Silinen Dosya</th><th>Boyut</th><th>Atlanan</th><th>Durum</th></tr>
            <tr>
                <td>Temp Klasörleri</td>
                <td>$($TempResult.DeletedCount)</td>
                <td>$($TempResult.DeletedSizeMB) MB</td>
                <td>$($TempResult.SkippedCount)</td>
                <td><span class="badge ok">Çalıştırıldı</span></td>
            </tr>
            <tr>
                <td>Prefetch Klasörü</td>
                <td>$($PrefetchResult.DeletedCount)</td>
                <td>$($PrefetchResult.DeletedSizeMB) MB</td>
                <td>$($PrefetchResult.SkippedCount)</td>
                <td>$prefetchNote</td>
            </tr>
        </table>
    </div>

    <footer>Local System Health Check &amp; Auto-Cleaner &middot; PowerShell</footer>
</div>
</body>
</html>
"@

    return $html
}

# ============================================================
# BÖLÜM 5 - ANA AKIŞ (MAIN)
# ============================================================

Write-Host "`n[1/5] Temizlik öncesi disk ve bellek durumu ölçülüyor..." -ForegroundColor Cyan
$diskBefore = Get-DiskStatus
$memBefore  = Get-MemoryStatus
Write-Host "      Disk boş alan : $($diskBefore.FreeGB) GB / $($diskBefore.TotalGB) GB"
Write-Host "      Boş RAM       : $($memBefore.FreeGB) GB / $($memBefore.TotalGB) GB"

Write-Host "`n[2/5] Temp klasörleri temizleniyor..." -ForegroundColor Cyan
# Kullanıcıya özel Temp klasörünün yanı sıra sistem geneli Temp klasörünü de
# hedef alıyoruz; ikisi de zamanla önemli miktarda geçici dosya biriktirir.
$tempPaths = @($env:TEMP, "$env:WINDIR\Temp")
$tempResult = [PSCustomObject]@{ DeletedCount = 0; DeletedSizeMB = 0.0; SkippedCount = 0 }

foreach ($path in $tempPaths) {
    $r = Remove-JunkFiles -Path $path -MinimumAgeDays $MinimumFileAgeDays
    $tempResult.DeletedCount  += $r.DeletedCount
    $tempResult.DeletedSizeMB += $r.DeletedSizeMB
    $tempResult.SkippedCount  += $r.SkippedCount
}
Write-Host "      $($tempResult.DeletedCount) dosya silindi ($($tempResult.DeletedSizeMB) MB), $($tempResult.SkippedCount) dosya atlandı."

Write-Host "`n[3/5] Prefetch klasörü kontrol ediliyor..." -ForegroundColor Cyan
$prefetchResult = [PSCustomObject]@{ DeletedCount = 0; DeletedSizeMB = 0.0; SkippedCount = 0 }
$prefetchRan = $false

if ($isAdmin) {
    # Prefetch dosyaları, Windows'un uygulama açılışını hızlandırmak için tuttuğu
    # önbellek kayıtlarıdır. Silinmeleri sistemi bozmaz; Windows bu dosyaları
    # ihtiyaç duyduğunda otomatik olarak yeniden oluşturur.
    $prefetchResult = Remove-JunkFiles -Path "$env:WINDIR\Prefetch" -MinimumAgeDays $MinimumFileAgeDays
    $prefetchRan = $true
    Write-Host "      $($prefetchResult.DeletedCount) dosya silindi ($($prefetchResult.DeletedSizeMB) MB), $($prefetchResult.SkippedCount) dosya atlandı."
} else {
    Write-Host "      Atlandı (Yönetici izni gerekiyor)." -ForegroundColor Yellow
}

Write-Host "`n[4/5] Temizlik sonrası disk ve bellek durumu ölçülüyor..." -ForegroundColor Cyan
$diskAfter = Get-DiskStatus
$memAfter  = Get-MemoryStatus
Write-Host "      Disk boş alan : $($diskAfter.FreeGB) GB / $($diskAfter.TotalGB) GB"

Write-Host "`n[5/5] HTML raporu oluşturuluyor..." -ForegroundColor Cyan
$html = New-HealthReportHtml -DiskBefore $diskBefore -DiskAfter $diskAfter `
    -MemBefore $memBefore -MemAfter $memAfter `
    -TempResult $tempResult -PrefetchResult $prefetchResult -PrefetchRan $prefetchRan

$desktopPath = [Environment]::GetFolderPath("Desktop")
$fileName    = "SistemSaglikRaporu_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
$reportPath  = Join-Path $desktopPath $fileName

$html | Out-File -FilePath $reportPath -Encoding utf8

Write-Host "`nRapor kaydedildi: $reportPath" -ForegroundColor Green

if (-not $NoAutoOpen) {
    Invoke-Item $reportPath
}

Write-Host "`n=== İşlem tamamlandı ===`n" -ForegroundColor Cyan
