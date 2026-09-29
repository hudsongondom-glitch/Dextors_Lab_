# Dv.Flows.ps1 - Cloud Flow (workflow table, category=5 "Modern Flow") and solution-membership
# helpers for the Keepit solution-awareness experiment
# (recipes/powerplatform/build-flow-solution-testset.ps1). This lab's own Keepit automation has
# been removed and will be redesigned separately.
#
# Solution membership is a SEPARATE table (solutioncomponent) mapping componentid+componenttype
# to solutionid - it is many-to-many, so the SAME workflowid can sit in more than one unmanaged
# solution at once. That is exactly the mechanism this experiment probes: does Keepit's backup
# distinguish "one flow, two solutions" from "two flows (same definition, different id), one
# solution each" - and does a restore honour either shape.

$script:DvComponentTypeWorkflow = 29        # SolutionComponent.componenttype for Workflow/Cloud Flow
$script:DvWorkflowCategoryModernFlow = 5    # workflow.category for a Power Automate cloud flow

function Get-DvFlowById {
    param($Dv, [Parameter(Mandatory)][string]$WorkflowId)
    Invoke-DvRequest -Dv $Dv -Path "workflows($WorkflowId)?`$select=workflowid,name,category,clientdata,type,statecode,statuscode,ismanaged,primaryentity" `
        -Label 'dv-get-flow'
}

function Find-DvFlowByName {
    param($Dv, [Parameter(Mandatory)][string]$Name)
    $r = Get-DvRecords -Dv $Dv -Query "workflows?`$select=workflowid,name,category,statecode,statuscode&`$filter=name eq '$Name' and category eq $script:DvWorkflowCategoryModernFlow" `
        -Label 'dv-find-flow' -NoEvidence
    if ($r.Ok -and $r.Records.Count) { return $r.Records[0] }
    return $null
}

# Listing aid only - surfaced when no source flow was resolved, so the caller has real
# workflowids to pick from with -SourceFlowId instead of hitting a dead end.
function Get-DvModernFlows {
    param($Dv, [int]$Top = 15)
    Get-DvRecords -Dv $Dv -Query "workflows?`$select=workflowid,name,statecode,ismanaged&`$filter=category eq $script:DvWorkflowCategoryModernFlow&`$top=$Top" `
        -Label 'dv-list-flows' -NoEvidence
}

<#
Clones a flow definition into a NEW workflow record (new workflowid) - the API equivalent of the
maker portal's "Save As". Copies clientdata verbatim so the clone is a functionally identical but
independently-identified flow: same definition, different componentid. Left inactive (draft) -
activating it is not needed for a backup/solution-membership test and would require a real
connection reference resolution this lab does not attempt.
#>
function New-DvFlowClone {
    param($Dv, [Parameter(Mandatory)]$Source, [Parameter(Mandatory)][string]$NewName, [string]$Label = 'dv-clone-flow')
    $body = @{
        name          = $NewName
        category      = $Source.category
        type          = 1   # Definition
        clientdata    = $Source.clientdata
        # required on create and not nullable - 'none' is Dataverse's own placeholder for a
        # cloud flow that is not bound to a specific table (confirmed via the 0x80040200
        # validation error when this is omitted).
        primaryentity = if ($Source.primaryentity) { $Source.primaryentity } else { 'none' }
    }
    New-DvRecord -Dv $Dv -EntitySet 'workflows' -Body $body -Label $Label
}

<#
Adds an EXISTING component (e.g. a flow) to a solution WITHOUT moving or copying it - the
unbound AddSolutionComponent action (Web API name; the SDK message is AddSolutionComponentRequest).
This is how the same workflowid ends up in two different solutions at once.
#>
function Add-DvSolutionComponent {
    param(
        $Dv,
        [Parameter(Mandatory)][string]$ComponentId,
        [Parameter(Mandatory)][int]$ComponentType,
        [Parameter(Mandatory)][string]$SolutionUniqueName,
        [switch]$AddRequiredComponents,
        [string]$Label = 'dv-add-solution-component'
    )
    $body = @{
        ComponentId           = $ComponentId
        ComponentType         = $ComponentType
        SolutionUniqueName    = $SolutionUniqueName
        AddRequiredComponents = [bool]$AddRequiredComponents
    }
    # Confirmed live: DoNotIncludeSubcomponents is only valid when ComponentType=1 (Entity) -
    # Dataverse rejects it (0x80040216) on every other component type, Workflow included.
    if ($ComponentType -eq 1) { $body['DoNotIncludeSubcomponents'] = $true }
    Invoke-DvRequest -Dv $Dv -Method POST -Path 'AddSolutionComponent' -Body $body -Label $Label
}

function Get-DvSolutionComponents {
    param($Dv, [Parameter(Mandatory)][string]$SolutionId, [int]$ComponentType)
    $filter = "_solutionid_value eq $SolutionId"
    if ($ComponentType) { $filter += " and componenttype eq $ComponentType" }
    Get-DvRecords -Dv $Dv -Query "solutioncomponents?`$select=solutioncomponentid,objectid,componenttype&`$filter=$filter" `
        -Label 'dv-solution-components' -NoEvidence
}
