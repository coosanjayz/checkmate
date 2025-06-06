# === CONFIGURATION ===
$Pat = "5CAAAAAAAAAAAAASAZDO4Hj9"
$Org = "WFTC-DataMart"
$Project = "CODE-MuleSoftESB"
$BaseUri = "https://dev.azure.com/$Org/$Project"
$EncodedPat = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
$Headers = @{
    Authorization = "Basic $EncodedPat"
    "Content-Type" = "application/json"
}
$BranchRef = "refs/heads/release/mule-4.9.4"

# === LOAD REPO LIST ===
$RepoFilePath = "repo-list.txt"
if (-Not (Test-Path $RepoFilePath)) {
    Write-Error "❌ repo-list.txt not found."
    exit 1
}
$TargetRepoNames = Get-Content $RepoFilePath | Where-Object { $_ -and -not $_.StartsWith("#") } | ForEach-Object { ($_ -split "/")[-1].Trim() }

# === FETCH ALL REPOS ===
$reposUri = "$BaseUri/_apis/git/repositories?api-version=7.1-preview.1"
$Repos = (Invoke-RestMethod -Uri $reposUri -Headers $Headers).value |
    Where-Object { $_.defaultBranch -ne $null -and $TargetRepoNames -contains $_.name }

# === FETCH ALL PIPELINES ===
$pipelinesUri = "$BaseUri/_apis/pipelines?api-version=7.1-preview.1"
$AllPipelines = (Invoke-RestMethod -Uri $pipelinesUri -Headers $Headers).value

# === FETCH ALL POLICIES ONCE ===
$policyUri = "$BaseUri/_apis/policy/configurations?api-version=7.1-preview.1"
$allPolicies = (Invoke-RestMethod -Uri $policyUri -Headers $Headers).value
$buildValidationPolicies = $allPolicies | Where-Object {
    $_.type.id -eq "0609b952-1397-4640-95ec-e00a01b2c241"
}

# === PROCESS EACH REPO ===
foreach ($repo in $Repos) {
    $repoName = $repo.name
    $repoId = $repo.id
    Write-Host "`n🔍 Processing $repoName..."

    # === CREATE release/mule-4.9.4 BRANCH IF NOT EXISTS ===
    $releaseBranchUri = "$BaseUri/_apis/git/repositories/$repoId/refs?filter=heads/release/mule-4.9.4&api-version=7.1-preview.1"
    $releaseBranch = (Invoke-RestMethod -Uri $releaseBranchUri -Headers $Headers).value
    if (-not $releaseBranch) {
        $mainRefUri = "$BaseUri/_apis/git/repositories/$repoId/refs?filter=heads/main&api-version=7.1-preview.1"
        $mainRef = (Invoke-RestMethod -Uri $mainRefUri -Headers $Headers).value | Where-Object { $_.name -eq "refs/heads/main" }
        if (-not $mainRef) {
            Write-Host "⚠️ Main branch not found. Skipping $repoName"
            continue
        }

        $mainObjectId = $mainRef.objectId
        $branchBody = @(
            @{
                name = $BranchRef
                oldObjectId = "0000000000000000000000000000000000000000"
                newObjectId = $mainObjectId
            }
        ) | ConvertTo-Json -Depth 10

        try {
            Invoke-RestMethod -Uri "$BaseUri/_apis/git/repositories/$repoId/refs?api-version=7.1-preview.1" -Headers $Headers -Method Post -Body $branchBody
            Write-Host "✅ Created $BranchRef"
        } catch {
            Write-Host "❌ Error creating branch: $($_.Exception.Message)"
            continue
        }
    } else {
        Write-Host "ℹ️ Branch already exists"
    }

    # === FIND MATCHING PR PIPELINE ===
    $pipeline = $AllPipelines | Where-Object { $_.name -like "$repoName*_PR_Pipeline" }
    if (-not $pipeline) {
        Write-Host "⚠️ Pipeline not found for $repoName"
        continue
    }
    $pipelineId = $pipeline.id

    # === CHECK IF BUILD VALIDATION POLICY EXISTS ===
    $policyExists = $false
    foreach ($policy in $buildValidationPolicies) {
        if ($policy.settings.buildDefinitionId -eq $pipelineId) {
            foreach ($scope in $policy.settings.scope) {
                if ($scope.repositoryId -eq $repoId -and $scope.refName -eq $BranchRef) {
                    $policyExists = $true
                    break
                }
            }
        }
        if ($policyExists) { break }
    }

    if ($policyExists) {
        Write-Host "✔️ Build validation already exists for $repoName. Skipping."
        continue
    }

    # === APPLY NEW BUILD VALIDATION POLICY ===
    $policyBody = @{
        isEnabled = $true
        isBlocking = $true
        type = @{ id = "0609b952-1397-4640-95ec-e00a01b2c241" }
        settings = @{
            buildDefinitionId = $pipelineId
            queueOnSourceUpdateOnly = $true
            manualQueueOnly = $false
            displayName = "$repoName PR Validation"
            validDuration = 720
            scope = @(@{
                repositoryId = $repoId
                refName = $BranchRef
                matchKind = "exact"
            })
        }
    } | ConvertTo-Json -Depth 10

    try {
        Invoke-RestMethod -Uri $policyUri -Headers $Headers -Method POST -Body $policyBody
        Write-Host "✅ Build validation policy applied for $repoName"
    } catch {
        Write-Host "❌ Failed to apply policy: $($_.Exception.Message)"
    }
}
