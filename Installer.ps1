#requires -version 5.1
param(
    [switch]$Elevated,
    [switch]$Silent,
    [ValidateSet('Normal')][string]$Profile = 'Normal',
    [string[]]$Applications,
    [switch]$DryRun
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptRoot 'config.json'
$LogRoot = if ($DryRun) { Join-Path $env:LOCALAPPDATA 'InstaladorPadrao\Logs' } else { Join-Path $env:ProgramData 'InstaladorPadrao\Logs' }
$script:LogFile = $null
$script:Config = $null
$script:CacheRoot = $null

function Write-InstallLog {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','SUCCESS')][string]$Level = 'INFO')
    if (-not (Test-Path $LogRoot)) { New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null }
    if (-not $script:LogFile) { $script:LogFile = Join-Path $LogRoot ("install_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date)) }
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-Elevation {
    if (Test-IsAdministrator) { return }
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath),'-Elevated')
    if ($Silent) { $arguments += @('-Silent','-Profile',$Profile) }
    if ($Applications) { $arguments += @('-Applications',('"{0}"' -f ($Applications -join ','))) }
    if ($DryRun) { $arguments += '-DryRun' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ($arguments -join ' ')
    exit
}

function Resolve-PackagePath {
    param([Parameter(Mandatory)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) { return $Path }
    return [IO.Path]::GetFullPath((Join-Path $ScriptRoot $Path))
}

function Get-CacheRoot {
    $path = [Environment]::ExpandEnvironmentVariables([string]$script:Config.CachePath)
    if ([string]::IsNullOrWhiteSpace($path)) { $path = Join-Path $env:USERPROFILE 'Downloads\InstaladorPadrao' }
    if ([IO.Path]::IsPathRooted($path)) { return [IO.Path]::GetFullPath($path) }
    return [IO.Path]::GetFullPath((Join-Path $ScriptRoot $path))
}

function Get-ApplicationCachePath {
    param([Parameter(Mandatory)]$Application)
    $fileName = [IO.Path]::GetFileName([string]$Application.Path)
    if ([string]::IsNullOrWhiteSpace($fileName)) { throw "Nome de arquivo inválido para $($Application.Name)." }
    return Join-Path (Join-Path $script:CacheRoot ([string]$Application.Id)) $fileName
}

function Remove-ApplicationCache {
    param([Parameter(Mandatory)][string]$PackagePath)
    if ($DryRun -or -not $script:CacheRoot) { return }
    $cacheRoot = ([IO.Path]::GetFullPath($script:CacheRoot)).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $packageFullPath = [IO.Path]::GetFullPath($PackagePath)
    if (-not $packageFullPath.StartsWith($cacheRoot, [StringComparison]::OrdinalIgnoreCase)) { return }
    $cacheFolder = Split-Path -Parent $PackagePath
    if (Test-Path -LiteralPath $cacheFolder) {
        Remove-Item -LiteralPath $cacheFolder -Recurse -Force -ErrorAction SilentlyContinue
        Write-InstallLog "Arquivos temporários removidos: $cacheFolder"
    }
}

function Remove-AllApplicationCache {
    if ($DryRun -or -not $script:CacheRoot) { return }
    if (Test-Path -LiteralPath $script:CacheRoot) {
        try {
            Remove-Item -LiteralPath $script:CacheRoot -Recurse -Force -ErrorAction SilentlyContinue
            Write-InstallLog "Limpeza geral concluída. Pasta temporária de downloads removida: $script:CacheRoot"
        } catch {
            Write-InstallLog "Não foi possível remover totalmente a pasta temporária: $script:CacheRoot" 'WARN'
        }
    }
}

function Get-DownloadErrorMessage {
    param([Exception]$Exception, [string]$Name)
    $webException = $Exception
    while ($webException -and $webException -isnot [Net.WebException]) { $webException = $webException.InnerException }
    if ($webException -is [Net.WebException]) {
        switch ($webException.Status) {
            'NameResolutionFailure' { return "Sem conexão com a internet ou falha de DNS ao baixar $Name." }
            'ConnectFailure'        { return "Não foi possível conectar ao servidor. Verifique a internet, proxy ou firewall." }
            'Timeout'               { return "O download de $Name expirou. Verifique a estabilidade da internet." }
            'ProxyNameResolutionFailure' { return 'Não foi possível localizar o proxy configurado.' }
            'TrustFailure'          { return 'Falha ao validar a conexão segura (TLS/certificado) do servidor.' }
        }
        if ($webException.Response -and $webException.Response.StatusCode) {
            return "Servidor retornou HTTP $([int]$webException.Response.StatusCode) ao baixar $Name."
        }
    }
    return "Falha no download de ${Name}: $($Exception.Message)"
}

function Invoke-PackageDownload {
    param([Parameter(Mandatory)]$Application, [scriptblock]$ProgressCallback)
    $source = Resolve-PackagePath ([string]$Application.Path)
    $destination = Get-ApplicationCachePath $Application
    $url = [string]$Application.DownloadUrl
    if ([string]::IsNullOrWhiteSpace($url)) {
        if ($DryRun) {
            Write-InstallLog "Modo simulação: usaria o pacote local $source" 'WARN'
            if ($ProgressCallback) { & $ProgressCallback "Simulação do pacote local: $($Application.Name)" 100 }
            return $source
        }
        if (-not (Test-Path -LiteralPath $source)) { throw "O pacote local não existe: $source" }
        Write-InstallLog "Usando pacote local: $source"
        if ($ProgressCallback) { & $ProgressCallback "Pacote local pronto: $($Application.Name)" 100 }
        return $source
    }
    $minimumBytes = 1
    if ($Application.PSObject.Properties['MinimumDownloadBytes']) {
        $minimumBytes = [long]$Application.MinimumDownloadBytes
    }
    if (Test-Path -LiteralPath $destination) {
        $cachedLength = (Get-Item -LiteralPath $destination).Length
        if ($cachedLength -ge $minimumBytes) {
            Write-InstallLog "Pacote temporário válido encontrado: $destination ($cachedLength bytes)"
            return $destination
        }
        Write-InstallLog "Pacote temporário incompleto encontrado e descartado: $destination ($cachedLength bytes)" 'WARN'
        Remove-Item -LiteralPath $destination -Force
    }
    $folder = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    if ($DryRun) {
        Write-InstallLog "Modo simulação: baixaria $url para $destination" 'WARN'
        if ($ProgressCallback) { & $ProgressCallback "Simulação do download: $($Application.Name)" 100 }
        return $destination
    }
    $partial = "$destination.download"
    Write-InstallLog "Download iniciado: $url"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $downloadTimeoutSeconds = 30
    if ($Application.PSObject.Properties['DownloadTimeoutSeconds']) { $downloadTimeoutSeconds = [int]$Application.DownloadTimeoutSeconds }
    $request = $null; $response = $null; $input = $null; $output = $null
    try {
        $request = [Net.HttpWebRequest]::Create($url)
        $request.UserAgent = 'InstaladorPadrao/1.1'
        $request.AllowAutoRedirect = $true
        $request.Timeout = $downloadTimeoutSeconds * 1000
        $request.ReadWriteTimeout = $downloadTimeoutSeconds * 1000
        $response = $request.GetResponse()
        $total = [long]$response.ContentLength
        $input = $response.GetResponseStream()
        $output = [IO.File]::Open($partial,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $buffer = New-Object byte[] (1024KB)
        $downloaded = [long]0; $watch = [Diagnostics.Stopwatch]::StartNew(); $lastUpdate = [TimeSpan]::Zero
        while (($read = $input.Read($buffer,0,$buffer.Length)) -gt 0) {
            $output.Write($buffer,0,$read); $downloaded += $read
            if (($watch.Elapsed - $lastUpdate).TotalMilliseconds -ge 200) {
                $speed = if ($watch.Elapsed.TotalSeconds -gt 0) { ($downloaded / 1MB) / $watch.Elapsed.TotalSeconds } else { 0 }
                $percent = if ($total -gt 0) { [Math]::Min(100,[Math]::Round(($downloaded*100.0)/$total,1)) } else { 0 }
                $sizeText = if ($total -gt 0) { '{0:N1}/{1:N1} MB' -f ($downloaded/1MB),($total/1MB) } else { '{0:N1} MB' -f ($downloaded/1MB) }
                $progressMessage = 'Baixando {0} - {1} - {2:N2} MB/s' -f $Application.Name,$sizeText,$speed
                if ($ProgressCallback) { & $ProgressCallback $progressMessage $percent }
                $lastUpdate = $watch.Elapsed
            }
        }
        $output.Flush(); $output.Close(); $output = $null
        if ($downloaded -lt $minimumBytes) { throw "O download terminou incompleto ($downloaded bytes; mínimo esperado: $minimumBytes bytes)." }
        Move-Item -LiteralPath $partial -Destination $destination -Force
        Write-InstallLog ("Download concluído: {0:N2} MB em {1:N1}s" -f ($downloaded/1MB),$watch.Elapsed.TotalSeconds) 'SUCCESS'
        if ($ProgressCallback) { & $ProgressCallback "Download concluído: $($Application.Name)" 100 }
        return $destination
    } catch {
        $friendly = Get-DownloadErrorMessage -Exception $_.Exception -Name ([string]$Application.Name)
        Write-InstallLog "$friendly URL: $url" 'ERROR'
        throw $friendly
    } finally {
        if ($output) { $output.Dispose() }
        if ($input) { $input.Dispose() }
        if ($response) { $response.Dispose() }
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
    }
}

function Test-ApplicationInstalled {
    param([Parameter(Mandatory)]$Application)
    if ($Application.PSObject.Properties['DetectionRegistryPaths']) {
        $valueName = [string]$Application.DetectionRegistryValue
        $expectedMatch = $null
        if ($Application.PSObject.Properties['DetectionRegistryMatch']) {
            $expectedMatch = [string]$Application.DetectionRegistryMatch
        }
        foreach ($registryPath in @($Application.DetectionRegistryPaths)) {
            $registryItem = Get-ItemProperty -LiteralPath ([string]$registryPath) -ErrorAction SilentlyContinue
            if ($registryItem) {
                $versionProperty = $registryItem.PSObject.Properties[$valueName]
                if ($versionProperty -and -not [string]::IsNullOrWhiteSpace([string]$versionProperty.Value) -and [string]$versionProperty.Value -ne '0.0.0.0') {
                    if ($expectedMatch) {
                        if ([string]$versionProperty.Value -like "*$expectedMatch*") { return $true }
                    } else {
                        return $true
                    }
                }
            }
        }
    }
    if ($Application.PSObject.Properties['DetectionPaths']) {
        foreach ($configuredPath in @($Application.DetectionPaths)) {
            $expandedPath = [Environment]::ExpandEnvironmentVariables([string]$configuredPath)
            if (Test-Path -Path $expandedPath) {
                if (-not $Application.PSObject.Properties['DetectionRegistryPaths']) {
                    return $true
                }
            }
        }
    }
    if ($Application.DetectionPath) {
        $path = [Environment]::ExpandEnvironmentVariables([string]$Application.DetectionPath)
        if (Test-Path -Path $path) { return $true }
    }
    if ($Application.DetectionDisplayName) {
        $roots = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        $pattern = [string]$Application.DetectionDisplayName
        foreach ($root in $roots) {
            $match = Get-ItemProperty $root -ErrorAction SilentlyContinue | Where-Object {
                $displayNameProperty = $_.PSObject.Properties['DisplayName']
                $displayNameProperty -and ([string]$displayNameProperty.Value -like $pattern)
            } | Select-Object -First 1
            if ($match) { return $true }
        }
    }
    return $false
}

function Wait-OfficeClickToRun {
    param(
        [string]$DisplayName = 'Microsoft Office',
        [int]$TimeoutSeconds = 3600,
        [scriptblock]$ProgressCallback
    )
    if ($DryRun) { return }
    Write-InstallLog "Aguardando o disparador do Office (OfficeC2RClient/OfficeClickToRun)..."
    Start-Sleep -Seconds 4
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $foundProcess = $false

    # Aguarda ate 30 segundos para o processo OfficeC2RClient ou setup iniciar
    while ($watch.Elapsed.TotalSeconds -lt 30) {
        $c2r = Get-Process -Name 'OfficeC2RClient', 'setup' -ErrorAction SilentlyContinue
        if ($c2r) {
            $foundProcess = $true
            break
        }
        Start-Sleep -Seconds 1
    }

    if ($foundProcess) {
        Write-InstallLog "Instalador do Office em execução em segundo plano. Aguardando conclusão..."
        while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            $c2r = Get-Process -Name 'OfficeC2RClient' -ErrorAction SilentlyContinue
            if (-not $c2r) {
                Write-InstallLog "Processo de instalação do Office concluído com sucesso." 'SUCCESS'
                break
            }
            if ($ProgressCallback) {
                $elapsedText = '{0:mm\:ss}' -f $watch.Elapsed
                & $ProgressCallback "Instalando $DisplayName em segundo plano... ($elapsedText)" 60
            }
            Start-Sleep -Seconds 3
        }
    } else {
        Write-InstallLog "Nenhum processo OfficeC2RClient detectado após iniciar o setup." 'WARN'
    }
}

function Invoke-ProcessChecked {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments,
        [int[]]$SuccessExitCodes = @(0,1641,3010),
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds = 1800,
        [string]$DisplayName = 'instalador',
        [bool]$ShowWindow = $false,
        [scriptblock]$ProgressCallback
    )
    $displayArgs = if ($Arguments) { $Arguments } else { '(sem argumentos)' }
    Write-InstallLog "Executando: $FilePath $displayArgs"
    if ($DryRun) { Write-InstallLog 'Modo simulação: execução ignorada.' 'WARN'; return 0 }
    if (-not (Test-Path -LiteralPath $FilePath)) { throw "Arquivo não encontrado: $FilePath" }
    $params = @{ FilePath = $FilePath; PassThru = $true }
    if (-not [string]::IsNullOrWhiteSpace($Arguments)) { $params.ArgumentList = $Arguments }
    if (-not $ShowWindow) { $params.WindowStyle = 'Hidden' }
    if ($WorkingDirectory) { $params.WorkingDirectory = $WorkingDirectory }
    $process = Start-Process @params
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not $process.WaitForExit(1000)) {
        $elapsedSeconds = [int]$watch.Elapsed.TotalSeconds
        if ($elapsedSeconds -ge $TimeoutSeconds) {
            throw "A instalação de $DisplayName excedeu o limite de $TimeoutSeconds segundos. O processo não foi encerrado automaticamente."
        }
        if ($ProgressCallback) {
            $elapsedText = '{0:mm\:ss}' -f $watch.Elapsed
            $percent = [Math]::Min(94, 70 + (($elapsedSeconds / [Math]::Max(1,$TimeoutSeconds)) * 24))
            & $ProgressCallback "Instalando $DisplayName - tempo decorrido: $elapsedText" $percent
        }
    }
    $process.Refresh()
    if ($SuccessExitCodes -notcontains $process.ExitCode) { throw "Processo encerrou com código $($process.ExitCode)." }
    if ($process.ExitCode -in @(1641,3010)) { Write-InstallLog 'O instalador solicitou reinicialização.' 'WARN' }
    return $process.ExitCode
}

function Invoke-ApplicationInstall {
    param([Parameter(Mandatory)]$Application, [scriptblock]$ProgressCallback)
    Write-InstallLog "Iniciando: $($Application.Name)"
    $skipIfInstalled = $true
    if ($Application.PSObject.Properties['SkipIfInstalled']) { $skipIfInstalled = [bool]$Application.SkipIfInstalled }
    if (-not $DryRun -and $skipIfInstalled -and (Test-ApplicationInstalled $Application)) {
        Write-InstallLog "$($Application.Name) já está instalado; etapa ignorada." 'SUCCESS'
        return @{ Id=$Application.Id; Name=$Application.Name; Status='Já instalado'; Success=$true }
    }
    $packagePath = Invoke-PackageDownload -Application $Application -ProgressCallback $ProgressCallback
    try {
        $codes = @($Application.SuccessExitCodes | ForEach-Object { [int]$_ })
        if ($codes.Count -eq 0) { $codes = @(0,1641,3010) }
        $processTimeout = 1800
        if ($Application.PSObject.Properties['ProcessTimeoutSeconds']) { $processTimeout = [int]$Application.ProcessTimeoutSeconds }
        $showInstallerWindow = $false
        if ($Application.PSObject.Properties['ShowInstallerWindow']) { $showInstallerWindow = [bool]$Application.ShowInstallerWindow }
        $processParameters = @{
            SuccessExitCodes = $codes
            TimeoutSeconds = $processTimeout
            DisplayName = [string]$Application.Name
            ShowWindow = $showInstallerWindow
            ProgressCallback = $ProgressCallback
        }
        if ($Application.Type -eq 'Iso') {
            $isoPath = $packagePath
            if ($DryRun) {
                Write-InstallLog "Modo simulação: montaria a ISO $isoPath" 'WARN'
                return @{ Id=$Application.Id; Name=$Application.Name; Status='Simulado'; Success=$true }
            }
            if (-not (Test-Path -LiteralPath $isoPath)) { throw "ISO não encontrada: $isoPath" }
            $image = $null
            try {
                $image = Mount-DiskImage -ImagePath $isoPath -PassThru
                $volume = $image | Get-Volume
                if (-not $volume.DriveLetter) { throw 'A ISO foi montada, mas não recebeu uma letra de unidade.' }
                $setup = Join-Path ($volume.DriveLetter + ':\') ([string]$Application.SetupRelativePath)
                Invoke-ProcessChecked -FilePath $setup -Arguments ([string]$Application.Arguments) -WorkingDirectory (Split-Path $setup) @processParameters | Out-Null
            } finally {
                if ($image) { Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue }
            }
        } elseif ($Application.Type -eq 'OfficeOdt') {
            $odtFolder = Split-Path -Parent $packagePath
            $setup = Join-Path $odtFolder 'setup.exe'
            if (-not (Test-Path -LiteralPath $setup)) {
                Invoke-ProcessChecked -FilePath $packagePath -Arguments ('/quiet /extract:"{0}"' -f $odtFolder) -SuccessExitCodes @(0) -WorkingDirectory $odtFolder -TimeoutSeconds $processTimeout -DisplayName ([string]$Application.Name) -ProgressCallback $ProgressCallback | Out-Null
            }
            Invoke-ProcessChecked -FilePath $setup -Arguments ([string]$Application.Arguments) -WorkingDirectory $odtFolder @processParameters | Out-Null
            Wait-OfficeClickToRun -DisplayName ([string]$Application.Name) -TimeoutSeconds $processTimeout -ProgressCallback $ProgressCallback
        } elseif ($Application.Type -eq 'OfficeIso') {
            $isoPath = $packagePath
            if ($DryRun) {
                Write-InstallLog "Modo simulacao: montaria a imagem Office $isoPath" 'WARN'
                return @{ Id=$Application.Id; Name=$Application.Name; Status='Simulado'; Success=$true }
            }
            if (-not (Test-Path -LiteralPath $isoPath)) { throw "Imagem Office nao encontrada: $isoPath" }
            $configXml = $null
            if ($Application.PSObject.Properties['ConfigXml'] -and -not [string]::IsNullOrWhiteSpace([string]$Application.ConfigXml)) {
                $configXml = Resolve-PackagePath ([string]$Application.ConfigXml)
            } else {
                $configXml = Join-Path (Split-Path -Parent $isoPath) 'configuration.xml'
            }
            if (-not (Test-Path -LiteralPath $configXml)) { throw "configuration.xml nao encontrado: $configXml" }
            Write-InstallLog "Montando imagem Office: $isoPath"
            $image = $null
            try {
                $image = Mount-DiskImage -ImagePath $isoPath -PassThru
                $volume = $image | Get-Volume
                if (-not $volume.DriveLetter) { throw 'A imagem foi montada, mas nao recebeu uma letra de unidade.' }
                $setup = Join-Path ($volume.DriveLetter + ':\') 'setup.exe'
                if (-not (Test-Path -LiteralPath $setup)) { throw "setup.exe nao encontrado na imagem montada ($($volume.DriveLetter):\)." }
                Write-InstallLog "Executando Office setup a partir da imagem: $setup"
                Invoke-ProcessChecked -FilePath $setup -Arguments "/configure `"$configXml`"" -WorkingDirectory ($volume.DriveLetter + ':\') @processParameters | Out-Null
                Wait-OfficeClickToRun -DisplayName ([string]$Application.Name) -TimeoutSeconds $processTimeout -ProgressCallback $ProgressCallback
            } finally {
                if ($image) {
                    Write-InstallLog "Desmontando imagem Office: $isoPath"
                    Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue
                }
            }
        } elseif ($Application.Type -eq 'Msi') {
            $file = $packagePath
            $msiArgs = '/i "{0}" {1}' -f $file, ([string]$Application.Arguments)
            Invoke-ProcessChecked -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -Arguments $msiArgs -WorkingDirectory (Split-Path $file) @processParameters | Out-Null
        } else {
            $file = $packagePath
            Invoke-ProcessChecked -FilePath $file -Arguments ([string]$Application.Arguments) -WorkingDirectory (Split-Path $file) @processParameters | Out-Null
        }
        if (-not $DryRun -and $Application.PSObject.Properties['VerifyAfterInstall'] -and [bool]$Application.VerifyAfterInstall) {
            $verificationTimeout = 300
            if ($Application.PSObject.Properties['VerificationTimeoutSeconds']) { $verificationTimeout = [int]$Application.VerificationTimeoutSeconds }
            $verificationWatch = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-ApplicationInstalled $Application)) {
                if ($verificationWatch.Elapsed.TotalSeconds -ge $verificationTimeout) {
                    throw "O instalador terminou, mas $($Application.Name) não foi detectado após $verificationTimeout segundos."
                }
                if ($ProgressCallback) {
                    $elapsedText = '{0:mm\:ss}' -f $verificationWatch.Elapsed
                    & $ProgressCallback "Confirmando a instalação de $($Application.Name) - $elapsedText" 97
                }
                Start-Sleep -Seconds 2
            }
            Write-InstallLog "$($Application.Name) confirmado no sistema." 'SUCCESS'
        }
        Write-InstallLog "$($Application.Name) concluído." 'SUCCESS'
        return @{ Id=$Application.Id; Name=$Application.Name; Status=($(if ($DryRun) {'Simulado'} else {'Concluído'})); Success=$true }
    } finally {
        if (-not $DryRun) { Remove-ApplicationCache -PackagePath $packagePath }
    }
}

function Get-ProfileApplications {
    param([string]$SelectedProfile)
    $ids = @($script:Config.Profiles.$SelectedProfile)
    $orderedApplications = @()
    foreach ($id in $ids) {
        $application = $script:Config.Applications | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        if ($application) { $orderedApplications += $application }
    }
    return $orderedApplications
}

function Expand-ApplicationDependencies {
    param([array]$Applications)
    $orderedApplications = @()
    $addedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($app in $Applications) {
        if ($app.PSObject.Properties['Dependencies']) {
            foreach ($dependencyId in @($app.Dependencies)) {
                if (-not $addedIds.Contains([string]$dependencyId)) {
                    $dependency = $script:Config.Applications | Where-Object { $_.Id -eq $dependencyId } | Select-Object -First 1
                    if (-not $dependency) { throw "Dependência desconhecida: $dependencyId." }
                    $orderedApplications += $dependency
                    [void]$addedIds.Add([string]$dependency.Id)
                }
            }
        }
        if ($addedIds.Add([string]$app.Id)) { $orderedApplications += $app }
    }
    return $orderedApplications
}

function Start-Installation {
    param([array]$Applications, [scriptblock]$StatusCallback)
    $Applications = @(Expand-ApplicationDependencies $Applications)
    $results = @()
    Write-InstallLog "Sessão iniciada. Perfil: $Profile; Simulação: $DryRun"
    $index = 0
    try {
        foreach ($app in $Applications) {
            $basePercent = ($index * 100.0) / [Math]::Max(1,$Applications.Count)
            $spanPercent = 100.0 / [Math]::Max(1,$Applications.Count)
            if ($StatusCallback) { & $StatusCallback "Preparando $($app.Name)..." $basePercent }
            $appCallback = { param($text,$itemPercent) if ($StatusCallback) { & $StatusCallback $text ($basePercent + (($itemPercent/100.0)*$spanPercent)) } }
            $failedDependencies = @()
            if ($app.PSObject.Properties['Dependencies']) {
                $dependencyIds = @($app.Dependencies)
                $failedDependencies = @($results | Where-Object { $_.Id -in $dependencyIds -and -not $_.Success })
            }
            if ($failedDependencies.Count) {
                $dependencyNames = @($failedDependencies | ForEach-Object { $_.Name }) -join ', '
                $message = "$($app.Name) não foi executado porque a dependência falhou: $dependencyNames."
                Write-InstallLog $message 'ERROR'
                $results += @{ Id=$app.Id; Name=$app.Name; Status='Dependência falhou'; Success=$false; Error=$message }
                $index++
                continue
            }
            try {
                $results += Invoke-ApplicationInstall $app -ProgressCallback $appCallback
            } catch {
                $message = "$($app.Name): $($_.Exception.Message)"
                Write-InstallLog $message 'ERROR'
                $results += @{ Id=$app.Id; Name=$app.Name; Status='Falhou'; Success=$false; Error=$_.Exception.Message }
                if (-not [bool]$script:Config.ContinueOnError) { break }
            }
            $index++
        }
    } finally {
        Remove-AllApplicationCache
    }
    $failed = @($results | Where-Object { -not $_.Success })
    Write-InstallLog ("Sessão finalizada. Sucessos: {0}; Falhas: {1}" -f ($results.Count-$failed.Count),$failed.Count) $(if ($failed.Count) {'ERROR'} else {'SUCCESS'})
    return $results
}

function Load-Configuration {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Configuração não encontrada: $ConfigPath" }
    $script:Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $script:Config.Applications -or -not $script:Config.Profiles) { throw 'O config.json é inválido ou incompleto.' }
    $script:CacheRoot = Get-CacheRoot
}


# ─────────────────────────────────────────────────────────────────────────────
# JANELA PRINCIPAL — UI COM SUPORTE A TEMA CLARO E TEMA ESCURO
# ─────────────────────────────────────────────────────────────────────────────
function Show-MainWindow {
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase

    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Instalador Padrao"
        Height="620" Width="740"
        MinHeight="500" MinWidth="640"
        WindowStartupLocation="CenterScreen"
        ResizeMode="CanResize"
        Background="#F4F6F9"
        Name="RootWindow">

  <Window.Resources>

    <!-- Botao Primario (Instalar) com animacao/triggers -->
    <Style x:Key="BtnPrimary" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="24,9"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="#0066CC" CornerRadius="4" Padding="{TemplateBinding Padding}" RenderTransformOrigin="0.5,0.5">
              <Border.RenderTransform>
                <ScaleTransform x:Name="BdScale" ScaleX="1" ScaleY="1"/>
              </Border.RenderTransform>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#0052A3"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="RenderTransform">
                  <Setter.Value>
                    <ScaleTransform ScaleX="0.97" ScaleY="0.97"/>
                  </Setter.Value>
                </Setter>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="#B0BEC5"/>
                <Setter Property="Foreground" Value="#ECEFF1"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Botao Secundario -->
    <Style x:Key="BtnSecondary" TargetType="Button">
      <Setter Property="Foreground" Value="#333333"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Padding" Value="16,8"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="#FFFFFF" BorderBrush="#CCCCCC" CornerRadius="4" Padding="{TemplateBinding Padding}" BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#F0F0F0"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#999999"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="#F5F5F5"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#E0E0E0"/>
                <Setter Property="Foreground" Value="#A0A0A0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Botao Alternar Tema -->
    <Style x:Key="BtnThemeToggle" TargetType="Button">
      <Setter Property="Foreground" Value="#0066CC"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Padding" Value="12,5"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="#E6F2FF" BorderBrush="#BBE0FF" CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#CCE5FF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Botao Ghost (Marcar/Desmarcar) -->
    <Style x:Key="BtnGhost" TargetType="Button">
      <Setter Property="Foreground" Value="#0066CC"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Padding" Value="8,4"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="3" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#E6F0FA"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="#A0A0A0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- App Item CheckBox -->
    <Style x:Key="AppRow" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="Row" Background="White" BorderThickness="0,0,0,1" BorderBrush="#EAEAEA" Padding="16,11">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <Border x:Name="CkBd" Grid.Column="0" Width="18" Height="18" CornerRadius="3"
                        BorderThickness="1.5" BorderBrush="#AAAAAA" Background="White" VerticalAlignment="Center" Margin="0,0,12,0">
                  <Path x:Name="CkMark" Stroke="White" StrokeThickness="2"
                        StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                        Data="M3,9 L7,13 L15,4"
                        HorizontalAlignment="Center" VerticalAlignment="Center"
                        Visibility="Collapsed"/>
                </Border>

                <TextBlock x:Name="AppTitle" Grid.Column="1" Text="{TemplateBinding Content}"
                           FontSize="13" Foreground="#222222" VerticalAlignment="Center"/>

                <Border x:Name="Badge" Grid.Column="2" CornerRadius="10" Padding="8,2"
                        Background="#E6F2FF" Visibility="Collapsed" VerticalAlignment="Center">
                  <TextBlock Text="Selecionado" FontSize="11" Foreground="#0066CC"/>
                </Border>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="CkBd" Property="Background" Value="#0066CC"/>
                <Setter TargetName="CkBd" Property="BorderBrush" Value="#0066CC"/>
                <Setter TargetName="CkMark" Property="Visibility" Value="Visible"/>
                <Setter TargetName="Badge" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Row" Property="Background" Value="#F8FAFC"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ProgressBar Style -->
    <Style x:Key="PBar" TargetType="ProgressBar">
      <Setter Property="Height" Value="8"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Border CornerRadius="4" Background="#E0E6ED" ClipToBounds="True" Height="8">
              <Grid>
                <Rectangle x:Name="PART_Indicator" HorizontalAlignment="Left" Fill="#0066CC"/>
              </Grid>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

  </Window.Resources>

  <Grid Name="MainGrid">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/> <!-- Header -->
      <RowDefinition Height="Auto"/> <!-- Toolbar -->
      <RowDefinition Height="*"/>    <!-- App list -->
      <RowDefinition Height="Auto"/> <!-- Progress -->
      <RowDefinition Height="Auto"/> <!-- Result panel -->
      <RowDefinition Height="Auto"/> <!-- Footer -->
    </Grid.RowDefinitions>

    <!-- HEADER -->
    <Border Name="HeaderBorder" Grid.Row="0" Background="White" BorderBrush="#E0E4E8" BorderThickness="0,0,0,1" Padding="24,18">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0">
          <TextBlock Name="HeaderTitle" FontSize="20" FontWeight="Bold" Foreground="#111827" Text="Instalador Padrao"/>
          <TextBlock Name="HeaderSub" FontSize="12" Foreground="#6B7280" Margin="0,4,0,0" Text="Selecione os programas que deseja instalar na maquina."/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <CheckBox Name="DryRunBox" VerticalAlignment="Center" Margin="0,0,16,0">
            <TextBlock Name="DryRunText" FontSize="12" Foreground="#4B5563" Text="Modo simulacao"/>
          </CheckBox>
          <Button Name="ThemeToggleBtn" Content="Modo Escuro" Style="{StaticResource BtnThemeToggle}"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- TOOLBAR -->
    <Border Name="ToolbarBorder" Grid.Row="1" Background="#F8FAFC" BorderBrush="#E0E4E8" BorderThickness="0,0,0,1" Padding="20,8">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Name="CountLabel" Grid.Column="0" FontSize="12" Foreground="#4B5563" VerticalAlignment="Center"/>
        <StackPanel Grid.Column="1" Orientation="Horizontal">
          <Button Name="SelectAllBtn" Content="Marcar todos" Style="{StaticResource BtnGhost}" Margin="0,0,6,0"/>
          <Button Name="ClearAllBtn" Content="Desmarcar todos" Style="{StaticResource BtnGhost}"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- APP LIST CONTAINER -->
    <Border Name="AppListBorder" Grid.Row="2" Margin="20,14,20,0" CornerRadius="6" Background="White" BorderBrush="#E0E4E8" BorderThickness="1">
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <StackPanel Name="AppsPanel"/>
      </ScrollViewer>
    </Border>

    <!-- PROGRESS CONTAINER -->
    <Border Name="ProgressBorder" Grid.Row="3" Margin="20,12,20,0" CornerRadius="6" Background="White" BorderBrush="#E0E4E8" BorderThickness="1" Padding="16,12">
      <StackPanel>
        <Grid Margin="0,0,0,6">
          <TextBlock Name="ProgressTitle" Text="Progresso da instalacao" FontSize="11" FontWeight="SemiBold" Foreground="#374151"/>
          <TextBlock Name="PercentLabel" Text="0%" FontSize="11" FontWeight="Bold" Foreground="#0066CC" HorizontalAlignment="Right"/>
        </Grid>
        <ProgressBar Name="Progress" Style="{StaticResource PBar}" Minimum="0" Maximum="100" Value="0"/>
        <TextBlock Name="StatusText" Text="Pronto para iniciar." FontSize="11.5" Foreground="#6B7280" Margin="0,6,0,0"/>
      </StackPanel>
    </Border>

    <!-- RESULT PANEL -->
    <Border Name="ResultPanel" Grid.Row="4" Margin="20,8,20,0" CornerRadius="6" Background="#F0F7FF" BorderBrush="#BAE6FD" BorderThickness="1" Padding="14,10" Visibility="Collapsed">
      <ScrollViewer VerticalScrollBarVisibility="Auto" MaxHeight="100">
        <StackPanel Name="ResultItems"/>
      </ScrollViewer>
    </Border>

    <!-- FOOTER -->
    <Border Name="FooterBorder" Grid.Row="5" Background="White" BorderBrush="#E0E4E8" BorderThickness="0,1,0,0" Padding="20,14" Margin="0,12,0,0">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Button Name="LogButton" Grid.Column="0" Content="Ver logs" Style="{StaticResource BtnSecondary}"/>
        <StackPanel Grid.Column="2" Orientation="Horizontal">
          <Button Name="CloseButton" Content="Fechar" Style="{StaticResource BtnSecondary}" Margin="0,0,10,0"/>
          <Button Name="InstallButton" Content="Instalar selecionados" Style="{StaticResource BtnPrimary}"/>
        </StackPanel>
      </Grid>
    </Border>

  </Grid>
</Window>
'@

    $reader  = [Xml.XmlNodeReader]::new($xaml)
    $window  = [Windows.Markup.XamlReader]::Load($reader)

    # ── Referencias de controles ──
    $headerBorder   = $window.FindName('HeaderBorder')
    $headerTitle    = $window.FindName('HeaderTitle')
    $headerSub      = $window.FindName('HeaderSub')
    $dryRunText     = $window.FindName('DryRunText')
    $themeToggleBtn = $window.FindName('ThemeToggleBtn')
    $toolbarBorder  = $window.FindName('ToolbarBorder')
    $countLabel     = $window.FindName('CountLabel')
    $appListBorder  = $window.FindName('AppListBorder')
    $appsPanel      = $window.FindName('AppsPanel')
    $progressBorder = $window.FindName('ProgressBorder')
    $progressTitle  = $window.FindName('ProgressTitle')
    $percentLabel   = $window.FindName('PercentLabel')
    $progress       = $window.FindName('Progress')
    $statusText     = $window.FindName('StatusText')
    $resultPanel    = $window.FindName('ResultPanel')
    $resultItems    = $window.FindName('ResultItems')
    $footerBorder   = $window.FindName('FooterBorder')
    $installButton  = $window.FindName('InstallButton')
    $closeButton    = $window.FindName('CloseButton')
    $logButton      = $window.FindName('LogButton')
    $dryRunBox      = $window.FindName('DryRunBox')
    $selectAllBtn   = $window.FindName('SelectAllBtn')
    $clearAllBtn    = $window.FindName('ClearAllBtn')

    if ($script:Config -and $script:Config.PSObject.Properties['Version'] -and -not [string]::IsNullOrWhiteSpace([string]$script:Config.Version)) {
        $headerTitle.Text = "Instalador Padrão v$($script:Config.Version)"
        $window.Title     = "Instalador Padrão v$($script:Config.Version)"
    }

    $script:checkBoxes = @{}
    $script:isDarkMode  = $false

    # ── Alternar Tema (Modo Claro / Modo Escuro) ──
    $applyTheme = {
        $bc = [Windows.Media.BrushConverter]::new()
        if ($script:isDarkMode) {
            # DARK MODE (Slate Dark)
            $window.Background         = $bc.ConvertFromString('#0F172A')
            $headerBorder.Background   = $bc.ConvertFromString('#1E293B')
            $headerBorder.BorderBrush = $bc.ConvertFromString('#334155')
            $headerTitle.Foreground    = $bc.ConvertFromString('#F8FAFC')
            $headerSub.Foreground      = $bc.ConvertFromString('#94A3B8')
            $dryRunText.Foreground     = $bc.ConvertFromString('#CBD5E1')
            $toolbarBorder.Background  = $bc.ConvertFromString('#0F172A')
            $toolbarBorder.BorderBrush = $bc.ConvertFromString('#334155')
            $countLabel.Foreground     = $bc.ConvertFromString('#94A3B8')
            $appListBorder.Background  = $bc.ConvertFromString('#1E293B')
            $appListBorder.BorderBrush = $bc.ConvertFromString('#334155')
            $progressBorder.Background = $bc.ConvertFromString('#1E293B')
            $progressBorder.BorderBrush= $bc.ConvertFromString('#334155')
            $progressTitle.Foreground  = $bc.ConvertFromString('#CBD5E1')
            $statusText.Foreground     = $bc.ConvertFromString('#94A3B8')
            $footerBorder.Background   = $bc.ConvertFromString('#1E293B')
            $footerBorder.BorderBrush  = $bc.ConvertFromString('#334155')
            $themeToggleBtn.Content    = "Modo Claro"

            foreach ($cb in $script:checkBoxes.Values) {
                $row = $cb.Template.FindName('Row', $cb)
                if ($row) {
                    $row.Background  = $bc.ConvertFromString('#1E293B')
                    $row.BorderBrush = $bc.ConvertFromString('#334155')
                }
                $txt = $cb.Template.FindName('AppTitle', $cb)
                if ($txt) {
                    $txt.Foreground = $bc.ConvertFromString('#F8FAFC')
                }
            }
        } else {
            # LIGHT MODE (Crisp Light)
            $window.Background         = $bc.ConvertFromString('#F4F6F9')
            $headerBorder.Background   = $bc.ConvertFromString('#FFFFFF')
            $headerBorder.BorderBrush = $bc.ConvertFromString('#E0E4E8')
            $headerTitle.Foreground    = $bc.ConvertFromString('#111827')
            $headerSub.Foreground      = $bc.ConvertFromString('#6B7280')
            $dryRunText.Foreground     = $bc.ConvertFromString('#4B5563')
            $toolbarBorder.Background  = $bc.ConvertFromString('#F8FAFC')
            $toolbarBorder.BorderBrush = $bc.ConvertFromString('#E0E4E8')
            $countLabel.Foreground     = $bc.ConvertFromString('#4B5563')
            $appListBorder.Background  = $bc.ConvertFromString('#FFFFFF')
            $appListBorder.BorderBrush = $bc.ConvertFromString('#E0E4E8')
            $progressBorder.Background = $bc.ConvertFromString('#FFFFFF')
            $progressBorder.BorderBrush= $bc.ConvertFromString('#E0E4E8')
            $progressTitle.Foreground  = $bc.ConvertFromString('#374151')
            $statusText.Foreground     = $bc.ConvertFromString('#6B7280')
            $footerBorder.Background   = $bc.ConvertFromString('#FFFFFF')
            $footerBorder.BorderBrush  = $bc.ConvertFromString('#E0E4E8')
            $themeToggleBtn.Content    = "Modo Escuro"

            foreach ($cb in $script:checkBoxes.Values) {
                $row = $cb.Template.FindName('Row', $cb)
                if ($row) {
                    $row.Background  = $bc.ConvertFromString('#FFFFFF')
                    $row.BorderBrush = $bc.ConvertFromString('#EAEAEA')
                }
                $txt = $cb.Template.FindName('AppTitle', $cb)
                if ($txt) {
                    $txt.Foreground = $bc.ConvertFromString('#222222')
                }
            }
        }
    }

    $themeToggleBtn.Add_Click({
        $script:isDarkMode = -not $script:isDarkMode
        & $applyTheme
    })

    # ── Atualiza contador ──
    $updateCount = {
        $total    = $script:checkBoxes.Count
        $selected = @($script:checkBoxes.Values | Where-Object { $_.IsChecked }).Count
        $countLabel.Text = "$selected de $total selecionados"
    }

    # ── Preenche lista de apps ──
    $appsPanel.Children.Clear()
    $script:checkBoxes = @{}
    foreach ($app in (Get-ProfileApplications 'Normal')) {
        $cb           = [Windows.Controls.CheckBox]::new()
        $cb.Style     = $window.Resources['AppRow']
        $cb.Content   = $app.Name
        $cb.IsChecked = $true
        $cb.Tag       = $app.Id
        $cb.Add_Checked({ & $updateCount })
        $cb.Add_Unchecked({ & $updateCount })
        $appsPanel.Children.Add($cb) | Out-Null
        $script:checkBoxes[$app.Id] = $cb
    }
    & $updateCount

    $dryRunBox.IsChecked = $DryRun

    # ── Marcar / Desmarcar todos ──
    $selectAllBtn.Add_Click({ foreach ($cb in $script:checkBoxes.Values) { $cb.IsChecked = $true  } })
    $clearAllBtn.Add_Click({  foreach ($cb in $script:checkBoxes.Values) { $cb.IsChecked = $false } })

    # ── Fechar / Logs ──
    $closeButton.Add_Click({ $window.Close() })
    $logButton.Add_Click({
        if (-not (Test-Path $LogRoot)) { New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null }
        Start-Process explorer.exe $LogRoot
    })

    # ── Instalar ──
    $installButton.Add_Click({
        $script:Profile = 'Normal'
        $script:DryRun  = [bool]$dryRunBox.IsChecked
        $selected       = @(Get-ProfileApplications 'Normal' | Where-Object { $script:checkBoxes[$_.Id].IsChecked })

        if (-not $selected.Count) {
            [Windows.MessageBox]::Show('Selecione pelo menos um programa.','Atencao','OK','Warning')
            return
        }
        $answer = [Windows.MessageBox]::Show(
            "Iniciar a instalacao de $($selected.Count) programa(s)?",
            'Confirmacao','YesNo','Question')
        if ($answer -ne 'Yes') { return }

        $installButton.IsEnabled = $false
        $selectAllBtn.IsEnabled  = $false
        $clearAllBtn.IsEnabled   = $false
        $resultPanel.Visibility  = [Windows.Visibility]::Collapsed
        $resultItems.Children.Clear()
        $progress.Value    = 5
        $percentLabel.Text = '5%'

        $callback = {
            param($text, $percent)
            $statusText.Text    = $text
            $pVal               = [Math]::Min(99,[Math]::Max(0,$percent))
            $progress.Value     = $pVal
            $percentLabel.Text  = "$([int]$pVal)%"
            $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Background)
        }

        $results = Start-Installation -Applications $selected -StatusCallback $callback

        $progress.Value    = 100
        $percentLabel.Text = '100%'

        $installButton.IsEnabled = $true
        $selectAllBtn.IsEnabled  = $true
        $clearAllBtn.IsEnabled   = $true

        # Resultado inline
        $resultPanel.Visibility = [Windows.Visibility]::Visible
        foreach ($r in $results) {
            $row             = [Windows.Controls.StackPanel]::new()
            $row.Orientation = [Windows.Controls.Orientation]::Horizontal
            $row.Margin      = [Windows.Thickness]::new(0,3,0,3)

            $lbl              = [Windows.Controls.TextBlock]::new()
            $lbl.Text         = if ($r.Success) { "[OK]  $($r.Name)  -  $($r.Status)" } else { "[ERRO]  $($r.Name)  -  $($r.Status)" }
            $lbl.FontSize     = 12
            $lbl.FontWeight   = if ($r.Success) { [Windows.FontWeights]::Normal } else { [Windows.FontWeights]::SemiBold }
            $lbl.Foreground   = if ($r.Success) { [Windows.Media.Brushes]::SeaGreen } else { [Windows.Media.Brushes]::Crimson }
            $lbl.VerticalAlignment = [Windows.VerticalAlignment]::Center
            $row.Children.Add($lbl) | Out-Null
            $resultItems.Children.Add($row) | Out-Null
        }

        $failed = @($results | Where-Object { -not $_.Success })
        if ($failed.Count) {
            $statusText.Text = "Finalizado com $($failed.Count) falha(s). Consulte o log."
        } else {
            $statusText.Text = 'Instalacao concluida com sucesso.'
        }
    })

    $window.Add_Closing({
        Remove-AllApplicationCache
    })

    $window.ShowDialog() | Out-Null
}

# ─────────────────────────────────────────────────────────────────────────────
# ENTRYPOINT
# ─────────────────────────────────────────────────────────────────────────────
try {
    if (-not $DryRun) { Request-Elevation }
    Load-Configuration
    Write-InstallLog "Aplicativo iniciado por $env:USERNAME em $env:COMPUTERNAME."
    if ($Silent) {
        $apps = Get-ProfileApplications $Profile
        if ($Applications) {
            $requestedIds   = @($Applications | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $unknownIds     = @($requestedIds | Where-Object { $_ -notin @($apps.Id) })
            if ($unknownIds.Count) { throw "Programa(s) desconhecido(s): $($unknownIds -join ', ')." }
            $apps = @($apps | Where-Object { $_.Id -in $requestedIds })
        }
        $results = Start-Installation -Applications $apps
        if (@($results | Where-Object { -not $_.Success }).Count) { exit 1 }
        exit 0
    }
    Show-MainWindow
} catch {
    try { Write-InstallLog $_.Exception.ToString() 'ERROR' } catch {}
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
    [Windows.MessageBox]::Show("Erro fatal: $($_.Exception.Message)`n`nLog: $script:LogFile",'Instalador Padrão','OK','Error') | Out-Null
    exit 1
} finally {
    Remove-AllApplicationCache
}

