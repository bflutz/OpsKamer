# 99-main.ps1 - Main menu loop + dispatch
# Split from Mission-Centre.ps1. Dot-sourced by the root script; relies on the
# script-scoped config globals ($ScanRoot, $Pi*, etc.) defined there.

function Start-MissionCentre {
    # @()-wrap: a 1-entry registry unwraps to a bare PSCustomObject on function return, and
    # under StrictMode PS 5.1 throws on scalar .Count (intrinsic members are exempt only in 6.1+).
    # Start-up work runs under the intro logo, one progress line per step (the root script
    # showed the logo just before calling us). The screen clears only when the menu is ready.
    [void](Invoke-McStartupStep 'checking for a newer Mission Centre' { Invoke-SelfUpdate })
    $config = @(Invoke-McStartupStep 'loading projects (shared registry)' { ,@(Import-ProjectConfig) })
    if ($AutoDormantEnabled) { [void](Invoke-AutoDormant ([ref]$config) $DormantIdleDays) }
    [void](Invoke-McStartupStep 'profiles and plugins' { Invoke-StartupDriftCheck })
    [void](Invoke-McStartupStep 'node security'        { Invoke-StartupNodeCheck })
    [void](Invoke-McStartupStep 'tool updates'         { Invoke-StartupToolUpdateCheck })
    Complete-McIntro
    $running = $true

    while ($running) {
        $script:McProjectCount = @($config).Count
        $script:McDormantCount = @($config | Where-Object { Test-ProjectDormant $_ }).Count
        Reset-McPanelCache
        Clear-Host
        $raw = Show-ProjectMenu $config
        if ($null -eq $raw) { $raw = '' }
        $raw = $raw.Trim()

        # Resolve the browse/find sub-views into a project selection (a stable number) or back.
        if ($raw.ToUpper() -eq 'A') {
            $raw = Show-AllProjects $config
        } elseif ($raw -like '/*') {
            $raw = Show-ProjectFilter $config $raw.Substring(1).Trim()
        }
        if ($null -eq $raw) { $raw = '' }
        # [D] from home or from the [A] list opens the dormant shelf.
        if ($raw.Trim().ToUpper() -eq 'O') {
            Show-OtherDeviceProjects ([ref]$config)
            continue
        }
        if ($raw.Trim().ToUpper() -eq 'D') {
            $raw = Show-DormantProjects ([ref]$config)
            if ($null -eq $raw) { $raw = '' }
        }
        $raw = $raw.Trim()
        if ($raw -eq '' -or $raw.ToUpper() -eq 'B') { continue }

        $rawUp = $raw.ToUpper()

        if ($rawUp -eq 'MATRIX') {
            Show-McMatrixRain
            continue
        } elseif ($rawUp -eq 'KAMER') {
            Show-McIntro -Hold
            continue
        }

        if ($rawUp -eq 'Q') {
            Write-Host ''
            Write-Host '  Goodbye.' -ForegroundColor DarkGray
            Write-Host ''
            $running = $false

        } elseif ($rawUp -eq 'M') {
            Start-MetaMission $config
            Start-Sleep -Seconds 1

        } elseif ($rawUp -eq 'MC') {
            Start-ContinueMission $ScanRoot $MetaProfile
            Start-Sleep -Seconds 1

        } elseif ($rawUp -eq 'MR') {
            Start-ResumePicker $ScanRoot $MetaProfile
            Start-Sleep -Seconds 1

        } elseif ($rawUp -eq 'H') {
            Clear-Host
            Invoke-EnvironmentHealth
            Read-Host '  Press Enter to continue'

        } elseif ($rawUp -eq 'G') {
            Clear-Host
            Install-StarterJigProfiles
            [void](Install-BundledSkills)
            Read-Host '  Press Enter to continue'

        } elseif ($rawUp -eq 'U') {
            Clear-Host
            Invoke-ToolUpdateMenu
            Read-Host '  Press Enter to continue'

        } elseif ($rawUp -eq 'SR') {
            Clear-Host
            Set-ScanRoot
            Read-Host '  Press Enter to continue'

        } elseif ($rawUp -eq 'NA') {
            Clear-Host
            Start-NewApp ([ref]$config)
            Read-Host '  Press Enter to continue'

        } elseif ($rawUp -eq 'N') {
            Clear-Host
            Add-NewProject ([ref]$config)
            Read-Host '  Press Enter to continue'

        } elseif ($rawUp -eq 'I') {
            Clear-Host
            Import-ExistingProject ([ref]$config)
            Read-Host '  Press Enter to continue'

        } elseif ($rawUp -eq 'S') {
            Clear-Host
            Sync-NewProjects ([ref]$config)
            Read-Host '  Press Enter to continue'

        } elseif ($raw -match '^\d+$') {
            $idx = [int]$raw - 1
            if ($idx -lt 0 -or $idx -ge @($config).Count) {
                Write-Host '  Invalid number.' -ForegroundColor Red
                Start-Sleep -Seconds 1
            } else {
                $project = $config[$idx]
                $inProject = $true

                while ($inProject) {
                    Clear-Host
                    Write-Banner
                    $prof = Get-OptionalProperty $project 'profile' $DefaultProfile
                    $action = Show-LaunchMenu $project

                    # Any launch from a dormant project reactivates it (it is in use again).
                    $launch = Resolve-LaunchAction $action $DefaultEngine
                    if ($launch -like 'pi-*' -and -not $PiEnabled) { $launch = '' }
                    if ($launch -or $action -in @('J', 'HA', 'HI') -or $action -match '^R\d+$') {
                        Resume-DormantProject ([ref]$config) $idx
                        $project = $config[$idx]
                    }

                    if ($launch -eq 'claude-new') {
                        Start-WithProfile  $project.path $prof (Get-ProjectName $project)
                        Start-Sleep -Seconds 1
                        $inProject = $false
                    } elseif ($launch -eq 'claude-continue') {
                        Start-ContinueMission $project.path $prof
                        Start-Sleep -Seconds 1
                        $inProject = $false
                    } elseif ($launch -eq 'claude-resume') {
                        Start-ResumePicker $project.path $prof
                        Start-Sleep -Seconds 1
                        $inProject = $false
                    } elseif ($action -eq 'J') {
                        Start-Jig          $project.path $prof
                        Start-Sleep -Seconds 1
                        $inProject = $false
                    } elseif ($launch -eq 'pi-new') {
                        Start-PiNewMission ([ref]$config) $idx
                        Start-Sleep -Seconds 1
                        $inProject = $false
                    } elseif ($launch -eq 'pi-continue') {
                        Start-PiContinue $project.path $prof
                        Start-Sleep -Seconds 1
                        $inProject = $false
                    } elseif ($launch -eq 'pi-resume') {
                        Start-PiResume   $project.path $prof
                        Start-Sleep -Seconds 1
                        $inProject = $false
                    } elseif ($action -match '^R(\d+)$') {
                        $ri = [int]$Matches[1] - 1
                        $sessions = @(Get-RecentSessions $project.path)
                        if ($ri -ge 0 -and $ri -lt $sessions.Count) {
                            Start-Resume $project.path $sessions[$ri].sessionId $prof
                            Start-Sleep -Seconds 1
                            $inProject = $false
                        } else {
                            Write-Host '  Invalid session number.' -ForegroundColor Red
                            Start-Sleep -Seconds 1
                        }
                    } elseif ($action -eq 'P') {
                        Invoke-ProfilePreflight $project.path $prof -Force | Out-Null
                        Read-Host '  Press Enter to continue'
                    } elseif ($action -eq 'X') {
                        Invoke-ContextSetup $project.path
                        Read-Host '  Press Enter to continue'
                    } elseif ($action -eq 'E') {
                        Open-ProjectFolder $project.path
                    } elseif ($action -eq 'RN') {
                        Edit-Project ([ref]$config) $idx
                        $project = $config[$idx]
                        Read-Host '  Press Enter to continue'
                    } elseif ($action -eq 'Z') {
                        $toDormant = -not (Test-ProjectDormant $project)
                        if ((Set-ProjectDormant ([ref]$config) @($idx) $toDormant) -gt 0) {
                            $msg = if ($toDormant) { 'Moved to dormant - find it under [D] on the home screen.' } else { 'Reactivated - back on the home screen.' }
                            Write-Host "  $msg" -ForegroundColor Green
                        }
                        $project = $config[$idx]
                        Start-Sleep -Seconds 1
                    } elseif ($action -eq 'RM') {
                        if (Remove-ProjectEntry ([ref]$config) $idx) {
                            Read-Host '  Press Enter to continue'
                            $inProject = $false   # entry gone; indexes shifted - back to the main list
                        } else {
                            Read-Host '  Press Enter to continue'
                        }
                    } elseif ($action -eq 'B') {
                        $inProject = $false
                    } else {
                        Write-Host '  Unknown option.' -ForegroundColor Red
                        Start-Sleep -Seconds 1
                    }
                }
            }

        } else {
            Write-Host '  Unknown option - pick a project number or a menu key ([/], A, D, M, MC, MR, N, I, S, SR, H, G, Q).' -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
}
