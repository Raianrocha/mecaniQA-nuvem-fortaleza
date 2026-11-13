$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$evidenceRoot = Join-Path $repoRoot "evidencias"
$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$runDirectory = Join-Path $evidenceRoot ("stress-" + $runId)
$context = (kubectl config current-context).Trim()
$expectedContext = "docker-desktop"
$kubectlPath = (Get-Command kubectl).Source
$watchProcesses = @()
$grafanaProcess = $null
$grafanaHeaders = $null
$phaseResults = @()
$observedAlertNames = @()
$originalEnvironment = @{
    CPU_WORK_ITERATIONS = "100"
    MEMORY_WORK_MB = "0"
    SIMULATED_ERROR_RATE = "0"
    PROCESSING_DELAY_SECONDS = "0"
}

function Write-LogHeader {
    param([string]$Path, [string]$Text)
    Add-Content -LiteralPath $Path -Value ("[{0}] {1}" -f (Get-Date -Format o), $Text)
}

function Invoke-KubectlCapture {
    param([string]$Path, [string[]]$KubectlArgs)
    Write-LogHeader -Path $Path -Text ("kubectl " + ($KubectlArgs -join " "))
    $result = & kubectl @KubectlArgs 2>&1
    $exitCode = $LASTEXITCODE
    $result | Out-File -LiteralPath $Path -Append -Encoding utf8
    if ($exitCode -ne 0) {
        throw ("kubectl {0} failed with exit code {1}" -f ($KubectlArgs -join " "), $exitCode)
    }
}

function Get-DeploymentEnvironment {
    $json = kubectl get deployment iot-simulator -o json | ConvertFrom-Json
    $container = $json.spec.template.spec.containers | Where-Object { $_.name -eq "simulator" }
    $result = @{}
    foreach ($item in $container.env) {
        if ($originalEnvironment.ContainsKey($item.name)) {
            $result[$item.name] = $item.value
        }
    }
    return $result
}

function Set-DeploymentEnvironment {
    param([hashtable]$Values)
    $arguments = @("set", "env", "deployment/iot-simulator")
    foreach ($name in $Values.Keys) {
        $arguments += ($name + "=" + $Values[$name])
    }
    & kubectl @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set simulator test environment."
    }
    kubectl rollout status deployment/iot-simulator --timeout=120s
    if ($LASTEXITCODE -ne 0) {
        throw "Simulator rollout did not finish."
    }
}

function Start-ResourceWatchers {
    $hpaLog = Join-Path $runDirectory "hpa-watch.log"
    $podsLog = Join-Path $runDirectory "pods-watch.log"
    $script:watchProcesses += Start-Process -FilePath $kubectlPath `
        -ArgumentList @("get", "hpa", "iot-simulator", "--watch") `
        -PassThru -RedirectStandardOutput $hpaLog -RedirectStandardError (Join-Path $runDirectory "hpa-watch.err")
    $script:watchProcesses += Start-Process -FilePath $kubectlPath `
        -ArgumentList @("get", "pods", "-l", "app=iot-simulator", "--watch", "-o", "wide") `
        -PassThru -RedirectStandardOutput $podsLog -RedirectStandardError (Join-Path $runDirectory "pods-watch.err")
    Write-LogHeader -Path (Join-Path $runDirectory "README.md") -Text "Started kubectl get hpa iot-simulator --watch and kubectl get pods --watch at $(Get-Date -Format o)."
}

function Start-GrafanaAccess {
    $out = Join-Path $runDirectory "grafana-port-forward.out"
    $err = Join-Path $runDirectory "grafana-port-forward.err"
    $script:grafanaProcess = Start-Process -FilePath $kubectlPath `
        -ArgumentList @("port-forward", "service/grafana", "13000:3000") `
        -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        try {
            $health = Invoke-RestMethod -Uri "http://127.0.0.1:13000/api/health" -TimeoutSec 2
            if ($health.database -eq "ok") {
                $encodedPassword = kubectl get secret grafana-admin -o jsonpath='{.data.password}'
                $password = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedPassword))
                $auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("admin:$password"))
                $script:grafanaHeaders = @{ Authorization = "Basic $auth" }
                Remove-Variable password,encodedPassword,auth -ErrorAction SilentlyContinue
                return
            }
        }
        catch {}
        Start-Sleep -Seconds 1
    }
    throw "Grafana API is not reachable through the local port-forward."
}

function Capture-GrafanaAlerts {
    $alertLog = Join-Path $runDirectory "grafana-alert-states.jsonl"
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            if ($attempt -gt 0) {
                if ($script:grafanaProcess -and -not $script:grafanaProcess.HasExited) {
                    Stop-Process -Id $script:grafanaProcess.Id -Force
                }
                Start-GrafanaAccess
            }
            $alerts = Invoke-RestMethod `
                -Uri "http://127.0.0.1:13000/api/alertmanager/grafana/api/v2/alerts" `
                -Headers $grafanaHeaders -TimeoutSec 5
            $snapshot = [pscustomobject]@{
                capturedAt = (Get-Date -Format o)
                alerts = @($alerts | ForEach-Object {
                    [pscustomobject]@{
                        labels = $_.labels
                        annotations = $_.annotations
                        status = $_.status
                        startsAt = $_.startsAt
                        endsAt = $_.endsAt
                    }
                })
            }
            $snapshot | ConvertTo-Json -Depth 8 -Compress | Add-Content -LiteralPath $alertLog
            $script:observedAlertNames += @($alerts | ForEach-Object {
                if ($_.labels.alertname) {
                    $_.labels.alertname
                }
            })
            return
        }
        catch {
            if ($attempt -eq 1) {
                Write-LogHeader -Path (Join-Path $runDirectory "grafana-alert-states.err") -Text $_.ToString()
            }
        }
    }
}

function Invoke-LoadPhase {
    param(
        [string]$Name,
        [hashtable]$Environment,
        [int]$Duration,
        [int]$Rate,
        [int]$Concurrency,
        [switch]$ExpectFailures
    )

    $podName = "iot-load-" + $Name
    $loadLog = Join-Path $runDirectory ($Name + "-load.log")
    $topLog = Join-Path $runDirectory ($Name + "-top-pods.log")
    $podsLog = Join-Path $runDirectory ($Name + "-pods.log")
    $eventsLog = Join-Path $runDirectory ($Name + "-events.log")
    $nextAlertsCapture = (Get-Date).AddSeconds(30)

    Set-DeploymentEnvironment -Values $Environment
    $command = @(
        "run", $podName, "--restart=Never",
        "--image=mecaniqa-iot-simulator:latest",
        "--image-pull-policy=IfNotPresent",
        "--command", "--", "python", "load_test.py",
        "--url", "http://iot-simulator:8080/readings",
        "--duration", "$Duration", "--rate", "$Rate", "--concurrency", "$Concurrency"
    )
    Write-LogHeader -Path $loadLog -Text ("kubectl " + ($command -join " "))
    & kubectl @command 2>&1 | Out-File -LiteralPath $loadLog -Append -Encoding utf8
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create the in-cluster load pod $podName."
    }

    $deadline = (Get-Date).AddSeconds($Duration + 120)
    $nextEventsCapture = (Get-Date).AddSeconds(30)
    $phase = ""
    while ((Get-Date) -lt $deadline) {
        $phase = (kubectl get pod $podName -o jsonpath='{.status.phase}' 2>$null)
        if ($LASTEXITCODE -eq 0 -and $phase -in @("Succeeded", "Failed")) {
            break
        }

        Write-LogHeader -Path $topLog -Text "kubectl top pods -l app=iot-simulator"
        kubectl top pods -l app=iot-simulator 2>&1 | Out-File -LiteralPath $topLog -Append -Encoding utf8
        Write-LogHeader -Path $podsLog -Text "kubectl get pods -l app=iot-simulator -o wide"
        kubectl get pods -l app=iot-simulator -o wide 2>&1 | Out-File -LiteralPath $podsLog -Append -Encoding utf8

        if ((Get-Date) -ge $nextEventsCapture) {
            Write-LogHeader -Path $eventsLog -Text "kubectl get events --sort-by=.lastTimestamp"
            kubectl get events --sort-by=.lastTimestamp 2>&1 | Out-File -LiteralPath $eventsLog -Append -Encoding utf8
            $nextEventsCapture = (Get-Date).AddSeconds(30)
        }
        if ((Get-Date) -ge $nextAlertsCapture) {
            Capture-GrafanaAlerts
            $nextAlertsCapture = (Get-Date).AddSeconds(30)
        }
        Start-Sleep -Seconds 10
    }

    if ($phase -notin @("Succeeded", "Failed")) {
        throw "Load pod $podName exceeded the test timeout."
    }

    Write-LogHeader -Path $loadLog -Text ("Load pod terminal phase: " + $phase)
    kubectl describe pod $podName 2>&1 | Out-File -LiteralPath (Join-Path $runDirectory ($Name + "-pod-describe.log")) -Encoding utf8
    $loadOutput = kubectl logs $podName --timestamps 2>&1
    $loadOutput | Out-File -LiteralPath $loadLog -Append -Encoding utf8
    $script:phaseResults += [pscustomobject]@{
        Name = $Name
        Phase = $phase
        ExpectedFailures = [bool]$ExpectFailures
    }
    $loadText = $loadOutput -join "`n"
    if ($phase -eq "Failed" -and $ExpectFailures -and $loadText -notmatch 'failed=[1-9]\d*') {
        throw "Load pod $podName failed without expected rejected readings."
    }
    if ($phase -eq "Failed" -and -not $ExpectFailures) {
        throw "Load pod $podName failed unexpectedly."
    }
    if ($phase -eq "Succeeded" -and $ExpectFailures) {
        Write-LogHeader -Path $loadLog -Text "No failed requests occurred; error-rate alert may not have been exercised."
    }
}

New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
$summaryPath = Join-Path $runDirectory "README.md"
$capturedEnvironment = $null
$testFailure = $null

try {
    if ($context -ne $expectedContext) {
        throw ("Safety check: expected context '{0}', got '{1}'." -f $expectedContext, $context)
    }
    $capturedEnvironment = Get-DeploymentEnvironment
    kubectl top nodes | Out-File -LiteralPath (Join-Path $runDirectory "preflight-top-nodes.log") -Encoding utf8
    if ($LASTEXITCODE -ne 0) {
        throw "Metrics API unavailable; refusing to run stress test."
    }
    docker image inspect mecaniqa-iot-simulator:latest --format '{{.Id}}' |
        Out-File -LiteralPath (Join-Path $runDirectory "image-id.log") -Encoding utf8
    kubectl exec deployment/iot-simulator -- python -c "import inspect, simulator; raise SystemExit(0 if 'PROCESSING_DELAY_SECONDS' in inspect.getsource(simulator.ReadingHandler.do_POST) else 1)"
    if ($LASTEXITCODE -ne 0) {
        throw "The cluster simulator image lacks latency instrumentation. Load the rebuilt image into the local Kubernetes node and retry."
    }

    Set-DeploymentEnvironment -Values $originalEnvironment
    $baselineDeadline = (Get-Date).AddMinutes(10)
    while ((Get-Date) -lt $baselineDeadline) {
        $replicas = kubectl get hpa iot-simulator -o jsonpath='{.status.currentReplicas}'
        $desired = kubectl get hpa iot-simulator -o jsonpath='{.status.desiredReplicas}'
        if ($replicas -eq "2" -and $desired -eq "2") {
            break
        }
        Start-Sleep -Seconds 15
    }
    if ($replicas -ne "2" -or $desired -ne "2") {
        throw "HPA did not return to its 2-replica baseline."
    }

    Start-ResourceWatchers
    Start-GrafanaAccess
    Capture-GrafanaAlerts
    Invoke-LoadPhase -Name "cpu-memory-errors" `
        -Environment @{
            CPU_WORK_ITERATIONS = "30000"
            MEMORY_WORK_MB = "0"
            SIMULATED_ERROR_RATE = "0.1"
            PROCESSING_DELAY_SECONDS = "0"
        } -Duration 480 -Rate 150 -Concurrency 32 -ExpectFailures

    Invoke-LoadPhase -Name "latency" `
        -Environment @{
            CPU_WORK_ITERATIONS = "100"
            MEMORY_WORK_MB = "80"
            SIMULATED_ERROR_RATE = "0"
            PROCESSING_DELAY_SECONDS = "0.9"
        } -Duration 480 -Rate 50 -Concurrency 64
}
catch {
    $testFailure = $_
    Write-LogHeader -Path (Join-Path $runDirectory "failure.log") -Text $_.ToString()
}
finally {
    if ($null -ne $capturedEnvironment) {
        try {
            Set-DeploymentEnvironment -Values $capturedEnvironment
            Write-LogHeader -Path (Join-Path $runDirectory "cleanup.log") -Text "Restored the captured simulator environment."
        }
        catch {
            Write-LogHeader -Path (Join-Path $runDirectory "cleanup.log") -Text ("Restore failed: " + $_.ToString())
        }
    }

    foreach ($name in @("iot-load-cpu-memory-errors", "iot-load-latency")) {
        kubectl logs $name --timestamps 2>&1 |
            Out-File -LiteralPath (Join-Path $runDirectory ($name + "-final.log")) -Encoding utf8
        kubectl delete pod $name --ignore-not-found 2>&1 |
            Out-File -LiteralPath (Join-Path $runDirectory "cleanup.log") -Append -Encoding utf8
    }

    $recoveryLog = Join-Path $runDirectory "recovery.log"
    $recoveryDeadline = (Get-Date).AddMinutes(10)
    while ((Get-Date) -lt $recoveryDeadline) {
        $replicas = kubectl get hpa iot-simulator -o jsonpath='{.status.currentReplicas}'
        $desired = kubectl get hpa iot-simulator -o jsonpath='{.status.desiredReplicas}'
        Write-LogHeader -Path $recoveryLog -Text ("HPA current={0} desired={1}" -f $replicas, $desired)
        kubectl top pods -l app=iot-simulator 2>&1 |
            Out-File -LiteralPath (Join-Path $runDirectory "recovery-top-pods.log") -Append -Encoding utf8
        kubectl get pods -l app=iot-simulator -o wide 2>&1 |
            Out-File -LiteralPath (Join-Path $runDirectory "recovery-pods.log") -Append -Encoding utf8
        if ($replicas -eq "2" -and $desired -eq "2") {
            break
        }
        Start-Sleep -Seconds 15
    }

    foreach ($process in $watchProcesses) {
        if ($null -ne $process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force
        }
        if ($grafanaProcess -and -not $grafanaProcess.HasExited) {
            Stop-Process -Id $grafanaProcess.Id -Force
        }
    }

    kubectl get pods,svc,hpa -o wide 2>&1 |
        Out-File -LiteralPath (Join-Path $runDirectory "final-resources.log") -Encoding utf8
    kubectl top pods 2>&1 |
        Out-File -LiteralPath (Join-Path $runDirectory "final-top-pods.log") -Encoding utf8
    $expectedAlertNames = @(
        "IoT simulator CPU above 80% of request",
        "IoT simulator memory above 85% of request",
        "IoT reading error ratio above 5%",
        "IoT reading p95 processing latency above 800ms"
    )
    $uniqueObservedAlerts = @($observedAlertNames | Sort-Object -Unique)
    $missingAlerts = @($expectedAlertNames | Where-Object { $uniqueObservedAlerts -notcontains $_ })
    @(
        "# MecaniQA stress test evidence",
        "",
        "- Run: $runId",
        "- Kubernetes context: $context",
        "- Target: `http://iot-simulator:8080/readings` inside the local cluster only.",
        "- Phases: CPU/error injection (480s, 150 req/s, concurrency 32); memory/latency injection (480s, 50 req/s, concurrency 64).",
        "- Injection parameters are lab-only and the captured simulator environment is restored by the script.",
        "- Phase results: $($phaseResults | ConvertTo-Json -Compress)",
        "- Grafana alert names observed firing: $($uniqueObservedAlerts -join ', ')",
        "- Expected alert names not observed firing: $($missingAlerts -join ', ')",
        "- Review `hpa-watch.log`, `pods-watch.log`, both `*-top-pods.log` files, load logs, events, `grafana-alert-states.jsonl`, and final resources.",
        "- Grafana alert-state snapshots are captured every 30 seconds; alert rules have a five-minute pending duration.",
        ""
    ) | Set-Content -LiteralPath $summaryPath -Encoding utf8
}

Write-Output ("Evidence saved to " + $runDirectory)
if ($null -ne $testFailure) {
    throw $testFailure
}
