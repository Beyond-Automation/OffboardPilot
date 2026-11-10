# Contributing to OffboardPilot

Thanks for taking the time to look at this. OffboardPilot is a practical tool for real IT environments and contributions are welcome — whether that is a bug report, a step you verified in your lab, or a suggestion for how the workflow could be better.

---

## Ways to contribute

**Run the lab guide and report what you found.**  
The [README lab guide](README.md#lab-guide) is designed to work without a production environment. If you follow it and something behaves differently than documented — a step fails, a prompt is confusing, the reconciliation report shows something unexpected — open an issue and describe what you saw. This is the most valuable kind of contribution.

**Report a bug.**  
If the script produces an incorrect result, skips a step it should not, or throws an error in an environment that should be supported, open an issue. Include your PowerShell version, whether you are running the mailbox path or the AD-only path, and the relevant section of the transcript from `C:\Scripts\Logs\`.

**Suggest an improvement.**  
If you have an idea for a workflow that is not covered, or a way to make an existing step more reliable, open an issue and describe the problem you are trying to solve. The preference here is for practical suggestions grounded in real offboarding scenarios.

**Submit a pull request.**  
For anything beyond a typo fix, open an issue first so we can discuss the approach before you write code. PRs without a linked issue may be declined if the change conflicts with the design direction.

---

## What we are not looking for

- Wrappers or GUIs around the existing scripts
- Changes that add external dependencies beyond the three supported PowerShell modules
- Environment-specific code paths (hardcoded domain names, tenant IDs, OU paths)

---

## Opening an issue

Use a clear title that describes the problem or suggestion. For bugs:

- Which script: `Invoke-UserOffboard.ps1`, `Get-EXOGroupMembership.ps1`, or `Reset-TestAccount.ps1`
- Which path: mailbox user or AD-only user
- What you expected to happen
- What actually happened
- Relevant output from the reconciliation report or transcript

For lab test reports, describe the test scenario, your expected result, and your observed result. You do not need to have found a bug — confirming that a path works as documented is useful.

---

## Pull requests

- Keep changes focused. One fix or feature per PR.
- Follow the existing comment style — every section and non-obvious line should be explained.
- Scripts must remain compatible with PowerShell 5.1.
- Do not hardcode environment-specific values. Everything that varies by environment must be prompted at runtime or passed as a parameter.
- Test your change in a lab before submitting.

---

## First issue

Looking for a place to start? See the open issues labeled **good first issue**.
