# vanessa-run v1.0 - Run Vanessa Automation scenarios in batch mode
<#
.SYNOPSIS
    Прогон сценариев Vanessa Automation в пакетном режиме с отчетом JUnit.

.DESCRIPTION
    Пишет VAParams.json, запускает менеджер тестирования (1cv8c /TestManager /Execute
    vanessa-automation.epf /C"StartFeaturePlayer;QuietInstallVanessaExt;VAParams=..."), ждет
    завершения с таймаутом, разбирает отчет JUnit и печатает итог в Markdown. Клиент тестирования
    поднимает шаг фичи «Дано Я открыл новый сеанс TestClient или подключил уже существующий»
    (блок Контекст) по профилю из настроек Vanessa (по умолчанию «Этот клиент» - та же база):
    в пакетном режиме без этого шага Vanessa клиента не подключает.
    Без -KeepProcesses после прогона закрывает клиентов тестирования этой базы, запущенных прогоном (иначе они
    держат базу), по таймауту или ошибке - и менеджер.

    Код возврата: 0 - все сценарии прошли, 1 - есть упавшие, 2 - прогон не состоялся
    (в том числе ошибка параметров).

    База: явный -InfoBasePath или явная пара -InfoBaseServer/-InfoBaseRef важнее переменных
    окружения; из переменных путь VANESSA_IB_PATH важнее пары VANESSA_IB_SERVER/VANESSA_IB_REF.

.PARAMETER Feature
    Путь к .feature файлу или каталогу фич.

.PARAMETER VanessaPath
    Путь к vanessa-automation.epf (или vanessa-automation-single.epf).
    По умолчанию - переменная окружения VANESSA_EPF.

.PARAMETER V8Path
    Каталог bin платформы или путь к 1cv8c.exe, можно с * (C:\Program Files\1cv8\8.3.27.*\bin -
    берется последний подходящий). По умолчанию - последняя полная установленная платформа.

.PARAMETER InfoBasePath
    Путь к файловой информационной базе. По умолчанию - переменная окружения VANESSA_IB_PATH.

.PARAMETER InfoBaseServer
    Сервер 1С (для серверной базы). По умолчанию - VANESSA_IB_SERVER.

.PARAMETER InfoBaseRef
    Имя базы на сервере. По умолчанию - VANESSA_IB_REF.

.PARAMETER UserName
    Имя пользователя 1С. По умолчанию - VANESSA_IB_USER.

.PARAMETER Password
    Пароль. Если не задан - берется из переменной окружения VANESSA_IB_PWD (если она есть).

.PARAMETER Tags
    Отбор сценариев по тегам (через запятую).

.PARAMETER IgnoreTags
    Теги исключения (через запятую).

.PARAMETER StopOnError
    Остановить прогон на первой ошибке.

.PARAMETER TimeoutMinutes
    Таймаут всего прогона, по умолчанию 30 минут.

.PARAMETER OutDir
    Каталог результатов (VAParams.json, junit, скриншоты, статус). По умолчанию - временный.

.PARAMETER ParamsFile
    JSON с дополнительными параметрами Vanessa (ключи VAParams.json, например настройки записи
    видеоинструкций: videocreate, videopath, ffmpegcomand, dotts, ttstype). Ключи из файла
    дописываются к параметрам скрипта и заменяют совпадающие.

.PARAMETER KeepProcesses
    Не завершать процессы менеджера и клиентов принудительно, в том числе при ошибке или таймауте.
    Использовать для записи видео: окно ошибки пользователь закрывает самостоятельно.

.EXAMPLE
    .\vanessa-run.ps1 -Feature "C:\repo\features\план.feature" -InfoBasePath "C:\Bases\Test" -UserName "Администратор" -VanessaPath "C:\VA\vanessa-automation-single.epf"
#>
[CmdletBinding()]
param(
    [string]$Feature,
    [string]$VanessaPath = $env:VANESSA_EPF,
    [string]$V8Path,
    [string]$InfoBasePath = $env:VANESSA_IB_PATH,
    [string]$InfoBaseServer = $env:VANESSA_IB_SERVER,
    [string]$InfoBaseRef = $env:VANESSA_IB_REF,
    [string]$UserName = $env:VANESSA_IB_USER,
    [string]$Password,
    [string]$Tags,
    [string]$IgnoreTags,
    [switch]$StopOnError,
    [int]$TimeoutMinutes = 30,
    [string]$OutDir,
    [string]$ParamsFile,
    [switch]$KeepProcesses
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$process = $null
$started = $null
$ibMarker = $null
$vaParams = $null
$params = $null

# Клиенты тестирования этой же базы, запущенные после старта менеджера. Vanessa пишет путь базы
# в командную строку клиента как в профиле (обычно с обратными слэшами), поэтому путь сравнивается
# без учета вида слэшей, завершающего слэша и регистра.
function Get-RunClients {
    if ($null -eq $started -or -not $ibMarker) { return @() }
    $marker = ($ibMarker -replace '/', '\').TrimEnd('\').ToLowerInvariant()
    @(Get-CimInstance Win32_Process -Filter "Name='1cv8c.exe' OR Name='1cv8.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and $_.CommandLine -match '(?i)/TESTCLIENT' -and $_.CreationDate -ge $started -and
            ($_.CommandLine -replace '/', '\').ToLowerInvariant().Contains($marker)
        })
}

# Менеджер этого прогона и клиенты тестирования этой же базы, запущенные после его старта.
function Stop-RunProcesses {
    if ($KeepProcesses -or $null -eq $started) { return }
    try { if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force } } catch { }
    Get-RunClients | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
}

# Рабочий VAParams Vanessa читает один раз при старте менеджера; ключи облачной озвучки стираются из него,
# как только запущен клиент тестирования (запасной срок - половина таймаута, не меньше 5 минут: первый
# старт после обновления конфигурации бывает долгим), и еще раз в конце. Имена - алиасы и
# внутренние имена настроек Vanessa.
$secretParamNames = @('yandexttsapikey', 'yandexttsoauthtoken', 'sberttsclientsecret', 'amazonttskey',
    'amazonttssecretkey', '1CttsPassword', 'ЗаписьВидеоYandexTTSApiKey', 'ЗаписьВидеоYandexTTSOauthToken',
    'ЗаписьВидеоСберTTSClientSecret', 'ЗаписьВидеоAmazonКлючДоступа', 'ЗаписьВидеоAmazonСекретныйКлюч',
    'ЗаписьВидео1СПароль')
function Clear-RunSecrets {
    if (-not $vaParams -or -not $params -or -not (Test-Path -LiteralPath $vaParams)) { return }
    $secretNames = @($params.Keys | Where-Object { $secretParamNames -contains $_ })
    if ($secretNames.Count -eq 0) { return }
    $publicParams = [ordered]@{}
    foreach ($name in $params.Keys) {
        $publicParams[$name] = $(if ($secretNames -contains $name) { '' } else { $params[$name] })
    }
    [IO.File]::WriteAllText($vaParams, ($publicParams | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($true)))
}

function Fail([string]$Message) {
    Write-Output "ОШИБКА: $Message"
    Stop-RunProcesses
    Clear-RunSecrets
    exit 2
}

# Любая непредвиденная ошибка: закрыть процессы прогона и вернуть код 2 (а не 1 - «есть упавшие»).
trap {
    Write-Output "ОШИБКА: $_"
    try { Stop-RunProcesses } catch { }
    try { Clear-RunSecrets } catch { Write-Warning "Не удалось очистить ключ из временного файла $vaParams" }
    exit 2
}

# --- проверки входа ---------------------------------------------------------------------------
if (-not $Feature) { Fail "не задан -Feature (файл .feature или каталог фич)" }
if ($TimeoutMinutes -lt 1 -or $TimeoutMinutes -gt 1440) { Fail "-TimeoutMinutes должен быть от 1 до 1440" }
if (-not (Test-Path -LiteralPath $Feature)) { Fail "не найден файл или каталог фич: $Feature" }
$Feature = (Resolve-Path -LiteralPath $Feature).Path
if (-not $VanessaPath) { Fail "не задан путь к Vanessa Automation: -VanessaPath или переменная VANESSA_EPF" }
if (-not (Test-Path -LiteralPath $VanessaPath)) { Fail "не найден файл Vanessa Automation: $VanessaPath" }
$VanessaPath = (Resolve-Path -LiteralPath $VanessaPath).Path

# Явно переданная пара сервер/база важнее пути к файловой базе из переменной окружения.
$serverExplicit = $PSBoundParameters.ContainsKey('InfoBaseServer') -or $PSBoundParameters.ContainsKey('InfoBaseRef')
if ($serverExplicit -and -not $PSBoundParameters.ContainsKey('InfoBasePath')) { $InfoBasePath = $null }
if ($InfoBasePath) {
    $ibConnection = "File=""$InfoBasePath"";"
    $ibMarker = $InfoBasePath
} elseif ($InfoBaseServer -and $InfoBaseRef) {
    $ibConnection = "Srvr=""$InfoBaseServer"";Ref=""$InfoBaseRef"";"
    $ibMarker = $InfoBaseRef
} else {
    Fail "нужен -InfoBasePath или пара -InfoBaseServer и -InfoBaseRef"
}
if (-not $Password -and $env:VANESSA_IB_PWD) { $Password = $env:VANESSA_IB_PWD }

# --- платформа: тонкий клиент ----------------------------------------------------------------
if ($V8Path -and $V8Path.Contains('*')) {
    $V8Path = Resolve-Path -Path $V8Path -ErrorAction SilentlyContinue |
        Sort-Object { $_.Path } | Select-Object -Last 1 -ExpandProperty Path
    if (-not $V8Path) { Fail "по маске -V8Path платформа не найдена" }
}
if ($V8Path) {
    if (Test-Path -LiteralPath $V8Path -PathType Container) { $client = Join-Path $V8Path '1cv8c.exe' }
    elseif ($V8Path -like '*1cv8.exe') { $client = Join-Path (Split-Path $V8Path) '1cv8c.exe' }
    else { $client = $V8Path }
} else {
    # Неполная установка (есть 1cv8c.exe, нет vrsbase.dll) падает при старте с «Ошибка загрузки компоненты vrsbase».
    $client = Get-ChildItem 'C:\Program Files\1cv8\*\bin\1cv8c.exe' -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.DirectoryName 'vrsbase.dll') } |
        Sort-Object { try { [version]($_.Directory.Parent.Name -replace '[^0-9.]', '').Trim('.') } catch { [version]'0.0' } } -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $client -or -not (Test-Path -LiteralPath $client)) { Fail "не найден 1cv8c.exe (задайте -V8Path)" }

# --- каталог результатов и VAParams.json -------------------------------------------------------
if (-not $OutDir) { $OutDir = Join-Path ([IO.Path]::GetTempPath()) ("vanessa-run-" + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$junitDir = Join-Path $OutDir 'junit'
$screenDir = Join-Path $OutDir 'screenshots'
$statusFile = Join-Path $OutDir 'status.log'
$platformLog = Join-Path $OutDir '1c-out.log'
foreach ($dir in @($junitDir, $screenDir)) {
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
foreach ($file in @($statusFile, $platformLog)) {
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
}

function Split-List([string]$Text) {
    if (-not $Text) { return @() }
    return @($Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Плоский формат с русскими ключами - тот же, что в CI самой Vanessa (tools/JSON/VBParams*.json).
$params = [ordered]@{
    'КаталогФич'                                     = $Feature
    'ВыполнитьСценарии'                              = $true
    'ЗавершитьРаботуСистемы'                         = 'Истина'
    'ОстановкаПриВозникновенииОшибки'                = $(if ($StopOnError) { 'Истина' } else { 'Ложь' })
    'ДелатьОтчетВФорматеjUnit'                       = 'Истина'
    'КаталогOutputjUnit'                             = $junitDir
    'ДелатьСкриншотПриВозникновенииОшибки'           = 'Истина'
    'КаталогOutputСкриншоты'                         = $screenDir
    'ВыгружатьСтатусВыполненияСценариевВФайл'        = 'Истина'
    'ПутьКФайлуДляВыгрузкиСтатусаВыполненияСценариев' = $statusFile
    'ПриравниватьPendingКFailed'                     = 'Истина'
    'СписокТеговОтбор'                               = @(Split-List $Tags)
    'СписокТеговИсключение'                          = @(Split-List $IgnoreTags)
}
if ($ParamsFile) {
    if (-not (Test-Path -LiteralPath $ParamsFile)) { Fail "не найден файл параметров: $ParamsFile" }
    try {
        $extra = Get-Content -LiteralPath $ParamsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Fail "не удалось прочитать JSON параметров: $ParamsFile. Проверьте формат файла."
    }
    foreach ($property in $extra.PSObject.Properties) { $params[$property.Name] = $property.Value }
}
$vaParams = Join-Path $OutDir 'VAParams.json'
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[IO.File]::WriteAllText($vaParams, ($params | ConvertTo-Json -Depth 5), $utf8Bom)

# --- запуск менеджера тестирования ----------------------------------------------------------------
$arguments = @('ENTERPRISE', '/IBConnectionString', ('"' + $ibConnection.Replace('"', '""') + '"'))
if ($UserName) { $arguments += ('/N"' + $UserName + '"') }
if ($Password) { $arguments += ('/P"' + $Password + '"') }
$arguments += @('/TestManager', '/Execute', ('"' + $VanessaPath + '"'),
    ('/C"StartFeaturePlayer;QuietInstallVanessaExt;VAParams=' + $vaParams + '"'),
    '/DisableStartupDialogs', '/DisableStartupMessages', ('/Out"' + $platformLog + '"'))

$started = Get-Date
$finished = $false
try {
    $process = Start-Process -FilePath $client -ArgumentList $arguments -PassThru
    $deadline = $started.AddMinutes($TimeoutMinutes)
    $secretsCleared = $false
    while (-not $finished -and (Get-Date) -lt $deadline) {
        $finished = $process.WaitForExit(2000)
        if (-not $secretsCleared -and -not $finished) {
            if (@(Get-RunClients).Count -gt 0) {
                Clear-RunSecrets
                $secretsCleared = $true
            } elseif (((Get-Date) - $started).TotalMinutes -ge [Math]::Max(5, $TimeoutMinutes / 2)) {
                Clear-RunSecrets
                $secretsCleared = $true
                if ($params -and @($params.Keys | Where-Object { $secretParamNames -contains $_ }).Count -gt 0) {
                    Write-Warning 'Клиент тестирования не обнаружен: ключи озвучки стерты из VAParams по сроку. Если Vanessa еще не прочитала параметры, озвучки не будет.'
                }
            }
        }
    }
} finally {
    # ЗавершитьРаботуСистемы закрывает менеджер, но клиент тестирования остается и держит базу
    # (обновление конфигурации потом не проходит): закрываем клиентов этого прогона всегда,
    # в том числе при прерывании скрипта. С -KeepProcesses принудительное завершение отключено.
    Stop-RunProcesses
    Clear-RunSecrets
}
$elapsed = [int]((Get-Date) - $started).TotalSeconds

# --- результат ---------------------------------------------------------------------------------
$status = if (Test-Path -LiteralPath $statusFile) { (Get-Content -LiteralPath $statusFile -Raw -Encoding UTF8).Trim() } else { $null }
$junitFiles = @(Get-ChildItem -LiteralPath $junitDir -Filter '*.xml' -Recurse -ErrorAction SilentlyContinue)

$cases = @()
$brokenReports = @()
foreach ($file in $junitFiles) {
    try {
        [xml]$xml = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    } catch {
        $brokenReports += $file.FullName
        continue
    }
    foreach ($case in $xml.SelectNodes('//testcase')) {
        $failure = $case.SelectSingleNode('failure')
        if (-not $failure) { $failure = $case.SelectSingleNode('error') }
        $skipped = $case.SelectSingleNode('skipped')
        $state = if ($failure) { 'Failed' } elseif ($skipped) { 'Skipped' } else { 'Passed' }
        $message = ''
        if ($failure) {
            $message = $failure.GetAttribute('message')
            if (-not $message) { $message = $failure.InnerText }
            $message = ($message -replace '\s+', ' ').Trim()
            if ($message.Length -gt 600) { $message = $message.Substring(0, 600) + '...' }
        }
        $cases += [pscustomobject]@{ Suite = $case.GetAttribute('classname'); Name = $case.GetAttribute('name'); State = $state; Message = $message }
    }
}

$passed = @($cases | Where-Object State -eq 'Passed').Count
$failed = @($cases | Where-Object State -eq 'Failed').Count
$skippedCount = @($cases | Where-Object State -eq 'Skipped').Count

Write-Output "# Vanessa Automation: $(Split-Path $Feature -Leaf)"
Write-Output ''
Write-Output "База: $ibConnection; платформа: $client"
Write-Output ''
Write-Output "| Всего | Прошло | Упало | Пропущено | Время, с | Статус Vanessa |"
Write-Output "|---|---|---|---|---|---|"
Write-Output "| $($cases.Count) | $passed | $failed | $skippedCount | $elapsed | $(if ($null -ne $status) { $status } else { 'нет файла' }) |"
Write-Output ''
if (-not $finished) {
    if ($KeepProcesses) {
        Write-Output "**Таймаут $TimeoutMinutes мин:** процессы оставлены открыты. Закройте окно ошибки и менеджер вручную перед следующим прогоном."
    } else {
        Write-Output "**Таймаут $TimeoutMinutes мин:** менеджер и клиенты тестирования этого прогона закрыты принудительно."
    }
    Write-Output ''
}
$showSuite = @($cases | Select-Object -ExpandProperty Suite -Unique).Count -gt 1
foreach ($case in $cases) {
    $mark = switch ($case.State) { 'Passed' { '+' } 'Failed' { 'x' } default { '-' } }
    $title = if ($showSuite -and $case.Suite) { "$($case.Suite): $($case.Name)" } else { $case.Name }
    Write-Output "- [$mark] $title"
    if ($case.Message) { Write-Output "    $($case.Message)" }
}
$screens = @(Get-ChildItem -LiteralPath $screenDir -File -Recurse -ErrorAction SilentlyContinue)
if ($screens.Count -gt 0) {
    Write-Output ''
    Write-Output 'Скриншоты ошибок:'
    $screens | ForEach-Object { Write-Output "- $($_.FullName)" }
}
if ($brokenReports.Count -gt 0) {
    Write-Output ''
    Write-Output 'Не удалось прочитать отчеты JUnit:'
    $brokenReports | ForEach-Object { Write-Output "- $_" }
}
$statusFailed = ($null -ne $status) -and ($status -ne '0') -and ($failed -eq 0)
if ($statusFailed) {
    Write-Output ''
    Write-Output "Vanessa вернула статус $status при отсутствии упавших сценариев: ошибка вне сценариев, см. лог и скриншоты."
}
if ($cases.Count -eq 0 -and (Test-Path -LiteralPath $platformLog)) {
    $platformText = (Get-Content -LiteralPath $platformLog -Raw -ErrorAction SilentlyContinue)
    if ($platformText) { Write-Output ''; Write-Output 'Сообщения платформы (/Out):'; Write-Output $platformText.Trim() }
}
Write-Output ''
Write-Output "Каталог результатов: $OutDir"

if (-not $finished -or $cases.Count -eq 0) { exit 2 }
if ($failed -gt 0 -or $statusFailed) { exit 1 }
exit 0
