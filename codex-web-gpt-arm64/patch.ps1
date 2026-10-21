param([Parameter(Mandatory=$true)][string]$RepositoryRoot)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$utf8 = [Text.UTF8Encoding]::new($false)
function Patch([string]$File,[string]$Before,[string]$After) {
  $p = Join-Path $root $File
  $s = [IO.File]::ReadAllText($p).Replace(([string][char]13 + [char]10), [string][char]10)
  $Before = $Before.Replace(([string][char]13 + [char]10), [string][char]10)
  $After = $After.Replace(([string][char]13 + [char]10), [string][char]10)
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
# Protect previously installed AMD64 tunnel binaries. ARM64 uses its own
# executable and manifest, so a failed migration cannot overwrite the old one.
Patch 'src/tunnel.ts' @'
  return join(getConfigDir(), "bin", process.platform === "win32" ? "tunnel-client.exe" : "tunnel-client");
'@ @'
  const nativeArm64 = process.platform === "win32" && (
    process.arch === "arm64"
    || /^(ARM64|AARCH64)$/i.test(process.env.PROCESSOR_ARCHITECTURE ?? "")
    || /^(ARM64|AARCH64)$/i.test(process.env.PROCESSOR_ARCHITEW6432 ?? "")
  );
  return join(getConfigDir(), "bin", nativeArm64 ? "tunnel-client-arm64.exe"
    : process.platform === "win32" ? "tunnel-client.exe" : "tunnel-client");
'@
Patch 'src/tunnel.ts' @'
  return join(getConfigDir(), "bin", "tunnel-client-manifest.json");
'@ @'
  const nativeArm64 = process.platform === "win32" && (
    process.arch === "arm64"
    || /^(ARM64|AARCH64)$/i.test(process.env.PROCESSOR_ARCHITECTURE ?? "")
    || /^(ARM64|AARCH64)$/i.test(process.env.PROCESSOR_ARCHITEW6432 ?? "")
  );
  return join(getConfigDir(), "bin", nativeArm64
    ? "tunnel-client-arm64-manifest.json" : "tunnel-client-manifest.json");
'@
# Same-version repair of an earlier ARM64 build with the old shared tunnel path.
Patch 'launcher/electron/runtime.cjs' '    const activeTunnel = existing.config?.tunnel;' @'
    const activeTunnel = existing.config?.tunnel;
    const nativeArm64Tunnel = this.platform === "win32" && process.arch === "arm64"
      ? path.join(this.coreHome || path.join(os.homedir(), ".codex-chatgpt-web"), "bin", "tunnel-client-arm64.exe")
      : null;
    const tunnelArchitectureMigrationRequired = existing.mode === "full"
      && nativeArm64Tunnel !== null && typeof activeTunnel?.binaryPath === "string"
      && path.resolve(activeTunnel.binaryPath).toLowerCase() !== path.resolve(nativeArm64Tunnel).toLowerCase();
'@
Patch 'launcher/electron/runtime.cjs' @'
        && !tunnelProfileMigrationRequired
        && !architectureMigrationRequired)) {
'@ @'
        && !tunnelProfileMigrationRequired
        && !architectureMigrationRequired
        && !tunnelArchitectureMigrationRequired)) {
'@
Patch 'tests/tunnel.test.ts' @'
  const name = platform === "win32" ? "tunnel-client.exe" : "tunnel-client";
'@ @'
  const name = platform === "win32"
    ? process.arch === "arm64" ? "tunnel-client-arm64.exe" : "tunnel-client.exe"
    : "tunnel-client";
'@
Patch 'tests/tunnel.test.ts' @'
    const manifest = join(fixture.root, "bin", "tunnel-client-manifest.json");
    let writes = 0;
'@ @'
    const manifest = join(fixture.root, "bin",
      process.arch === "arm64" ? "tunnel-client-arm64-manifest.json" : "tunnel-client-manifest.json");
    let writes = 0;
'@
Patch 'tests/tunnel.test.ts' @'
    const manifest = join(fixture.root, "bin", "tunnel-client-manifest.json");
    const oldBinary = "trusted 0.0.12 binary";
'@ @'
    const manifest = join(fixture.root, "bin",
      process.arch === "arm64" ? "tunnel-client-arm64-manifest.json" : "tunnel-client-manifest.json");
    const oldBinary = "trusted 0.0.12 binary";
'@
Patch 'tests/tunnel.test.ts' @'
test("tunnel installation retries only transient Windows cleanup failures and leaves other staging files alone", async () => {
'@ @'
test("Windows ARM64 installation preserves legacy x64 tunnel credentials and executable", async () => {
  if (process.platform !== "win32" || process.arch !== "arm64") return;
  await withTunnelInstall("win32", async fixture => {
    const oldExecutable = join(fixture.root, "bin", "tunnel-client.exe");
    const oldManifest = join(fixture.root, "bin", "tunnel-client-manifest.json");
    const oldExeContent = Buffer.from("existing amd64 executable that must not be modified");
    const oldManifestContent = "legacy manifest that must not be modified";
    fs.writeFileSync(oldExecutable, oldExeContent);
    fs.writeFileSync(oldManifest, oldManifestContent);
    const installed = await installTunnelClient();
    expect(installed).toBe(fixture.executable);
    expect(installed).toContain("tunnel-client-arm64.exe");
    expect(fs.readFileSync(oldExecutable)).toEqual(oldExeContent);
    expect(fs.readFileSync(oldManifest, "utf8")).toBe(oldManifestContent);
    expect(fs.existsSync(join(fixture.root, "bin", "tunnel-client-arm64-manifest.json"))).toBe(true);
  });
});

test("tunnel installation retries only transient Windows cleanup failures and leaves other staging files alone", async () => {
'@
Write-Host 'Source patch complete; existing profiles are unchanged.'
