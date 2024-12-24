# Check if any apps need to be updated. If so, update them.
Write-Host "Checking if any apps need to be updated..." -ForegroundColor Blue

$updateResults = winget update
if ($updateResults -match "No installed package found matching input criteria.") {
    Write-Host "No apps found that need to be updated." -ForegroundColor Yellow
}
else {
    # Extract the names of the apps to be updated starting from index 11
    $appsToUpdate = $updateResults | Where-Object { $_ -match "^\S+\s+\S+\s+\S+\s+\S+\s+\S+$" -and $_ -ne "Name       Id                    Version   Available Source" } | ForEach-Object {
        $_.Split()[0]
    }
}

# Print update results formatted as an array
Write-Host "Formatted update results:" -ForegroundColor Green
$i = 0
$updateResults | ForEach-Object { 
    Write-Host "updateResults[$i] = $($_)" 
    $i++
}

# Print the names of the apps to be updated
Write-Host "Apps to update: $($appsToUpdate -join ', ')" -ForegroundColor Green

#  15.61.3.0