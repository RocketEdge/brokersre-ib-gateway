# Reduce a Trivy JSON report (SchemaVersion 2) to the fields the CI scripts and their tests read.
#
# Purpose: the fixtures in this directory are real Trivy output, but a full report carries every
# CVE description, reference list, CVSS vector, layer digest and the image history (0.6 to 1.8 MB
# per report). This filter keeps the report's shape and drops that bulk; it never invents a
# field or a value. Usage: jq -f trim.jq full-report.json > fixture.json
#
# Kept: SchemaVersion, Trivy.Version, CreatedAt, ArtifactName, ArtifactType, Metadata.OS, and per
# result Target, Class, Type and, for every vulnerability, the id, package, path, purl, versions,
# status, severity and title. A result without findings keeps no Vulnerabilities key, exactly as
# Trivy writes it.
{
  SchemaVersion,
  Trivy,
  CreatedAt,
  ArtifactName,
  ArtifactType,
  Metadata: {OS: .Metadata.OS},
  Results: [
    .Results[]?
    | {Target, Class, Type}
      + (if .Vulnerabilities then
           {Vulnerabilities: [
             .Vulnerabilities[]
             | {VulnerabilityID, PkgName, PkgPath, PkgIdentifier: {PURL: .PkgIdentifier.PURL},
                InstalledVersion, FixedVersion, Status, Severity, Title}
             | with_entries(select(.value != null))
           ]}
         else {} end)
  ]
}
