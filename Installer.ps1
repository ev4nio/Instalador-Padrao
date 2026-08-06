#requires -version 5.1
param(
    [switch]$Elevated,
    [switch]$Silent,
    [ValidateSet('Padrao','SAC','SalaApoio')][string]$Profile = 'Padrao',
    [switch]$DryRun
)

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
    $cacheRoot = ([IO.Path]::GetFullPath($script:CacheRoot)).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $packageFullPath = [IO.Path]::GetFullPath($PackagePath)
    if (-not $packageFullPath.StartsWith($cacheRoot, [StringComparison]::OrdinalIgnoreCase)) { return }
    $cacheFolder = Split-Path -Parent $PackagePath
    if (Test-Path -LiteralPath $cacheFolder) {
        Remove-Item -LiteralPath $cacheFolder -Recurse -Force
        Write-InstallLog "Arquivos temporários removidos: $cacheFolder"
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
    if (Test-Path -LiteralPath $destination) {
        Write-InstallLog "Pacote temporário encontrado: $destination"
        return $destination
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
    $request = $null; $response = $null; $input = $null; $output = $null
    try {
        $request = [Net.HttpWebRequest]::Create($url)
        $request.UserAgent = 'InstaladorPadrao/1.1'
        $request.AllowAutoRedirect = $true
        $request.Timeout = 30000
        $request.ReadWriteTimeout = 30000
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
        if ($downloaded -le 0) { throw 'O servidor retornou um arquivo vazio.' }
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
    if ($Application.DetectionPath) {
        $path = [Environment]::ExpandEnvironmentVariables([string]$Application.DetectionPath)
        if (Test-Path -LiteralPath $path) { return $true }
    }
    if ($Application.DetectionDisplayName) {
        $roots = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
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

function Invoke-ProcessChecked {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments,
        [int[]]$SuccessExitCodes = @(0,1641,3010),
        [string]$WorkingDirectory
    )
    $displayArgs = if ($Arguments) { $Arguments } else { '(sem argumentos)' }
    Write-InstallLog "Executando: $FilePath $displayArgs"
    if ($DryRun) { Write-InstallLog 'Modo simulação: execução ignorada.' 'WARN'; return 0 }
    if (-not (Test-Path -LiteralPath $FilePath)) { throw "Arquivo não encontrado: $FilePath" }
    $params = @{ FilePath = $FilePath; ArgumentList = $Arguments; Wait = $true; PassThru = $true; WindowStyle = 'Hidden' }
    if ($WorkingDirectory) { $params.WorkingDirectory = $WorkingDirectory }
    $process = Start-Process @params
    if ($SuccessExitCodes -notcontains $process.ExitCode) { throw "Processo encerrou com código $($process.ExitCode)." }
    if ($process.ExitCode -in @(1641,3010)) { Write-InstallLog 'O instalador solicitou reinicialização.' 'WARN' }
    return $process.ExitCode
}

function Invoke-ApplicationInstall {
    param([Parameter(Mandatory)]$Application, [scriptblock]$ProgressCallback)
    Write-InstallLog "Iniciando: $($Application.Name)"
    if (-not $DryRun -and (Test-ApplicationInstalled $Application)) {
        Write-InstallLog "$($Application.Name) já está instalado; etapa ignorada." 'SUCCESS'
        return @{ Name=$Application.Name; Status='Já instalado'; Success=$true }
    }
    $packagePath = Invoke-PackageDownload -Application $Application -ProgressCallback $ProgressCallback
    $codes = @($Application.SuccessExitCodes | ForEach-Object { [int]$_ })
    if ($codes.Count -eq 0) { $codes = @(0,1641,3010) }
    $installationSucceeded = $false
    if ($Application.Type -eq 'Iso') {
        $isoPath = $packagePath
        if ($DryRun) {
            Write-InstallLog "Modo simulação: montaria a ISO $isoPath" 'WARN'
            return @{ Name=$Application.Name; Status='Simulado'; Success=$true }
        }
        if (-not (Test-Path -LiteralPath $isoPath)) { throw "ISO não encontrada: $isoPath" }
        $image = $null
        try {
            $image = Mount-DiskImage -ImagePath $isoPath -PassThru
            $volume = $image | Get-Volume
            if (-not $volume.DriveLetter) { throw 'A ISO foi montada, mas não recebeu uma letra de unidade.' }
            $setup = Join-Path ($volume.DriveLetter + ':\') ([string]$Application.SetupRelativePath)
            Invoke-ProcessChecked -FilePath $setup -Arguments ([string]$Application.Arguments) -SuccessExitCodes $codes -WorkingDirectory (Split-Path $setup) | Out-Null
        } finally {
            if ($image) { Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue }
        }
    } elseif ($Application.Type -eq 'OfficeOdt') {
        $odtFolder = Split-Path -Parent $packagePath
        $setup = Join-Path $odtFolder 'setup.exe'
        if (-not (Test-Path -LiteralPath $setup)) {
            Invoke-ProcessChecked -FilePath $packagePath -Arguments ('/quiet /extract:"{0}"' -f $odtFolder) -SuccessExitCodes @(0) -WorkingDirectory $odtFolder | Out-Null
        }
        Invoke-ProcessChecked -FilePath $setup -Arguments ([string]$Application.Arguments) -SuccessExitCodes $codes -WorkingDirectory $odtFolder | Out-Null
    } elseif ($Application.Type -eq 'Msi') {
        $file = $packagePath
        $msiArgs = '/i "{0}" {1}' -f $file, ([string]$Application.Arguments)
        Invoke-ProcessChecked -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -Arguments $msiArgs -SuccessExitCodes $codes -WorkingDirectory (Split-Path $file) | Out-Null
    } else {
        $file = $packagePath
        Invoke-ProcessChecked -FilePath $file -Arguments ([string]$Application.Arguments) -SuccessExitCodes $codes -WorkingDirectory (Split-Path $file) | Out-Null
    }
    $installationSucceeded = $true
    if ($installationSucceeded -and -not $DryRun) { Remove-ApplicationCache -PackagePath $packagePath }
    Write-InstallLog "$($Application.Name) concluído." 'SUCCESS'
    return @{ Name=$Application.Name; Status=($(if ($DryRun) {'Simulado'} else {'Concluído'})); Success=$true }
}

function Get-ProfileApplications {
    param([string]$SelectedProfile)
    $ids = @($script:Config.Profiles.$SelectedProfile)
    return @($script:Config.Applications | Where-Object { $ids -contains $_.Id })
}

function Start-Installation {
    param([array]$Applications, [scriptblock]$StatusCallback)
    $results = @()
    Write-InstallLog "Sessão iniciada. Perfil: $Profile; Simulação: $DryRun"
    $index = 0
    foreach ($app in $Applications) {
        $basePercent = ($index * 100.0) / [Math]::Max(1,$Applications.Count)
        $spanPercent = 100.0 / [Math]::Max(1,$Applications.Count)
        if ($StatusCallback) { & $StatusCallback "Preparando $($app.Name)..." $basePercent }
        $appCallback = { param($text,$itemPercent) if ($StatusCallback) { & $StatusCallback $text ($basePercent + (($itemPercent/100.0)*$spanPercent*0.65)) } }
        try {
            $results += Invoke-ApplicationInstall $app -ProgressCallback $appCallback
        } catch {
            $message = "$($app.Name): $($_.Exception.Message)"
            Write-InstallLog $message 'ERROR'
            $results += @{ Name=$app.Name; Status='Falhou'; Success=$false; Error=$_.Exception.Message }
            if (-not [bool]$script:Config.ContinueOnError) { break }
        }
        $index++
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

function Show-MainWindow {
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="Instalador Padrão" Height="650" Width="820" WindowStartupLocation="CenterScreen" ResizeMode="CanMinimize" Background="#F4F6F9">
 <Grid Margin="22"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <StackPanel><TextBlock Text="Instalador de programas" FontSize="27" FontWeight="SemiBold" Foreground="#172033"/><TextBlock Text="Escolha um perfil e confira os componentes antes de iniciar." Margin="0,5,0,18" Foreground="#5E687A"/></StackPanel>
  <Grid Grid.Row="1" Margin="0,0,0,14"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="Perfil de instalação" FontWeight="SemiBold"/><ComboBox Name="ProfileBox" Width="280" HorizontalAlignment="Left" Margin="0,6,0,0"><ComboBoxItem Tag="Padrao">Instalação padrão</ComboBoxItem><ComboBoxItem Tag="SAC">SAC</ComboBoxItem><ComboBoxItem Tag="SalaApoio">Sala de apoio</ComboBoxItem></ComboBox></StackPanel><CheckBox Name="DryRunBox" Grid.Column="1" Content="Modo simulação" VerticalAlignment="Bottom" Margin="25,0,0,7" ToolTip="Gera o log sem executar os instaladores."/></Grid>
  <Border Grid.Row="2" Background="White" BorderBrush="#D9DEE8" BorderThickness="1" CornerRadius="7" Padding="16"><DockPanel><TextBlock DockPanel.Dock="Top" Text="Prévia — desmarque o que não quiser instalar" FontWeight="SemiBold" Margin="0,0,0,12"/><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Name="AppsPanel"/></ScrollViewer></DockPanel></Border>
  <StackPanel Grid.Row="3" Margin="0,14,0,12"><ProgressBar Name="Progress" Height="8" Minimum="0" Maximum="100"/><TextBlock Name="StatusText" Text="Pronto para iniciar." Margin="0,7,0,0" Foreground="#5E687A"/></StackPanel>
  <Grid Grid.Row="4"><Button Name="LogButton" Content="Abrir pasta de logs" HorizontalAlignment="Left" Padding="16,9"/><StackPanel Orientation="Horizontal" HorizontalAlignment="Right"><Button Name="CloseButton" Content="Fechar" Padding="20,9" Margin="0,0,10,0"/><Button Name="InstallButton" Content="Instalar selecionados" Padding="20,9" Background="#1769E0" Foreground="White" FontWeight="SemiBold"/></StackPanel></Grid>
 </Grid>
</Window>
'@
    $reader = [Xml.XmlNodeReader]::new($xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $profileBox = $window.FindName('ProfileBox'); $appsPanel = $window.FindName('AppsPanel')
    $installButton = $window.FindName('InstallButton'); $closeButton = $window.FindName('CloseButton')
    $logButton = $window.FindName('LogButton'); $progress = $window.FindName('Progress')
    $statusText = $window.FindName('StatusText'); $dryRunBox = $window.FindName('DryRunBox')
    $script:checkBoxes = @{}
    $refresh = {
        $appsPanel.Children.Clear(); $script:checkBoxes = @{}
        $tag = [string](($profileBox.SelectedItem).Tag)
        foreach ($app in (Get-ProfileApplications $tag)) {
            $cb = [Windows.Controls.CheckBox]::new(); $cb.Content = $app.Name; $cb.IsChecked = $true; $cb.Tag = $app.Id; $cb.Margin = '2,7,2,7'; $cb.FontSize = 14
            $appsPanel.Children.Add($cb) | Out-Null; $script:checkBoxes[$app.Id] = $cb
        }
    }
    $dryRunBox.IsChecked = $DryRun
    $profileBox.Add_SelectionChanged($refresh); $profileBox.SelectedIndex = 0
    $closeButton.Add_Click({ $window.Close() })
    $logButton.Add_Click({ if (-not (Test-Path $LogRoot)) { New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null }; Start-Process explorer.exe $LogRoot })
    $installButton.Add_Click({
        $selectedTag = [string](($profileBox.SelectedItem).Tag); $script:Profile = $selectedTag; $script:DryRun = [bool]$dryRunBox.IsChecked
        $selected = @(Get-ProfileApplications $selectedTag | Where-Object { $script:checkBoxes[$_.Id].IsChecked })
        if (-not $selected.Count) { [Windows.MessageBox]::Show('Selecione pelo menos um programa.','Nada selecionado','OK','Warning'); return }
        $answer = [Windows.MessageBox]::Show("Iniciar a instalação de $($selected.Count) programa(s)?",'Confirmação','YesNo','Question')
        if ($answer -ne 'Yes') { return }
        $installButton.IsEnabled = $false; $profileBox.IsEnabled = $false; $progress.Value = 5
        $callback = { param($text,$percent) $statusText.Text=$text; $progress.Value=[Math]::Min(99,[Math]::Max(0,$percent)); $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background) }
        $results = Start-Installation -Applications $selected -StatusCallback $callback
        $progress.Value = 100; $installButton.IsEnabled = $true; $profileBox.IsEnabled = $true
        $failed = @($results | Where-Object { -not $_.Success })
        if ($failed.Count) {
            $statusText.Text = "Finalizado com $($failed.Count) falha(s). Consulte o log."
            [Windows.MessageBox]::Show("A instalação terminou com falhas.`n`nLog: $script:LogFile",'Instalação incompleta','OK','Error')
        } else {
            $statusText.Text = 'Instalação concluída com sucesso.'
            [Windows.MessageBox]::Show("Instalação concluída.`n`nLog: $script:LogFile",'Concluído','OK','Information')
        }
    })
    $window.ShowDialog() | Out-Null
}

try {
    if (-not $DryRun) { Request-Elevation }
    Load-Configuration
    Write-InstallLog "Aplicativo iniciado por $env:USERNAME em $env:COMPUTERNAME."
    if ($Silent) {
        $apps = Get-ProfileApplications $Profile
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
}
