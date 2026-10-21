param([Parameter(Mandatory=$true)][string]$RepositoryRoot)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$utf8 = [Text.UTF8Encoding]::new($false)
function Patch([string]$File,[string]$Before,[string]$After) {
  $p = Join-Path $root $File
  $s = [IO.File]::ReadAllText($p).Replace(([string][char]13 + [char]10), [string][char]10)
  $count = $s.Split(@($Before), [StringSplitOptions]::None).Count - 1
  if ($count -ne 1) { throw "Expected one match, found $count in $File" }
  [IO.File]::WriteAllText($p, $s.Replace($Before,$After), $utf8)
  Write-Host "Patched $File"
}
Patch 'src/tunnel.ts' @'
  const arch = process.arch === "arm64" ? "arm64" : process.arch === "x64" ? "amd64" : undefined;
'@ @'
  const arm64Windows = process.platform === "win32" && (
    process.arch === "arm64" || /^(ARM64|AARCH64)$/i.test(process.env.PROCESSOR_ARCHITECTURE ?? "")
    || /^(ARM64|AARCH64)$/i.test(process.env.PROCESSOR_ARCHITEW6432 ?? "")
  );
  const arch = arm64Windows ? "arm64" : process.arch === "arm64" ? "arm64" : process.arch === "x64" ? "amd64" : undefined;
'@
Patch 'src/tunnel.ts' 'chmodSync, existsSync, mkdirSync, readFileSync, rmSync, statSync' 'chmodSync, existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync'
Patch 'src/tunnel.ts' 'if (action === "reuse") return executable;' 'if (action === "reuse" && manifest.asset === platformAsset()) return executable;'
Patch 'src/tunnel.ts' @'
  atomicWriteFile(stagedExecutable, binary);
  try {
    if (process.platform !== "win32") chmodSync(stagedExecutable, 0o700);
'@ @'
  if (process.platform === "win32") {
    writeFileSync(stagedExecutable, binary, { flag: "wx" });
  } else {
    atomicWriteFile(stagedExecutable, binary);
  }
  try {
    if (process.platform !== "win32") chmodSync(stagedExecutable, 0o700);
'@
Patch 'src/tunnel.ts' @'
    const version = runChecked(stagedExecutable, ["--version"], { timeout: 10_000 });
'@ @'
    let version: ReturnType<typeof runChecked> | undefined;
    const delays = process.platform === "win32" ? [0, 300, 1000, 2000] : [0];
    for (let i = 0; i < delays.length; i++) {
      if (delays[i] > 0) await new Promise(resolve => setTimeout(resolve, delays[i]));
      try {
        version = runChecked(stagedExecutable, ["--version"], { timeout: 10_000 });
        break;
      } catch (error) {
        if (i === delays.length - 1 || !["EACCES", "EPERM", "EBUSY"].includes((error as NodeJS.ErrnoException).code ?? "")) throw error;
      }
    }
    if (!version) throw new Error("Tunnel version check failed");
'@
Patch 'src/tunnel.ts' @'
    atomicWriteFile(executable, binary);
    if (process.platform !== "win32") chmodSync(executable, 0o700);
'@ @'
    if (process.platform === "win32" && !existsSync(executable)) {
      writeFileSync(executable, binary, { flag: "wx" });
    } else {
      atomicWriteFile(executable, binary);
    }
    if (process.platform !== "win32") chmodSync(executable, 0o700);
'@
Patch 'launcher/scripts/package.cjs' 'if (target === "--linux") {' @'
if (target === "--win") {
  if (!["x64", "arm64"].includes(process.arch)) throw new Error("Unsupported Windows architecture: " + process.arch);
  builderArgs.push("--" + process.arch);
  validateRuntimeBundle(path.join(root, "build", "runtime"), {
    version: launcherManifest.version,
    platform: "win32",
    arch: process.arch,
  });
}
if (target === "--linux") {
'@
Patch 'launcher/scripts/smoke-package.cjs' 'artifact(/-win-x64\.exe$/, "Windows installer")' 'artifact(new RegExp("-win-" + process.arch + "\\.exe$"), "Windows " + process.arch + " installer")'
Patch 'launcher/package.json' '"runAfterFinish": true' @'
"runAfterFinish": true,
    "deleteAppDataOnUninstall": false
'@
Patch 'launcher/electron/runtime.cjs' '    const interactionMode = existing.config?.browserInteractionMode ?? "automatic";' @'
    const interactionMode = existing.config?.browserInteractionMode ?? "automatic";
    const currentRuntimeRoot = this.runtimeRootProvider?.() ?? this.installedRuntimeRoot;
    const oldRuntime = existing.config?.runtimeCommand?.[0];
    const architectureMigrationRequired = this.platform === "win32"
      && typeof currentRuntimeRoot === "string" && typeof oldRuntime === "string"
      && !path.resolve(oldRuntime).toLowerCase().startsWith((path.resolve(currentRuntimeRoot) + path.sep).toLowerCase());
'@
Patch 'launcher/electron/runtime.cjs' @'
        && !connectorMigrationRequired
        && !tunnelProfileMigrationRequired)) {
'@ @'
        && !connectorMigrationRequired
        && !tunnelProfileMigrationRequired
        && !architectureMigrationRequired)) {
'@
Patch 'scripts/prepare-windows-baseline-bun.ps1' '[Parameter(Mandatory = $true)][string]$GitHubEnv' @'
[Parameter(Mandatory = $true)][string]$GitHubEnv,
  [ValidateSet("x64", "arm64")][string]$Architecture = "x64"
'@
Patch 'scripts/prepare-windows-baseline-bun.ps1' '$Asset = "bun-windows-x64-baseline.zip"' '$Asset = if ($Architecture -eq "arm64") { "bun-windows-aarch64.zip" } else { "bun-windows-x64-baseline.zip" }'
Patch 'scripts/prepare-windows-baseline-bun.ps1' '"codex-chatgpt-web-bun-baseline-$Version"' '"codex-chatgpt-web-bun-$Architecture-$Version"'
Patch 'scripts/prepare-windows-baseline-bun.ps1' '$_ -match "  bun-windows-x64-baseline\.zip$"' '$_ -match "  $([regex]::Escape($Asset))$"'
Write-Host 'Source patch complete; existing profiles are unchanged.'
